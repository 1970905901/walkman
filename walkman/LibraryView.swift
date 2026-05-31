import SwiftUI

enum LibraryRoute: Hashable {
    case playlist(UUID)
}

struct LibraryView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var history: PlayHistoryStore
    @State private var showCreate = false
    @State private var newName = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                HStack(spacing: 14) {
                    NavigationLink {
                        DownloadedView()
                    } label: {
                        LibraryShortcutCard(
                            icon: "arrow.down.circle.fill",
                            title: "已下载",
                            subtitle: "\(downloads.completedCount) 首 · \(downloads.folders.count) 个歌单",
                            gradient: [.accentColor, .accentColor.opacity(0.6)]
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        PlayHistoryView()
                    } label: {
                        LibraryShortcutCard(
                            icon: "clock.arrow.circlepath",
                            title: "播放历史",
                            subtitle: "\(history.tracks.count) 首",
                            gradient: [.orange, .pink]
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DS.Spacing.l)

                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(playlists.playlists) { p in
                            NavigationLink(value: p.id) {
                                PlaylistCard(playlist: p, tracks: playlists.tracks(in: p))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    playlists.deletePlaylist(p.id)
                                } label: {
                                    Label("删除歌单", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                } header: {
                    sectionHeader("歌单", subtitle: "\(playlists.playlists.count) 个")
                        .padding(.horizontal, DS.Spacing.l)
                }
            }
            .padding(.vertical, DS.Spacing.m)
        }
        .brandedSurface()
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: UUID.self) { id in
            if let p = playlists.playlists.first(where: { $0.id == id }) {
                PlaylistDetailView(playlistID: p.id)
            }
        }
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .playlist(let id):
                if let p = playlists.playlists.first(where: { $0.id == id }) {
                    PlaylistDetailView(playlistID: p.id)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
            }
        }
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("名称", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("创建") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = playlists.createPlaylist(name: n) }
                newName = ""
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(title).font(DS.Typography.sectionTitle)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

/// Half-width entry card used for the 已下载 / 播放历史 shortcuts at the top of 我的.
private struct LibraryShortcutCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

private struct PlaylistCard: View {
    let playlist: PlaylistMeta
    let tracks: [Track]

    private var coverURLs: [String?] {
        Array(tracks.prefix(4).map { $0.picURL })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverMosaic(urls: coverURLs)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(playlist.trackIDs.count) 首")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CoverMosaic: View {
    let urls: [String?]

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 2
            if urls.isEmpty {
                placeholder
            } else if urls.count == 1 {
                cover(urls[0], size: geo.size.width)
            } else {
                ZStack {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            cover(urls[safe: 0] ?? nil, size: s)
                            cover(urls[safe: 2] ?? nil, size: s)
                        }
                        VStack(spacing: 0) {
                            cover(urls[safe: 1] ?? nil, size: s)
                            cover(urls[safe: 3] ?? nil, size: s)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cover(_ url: String?, size: CGFloat) -> some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill().frame(width: size, height: size).clipped()
            default: placeholder.frame(width: size, height: size)
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(.tertiarySystemFill), Color(.quaternarySystemFill)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(Image(systemName: "music.note.list").font(.system(size: 32)).foregroundColor(.secondary.opacity(0.6)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Playlist Detail

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var playback: PlaybackEngine

    private var playlist: PlaylistMeta? {
        playlists.playlists.first(where: { $0.id == playlistID })
    }
    private var tracks: [Track] {
        guard let p = playlist else { return [] }
        return playlists.tracks(in: p)
    }

    var body: some View {
        if let p = playlist {
            List {
                Section {
                    HStack(spacing: 14) {
                        CoverMosaicCompact(urls: tracks.prefix(4).map { $0.picURL })
                            .frame(width: 110, height: 110)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.name).font(.title3.bold())
                            Text("\(tracks.count) 首")
                                .font(.subheadline).foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                Button {
                                    if let first = tracks.first {
                                        playback.play(track: first, in: tracks, startIndex: 0)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "play.fill")
                                        Text("播放全部")
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(tracks.isEmpty)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(tracks) { t in
                        TrackRow(track: t)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(track: t, in: tracks, startIndex: tracks.firstIndex { $0.id == t.id })
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .trackRowSwipe(t, onRemove: { playlists.remove(trackIDs: [t.id], from: p.id) })
                    }
                } header: {
                    Text("曲目").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(p.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("歌单不存在", systemImage: "trash")
        }
    }
}

private struct CoverMosaicCompact: View {
    let urls: [String?]
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 2
            if urls.compactMap({ $0 }).isEmpty {
                LinearGradient(colors: [.accentColor.opacity(0.5), .accentColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: 28)).foregroundColor(.white))
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        cover(urls[safe: 0] ?? nil, size: s)
                        cover(urls[safe: 2] ?? nil, size: s)
                    }
                    VStack(spacing: 0) {
                        cover(urls[safe: 1] ?? nil, size: s)
                        cover(urls[safe: 3] ?? nil, size: s)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }

    @ViewBuilder
    private func cover(_ url: String?, size: CGFloat) -> some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill().frame(width: size, height: size).clipped()
            default: Color(.tertiarySystemFill).frame(width: size, height: size)
            }
        }
    }
}

private extension ArraySlice where Element == String? {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

