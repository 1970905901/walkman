import SwiftUI

// MARK: - Search (iPad)
//
// QQ 音乐 iPad 的搜索是占据整个 detail-pane 中央的大输入框 + 多 tab 结果。
// 顶部一个 hero 区域(带热词),提交后切换为多 tab 结果列表(单曲/歌单/MV/专辑/歌手)。
// 我们当前后端只支持单曲搜索 + 歌单搜索,先做单曲;tab 框架预留。

struct IPadSearchView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @AppStorage("search.history") private var historyJSON: String = "[]"
    @State private var keyword: String = ""
    @State private var submitted: String = ""
    @State private var selectedScope: SearchScope = .all
    @State private var resultsByScope: [SearchScope: [Track]] = [:]
    @State private var loadingScopes: Set<SearchScope> = []
    /// 跟 iPhone 不同 — iPad 搜索结果上方还有一个"歌单"区,聚合所有源的同名歌单。
    /// 跟 walkman-tv 搜索页一致(参考用户提供的 IMG_2069)。
    @State private var playlistResults: [SonglistInfo] = []
    @State private var loadingPlaylists = false
    @State private var navPath = NavigationPath()
    @FocusState private var focused: Bool

    private let tabs: [SearchScope] = [
        .all, .source(.kw), .source(.wy), .source(.kg), .source(.tx),
    ]

    var body: some View {
        VStack(spacing: 0) {
            heroOrField
                .padding(.horizontal, 32)
                .padding(.top, submitted.isEmpty ? 60 : 16)
                .padding(.bottom, 8)
                .ipadContentWidth()

            if !submitted.isEmpty {
                scopeTabs
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .ipadContentWidth()
                resultsList
            } else {
                emptyHero
            }
        }
        .background(IPad.Color.contentBackground)
    }

    // MARK: Bar / Hero

    /// When not yet searched: render a large centered hero header above the
    /// search field (QQ 音乐 PC 端的"打开搜索"体验)。
    /// Once submitted: shrink to a compact toolbar-style field at the top.
    @ViewBuilder
    private var heroOrField: some View {
        if submitted.isEmpty {
            VStack(spacing: 14) {
                Text("发现你喜欢的音乐")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("在 4 个音源中搜索 · 自定义脚本提供高品质播放地址")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.bottom, 6)
                searchField
                    .frame(maxWidth: 560)
                if !history.isEmpty {
                    historyRow
                        .frame(maxWidth: 720)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.Palette.textTertiary)
            TextField("歌曲、歌手、专辑", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { submit() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? DS.Palette.brandStart.opacity(0.6) : DS.Palette.strokeSubtle,
                        lineWidth: focused ? 1.5 : 0.5)
        )
    }

    @ViewBuilder
    private var historyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近搜索").font(.system(size: 12)).foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                Button("清除") { historyJSON = "[]" }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            HStack(spacing: 8) {
                ForEach(history.prefix(8), id: \.self) { tag in
                    Button { keyword = tag; submit() } label: {
                        Text(tag)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(DS.Palette.strokeSubtle.opacity(0.4)))
                            .foregroundStyle(DS.Palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 12)
    }

    private var scopeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs) { scope in
                    let isActive = selectedScope == scope
                    Button { selectedScope = scope } label: {
                        HStack(spacing: 6) {
                            Circle().fill(scope.tint).frame(width: 6, height: 6)
                            Text(scope.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            if let n = resultsByScope[scope]?.count, n > 0 {
                                Text("\(n)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isActive ? .white.opacity(0.85) : DS.Palette.textTertiary)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(isActive ? .white : DS.Palette.textPrimary)
                        .background(Capsule().fill(isActive ? scope.tint : DS.Palette.strokeSubtle.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resultsList: some View {
        let results = resultsByScope[selectedScope] ?? []
        return NavigationStack(path: $navPath) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    // 歌单结果 carousel — 在歌曲列表之上,跟 walkman-tv 搜索
                    // 页的"歌单 (N)" + "歌曲 (N)" 双 section 一致
                    if !playlistResults.isEmpty {
                        playlistsSection
                            .padding(.bottom, 18)
                    }
                    // 歌曲列表 section
                    if !results.isEmpty {
                        HStack {
                            Text("歌曲")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DS.Palette.textPrimary)
                            Text("\(results.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Palette.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, t in
                        IPadTrackRow(
                            index: idx + 1,
                            track: t,
                            isPlaying: playback.currentTrack?.id == t.id,
                            onTap: {
                                playback.play(track: t, in: results, startIndex: idx)
                                pushHistory(submitted)
                            },
                            onMenu: { /* TODO: context menu */ }
                        )
                    }
                    if loadingScopes.contains(selectedScope) && results.isEmpty
                        && playlistResults.isEmpty {
                        LoadingPlaceholder(topPadding: 60)
                    } else if results.isEmpty && playlistResults.isEmpty {
                        BrandedEmpty(icon: "magnifyingglass",
                                     title: "没有结果",
                                     subtitle: "试试别的关键词,或切换音源")
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 120)
                .ipadContentWidth()
            }
            .navigationDestination(for: SonglistInfo.self) { info in
                SonglistDetailView(info: info)
            }
        }
    }

    /// "歌单 (N)" 横向 carousel — 用现有的 IPadAlbumCard,点击进入 SonglistDetailView。
    /// 跨 source 聚合,展示前 8 个匹配的歌单。
    @ViewBuilder
    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("歌单")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("\(playlistResults.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                if loadingPlaylists {
                    UIKitSpinner(style: .medium).scaleEffect(0.6).frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(playlistResults.prefix(8)) { p in
                        NavigationLink(value: p) {
                            IPadAlbumCard(
                                imageURL: p.picURL,
                                title: p.name,
                                subtitle: p.playCount ?? p.author,
                                fallbackTint: p.source.tint,
                                size: 140
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var emptyHero: some View {
        Spacer()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Logic

    private func submit() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        submitted = kw
        focused = false
        Task { await runSearch(kw) }
    }

    @MainActor
    private func runSearch(_ keyword: String) async {
        resultsByScope = [:]
        playlistResults = []
        loadingPlaylists = true
        // Songs across all sources(并行)
        async let songsTask: Void = withTaskGroup(of: Void.self) { group in
            for scope in tabs where scope != .all {
                guard case let .source(src) = scope else { continue }
                group.addTask {
                    await searchOne(src, keyword: keyword)
                }
            }
        }
        // Playlists across all sources(并行)— Songlists.service 给 .search 实现
        async let playlistsTask: [SonglistInfo] = searchPlaylistsAcrossSources(keyword: keyword)
        _ = await songsTask
        let plists = await playlistsTask
        playlistResults = plists
        loadingPlaylists = false

        // Build merged "全部" result for songs
        var all: [Track] = []
        for scope in tabs where scope != .all {
            if let r = resultsByScope[scope] { all.append(contentsOf: r) }
        }
        resultsByScope[.all] = all
    }

    /// 并行扫每个 Songlists.service 的 search 实现,interleave 结果。
    /// 某些源不实现 search(默认 no-op 返回 []),没 result 的就跳过。
    private func searchPlaylistsAcrossSources(keyword: String) async -> [SonglistInfo] {
        let srcs: [SourceID] = [.kw, .wy, .kg, .tx]
        let groups = await withTaskGroup(of: (SourceID, [SonglistInfo]).self) { group -> [SourceID: [SonglistInfo]] in
            for s in srcs {
                group.addTask {
                    guard let svc = Songlists.service(for: s) else { return (s, []) }
                    do {
                        return (s, try await svc.search(keyword: keyword, page: 1))
                    } catch {
                        return (s, [])
                    }
                }
            }
            var dict: [SourceID: [SonglistInfo]] = [:]
            for await (s, lists) in group { dict[s] = lists }
            return dict
        }
        var merged: [SonglistInfo] = []
        let maxPer = srcs.map { (groups[$0]?.count ?? 0) }.max() ?? 0
        for i in 0..<maxPer {
            for s in srcs {
                if let g = groups[s], i < g.count {
                    merged.append(g[i])
                }
            }
        }
        return merged
    }

    @MainActor
    private func searchOne(_ src: SourceID, keyword: String) async {
        let scope = SearchScope.source(src)
        loadingScopes.insert(scope)
        defer { loadingScopes.remove(scope) }
        guard let catalog = Catalogs.service(for: src) else { return }
        do {
            let tracks = try await catalog.search(keyword: keyword, page: 1)
            resultsByScope[scope] = tracks
        } catch {
            resultsByScope[scope] = []
        }
    }

    private var history: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(historyJSON.utf8))) ?? []
    }

    private func pushHistory(_ kw: String) {
        var arr = history
        arr.removeAll { $0 == kw }
        arr.insert(kw, at: 0)
        if arr.count > 12 { arr = Array(arr.prefix(12)) }
        if let data = try? JSONEncoder().encode(arr), let s = String(data: data, encoding: .utf8) {
            historyJSON = s
        }
    }
}
