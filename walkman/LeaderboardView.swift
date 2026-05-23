import SwiftUI

/// Two-level view: list of boards (排行榜) → board detail (songs of that board).
/// Supports multiple platforms via segmented picker at top.
struct LeaderboardView: View {
    @AppStorage("ui.boardSource") private var selectedSourceRaw: String = SourceID.kw.rawValue
    @State private var boards: [BoardInfo] = []
    @State private var isLoading = false

    private var selectedSource: SourceID {
        get { SourceID(rawValue: selectedSourceRaw) ?? .kw }
    }
    private var selectedSourceBinding: Binding<SourceID> {
        Binding(get: { selectedSource }, set: { selectedSourceRaw = $0.rawValue })
    }

    private var supportedSources: [SourceID] { Boards.all.map { $0.source } }

    var body: some View {
        VStack(spacing: 0) {
            if supportedSources.count > 1 {
                ChipBar(items: supportedSources, title: { $0.displayName }, selection: selectedSourceBinding)
                    .padding(.top, DS.Spacing.s)
                    .padding(.bottom, DS.Spacing.xs)
            }
            if isLoading && boards.isEmpty {
                ProgressView().padding(.top, 60)
                Spacer()
            } else {
                List {
                    Section {
                        ForEach(boards) { board in
                            NavigationLink(value: board) {
                                HStack(spacing: 12) {
                                    BoardThumbnail(board: board)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(board.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .lineLimit(1)
                                        HStack(spacing: 5) {
                                            SourceChip(source: board.source)
                                            Text("Top 100").font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: BoardInfo.self) { board in
            BoardDetailView(board: board)
        }
        .task(id: selectedSource) {
            await load()
        }
    }

    private func load() async {
        guard let svc = Boards.service(for: selectedSource) else { return }
        boards = svc.list  // immediate placeholder
        isLoading = true
        defer { isLoading = false }
        boards = await svc.fetchBoards()
    }
}

private struct BoardThumbnail: View {
    let board: BoardInfo
    var body: some View {
        AsyncImage(url: board.picURL.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default:
                LinearGradient(colors: [board.source.tint, board.source.tint.opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(
                    Text(String(board.name.prefix(2)))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1).minimumScaleFactor(0.5)
                )
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

struct BoardDetailView: View {
    let board: BoardInfo
    @EnvironmentObject var playback: PlaybackEngine
    @State private var tracks: [Track] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var trackToAdd: Track?

    var body: some View {
        Group {
            if isLoading && tracks.isEmpty {
                ProgressView().padding(.top, 60)
            } else if let error, tracks.isEmpty {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                List {
                    Section {
                        HStack(spacing: 14) {
                            BoardThumbnail(board: board)
                                .frame(width: 96, height: 96)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(board.name).font(.title3.bold()).lineLimit(2)
                                Text("\(tracks.count) 首歌曲").font(.subheadline).foregroundColor(.secondary)
                                if !tracks.isEmpty {
                                    Button {
                                        playback.play(track: tracks[0], in: tracks, startIndex: 0)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "play.fill")
                                            Text("播放全部")
                                        }
                                        .font(.system(size: 13, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, t in
                            HStack(alignment: .center, spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28)
                                TrackRow(track: t)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(track: t, in: tracks, startIndex: idx)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button { trackToAdd = t } label: { Label("收藏", systemImage: "plus.circle") }
                                    .tint(.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistSheet(track: track)
        }
        .task {
            guard tracks.isEmpty, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            guard let svc = Boards.service(for: board.source) else { return }
            do {
                tracks = try await svc.fetchTracks(bangid: board.bangid, page: 1)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
