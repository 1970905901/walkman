import SwiftUI

enum LibraryRoute: Hashable {
    case playlist(UUID)
}

struct LibraryView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var playback: PlaybackEngine
    @State private var showCreate = false
    @State private var newName = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                quickActions
                    .padding(.horizontal, DS.Spacing.l)

                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(playlists.playlists) { p in
                            NavigationLink(value: p.id) {
                                PlaylistCard(playlist: p, tracks: playlists.tracks(in: p))
                            }
                            .buttonStyle(.plain)
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
        .background(Color(.systemGroupedBackground))
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus.circle.fill") }
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

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickActionTile(icon: "link.badge.plus", title: "贴 URL 播放", tint: .accentColor, destination: PlayURLView())
            QuickActionTile(icon: "doc.text.magnifyingglass", title: "音源脚本", tint: .orange, destination: ScriptManagerView())
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

private struct QuickActionTile<D: View>: View {
    let icon: String
    let title: String
    let tint: Color
    let destination: D

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
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

private struct CoverMosaic: View {
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
                                    Label("播放全部", systemImage: "play.fill")
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
                    }
                    .onDelete { idx in
                        let ids = idx.map { tracks[$0].id }
                        playlists.remove(trackIDs: ids, from: p.id)
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

// MARK: - PlayURLView (kept simple, restyled)

struct PlayURLView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @State private var url: String = ""
    @State private var name: String = "URL Track"
    @State private var artist: String = "未知"

    var body: some View {
        Form {
            Section("音频地址") {
                TextField("https://...", text: $url, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("元数据(可选)") {
                TextField("歌曲名", text: $name)
                TextField("歌手", text: $artist)
            }
            Section {
                Button {
                    guard let u = URL(string: url) else { return }
                    let t = Track(
                        id: Track.makeID(source: .local, songmid: url),
                        name: name.isEmpty ? "URL" : name,
                        singer: artist.isEmpty ? "未知" : artist,
                        source: .local, songmid: url
                    )
                    playback.playDirectURL(u, asTrack: t)
                } label: {
                    HStack {
                        Spacer()
                        Label("立即播放", systemImage: "play.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                }
                .disabled(URL(string: url) == nil)
            }
        }
        .navigationTitle("贴 URL 播放")
        .navigationBarTitleDisplayMode(.inline)
    }
}
