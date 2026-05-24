import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @EnvironmentObject var sources: SourceManager
    @Environment(\.dismiss) var dismiss
    @StateObject private var artwork = ArtworkColors()
    @State private var seekValue: Double = 0
    @State private var isSeeking: Bool = false
    @State private var page: Int = 0  // 0 = cover, 1 = lyrics
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var loadingLyrics = false
    @State private var trackToFavorite: Track?
    @State private var trackToDownload: Track?

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
        .onAppear {
            sync()
        }
        .onChange(of: playback.currentTrack?.id) { _, _ in sync() }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .preferredColorScheme(.light)   // sheet stays in normal appearance
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $trackToFavorite) { track in
            AddToPlaylistSheet(track: track)
        }
        .sheet(item: $trackToDownload) { track in
            DownloadSheet(track: track)
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

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("正在播放").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.65))
                HStack(spacing: 5) {
                    Text(playback.currentTrack?.source.displayName ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    // Actual quality being played (after lx-music's getPlayQuality cascade)
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
                        .background(Color.white.opacity(0.15), in: Capsule())
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Menu {
                    Button { if let t = playback.currentTrack { trackToFavorite = t } } label: {
                        Label("收藏", systemImage: "heart")
                    }
                    Button { if let t = playback.currentTrack { trackToDownload = t } } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(playback.currentTrack == nil)
            }
        }
        .foregroundColor(.white)
        .padding(.top, 8)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(page == i ? 0.95 : 0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Cover page

    private var coverPage: some View {
        VStack(spacing: DS.Spacing.xl) {
            Spacer()
            ZStack {
                Artwork(url: playback.currentTrack?.picURL, size: 320, radius: DS.Radius.xlarge)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
                    .scaleEffect(playback.isPlaying ? 1.0 : 0.92)
                    .animation(.spring(duration: 0.45), value: playback.isPlaying)
            }
            VStack(spacing: 6) {
                Text(playback.currentTrack?.name ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(playback.currentTrack?.subtitle ?? "")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Lyrics page

    private var lyricsPage: some View {
        Group {
            if loadingLyrics {
                ProgressView().tint(.white)
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
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.75))
        }
        .padding(.bottom, DS.Spacing.l)
    }

    // MARK: - Controls

    private var controlSection: some View {
        HStack {
            Button {
                playback.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(playback.shuffle ? .white : .white.opacity(0.55))
            }
            Spacer()
            Button { playback.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
            Spacer()
            Button { playback.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Color.white)
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    if playback.isBuffering {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.black)
                            .offset(x: playback.isPlaying ? 0 : 2)
                    }
                }
            }
            Spacer()
            Button { playback.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
            Spacer()
            Button {
                let modes = PlaybackEngine.LoopMode.allCases
                let i = modes.firstIndex(of: playback.loopMode) ?? 0
                playback.loopMode = modes[(i + 1) % modes.count]
            } label: {
                Image(systemName: playback.loopMode.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(playback.loopMode == .off ? .white.opacity(0.55) : .white)
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
            let trackHeight: CGFloat = dragging ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                    .frame(height: trackHeight)
                Capsule().fill(Color.white)
                    .frame(width: geo.size.width * progress, height: trackHeight)
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
            .animation(.easeOut(duration: 0.15), value: dragging)
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
        let active = LRCParser.activeIndex(at: currentTime, in: lines)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Color.clear.frame(height: 80)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                        VStack(spacing: 4) {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: idx == active ? 19 : 16, weight: idx == active ? .bold : .regular))
                                .foregroundColor(idx == active ? .white : .white.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .scaleEffect(idx == active ? 1.05 : 1.0)
                                .animation(.spring(duration: 0.4), value: active)
                            if let tr = line.translation, !tr.isEmpty {
                                Text(tr)
                                    .font(.system(size: idx == active ? 14 : 12))
                                    .foregroundColor(idx == active ? .white.opacity(0.85) : .white.opacity(0.35))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .id(line.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if line.time >= 0 { onTap(line.time) }
                        }
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
