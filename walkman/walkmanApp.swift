import SwiftUI
import UIKit

@main
struct walkmanApp: App {
    /// Mac Catalyst 关掉"窗口关闭 = 退出 app"行为靠 WalkmanAppDelegate 暴露的
    /// `applicationShouldTerminateAfterLastWindowClosed:` —— Catalyst runtime
    /// 会自动把 NSApplicationDelegate 调用转发到我们的 UIApplicationDelegate。
    @UIApplicationDelegateAdaptor(WalkmanAppDelegate.self) private var appDelegate

    @StateObject private var playback = PlaybackEngine()
    @StateObject private var sources = SourceManager()
    @StateObject private var playlists = PlaylistStore()
    @StateObject private var scripts = ScriptStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var downloads = DownloadStore.shared
    @StateObject private var history = PlayHistoryStore()
    @StateObject private var sleepTimer = SleepTimer()
    @StateObject private var recents = RecentTracksRecorder()
    @StateObject private var eq = EQStore()
    /// Bridges Darwin notifications from the widget's transport-button intents
    /// back into PlaybackEngine. Init-once, no UI state.
    private let commandBridge = CommandBridge()
    /// Cold-launch brand splash; auto-dismissed shortly after the root scene
    /// appears so the user lands on the app proper without seeing a fresh blank
    /// frame between system LaunchScreen and content.
    @State private var showSplash = true

    init() {
        AppNavBarAppearance.applyDefault()
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
                await bootstrap()
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
                    
                    // 如果你希望标题栏完全透明，融合你的 ZStack 背景，可以解开下面这行的注释：
                    // titlebar.toolbar = nil
                }
                #endif
            }
        }
    }

    private func bootstrap() async {
        sources.fallbackEnabled = settings.enableDirectFallback
        // Downloads reuse the same URL resolution as playback (script → other-source → direct).
        downloads.urlResolver = { [sources] track, quality in
            try await sources.resolveMusicURL(track: track, quality: quality).url
        }
        // 下载完成后写 metadata 时用 —— 跟 PlaybackEngine 共用 LyricsFetcher 的缓存。
        downloads.lyricsResolver = { [sources] track in
            await LyricsFetcher.shared.fetch(for: track, sources: sources)
        }
        playback.setURLResolver { [sources, settings, playback, downloads] track in
            // Prefer a local downloaded file — plays offline and skips the network entirely.
            if let local = await MainActor.run(body: { downloads.localURL(for: track.id) }) {
                let q = await MainActor.run { downloads.quality(for: track.id) } ?? .k320
                return ResolvedTrack(url: local, origin: .localFile, quality: q, warning: nil)
            }
            sources.fallbackEnabled = settings.enableDirectFallback
            // `qualityCap` is set by PlaybackEngine when AVPlayer rejects a higher format
            // (e.g. 24-bit Hi-Res FLAC). When set, we resolve at the lower quality instead.
            let q = await MainActor.run { playback.qualityCap } ?? settings.preferredQuality
            return try await sources.resolveMusicURL(track: track, quality: q)
        }
        // Synced lyric line shown in the CarPlay/lock-screen album field.
        playback.setLyricsResolver { [sources] track in
            await LyricsFetcher.shared.fetch(for: track, sources: sources)
        }
        // Record every track that starts playing into the play-history list.
        playback.onTrackPlayed = { [history] track in history.record(track) }
        for s in scripts.scripts where s.enabled {
            await sources.load(script: s)
        }
        // Bring back the queue + position from the previous session (paused, no autoplay).
        playback.restoreLastSession()
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
