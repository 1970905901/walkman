import SwiftUI

// MARK: - Home (发现页) — QQ 音乐风的 iPad 首页
//
// Vertical scroll feed:
//   1. Hero banner carousel — 每个 enabled 源选一张代表歌单作 banner,
//      自动 5s 切换 + 手动滑动 + 底部点指示器
//   2. 推荐歌单 carousel — 8-10 个最热歌单(混合所有 enabled 源)
//   3. 排行榜 carousel — 各源代表榜单
//
// 所有 section header 的 subtitle 跟着 settings.homeSources 走 — 用户在设置
// 里只勾酷我,subtitle 就只显示 "酷我"。

struct IPadHomeView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var settings: SettingsStore
    @Binding var path: NavigationPath
    @State private var recommendations: [SonglistInfo] = []
    @State private var boards: [BoardInfo] = []
    @State private var isLoading = true
    /// Hero 轮换:每个 enabled 源贡献一张 banner(取 fetchTop 的第一条)
    @State private var heroes: [HeroItem] = []
    @State private var heroIndex: Int = 0
    @State private var heroTimer: Timer?

    /// Source order for the home feed. Preserved order matches the iPad sidebar
    /// (kw → wy → kg → tx), filtered to whatever the user enabled in Settings.
    private var activeSources: [SourceID] {
        [.kw, .wy, .kg, .tx].filter { settings.homeSources.contains($0) }
    }

    /// 显示给 section header 用的源列表 — eg "酷我 · 网易云"。无源时不显示。
    private var sourceListLabel: String {
        activeSources.map(\.displayName).joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IPad.Layout.sectionTopSpacing) {
                if isLoading {
                    LoadingPlaceholder(topPadding: 120)
                } else {
                    heroBannerCarousel
                    recommendationsCarousel
                    leaderboardCarousel
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 96)   // room for bottom mini player
            .ipadContentWidth()
        }
        .background(IPad.Color.contentBackground)
        // Re-fetch whenever the user toggles a source in Settings — task id
        // 包含 sorted source set,等价的 set 不会重复 refetch。
        .task(id: settings.homeSources.map(\.rawValue).sorted().joined(separator: ",")) {
            await load()
        }
        .onDisappear { stopHeroTimer() }
    }

    // MARK: - Hero banner carousel
    //
    // 用 SwiftUI TabView(.page) 做轮播 + 一个 Timer 每 6s 推进 heroIndex,
    // 手动滑动会被尊重(TabView 不打架),滑动后 timer 重置周期。

    @ViewBuilder
    private var heroBannerCarousel: some View {
        if !heroes.isEmpty {
            VStack(spacing: 10) {
                TabView(selection: $heroIndex) {
                    ForEach(Array(heroes.enumerated()), id: \.offset) { idx, h in
                        IPadHeroBanner(
                            title: h.info.name,
                            subtitle: "\(h.info.source.displayName) · \(h.info.playCount ?? "热门播放")",
                            imageURL: h.info.picURL,
                            accentStart: h.accentStart,
                            accentEnd: h.accentEnd,
                            action: { path.append(h.info) }
                        )
                        .padding(.horizontal, 1)
                        .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 280)
                .padding(.top, 8)
                // 手动滑动后重置自动切换的计时,不让 timer 立刻切走用户刚选的页
                .onChange(of: heroIndex) { _, _ in
                    restartHeroTimer()
                }

                // 自定义底部指示器 — 当前页是品牌渐变长 capsule,其它是灰色短点
                HStack(spacing: 6) {
                    ForEach(heroes.indices, id: \.self) { i in
                        let on = i == heroIndex
                        Capsule()
                            .fill(on
                                  ? AnyShapeStyle(DS.Palette.brandGradient)
                                  : AnyShapeStyle(Color.primary.opacity(0.18)))
                            .frame(width: on ? 22 : 6, height: 5)
                            .animation(.spring(duration: 0.3), value: heroIndex)
                            .onTapGesture {
                                heroIndex = i
                            }
                    }
                }
            }
            .onAppear { startHeroTimer() }
        }
    }

    private func startHeroTimer() {
        stopHeroTimer()
        guard heroes.count > 1 else { return }
        heroTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                heroIndex = (heroIndex + 1) % heroes.count
            }
        }
    }

    private func restartHeroTimer() {
        startHeroTimer()   // start 内部会先 stop
    }

    private func stopHeroTimer() {
        heroTimer?.invalidate()
        heroTimer = nil
    }

    // MARK: Carousels

    @ViewBuilder
    private var recommendationsCarousel: some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                IPadSectionHeader("推荐歌单", subtitle: sourceListLabel) {
                    Button("查看全部") { path.append(IPadDestination.songlist) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(recommendations.prefix(12)) { list in
                            Button {
                                path.append(list)
                            } label: {
                                IPadAlbumCard(
                                    imageURL: list.picURL,
                                    title: list.name,
                                    subtitle: list.playCount ?? list.author,
                                    fallbackTint: list.source.tint
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var leaderboardCarousel: some View {
        if !boards.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                // subtitle 跟 settings.homeSources 联动 — 用户去掉某个平台就
                // 不会再误以为榜单还展示那个平台
                IPadSectionHeader("排行榜", subtitle: sourceListLabel) {
                    Button("查看全部") { path.append(IPadDestination.leaderboard) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(boards) { b in
                            Button {
                                path.append(b)
                            } label: {
                                IPadAlbumCard(
                                    imageURL: b.picURL,
                                    title: b.name,
                                    subtitle: b.source.displayName,
                                    fallbackTint: b.source.tint,
                                    fallbackIcon: "chart.bar.fill"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data
    //
    // 总流程:
    //   1. activeSources 并行 fetchTop → 每个源拿到 ~30 张歌单
    //   2. 每个源的第一张做 hero banner(轮换池)— 颜色用源 tint 做渐变
    //   3. 剩下的 interleave 进 recommendations(混排,不让一个源连续多张)
    //   4. boards = enabled 源各取前 2 个榜单

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let srcs = activeSources
        let groups = await withTaskGroup(of: (SourceID, [SonglistInfo]).self) { group -> [SourceID: [SonglistInfo]] in
            for s in srcs {
                group.addTask { (s, await fetchTop(s)) }
            }
            var dict: [SourceID: [SonglistInfo]] = [:]
            for await (s, list) in group { dict[s] = list }
            return dict
        }

        // Hero pool — 每个源贡献一张,源色做渐变,顺序按 srcs
        var heroPool: [HeroItem] = []
        for s in srcs {
            if let first = groups[s]?.first {
                heroPool.append(HeroItem(
                    info: first,
                    accentStart: s.tint,
                    accentEnd: s.tint.opacity(0.55).overlay(.black, amount: 0.15)
                ))
            }
        }
        heroes = heroPool
        heroIndex = 0

        // Recommendations — 跳过每个源的第一张(已经在 hero 里),interleave 剩下的
        var merged: [SonglistInfo] = []
        let tails: [SourceID: ArraySlice<SonglistInfo>] = Dictionary(uniqueKeysWithValues:
            srcs.map { s in (s, (groups[s] ?? []).dropFirst().prefix(8)) }
        )
        let maxPer = tails.values.map(\.count).max() ?? 0
        for i in 0..<maxPer {
            for s in srcs {
                let arr = tails[s] ?? []
                let idx = arr.startIndex + i
                if idx < arr.endIndex {
                    merged.append(arr[idx])
                }
            }
        }
        recommendations = merged

        // 排行榜:用 svc.fetchBoards() 而不是 svc.list,这样能拿到带 picURL
        // 的真实榜单封面(各源端 fetchBoards 实现都会去对方平台 API 拉 cover)。
        // 配额规则 — 总数固定 12 张,均摊到 enabled 平台:
        //   1 个平台:这个平台拿全部 12 张
        //   2 个平台:每个 6 张
        //   3 个平台:每个 4 张
        //   4 个平台:每个 3 张
        // 不够 12 的平台(榜单总数较少)会让出名额给后面有空位的源
        let boardSources = Boards.all.filter { settings.homeSources.contains($0.source) }
        var fetchedBoards: [BoardInfo] = []
        await withTaskGroup(of: (Int, [BoardInfo]).self) { group in
            for (idx, svc) in boardSources.enumerated() {
                group.addTask { (idx, await svc.fetchBoards()) }
            }
            var bySource: [Int: [BoardInfo]] = [:]
            for await (idx, list) in group { bySource[idx] = list }

            let totalTarget = 12
            let n = boardSources.count
            guard n > 0 else { return }
            let perSource = max(1, totalTarget / n)

            // 第一轮:每个源按 perSource 拿
            var picked: [Int: ArraySlice<BoardInfo>] = [:]
            var totalPicked = 0
            for i in 0..<n {
                let available = bySource[i] ?? []
                let take = available.prefix(perSource)
                picked[i] = take
                totalPicked += take.count
            }
            // 第二轮:补到 totalTarget — 从还有剩的源里轮流加
            if totalPicked < totalTarget {
                var remaining = totalTarget - totalPicked
                var cursor = 0
                while remaining > 0 {
                    let i = cursor % n
                    cursor += 1
                    let available = bySource[i] ?? []
                    let already = picked[i]?.count ?? 0
                    if already < available.count {
                        picked[i] = available.prefix(already + 1)
                        remaining -= 1
                    } else if cursor > n * 2 {
                        // 所有源都用尽,提前退出避免无限循环
                        break
                    }
                }
            }
            for i in 0..<n {
                fetchedBoards.append(contentsOf: picked[i] ?? [])
            }
        }
        boards = fetchedBoards

        startHeroTimer()
    }

    private func fetchTop(_ source: SourceID) async -> [SonglistInfo] {
        guard let svc = Songlists.service(for: source),
              let order = svc.orders.first else { return [] }
        do {
            return try await svc.fetchRecommended(order: order, tag: .all, page: 1)
        } catch {
            return []
        }
    }
}

// MARK: - Hero item & color helper

private struct HeroItem: Identifiable {
    let id = UUID()
    let info: SonglistInfo
    let accentStart: Color
    let accentEnd: Color
}

private extension Color {
    /// 简化版颜色混合 — 用于让 banner 渐变从源色到稍暗的版本,模拟"日落"感
    func overlay(_ other: Color, amount: Double) -> Color {
        let f = min(max(amount, 0), 1)
        let a = UIColor(self)
        let b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red:   Double(ar + (br - ar) * CGFloat(f)),
            green: Double(ag + (bg - ag) * CGFloat(f)),
            blue:  Double(ab + (bb - ab) * CGFloat(f))
        )
    }
}
