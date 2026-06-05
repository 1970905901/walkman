import SwiftUI

// MARK: - 资料库 (iPad)
//
// QQ 音乐 iPad 的"我的"页面布局:
//   - 顶部用户问候 / "继续听" hero (最近播放的歌曲 — 大封面 + 播放按钮)
//   - "最近播放" 水平 carousel
//   - "我喜欢" 入口卡(单独大)
//   - "我的歌单" grid
//
// sidebar 已经列了"本地与下载/最近播放/听歌报告"这些入口,所以 detail pane 不再
// 重复显示这些卡片。如果用户从 sidebar 点击具体歌单,这个视图直接被替换为
// IPadPlaylistDetailView。

struct IPadLibraryView: View {
    @EnvironmentObject var playlists: PlaylistStore
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var history: PlayHistoryStore
    @Binding var path: NavigationPath
    @State private var showCreate = false
    @State private var newName = ""

    private var recentTracks: [Track] { Array(history.tracks.prefix(12)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IPad.Layout.sectionTopSpacing) {
                headerRow

                if !recentTracks.isEmpty {
                    continueListening
                    recentCarousel
                }

                playlistGrid
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 96)
            .ipadContentWidth()
        }
        .background(IPad.Color.contentBackground)
        .alert("新建歌单", isPresented: $showCreate) {
            TextField("歌单名", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("创建") {
                let n = newName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { _ = playlists.createPlaylist(name: n) }
                newName = ""
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("资料库")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("\(playlists.playlists.count) 个歌单 · \(history.tracks.count) 首最近播放")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer()
            Button { showCreate = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("新建歌单")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(Color.white)
                .background(Capsule().fill(DS.Palette.brandGradient))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    // MARK: Continue listening hero

    @ViewBuilder
    private var continueListening: some View {
        if let last = recentTracks.first {
            HStack(spacing: 20) {
                Artwork(url: last.picURL, size: 140, radius: 16)
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("继续听")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .textCase(.uppercase)
                    Text(last.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                    Text(last.singer)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Button {
                            playback.play(track: last, in: recentTracks, startIndex: 0)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("继续播放")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(DS.Palette.brandGradient))
                            .foregroundStyle(Color.white)
                        }
                        .buttonStyle(.plain)
                        Button {
                            path.append(IPadDestination.history)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("最近播放列表")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .overlay(Capsule().stroke(DS.Palette.strokeSubtle, lineWidth: 1))
                            .foregroundStyle(DS.Palette.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(DS.Palette.strokeSubtle, lineWidth: 0.5)
            )
        }
    }

    private var recentCarousel: some View {
        VStack(alignment: .leading, spacing: 14) {
            IPadSectionHeader("最近播放") {
                Button("更多") { path.append(IPadDestination.history) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(recentTracks.enumerated()), id: \.element.id) { idx, t in
                        Button {
                            playback.play(track: t, in: recentTracks, startIndex: idx)
                        } label: {
                            IPadAlbumCard(
                                imageURL: t.picURL,
                                title: t.name,
                                subtitle: t.singer,
                                fallbackTint: t.source.tint,
                                size: 150
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var playlistGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            IPadSectionHeader("我的歌单", subtitle: "\(playlists.playlists.count) 个")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 18)],
                spacing: 22
            ) {
                ForEach(playlists.playlists) { p in
                    Button {
                        path.append(IPadDestination.playlist(p.id))
                    } label: {
                        IPadAlbumCard(
                            imageURL: playlists.tracks(in: p).first?.picURL,
                            title: p.name,
                            subtitle: "\(p.trackIDs.count) 首",
                            fallbackTint: DS.Palette.brandStart,
                            size: 160
                        )
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
        }
    }
}
