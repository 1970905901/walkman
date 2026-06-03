import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var sources: SourceManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sleepTimer: SleepTimer
    @Environment(\.dismiss) var dismiss
    @StateObject private var artwork = ArtworkColors()
    @State private var showSleepSheet = false
    @State private var seekValue: Double = 0
    @State private var isSeeking: Bool = false
    @State private var page: Int = 0  // 0 = cover, 1 = lyrics
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var loadingLyrics = false
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?
    @State private var dragOffset: CGFloat = 0

    /// Shared selector — see `PlaybackCycleMode` in PlaybackEngine.swift.
    private var cycleMode: PlaybackCycleMode {
        PlaybackCycleMode.current(shuffle: playback.shuffle, loop: playback.loopMode)
    }

    var body: some View {
        ZStack {
            PlayerBackdrop(primary: artwork.primary, secondary: artwork.secondary)
            VStack(spacing: 0) {
                topBar
                TabView(selection: $page) {
                    coverPage.tag(0)
                    lyricsPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                pageDots
                    .padding(.bottom, DS.Spacing.s)

                progressSection
                controlSection
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, DS.Spacing.l)
        }
        .preferredColorScheme(.dark)
        .offset(y: dragOffset)
        // Custom drag-to-dismiss. fullScreenCover doesn't have sheet's built-in swipe-down,
        // so we re-implement it: track downward drags from the top ~180pt strip (now wider
        // since the chrome — chevron/menu buttons — is gone), dismiss if >120pt or fast
        // enough, otherwise spring back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    if v.startLocation.y < 180 || dragOffset > 0 {
                        dragOffset = max(0, v.translation.height)
                    }
                }
                .onEnded { v in
                    if dragOffset > 120 || v.predictedEndTranslation.height > 250 {
                        dismiss()
                    } else {
                        withAnimation(DS.Motion.standard) { dragOffset = 0 }
                    }
                }
        )
        .onAppear {
            sync()
        }
        .onChange(of: playback.currentTrack?.id) { _, _ in sync() }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToFavorite) { track in
            AddToPlaylistSheet(track: track)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $trackToDownload) { track in
            DownloadSheet(track: track)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func sync() {
        artwork.extract(from: playback.currentTrack?.picURL)
        lyrics = []
        guard let track = playback.currentTrack else { return }
        loadingLyrics = true
        Task {
            let lines = await LyricsFetcher.shared.fetch(for: track, sources: sources)
            await MainActor.run {
                self.lyrics = lines
                self.loadingLyrics = false
            }
        }
    }

    // MARK: - Top bar

    /// Dismissal is driven by the drag-down gesture (see `simultaneousGesture` on body),
    /// so no chevron is needed. The center shows source/quality/origin only when
    /// `settings.showDebugNotices` is on. The right side carries a chrome-less "⋯"
    /// menu — anchored where every iOS music app puts secondary actions.
    private var topBar: some View {
        ZStack {
            if settings.showDebugNotices {
                HStack(spacing: 5) {
                    Text(playback.currentTrack?.source.displayName ?? "")
                        .font(DS.Typo.bodyStrong)
                        .foregroundColor(.white)
                    if let q = playback.currentQuality {
                        Text(QualityBadgeStyle(quality: q).label)
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(Color.white.opacity(0.75), lineWidth: 1)
                            )
                    }
                    if let origin = playback.currentOrigin {
                        HStack(spacing: 3) {
                            Image(systemName: origin.iconName).font(.system(size: 9, weight: .bold))
                            Text(origin.displayLabel).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.Glass.thin, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    }
                }
            }
            HStack {
                Spacer()
                Menu {
                    Button { if let t = playback.currentTrack { trackToFavorite = t } } label: {
                        Label("收藏", systemImage: "heart")
                    }
                    Button { if let t = playback.currentTrack { trackToDownload = t } } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                    Divider()
                    Button { showSleepSheet = true } label: {
                        // Active timer shows its label so the user can see what's armed at a glance.
                        switch sleepTimer.mode {
                        case .duration:
                            Label("睡眠 · \(sleepTimer.countdownText ?? "")", systemImage: "moon.zzz.fill")
                        case .endOfTrack:
                            Label("睡眠 · 当前歌曲结束", systemImage: "moon.zzz.fill")
                        case .none:
                            Label("睡眠定时", systemImage: "moon.zzz")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: 44, height: 36)   // generous hit area, no visible chrome
                        .contentShape(Rectangle())
                }
                .disabled(playback.currentTrack == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .padding(.top, 8)
    }


    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                let on = page == i
                Capsule()
                    .fill(on
                          ? AnyShapeStyle(DS.Palette.brandGradient)
                          : AnyShapeStyle(Color.white.opacity(0.25)))
                    .frame(width: on ? 22 : 8, height: 4)
                    .animation(DS.Motion.standard, value: page)
            }
        }
    }

    // MARK: - Cover page

    private var coverPage: some View {
        VStack(spacing: 0) {
            Spacer()
            // Album art + title/subtitle wrapped in one id'd container so SwiftUI
            // crossfades the whole "track identity" block when the song changes,
            // instead of hard-cutting on each property update. Scale on the way in
            // gives a tiny "rise" — feels like the new song settled into place.
            ZStack {
                if let track = playback.currentTrack {
                    VStack(spacing: 0) {
                        Artwork(url: track.picURL, size: 320, radius: DS.Radius.xlarge)
                            .elevation(DS.Elevation.e3(artwork.primary))
                            .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                            .scaleEffect(playback.isPlaying ? 1.0 : 0.92)
                            .animation(DS.Motion.emphasis, value: playback.isPlaying)

                        VStack(spacing: 6) {
                            Text(track.name)
                                .font(DS.Typo.title)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(track.subtitle)
                                .font(DS.Typo.body)
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        }
                        .padding(.top, DS.Spacing.xl)
                    }
                    .id(track.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96)),
                        removal: .opacity
                    ))
                }
            }
            .animation(DS.Motion.standard, value: playback.currentTrack?.id)

            AudioWave(active: playback.isPlaying && !playback.isBuffering,
                      level: playback.audioLevel)
                .frame(height: 68)
                .padding(.horizontal, 4)
                .padding(.top, DS.Spacing.l)
            Spacer()
        }
        .offset(y: -18)
    }

    // MARK: - Lyrics page

    private var lyricsPage: some View {
        Group {
            if loadingLyrics {
                UIKitSpinner(style: .medium, color: .white)
            } else if lyrics.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.white.opacity(0.5))
                    Text("暂无歌词").foregroundColor(.white.opacity(0.7))
                }
            } else {
                LyricsScroll(lines: lyrics, currentTime: playback.currentTime, onTap: { time in
                    playback.seek(to: time)
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Progress section

    private var progressSection: some View {
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
                Text("-" + format(time: max(0, playback.duration - (isSeeking ? seekValue : playback.currentTime))))
            }
            .font(DS.Typo.numeric)
            // Same beige family as the thumb/transport row, kept very low
            // opacity so the time-readout sits in the background and the eye
            // lands on the cover + play button first.
            .foregroundStyle(DS.Palette.cassetteBody.opacity(0.36))
        }
        .padding(.bottom, DS.Spacing.l)
    }

    // MARK: - Controls

    /// Bottom control row. Cycle mode (left) is the combined shuffle/loop selector;
    /// list.bullet (right) opens the playback queue — both used to live in TopBar.
    ///
    /// Secondary buttons all use `cassetteBody.opacity(0.5)` so they share the warm
    /// palette of the main play button + slider thumb but read as supporting cast
    /// rather than competing for attention.
    private var controlSection: some View {
        let secondaryTint = DS.Palette.cassetteBody.opacity(0.5)
        return HStack {
            Button {
                cycleMode.advanced().apply(to: playback)
            } label: {
                Image(systemName: cycleMode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(secondaryTint)
            }
            Spacer()
            Button { playback.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            Spacer()
            Button { playback.togglePlayPause() } label: {
                ZStack {
                    // Warm beige disc echoes the cassette body in the app icon —
                    // pressing it feels like pressing a cassette key. Glyph is
                    // the deep burgundy half of brand, not the gradient, so the
                    // small triangle reads as a single solid color (gradient at
                    // this size just smears into "dark blob").
                    Circle().fill(DS.Palette.cassetteBody)
                        .frame(width: 76, height: 76)
                        .shadow(color: artwork.primary.opacity(0.55), radius: 22, y: 8)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    if playback.isBuffering {
                        UIKitSpinner(style: .medium, color: UIColor(DS.Palette.brandStart))
                    } else {
                        // Top→bottom burgundy → brass mini-gradient gives the
                        // glyph a subtle "metal-warmed" feel, and 0.85 opacity
                        // lets the beige disc bleed through a bit so the
                        // triangle/pause bars don't punch as hard.
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        DS.Palette.brandStart.opacity(0.85),
                                        DS.Palette.brandEnd.opacity(0.85)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .offset(x: playback.isPlaying ? 0 : 2)
                    }
                }
            }
            Spacer()
            Button { playback.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(secondaryTint)
            }
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(secondaryTint)
            }
        }
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Audio rhythm wave

/// Horizontal flowing waveform: a few overlapping sine waves with different amplitude/wavelength/
/// speed/opacity (the varying opacity gives the depth look). Drifts while playing, freezes on pause.
///
/// If `level > 0` is supplied it overrides the synthetic "beat" envelope — the
/// waves then ride the *real* audio RMS sampled by `AudioLevelTap`. Falls back
/// to the synthetic beat when level isn't available (e.g. audio tap couldn't
/// install — happens on HLS or right at song-start before the asset loads).
struct AudioWave: View {
    var active: Bool
    var color: Color = .white
    /// 0…1, smoothed RMS from `PlaybackEngine.audioLevel`. 0 means "use synthetic".
    var level: Float = 0

    // (baseAmp fraction, wavelength, drift speed, pulse speed, pulse phase, max opacity, line width)
    private let waves: [(amp: CGFloat, wl: CGFloat, drift: Double, pulse: Double, pPhase: Double, opacity: Double, width: CGFloat)] = [
        (1.00, 235, 0.70, 2.6, 0.0, 0.45, 1.3),
        (0.74, 165, 1.10, 3.4, 1.1, 0.85, 1.1),
        (0.52, 125, 1.65, 4.3, 2.4, 0.32, 0.9),
    ]

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                let W = size.width
                for w in waves {
                    let pulse: Double
                    if level > 0.02 {
                        // Real-audio path: amplitude follows live RMS. Floor at
                        // 0.15 so the wave doesn't completely collapse during
                        // quiet passages.
                        pulse = max(0.15, Double(level))
                    } else {
                        // Synthetic fallback: two summed sines with a wide swing → snappy, music-like rise/fall
                        let beat = 0.5 + 0.38 * sin(t * w.pulse + w.pPhase) + 0.22 * sin(t * w.pulse * 1.9 + w.pPhase * 1.7)
                        pulse = max(0.08, beat)
                    }
                    // Clamp so the tallest peak always stays inside the view (no clipping). 0.92 leaves
                    // a little headroom for the line width on top of the half-height.
                    let amp = min(w.amp * CGFloat(pulse), 0.92) * size.height / 2
                    let phase = t * w.drift * 2.2
                    var path = Path()
                    var x: CGFloat = 0
                    func y(at x: CGFloat) -> CGFloat {
                        // envelope: 0 at both ends, 1 in the middle → all lines converge at the edges
                        let env = sin(Double(x / W) * .pi)
                        return midY + CGFloat(sin(Double(x / w.wl) * 2 * .pi + phase)) * amp * CGFloat(env)
                    }
                    path.move(to: CGPoint(x: 0, y: y(at: 0)))
                    while x <= W {
                        path.addLine(to: CGPoint(x: x, y: y(at: x)))
                        x += 2
                    }
                    // lighter at both ends, darker in the middle
                    let grad = Gradient(stops: [
                        .init(color: color.opacity(0), location: 0.0),
                        .init(color: color.opacity(w.opacity), location: 0.5),
                        .init(color: color.opacity(0), location: 1.0),
                    ])
                    ctx.stroke(path,
                               with: .linearGradient(grad,
                                                     startPoint: CGPoint(x: 0, y: midY),
                                                     endPoint: CGPoint(x: W, y: midY)),
                               lineWidth: w.width)
                }
            }
        }
    }
}

// MARK: - Custom progress slider

struct ProgressSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onChangeBegan: () -> Void
    var onChangeEnded: () -> Void

    init(value: Binding<Double>, in range: ClosedRange<Double>,
         onChangeBegan: @escaping () -> Void = {},
         onChangeEnded: @escaping () -> Void = {}) {
        self._value = value
        self.range = range
        self.onChangeBegan = onChangeBegan
        self.onChangeEnded = onChangeEnded
    }

    @State private var dragging = false
    @State private var lastWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let progress = max(0, min(1, (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 1)))
            let trackHeight: CGFloat = dragging ? 6 : 4
            let thumbSize: CGFloat = dragging ? 16 : 10
            let thumbX = geo.size.width * progress
            ZStack(alignment: .leading) {
                // Glass track (unfilled): white@18% capsule
                Capsule().fill(Color.white.opacity(0.18))
                    .frame(height: trackHeight)
                // Filled portion: brand gradient
                Capsule().fill(DS.Palette.brandGradient)
                    .frame(width: thumbX, height: trackHeight)
                // Thumb: half-opacity cassette beige — same warm palette as the
                // main play button, but soft enough to read as "secondary
                // control" rather than competing for the eye.
                Circle()
                    .fill(DS.Palette.cassetteBody.opacity(0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(height: 24, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; onChangeBegan() }
                        let x = max(0, min(geo.size.width, v.location.x))
                        let p = x / max(geo.size.width, 1)
                        value = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onChangeEnded()
                    }
            )
            .animation(DS.Motion.micro, value: dragging)
            .onAppear { lastWidth = geo.size.width }
        }
        .frame(height: 24)
    }
}

// MARK: - Lyrics scroll

struct LyricsScroll: View {
    let lines: [LyricLine]
    let currentTime: Double
    let onTap: (Double) -> Void

    var body: some View {
        // Look slightly ahead so the highlighted line lands as the vocal reaches it, matching
        // the CarPlay / lock-screen behavior.
        let active = LRCParser.activeIndex(at: currentTime + LyricSync.leadSeconds, in: lines)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Color.clear.frame(height: 80)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                        LyricRow(line: line, isCurrent: idx == active, activeBinding: active, onTap: onTap)
                    }
                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, DS.Spacing.l)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.15),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .onChange(of: active) { _, new in
                if let new {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(lines[new].id, anchor: .center)
                    }
                }
            }
        }
    }
}

/// Single lyric row. Extracted from the ForEach body because Swift's type checker
/// times out on the inline conditional `AnyShapeStyle(...)` ternary.
private struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let activeBinding: Int?
    let onTap: (Double) -> Void

    private var foreground: AnyShapeStyle {
        isCurrent
            ? AnyShapeStyle(DS.Palette.brandGradient)
            : AnyShapeStyle(Color.white.opacity(0.42))
    }

    private var translationColor: Color {
        isCurrent ? .white.opacity(0.85) : .white.opacity(0.32)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(isCurrent ? DS.Typo.lyricBig : DS.Typo.lyricSmall)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .scaleEffect(isCurrent ? 1.0 : 0.94)
                .animation(DS.Motion.lyric, value: activeBinding)
            if let tr = line.translation, !tr.isEmpty {
                Text(tr)
                    .font(.system(size: isCurrent ? 14 : 12))
                    .foregroundColor(translationColor)
            }
        }
        .frame(maxWidth: .infinity)
        .id(line.id)
        .contentShape(Rectangle())
        .onTapGesture {
            if line.time >= 0 { onTap(line.time) }
        }
    }
}
