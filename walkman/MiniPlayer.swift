import SwiftUI

extension View {
    /// 给内容底部让出 MiniPlayer 占的高度。
    ///
    /// MiniPlayer 是浮在 TabView 之上的 overlay(见 RootTabView.overlays),
    /// overlay 不参与布局,所以列表滚到底时最后一行会被它盖住。这里用
    /// safeAreaInset 补上等高的安全区 —— 挂在 NavigationStack 上,push 进去的
    /// 详情页也会继承,不用每个页面各自记着留白。没在播放时不占空间。
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }
}

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject var playback: PlaybackEngine

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: playback.currentTrack != nil ? MiniPlayer.cardHeight + DS.Spacing.s : 0)
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var playback: PlaybackEngine
    @ObservedObject private var downloads = DownloadStore.shared
    var onTap: () -> Void

    var body: some View {
        if let track = playback.currentTrack {
            HStack(spacing: 10) {
                Artwork(url: downloads.displayCoverURL(for: track), size: 42, radius: DS.Radius.small)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(track.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let q = playback.currentQuality {
                            QualityBadge(style: QualityBadgeStyle(quality: q))
                        }
                    }
                    Text(track.singer).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if playback.isBuffering {
                    UIKitSpinner(style: .medium).frame(width: 30, height: 30)
                } else {
                    PlayPauseRing(progress: progress, isPlaying: playback.isPlaying) {
                        playback.togglePlayPause()
                    }
                }
                Button { playback.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.85))
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 6)
            .background(DS.Glass.mid)   // mid pane — heavier than .ultraThin so the mini player reads as a "surface" against any underlying content
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    .stroke(DS.Palette.strokeSubtle, lineWidth: 0.5)
            )
            .elevation(DS.Elevation.e2())
            .padding(.horizontal, DS.Spacing.s)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
    }

    /// 卡片自身的高度:封面 42 + 上下 padding 6 各一。给 miniPlayerInset 用,
    /// 改了这里的布局记得跟着改,否则列表底部要么被挡要么留白过多。
    static let cardHeight: CGFloat = 42 + 6 * 2

    private var progress: Double {
        guard playback.duration > 0 else { return 0 }
        return min(1, max(0, playback.currentTime / playback.duration))
    }
}

private struct PlayPauseRing: View {
    let progress: Double
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(DS.Palette.strokeStrong, lineWidth: 2)
                    .frame(width: 30, height: 30)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(DS.Palette.brandStart, style: .init(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 30, height: 30)
                    .animation(.linear(duration: 0.4), value: progress)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(DS.Palette.brandGradient)
            }
        }
        .buttonStyle(.plain)
    }
}
