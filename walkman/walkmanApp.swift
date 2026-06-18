import SwiftUI
import UIKit

@main
struct walkmanApp: App {
    /// Mac Catalyst 关掉"窗口关闭 = 退出 app"行为靠 WalkmanAppDelegate 暴露的
    /// `applicationShouldTerminateAfterLastWindowClosed:` —— Catalyst runtime
    /// 会自动把 NSApplicationDelegate 调用转发到我们的 UIApplicationDelegate。
    @UIApplicationDelegateAdaptor(WalkmanAppDelegate.self) private var appDelegate

    @StateObject private var playback: PlaybackEngine
    @StateObject private var sources: SourceManager
    @StateObject private var playlists: PlaylistStore
    @StateObject private var scripts: ScriptStore
    @StateObject private var settings: SettingsStore
    @StateObject private var downloads: DownloadStore
    @StateObject private var history: PlayHistoryStore
    @StateObject private var sleepTimer = SleepTimer()
    @StateObject private var recents = RecentTracksRecorder()
    @StateObject private var eq = EQStore()
    /// 发现页 (IPadHomeView) 的内存缓存 —— 在 walkmanApp 顶层 @StateObject
    /// 一次,这样侧边栏切走 / NavigationStack pop 重建视图时缓存还在,
    /// 不会每次回发现页都白屏 + 重新拉网络。
    @StateObject private var homeFeed = HomeFeedStore()
    /// Bridges Darwin notifications from the widget's transport-button intents
    /// back into PlaybackEngine. Init-once, no UI state.
    private let commandBridge = CommandBridge()
    /// Cold-launch brand splash; auto-dismissed shortly after the root scene
    /// appears so the user lands on the app proper without seeing a fresh blank
    /// frame between system LaunchScreen and content.
    @State private var showSplash = true

    init() {
        AppNavBarAppearance.applyDefault()
        // Stores are built here (not as inline @StateObject defaults) so they
        // can be registered into AppServices during a background launch —
        // Siri AudioPlaybackIntents run App.init but never connect a scene,
        // so registration in `.task` would come too late.
        let playback = PlaybackEngine()
        let sources = SourceManager()
        let playlists = PlaylistStore()
        let scripts = ScriptStore()
        let settings = SettingsStore()
        let downloads = DownloadStore.shared
        let history = PlayHistoryStore()
        _playback = StateObject(wrappedValue: playback)
        _sources = StateObject(wrappedValue: sources)
        _playlists = StateObject(wrappedValue: playlists)
        _scripts = StateObject(wrappedValue: scripts)
        _settings = StateObject(wrappedValue: settings)
        _downloads = StateObject(wrappedValue: downloads)
        _history = StateObject(wrappedValue: history)
        AppServices.shared.register(
            playback: playback, sources: sources, playlists: playlists,
            scripts: scripts, settings: settings, downloads: downloads,
            history: history)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    // Use the AccentColor asset (light + dark variants) instead of the
                    // raw `brandStart` constant — the latter is locked to the light
                    // shade and renders too dark on a black backdrop. iOS 26 still
                    // needs `.tint(...)` explicitly because the system no longer
                    // auto-pulls AccentColor for every control.
                    .tint(Color("AccentColor"))
                    .environmentObject(playback)
                    .environmentObject(sources)
                    .environmentObject(playlists)
                    .environmentObject(scripts)
                    .environmentObject(settings)
                    .environmentObject(downloads)
                    .environmentObject(history)
                    .environmentObject(sleepTimer)
                    .environmentObject(eq)
                    .environmentObject(homeFeed)

                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                sleepTimer.bind(to: playback)
                recents.bind(to: playback)
                commandBridge.start(playback: playback, sources: sources)
                playback.bindEQ(eq)
                // Mac 状态栏图标 + 下拉菜单 —— iOS 下是 no-op stub。
                // 必须在 PlaybackEngine 已经创建之后 install,这样 Combine
                // 订阅当前歌曲 / 播放状态时直接拿到 publisher。
                MacStatusBarController.shared.install(playback: playback)
                await AppServices.shared.bootstrapIfNeeded()
                // Splash lives for ~900ms — long enough for the spring reveal,
                // short enough not to feel like a wait.
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeInOut(duration: 0.32)) { showSplash = false }
            }
            // 👇 新增：在组件挂载时隐藏 Mac 端的标题栏文字
            .onAppear {
                #if targetEnvironment(macCatalyst)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                }
                #endif
            }
        }
    }

}

// MARK: - App-level UINavigationBar baseline

/// One source of truth for the app's UINavigationBar appearance.
///
/// Any screen that temporarily overrides `UINavigationBar.appearance()`
/// (e.g. `SettingsView` swaps to a transparent bar while it's open) MUST call
/// `applyDefault()` in `.onDisappear` to put the baseline back. Restoring to
/// an invented "brand red" value (the previous bug) poisoned every sheet
/// presented afterwards because UIKit appearance proxies are global state.
enum AppNavBarAppearance {
    /// Rounded inline titles + PingFang large titles to give Chinese headings
    /// real character (default SF Pro renders 汉字 with the system fallback,
    /// which looks generic). Tint stays driven by AccentColor.
    static func applyDefault() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        let inlineFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
        let largeFont = UIFont(name: "PingFangSC-Semibold", size: 32)
            ?? UIFont.systemFont(ofSize: 32, weight: .bold)
        nav.titleTextAttributes = [.font: inlineFont]
        nav.largeTitleTextAttributes = [.font: largeFont]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}
