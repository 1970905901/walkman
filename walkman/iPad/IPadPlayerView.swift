import SwiftUI

// MARK: - iPad / Mac full-screen player
//
// 双栏布局,QQ 音乐桌面"正在播放"页节奏:
//
//   ┌─────────────────────────────────────────────────────────────────┐
//   │ ⌄                            [音质/源]                  ⋯       │
//   │                                                                  │
//   │   ┌──────────────────┐       ┌────────────────────────────────┐ │
//   │   │                  │       │     歌词                        │ │
//   │   │      封面         │       │     ─────                       │ │
//   │   │     420×420       │       │     当前行(大字、强调色)        │ │
//   │   │                  │       │     下一行                      │ │
//   │   └──────────────────┘       │     ...                         │ │
//   │   歌名 / 歌手 · 专辑          │     ...                         │ │
//   │                              └────────────────────────────────┘ │
//   │   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ 00:35 ── 04:21          │
//   │   🔁  ⏮  ●▶  ⏭  ❤  📋  📺                                       │
//   └─────────────────────────────────────────────────────────────────┘
//
// 大小:左封面 + 控件 ~50%,右歌词 ~50%。封面 max 420pt 不让整个布局比例失衡。

struct IPadPlayerView: View {
    let onClose: () -> Void

    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var sources: SourceManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sleepTimer: SleepTimer
    @StateObject private var artwork = ArtworkColors()

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var showSleepSheet = false
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?
    @State private var lyrics: [LyricLine] = []
    @State private var loadingLyrics = false
    private var cycleMode: PlaybackCycleMode {
        PlaybackCycleMode.current(shuffle: playback.shuffle, loop: playback.loopMode)
    }

    var body: some View {
        ZStack {
            PlayerBackdrop(primary: artwork.primary, secondary: artwork.secondary)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                HStack(alignment: .top, spacing: 36) {
                    leftPane
                    rightPane
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            extractColors()
            loadLyrics()
        }
        .onChange(of: playback.currentTrack?.id) { _, _ in
            extractColors()
            loadLyrics()
        }
        .sheet(isPresented: $showQueue) {
            NavigationStack { QueueView() }
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEQ) {
            NavigationStack { EQView() }
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToFavorite) { t in
            AddToPlaylistSheet(track: t)
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToDownload) { t in
            DownloadSheet(track: t)
                .inheritedAppearance()
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Top bar
    //
    // 极简:只有左上的"缩小"按钮和右上的 ⋯ 菜单。源/音质/MV 徽章都搬到下方
    // 歌名行 + bottom bar(用户已经在那里看到它们)。

    /// 跟 iPhone PlayerView 一致 — 米色 cassetteBody 作为 secondary controls 的
    /// 暖色调,跟 brand burgundy 主色形成"老式磁带机暖光"的整体氛围。比之前
    /// 纯白色的图标更跟 iPhone 端 visually-consistent。
    private var iconTint: Color { DS.Palette.cassetteBody.opacity(0.85) }
    private var iconBorder: Color { DS.Palette.cassetteBody.opacity(0.22) }

    private var topBar: some View {
        HStack(spacing: 14) {
            // 收起回首页 — 下拉箭头(同 iPhone PlayerView 风格)
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(iconBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("收起")

            Spacer()

            // ⋯ menu
            Menu {
                Button { if let t = playback.currentTrack { trackToFavorite = t } } label: {
                    Label("收藏", systemImage: "heart")
                }
                Button { if let t = playback.currentTrack { trackToDownload = t } } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                Divider()
                Button { showEQ = true } label: {
                    Label("均衡器", systemImage: "slider.vertical.3")
                }
                Button { showSleepSheet = true } label: {
                    Label("睡眠定时", systemImage: "moon.zzz")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(iconBorder, lineWidth: 0.5))
            }
            .disabled(playback.currentTrack == nil)
        }
    }

    // MARK: - Left pane (cover + meta + controls)

    /// 0...1 唱针位置。歌曲切换时 currentTrack?.id 变化 → progress 自动从 0
    /// 重新增长;歌曲进度更新时 currentTime/duration 推进 progress。用
    /// `.animation(.linear)` 让 stylus 平滑地从外向内扫,而不是跳跃。
    private var playProgress: Double {
        guard playback.duration > 0 else { return 0 }
        return max(0, min(1, playback.currentTime / playback.duration))
    }

    private var leftPane: some View {
        VStack(spacing: 22) {
            // 彩胶尺寸根据可用宽度自适应 — 横屏 ~520pt(原值),竖屏 ~360pt
            // 不至于把唱片做得比右侧歌词区还大。用 GeometryReader 读自己宽度。
            GeometryReader { geo in
                let available = min(geo.size.width, geo.size.height) - 24
                let discSize = max(280, min(available, 520))
                ZStack {
                    if let track = playback.currentTrack {
                        IPadVinylDisc(
                            imageURL: track.picURL,
                            isPlaying: playback.isPlaying,
                            // artwork.primary 来自封面提取,如果太灰会推到品牌色保底
                            vinylTint: saturatedTint(artwork.primary),
                            size: discSize,
                            progress: playProgress
                        )
                        // currentTrack.id 一变(换歌)→ progress 重置回 0,
                        // 加 spring 让回到起点是个轻盈的回弹而不是瞬移
                        .animation(.spring(response: 0.6, dampingFraction: 0.85),
                                   value: track.id)
                        // playProgress 每秒推进 → stylus 平滑跟进。用 linear
                        // 避免 spring 过冲在精细位移上产生"颤抖"。
                        .animation(.linear(duration: 0.5), value: playProgress)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxWidth: 520, maxHeight: 520)
            .aspectRatio(1, contentMode: .fit)

            // 歌名 / 歌手 / 来源·音质·MV 元信息行
            // 控件在 IPadBottomBar 里持续显示,这里只放标题 + 一行 meta chips。
            // 文字色用米色 cassette 系列保持跟 iPhone 一致。
            if let track = playback.currentTrack {
                VStack(spacing: 8) {
                    Text(track.name)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Palette.cassetteBody)
                        .lineLimit(1)
                    Text(track.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.cassetteBody.opacity(0.65))
                        .lineLimit(1)

                    // 元信息行:来源 dot + 名称 · 音质徽章 · MV 徽章
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(track.source.tint).frame(width: 6, height: 6)
                            Text(track.source.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.85))
                        }
                        if let q = playback.currentQuality {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                            QualityBadge(style: QualityBadgeStyle(quality: q))
                        } else if let highest = QualityBadgeStyle(highestIn: track.qualities) {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                            QualityBadge(style: highest)
                        }
                        if track.extras["mvId"]?.isEmpty == false {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                            IPadMVTag()
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 560)
    }

    /// 如果封面提取的 primary 太灰(saturation < 0.25),用品牌主色顶上 —
    /// 否则彩胶看起来跟纯黑胶没区别,失去"colored gel"的存在感。
    private func saturatedTint(_ color: Color) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.25 || b < 0.20 {
            return DS.Palette.brandStart
        }
        // 略微提升饱和度,让彩胶更鲜
        return Color(UIColor(hue: h, saturation: min(s * 1.3, 1.0), brightness: max(b, 0.55), alpha: 1))
    }

    // MARK: - Right pane (lyrics)

    private var rightPane: some View {
        Group {
            if loadingLyrics {
                VStack {
                    Spacer()
                    UIKitSpinner(style: .medium, color: UIColor(DS.Palette.cassetteBody))
                    Spacer()
                }
            } else if lyrics.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(DS.Palette.cassetteBody.opacity(0.45))
                    Text("暂无歌词")
                        .foregroundStyle(DS.Palette.cassetteBody.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                LyricsScroll(
                    lines: lyrics,
                    currentTime: playback.currentTime,
                    onTap: { time in playback.seek(to: time) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 米色玻璃面板 — 用很低不透明度的 cassette 色,跟 iPhone 端歌词
            // 区色调一致。
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(DS.Palette.cassetteBody.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(DS.Palette.cassetteBody.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Progress + controls

    private var progressBlock: some View {
        VStack(spacing: 6) {
            ProgressSlider(
                value: Binding(
                    get: { isSeeking ? seekValue : playback.currentTime },
                    set: { seekValue = $0; isSeeking = true }
                ),
                in: 0...max(playback.duration, 1),
                onChangeBegan: { isSeeking = true },
                onChangeEnded: {
                    playback.seek(to: seekValue)
                    isSeeking = false
                }
            )
            HStack {
                Text(format(time: isSeeking ? seekValue : playback.currentTime))
                Spacer()
                Text(format(time: playback.duration))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var controlBlock: some View {
        let secondaryTint = Color.white.opacity(0.7)
        return HStack {
            Button {
                cycleMode.advanced().apply(to: playback)
            } label: {
                Image(systemName: cycleMode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(cycleMode == .sequence ? secondaryTint : Color.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { playback.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            .buttonStyle(.plain)

            Spacer()

            // Center brand-gradient play/pause — visually anchors the row.
            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(DS.Palette.brandGradient)
                        .frame(width: 72, height: 72)
                        .shadow(color: DS.Palette.brandStart.opacity(0.55), radius: 18, y: 8)
                    if playback.isBuffering {
                        UIKitSpinner(style: .medium, color: .white)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundStyle(.white)
                            .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button { playback.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(secondaryTint)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private func extractColors() {
        guard let pic = playback.currentTrack?.picURL else { return }
        artwork.extract(from: pic)
    }

    private func loadLyrics() {
        lyrics = []
        guard let track = playback.currentTrack else { return }
        loadingLyrics = true
        Task {
            let lines = await LyricsFetcher.shared.fetch(for: track, sources: sources)
            await MainActor.run {
                if playback.currentTrack?.id == track.id {
                    lyrics = lines
                    loadingLyrics = false
                }
            }
        }
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
