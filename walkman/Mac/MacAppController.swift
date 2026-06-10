import Foundation
import UIKit
import Combine
import ObjectiveC.runtime

// MARK: - UIApplicationDelegate

/// 注入到 walkmanApp 的 @UIApplicationDelegateAdaptor。本身在 iOS 上是无作用的占位,
/// 主要价值在于 Mac Catalyst —— 实现了 AppKit 才有的 `applicationShouldTerminateAfterLastWindowClosed:`
/// (返回 NO ⇒ 红色关闭按钮只是关窗口,app 进程继续跑),以及 `applicationShouldHandleReopen:`
/// (点 Dock 图标时让窗口回来)。Catalyst runtime 会自动把 NSApplicationDelegate 的调用转发
/// 到我们的 UIApplicationDelegate 实例上,前提是 selector 一字不差地暴露出来。
final class WalkmanAppDelegate: NSObject, UIApplicationDelegate {
    #if targetEnvironment(macCatalyst)
    @objc(applicationShouldTerminateAfterLastWindowClosed:)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: Any) -> Bool {
        // 状态栏图标一直在,用户随时可以从状态栏菜单"打开播放器"把窗口叫回来。
        return false
    }

    @objc(applicationShouldHandleReopen:hasVisibleWindows:)
    func applicationShouldHandleReopen(_ sender: Any, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MacStatusBarController.shared.showMainWindow()
        }
        return true
    }
    #endif
}

// MARK: - Notification names (status bar → views)

extension Notification.Name {
    static let walkmanMacOpenSearch = Notification.Name("walkmanMacOpenSearch")
    static let walkmanMacOpenPlayer = Notification.Name("walkmanMacOpenPlayer")
}

#if targetEnvironment(macCatalyst)

// MARK: - MacStatusBarController

/// 维护 Mac 状态栏(menu bar)右侧的图标:显示当前歌曲(长文本走滚动),配一个下拉菜单
/// 控制播放/暂停、上一首/下一首、搜索、打开播放器、退出。
///
/// 实现策略:Mac Catalyst 不能直接 `import AppKit`,所以所有 AppKit 类(NSStatusBar、
/// NSStatusItem、NSMenu、NSMenuItem、NSApplication、NSWindow)都通过:
///   - `NSClassFromString("...")` 拿类对象
///   - 对返回值用 `setValue(_:forKey:)` / `value(forKey:)` 读写普通属性
///   - 要传 `SEL` 参数的方法(setAction:、activateIgnoringOtherApps: 等)用
///     `class_getInstanceMethod` + `unsafeBitCast` 拿到带 C 调用约定的 IMP 直接调
///
/// 这套桥接 OC API 上下文的损耗不大,生命周期 stick 在 shared singleton 上 ——
/// 状态栏项跟 app 进程同生死。
@MainActor
final class MacStatusBarController: NSObject {
    static let shared = MacStatusBarController()

    // MARK: AppKit handles (stored as NSObject since the real types aren't visible)
    private var statusItem: NSObject?
    private var statusItemButton: NSObject?
    private var menu: NSObject?
    private var playPauseItem: NSObject?
    private var nextItem: NSObject?
    private var prevItem: NSObject?
    private var searchItem: NSObject?
    private var openPlayerItem: NSObject?
    private var quitItem: NSObject?

    // MARK: State
    private weak var playback: PlaybackEngine?
    private var cancellables = Set<AnyCancellable>()
    private var fullText: String = "随便听"
    private var scrollIdx: Int = 0
    private var scrollTimer: Timer?
    private var hasTrack: Bool = false
    private var isPlaying: Bool = false
    private var installed = false

    /// 一个屏字符数上限,超过就滚动。中英文混排按 unicode scalar 算,够用。
    private let displayWidth: Int = 24
    /// 滚动节奏 —— 0.35s/步,既能看清楚又不会太燥。
    private let scrollInterval: TimeInterval = 0.35

    private override init() { super.init() }

    // MARK: - Install

    func install(playback: PlaybackEngine) {
        guard !installed else { return }
        installed = true
        self.playback = playback
        createStatusItem()
        createMenu()
        observePlayback()
        startScrollTimer()
        refresh(track: playback.currentTrack, isPlaying: playback.isPlaying)
    }

    // MARK: - AppKit bridging helpers

    /// `NSClassFromString` 拿到的类做一下兜底转换。
    private static func cls(_ name: String) -> NSObject.Type? {
        NSClassFromString(name) as? NSObject.Type
    }

    /// `[NSApplication sharedApplication]`。
    private func nsApp() -> NSObject? {
        Self.cls("NSApplication")?.value(forKey: "sharedApplication") as? NSObject
    }

    /// 调用带 `SEL` 参数的方法 —— `setValue(forKey:)` 处理不了 SEL,只能走 IMP。
    private func invokeSelectorSetter(
        on obj: NSObject,
        setter: String,
        value: Selector,
        klass: AnyClass
    ) {
        let sel = NSSelectorFromString(setter)
        guard let method = class_getInstanceMethod(klass, sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (NSObject, Selector, Selector) -> Void
        unsafeBitCast(imp, to: Fn.self)(obj, sel, value)
    }

    /// 调用带 `BOOL` 参数的方法(activateIgnoringOtherApps: 等)。
    private func invokeBoolSetter(
        on obj: NSObject,
        selector: String,
        value: Bool,
        klass: AnyClass
    ) {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(klass, sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (NSObject, Selector, ObjCBool) -> Void
        unsafeBitCast(imp, to: Fn.self)(obj, sel, ObjCBool(value))
    }

    // MARK: - Status item construction

    private func createStatusItem() {
        guard let barClass = Self.cls("NSStatusBar"),
              let bar = barClass.value(forKey: "systemStatusBar") as? NSObject else { return }
        // NSVariableStatusItemLength = -1.0 —— 让 AppKit 跟着 button 的 title 算宽度。
        guard let item = bar.perform(
            NSSelectorFromString("statusItemWithLength:"),
            with: NSNumber(value: -1.0)
        )?.takeUnretainedValue() as? NSObject else { return }
        statusItem = item
        statusItemButton = item.value(forKey: "button") as? NSObject
        // 初始 placeholder,避免在 createMenu / refresh 之前 button 空白。
        statusItemButton?.setValue("♪", forKey: "title")
    }

    // MARK: - Menu construction

    private func createMenu() {
        guard let menuClass = Self.cls("NSMenu"),
              let m = menuClass.init() as? NSObject else { return }
        menu = m

        playPauseItem  = addItem(to: m, title: "播放",     action: #selector(_playPauseTapped))
        prevItem       = addItem(to: m, title: "上一首",   action: #selector(_prevTapped))
        nextItem       = addItem(to: m, title: "下一首",   action: #selector(_nextTapped))
        addSeparator(to: m)
        searchItem     = addItem(to: m, title: "搜索",      action: #selector(_searchTapped))
        openPlayerItem = addItem(to: m, title: "打开播放器", action: #selector(_openPlayerTapped))
        addSeparator(to: m)
        quitItem       = addItem(to: m, title: "退出 随便听", action: #selector(_quitTapped))

        statusItem?.setValue(m, forKey: "menu")
    }

    @discardableResult
    private func addItem(to menu: NSObject, title: String, action: Selector) -> NSObject? {
        guard let itemClass = Self.cls("NSMenuItem"),
              let item = itemClass.init() as? NSObject else { return nil }
        item.setValue(title, forKey: "title")
        item.setValue(self, forKey: "target")
        invokeSelectorSetter(on: item, setter: "setAction:", value: action, klass: itemClass)
        _ = menu.perform(NSSelectorFromString("addItem:"), with: item)
        return item
    }

    private func addSeparator(to menu: NSObject) {
        guard let itemClass = Self.cls("NSMenuItem"),
              let sep = itemClass.perform(NSSelectorFromString("separatorItem"))?
                                  .takeUnretainedValue() as? NSObject else { return }
        _ = menu.perform(NSSelectorFromString("addItem:"), with: sep)
    }

    // MARK: - Playback observation

    private func observePlayback() {
        guard let playback else { return }
        Publishers.CombineLatest(playback.$currentTrack, playback.$isPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track, playing in
                self?.refresh(track: track, isPlaying: playing)
            }
            .store(in: &cancellables)
    }

    private func refresh(track: Track?, isPlaying: Bool) {
        let newText: String
        if let track {
            let singer = track.singer.isEmpty ? "未知" : track.singer
            newText = "\(track.name) - \(singer)"
            hasTrack = true
        } else {
            newText = "随便听"
            hasTrack = false
        }
        // 只在文字真的变了(切歌 / 停掉)的时候重置滚动位置 —— 单纯按 play/pause
        // 不重置,这样从暂停恢复播放时能从原位置接着滚,不会突然跳回开头。
        if newText != fullText {
            fullText = newText
            scrollIdx = 0
        }
        self.isPlaying = isPlaying
        updateDisplay()
    }

    // MARK: - Title scrolling

    private func startScrollTimer() {
        scrollTimer?.invalidate()
        let timer = Timer(timeInterval: scrollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceScroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func advanceScroll() {
        // 暂停 / 没歌时:freeze。timer 还在转但 advance 是 no-op,开销可以忽略。
        // 跟用户对 menu bar 标题的直觉一致 —— 没在播放就不动,看着才稳。
        guard isPlaying else { return }
        let total = fullText.unicodeScalars.count
        guard total > displayWidth else {
            if scrollIdx != 0 {
                scrollIdx = 0
                updateDisplay()
            }
            return
        }
        // 走 (内容 + "   " 间隔) 的循环,看起来不会突然跳。
        scrollIdx = (scrollIdx + 1) % (total + 3)
        updateDisplay()
    }

    private func updateDisplay() {
        let title: String = {
            let scalars = Array(fullText.unicodeScalars)
            if scalars.count <= displayWidth { return fullText }
            let pad: [Unicode.Scalar] = Array("   ".unicodeScalars)
            let doubled = scalars + pad + scalars
            let start = scrollIdx
            let end = min(start + displayWidth, doubled.count)
            return String(String.UnicodeScalarView(doubled[start..<end]))
        }()
        statusItemButton?.setValue(title, forKey: "title")

        // 菜单项文案 / 灰态联动 ——
        // 有歌:播放 ⇄ 暂停 跟实际状态对齐;前三项可点
        // 无歌:菜单第一项固定显示"播放"且置灰,前三项全灰
        playPauseItem?.setValue(isPlaying ? "暂停" : "播放", forKey: "title")
        playPauseItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        prevItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
        nextItem?.setValue(NSNumber(value: hasTrack), forKey: "enabled")
    }

    // MARK: - Window control

    /// 把主窗口叫回来 + 把 app 提到前台。状态栏菜单"搜索""打开播放器"以及
    /// Dock 点击 reopen 都用这个。
    func showMainWindow() {
        guard let app = nsApp(),
              let windows = app.value(forKey: "windows") as? [NSObject] else { return }
        if let win = windows.first {
            _ = win.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
        }
        invokeBoolSetter(on: app, selector: "activateIgnoringOtherApps:",
                         value: true, klass: type(of: app))
    }

    // MARK: - Menu actions (called from AppKit via setAction)

    @objc private func _playPauseTapped() {
        playback?.togglePlayPause()
    }

    @objc private func _prevTapped() {
        playback?.previous()
    }

    @objc private func _nextTapped() {
        playback?.next()
    }

    @objc private func _searchTapped() {
        showMainWindow()
        NotificationCenter.default.post(name: .walkmanMacOpenSearch, object: nil)
    }

    @objc private func _openPlayerTapped() {
        showMainWindow()
        NotificationCenter.default.post(name: .walkmanMacOpenPlayer, object: nil)
    }

    @objc private func _quitTapped() {
        guard let app = nsApp() else { return }
        _ = app.perform(NSSelectorFromString("terminate:"), with: nil)
    }
}

#else

// iOS / iPad-native: provide a no-op so the rest of the code can call install()
// unconditionally without #if at every site.
@MainActor
final class MacStatusBarController: NSObject {
    static let shared = MacStatusBarController()
    private override init() { super.init() }
    func install(playback: PlaybackEngine) {}
    func showMainWindow() {}
}

#endif
