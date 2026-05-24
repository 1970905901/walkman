import SwiftUI

/// Browse recommended playlists per platform; tap → detail with songs.
struct SonglistView: View {
    @AppStorage("ui.songlistSource") private var selectedSourceRaw: String = SourceID.kw.rawValue
    @State private var orderID: String = ""
    @State private var playlists: [SonglistInfo] = []
    @State private var isLoading = false
    @State private var error: String?

    private var selectedSource: SourceID {
        SourceID(rawValue: selectedSourceRaw) ?? .kw
    }
    private var selectedSourceBinding: Binding<SourceID> {
        Binding(get: { selectedSource }, set: { selectedSourceRaw = $0.rawValue })
    }

    private var supportedSources: [SourceID] { Songlists.all.map { $0.source } }
    private var currentOrders: [SonglistOrder] { Songlists.service(for: selectedSource)?.orders ?? [] }
    private var currentOrder: SonglistOrder {
        currentOrders.first { $0.id == orderID } ?? currentOrders.first ?? SonglistOrder(id: "hot", name: "最热")
    }
    private var orderBinding: Binding<SonglistOrder> {
        Binding(get: { currentOrder }, set: { orderID = $0.id })
    }
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            if supportedSources.count > 1 {
                ChipBar(items: supportedSources, title: { $0.displayName }, selection: selectedSourceBinding)
                    .padding(.top, DS.Spacing.s)
            }
            if currentOrders.count > 1 {
                ChipBar(items: currentOrders, title: { $0.name }, selection: orderBinding)
            }

            ScrollView {
                if isLoading && playlists.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if let error, playlists.isEmpty {
                    ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(playlists) { list in
                            NavigationLink(value: list) {
                                SonglistCard(info: list)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.l)
                    .padding(.vertical, DS.Spacing.l)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: SonglistInfo.self) { info in
            SonglistDetailView(info: info)
        }
        .task(id: SortKey(source: selectedSource, order: currentOrder.id)) {
            await load()
        }
    }

    private struct SortKey: Hashable {
        let source: SourceID
        let order: String
    }

    private func load() async {
        playlists = []
        error = nil
        let svcOrder = currentOrder
        guard let svc = Songlists.service(for: selectedSource) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await svc.fetchRecommended(order: svcOrder, page: 1)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SonglistCard: View {
    let info: SonglistInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: info.picURL.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default:
                        LinearGradient(colors: [info.source.tint, info.source.tint.opacity(0.45)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "music.note.list").font(.system(size: 30)).foregroundColor(.white))
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)

                if let plays = info.playCount {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        Text(plays).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(info.author.isEmpty ? info.source.displayName : info.author)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct SonglistDetailView: View {
    let info: SonglistInfo
    @EnvironmentObject var playback: PlaybackEngine
    @StateObject private var artwork = ArtworkColors()
    @State private var detail: SonglistDetail?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let detail {
                List {
                    Section {
                        header(detail: detail)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(Array(detail.tracks.enumerated()), id: \.element.id) { idx, t in
                            HStack(alignment: .center, spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                    .frame(width: 28)
                                TrackRow(track: t)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playback.play(track: t, in: detail.tracks, startIndex: idx)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .trackRowSwipe(t)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else if isLoading {
                ProgressView().padding(.top, 60)
            } else if let error {
                ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(detail?.info.name ?? info.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard detail == nil, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            artwork.extract(from: info.picURL)
            guard let svc = Songlists.service(for: info.source) else { return }
            do {
                detail = try await svc.fetchDetail(info)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func header(detail: SonglistDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: detail.info.picURL.flatMap(URL.init(string:))) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default:
                    LinearGradient(colors: [info.source.tint, info.source.tint.opacity(0.5)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note.list").font(.system(size: 36)).foregroundColor(.white))
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.info.name).font(.system(size: 17, weight: .bold)).lineLimit(3)
                if !detail.info.author.isEmpty {
                    Text(detail.info.author).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }
                Text("\(detail.tracks.count) 首")
                    .font(.subheadline).foregroundColor(.secondary)
                if !detail.tracks.isEmpty {
                    Button {
                        playback.play(track: detail.tracks[0], in: detail.tracks, startIndex: 0)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("播放全部")
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
