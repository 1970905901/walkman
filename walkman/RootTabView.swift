import SwiftUI

struct ErrorBanner: View {
    let text: String
    var tone: Tone = .warning
    let onDismiss: () -> Void

    enum Tone { case warning, info }
    private var accent: Color { tone == .info ? .blue : .orange }
    private var icon: String { tone == .info ? "info.circle.fill" : "exclamationmark.triangle.fill" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(accent)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .lineLimit(3)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// Identifies the four iPhone tabs. `WalkmanSection.title` is the short Chinese
/// label used in the tab bar. iPad/Mac do NOT use this — they have their own
/// navigation models under `walkman/iPad/` and `walkman/Mac/`.
enum WalkmanSection: String, Hashable, CaseIterable, Identifiable {
    case search, leaderboard, songlist, library
    var id: String { rawValue }

    var title: String {
        switch self {
        case .search:      return "搜索"
        case .leaderboard: return "排行榜"
        case .songlist:    return "歌单"
        case .library:     return "我的"
        }
    }
    var systemImage: String {
        switch self {
        case .search:      return "magnifyingglass"
        case .leaderboard: return "chart.bar.fill"
        case .songlist:    return "rectangle.stack.fill"
        case .library:     return "music.note.list"
        }
    }
    /// Legacy integer tag — keeps `@AppStorage("ui.activeTab")` portable.
    var tag: Int {
        switch self {
        case .search: 0; case .leaderboard: 1; case .songlist: 2; case .library: 3
        }
    }
    static func from(tag: Int) -> WalkmanSection {
        WalkmanSection.allCases.first(where: { $0.tag == tag }) ?? .search
    }
}

/// Root view. Dispatches between three completely independent layouts:
///
/// - **iPhone (compact size class)** → `phoneTabs` (existing TabView UI)
/// - **iPad (regular size class, not Catalyst)** → `IPadRootView` (under `walkman/iPad/`)
/// - **Mac Catalyst** → `MacRootView` (under `walkman/Mac/`)
///
/// Per user request these three layouts are NOT trying to share view bodies via
/// sizeClass branches inside SearchView/LibraryView/etc. Each platform owns its
/// own visual language. Shared layer = models, stores, playback, design tokens,
/// resolvers — anything that isn't a screen.
struct RootTabView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var showPlayer = false
    @State private var leaderboardPath = NavigationPath()
    @State private var songlistPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @AppStorage("ui.activeTab") private var activeTab: Int = 0

    /// True when the binary is running under Mac Catalyst. Detected at runtime
    /// rather than `#if targetEnvironment(macCatalyst)` so a single build can
    /// branch correctly at the view layer.
    private var isCatalyst: Bool {
        ProcessInfo.processInfo.isMacCatalystApp
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isCatalyst {
                MacRootView(onOpenPlayer: openPlayer)
            } else if hSize == .compact {
                phoneTabs
            } else {
                IPadRootView(onOpenPlayer: openPlayer)
            }
            overlays
        }
    }

    /// Show the full PlayerView with the standard spring animation. Passed to
    /// IPadRootView's bottom bar so tapping the cover/title in the QQ-style
    /// bar opens the same modal player the iPhone MiniPlayer opens.
    private func openPlayer() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            showPlayer = true
        }
    }

    // MARK: - iPhone (compact)

    private var phoneTabs: some View {
        TabView(selection: $activeTab) {
            NavigationStack(path: $searchPath) { SearchView() }
                .miniPlayerInset()
                .tabItem { Label(WalkmanSection.search.title, systemImage: WalkmanSection.search.systemImage) }
                .tag(WalkmanSection.search.tag)
            NavigationStack(path: $leaderboardPath) { LeaderboardView() }
                .miniPlayerInset()
                .tabItem { Label(WalkmanSection.leaderboard.title, systemImage: WalkmanSection.leaderboard.systemImage) }
                .tag(WalkmanSection.leaderboard.tag)
            NavigationStack(path: $songlistPath) { SonglistView() }
                .miniPlayerInset()
                .tabItem { Label(WalkmanSection.songlist.title, systemImage: WalkmanSection.songlist.systemImage) }
                .tag(WalkmanSection.songlist.tag)
            NavigationStack(path: $libraryPath) { LibraryView() }
                .miniPlayerInset()
                .tabItem { Label(WalkmanSection.library.title, systemImage: WalkmanSection.library.systemImage) }
                .tag(WalkmanSection.library.tag)
        }
    }

    // MARK: - Overlays (mini player, error banner, full player)

    @ViewBuilder
    private var overlays: some View {
        // iPhone-only floating MiniPlayer. iPad/Mac use a full-width bottom
        // bar (IPadBottomBar) rendered inside IPadRootView, so a floating
        // overlay here would just stack on top of it and look duplicated.
        if playback.currentTrack != nil, hSize == .compact, !isCatalyst {
            MiniPlayer(onTap: openPlayer)
                .padding(.bottom, 50)
                .transition(.move(edge: .bottom))
                .opacity(showPlayer ? 0 : 1)
                .animation(.spring(duration: 0.3), value: playback.currentTrack?.id)
        }
        if let err = playback.lastError {
            ErrorBanner(text: err, tone: .warning) { playback.lastError = nil }
                .padding(.bottom, playback.currentTrack != nil ? 110 : 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: playback.lastError)
        } else if let notice = playback.cascadeNotice, settings.showDebugNotices {
            ErrorBanner(text: notice, tone: .info) { playback.cascadeNotice = nil }
                .padding(.bottom, playback.currentTrack != nil ? 110 : 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: playback.cascadeNotice)
        }

        // PlayerView overlay only fires for iPhone (compact). iPad/Mac own
        // their player as a content-area swap inside IPadRootView so the
        // persistent IPadBottomBar stays visible like QQ 音乐 桌面端.
        if showPlayer, hSize == .compact, !isCatalyst {
            PlayerView(onClose: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    showPlayer = false
                }
            })
            .transition(.move(edge: .bottom))
            .zIndex(10)
        }
    }
}
