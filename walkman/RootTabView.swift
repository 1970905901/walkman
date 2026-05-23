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

struct RootTabView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var settings: SettingsStore
    @State private var showPlayer = false
    @State private var leaderboardPath = NavigationPath()
    @State private var songlistPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @AppStorage("ui.activeTab") private var activeTab: Int = 0
    @AppStorage("debug.showPlayer") private var debugShowPlayer: Bool = false
    @AppStorage("debug.openScreen") private var debugOpenScreen: String = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $activeTab) {
                NavigationStack { SearchView() }
                    .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                    .tag(0)
                NavigationStack(path: $leaderboardPath) { LeaderboardView() }
                    .tabItem { Label("排行榜", systemImage: "chart.bar.fill") }
                    .tag(1)
                NavigationStack(path: $songlistPath) { SonglistView() }
                    .tabItem { Label("歌单", systemImage: "rectangle.stack.fill") }
                    .tag(2)
                NavigationStack(path: $libraryPath) { LibraryView() }
                    .tabItem { Label("我的", systemImage: "music.note.list") }
                    .tag(3)
            }
            if playback.currentTrack != nil {
                MiniPlayer(onTap: { showPlayer = true })
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom))
            }
            if let err = playback.lastError {
                ErrorBanner(text: err, tone: .warning) { playback.lastError = nil }
                    .padding(.bottom, playback.currentTrack != nil ? 110 : 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let notice = playback.cascadeNotice, settings.showDebugNotices {
                ErrorBanner(text: notice, tone: .info) { playback.cascadeNotice = nil }
                    .padding(.bottom, playback.currentTrack != nil ? 110 : 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: playback.lastError)
        .animation(.spring(duration: 0.3), value: playback.cascadeNotice)
        .animation(.spring(duration: 0.3), value: playback.currentTrack?.id)
        .sheet(isPresented: $showPlayer) {
            PlayerView()
        }
        .task {
            // Debug auto-navigation (open a specific screen after launch).
            if debugOpenScreen.hasPrefix("leaderboard") {
                activeTab = 1   // 排行榜 tab
                let parts = debugOpenScreen.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2,
                   let board = Boards.allBoards.first(where: { $0.id == parts[1] }) {
                    leaderboardPath.append(board)
                }
            } else if debugOpenScreen.hasPrefix("songlist") {
                activeTab = 2   // 歌单 tab
                let parts = debugOpenScreen.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let pid = parts[1]
                    songlistPath.append(SonglistInfo(id: pid, source: .kw, name: "Loading…", author: "", picURL: nil, trackCount: nil, playCount: nil))
                }
            }
            guard debugShowPlayer else { return }
            for _ in 0..<150 {  // 150 × 200ms = 30s budget so script resolve has time to finish
                if playback.currentTrack != nil && playback.isPlaying {
                    showPlayer = true
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
