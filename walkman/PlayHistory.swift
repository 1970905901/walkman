import SwiftUI
import Combine

/// Recently-played tracks, most-recent first. Recorded by PlaybackEngine via `onTrackPlayed`
/// and persisted to disk so history survives relaunches.
@MainActor
final class PlayHistoryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []

    private let url: URL
    private let maxEntries = 200

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.url = dir.appendingPathComponent("playHistory.json")
        load()
    }

    /// Move `track` to the top of history (dedup by id), capping the list length.
    func record(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        tracks.insert(track, at: 0)
        if tracks.count > maxEntries { tracks.removeLast(tracks.count - maxEntries) }
        save()
    }

    func remove(_ trackID: String) {
        tracks.removeAll { $0.id == trackID }
        save()
    }

    func clear() {
        tracks.removeAll()
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracks) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - 播放历史

struct PlayHistoryView: View {
    @EnvironmentObject var history: PlayHistoryStore
    @EnvironmentObject var playback: PlaybackEngine
    @State private var showClear = false

    var body: some View {
        List {
            if !history.tracks.isEmpty {
                // Section header: count + clear shortcut feel like a small toolbar
                // attached to the list, rather than a stripe of secondary text.
                Section {
                    ForEach(Array(history.tracks.enumerated()), id: \.element.id) { idx, t in
                        HStack(alignment: .center, spacing: 4) {
                            Text("\(idx + 1)")
                                .font(DS.Typo.numeric)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .frame(width: 28)
                            TrackRow(track: t)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { playback.play(track: t, in: history.tracks, startIndex: idx) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { history.remove(t.id) } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("最近播放")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                        Spacer()
                        Text("\(history.tracks.count) 首")
                            .font(DS.Typo.numeric)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandedSurface()
        .navigationTitle("播放历史")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !history.tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showClear = true } label: { Image(systemName: "trash") }
                }
            }
        }
        .overlay {
            if history.tracks.isEmpty {
                BrandedEmpty(icon: "clock.arrow.circlepath",
                             title: "还没有播放记录",
                             subtitle: "播放过的歌曲会出现在这里",
                             topPadding: 80)
            }
        }
        .confirmationDialog("清空播放历史?", isPresented: $showClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        }
    }
}
