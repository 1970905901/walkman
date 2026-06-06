import SwiftUI

// MARK: - iPad root
//
// Layout:
//   ┌──────────────────────────────────────────────┐
//   │ Sidebar (240pt)  │  TopBar                    │
//   │  - 浏览 grp       │ ─────────────────────────  │
//   │  - 我的音乐 grp   │  Detail (NavigationStack)  │
//   │  - 我的歌单 grp   │   - selected page         │
//   │                  │   - pushed detail (歌单/榜单)│
//   │  - 设置          │                            │
//   └──────────────────────────────────────────────┘
//
// MiniPlayer / PlayerView are full-screen overlays drawn by RootTabView's
// `overlays` builder above this view — IPadRootView itself doesn't draw them.

struct IPadRootView: View {
    /// Legacy callback kept for binary compatibility with RootTabView's wiring.
    /// On iPad we ignore it and own `showPlayer` locally so the full-screen
    /// player can replace just the content area while the bottom bar stays
    /// visible (mirrors QQ 音乐 桌面端 behavior).
    var onOpenPlayer: () -> Void = {}

    @AppStorage("ipad.selection") private var rawSelection: String = "home"
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showPlayer = false

    private var selection: Binding<IPadDestination> {
        Binding(
            get: { decode(rawSelection) },
            set: { encodeAndSet($0) }
        )
    }

    var body: some View {
        // 两种布局根据 showPlayer 切换:
        //   - false: HStack(sidebar, VStack(detail, bottomBar))  ← 浏览态,bottomBar 只在右侧
        //   - true:  VStack(playerFullWidth, bottomBar)          ← 全屏播放器,bottomBar 跨整宽
        // 这样浏览态时 bar 不会覆盖 sidebar,播放器态时 sidebar 消失 bar 自然跨整宽。
        Group {
            if showPlayer {
                VStack(spacing: 0) {
                    IPadPlayerView(onClose: {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            showPlayer = false
                        }
                    })
                    IPadBottomBar(
                        onOpenPlayer: { /* 已在播放器里 */ },
                        compactMode: true
                    )
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 0) {
                    IPadSidebar(selection: selection,
                                 onOpenSettings: { showSettings = true })
                    VStack(spacing: 0) {
                        detail
                        IPadBottomBar(
                            onOpenPlayer: {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                    showPlayer = true
                                }
                            },
                            compactMode: false
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(IPad.Color.contentBackground)
                }
            }
        }
        .background(IPad.Color.contentBackground)
        // Reset push stack when the user picks a different sidebar entry
        // (going from "排行榜" to "歌单" shouldn't keep a 排行榜 detail pushed).
        .onChange(of: rawSelection) { _, _ in
            path = NavigationPath()
        }
        // MARK: - 针对 Mac Catalyst 优化设置弹窗交互
        #if targetEnvironment(macCatalyst)
        .popover(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
                .frame(width: 520, height: 640) // 为 Mac 桌面端提供一个固定且精致的设置窗口尺寸
        }
        #else
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
    }


    @ViewBuilder
    private var detail: some View {
        NavigationStack(path: $path) {
            currentRoot
                .navigationDestination(for: IPadDestination.self) { dest in
                    rootFor(dest)
                }
                .navigationDestination(for: SonglistInfo.self) { info in
                    SonglistDetailView(info: info)
                }
                .navigationDestination(for: BoardInfo.self) { board in
                    BoardDetailView(board: board)
                }
                .navigationDestination(for: UUID.self) { id in
                    PlaylistDetailView(playlistID: id)
                }
        }
    }

    /// Top-level root for the currently selected sidebar entry. Subroutes are
    /// pushed onto `path` by the rendered view (e.g. tapping a card in
    /// IPadHomeView appends a `SonglistInfo` which routes here through
    /// `navigationDestination(for: SonglistInfo.self)`).
    @ViewBuilder
    private var currentRoot: some View {
        switch decode(rawSelection) {
        case .home:        IPadHomeView(path: $path)
        case .search:      IPadSearchView()
        case .leaderboard: IPadLeaderboardView(path: $path)
        case .songlist:    IPadSonglistView(path: $path)
        case .library:     IPadLibraryView(path: $path)
        case .downloads:   DownloadedView()
        case .history:     PlayHistoryView()
        case .stats:       StatsView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        }
    }

    /// Lets a sidebar entry be re-routed via path append (rare; mostly used
    /// when the home view's "查看全部" button pushes IPadDestination.songlist).
    @ViewBuilder
    private func rootFor(_ dest: IPadDestination) -> some View {
        switch dest {
        case .home:        IPadHomeView(path: $path)
        case .search:      IPadSearchView()
        case .leaderboard: IPadLeaderboardView(path: $path)
        case .songlist:    IPadSonglistView(path: $path)
        case .library:     IPadLibraryView(path: $path)
        case .downloads:   DownloadedView()
        case .history:     PlayHistoryView()
        case .stats:       StatsView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        }
    }

    // MARK: - Selection codec
    //
    // `@AppStorage` only handles plain types — encode IPadDestination as a
    // short string. Playlist UUIDs are special-cased ("playlist:<uuid>").

    private func decode(_ raw: String) -> IPadDestination {
        if raw.hasPrefix("playlist:") {
            let uuid = String(raw.dropFirst("playlist:".count))
            if let id = UUID(uuidString: uuid) {
                return .playlist(id)
            }
        }
        switch raw {
        case "home":        return .home
        case "search":      return .search
        case "leaderboard": return .leaderboard
        case "songlist":    return .songlist
        case "library":     return .library
        case "downloads":   return .downloads
        case "history":     return .history
        case "stats":       return .stats
        default:            return .home
        }
    }

    private func encodeAndSet(_ dest: IPadDestination) {
        switch dest {
        case .home:        rawSelection = "home"
        case .search:      rawSelection = "search"
        case .leaderboard: rawSelection = "leaderboard"
        case .songlist:    rawSelection = "songlist"
        case .library:     rawSelection = "library"
        case .downloads:   rawSelection = "downloads"
        case .history:     rawSelection = "history"
        case .stats:       rawSelection = "stats"
        case .playlist(let id): rawSelection = "playlist:\(id.uuidString)"
        }
    }
}
