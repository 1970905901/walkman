import SwiftUI

/// "Up Next" — current playback queue with reorder / remove / tap-to-play.
/// Shown as a sheet from PlayerView.
struct QueueView: View {
    @EnvironmentObject var playback: PlaybackEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modeBar
                if playback.queue.isEmpty {
                    ContentUnavailableView("队列空空如也", systemImage: "music.note.list",
                                           description: Text("从搜索、排行榜或歌单点歌后,接下来播放的歌会显示在这里"))
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(Array(playback.queue.enumerated()), id: \.element.id) { idx, track in
                                row(idx: idx, track: track)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            }
                            .onMove { src, dst in
                                guard let from = src.first else { return }
                                playback.moveInQueue(from: from, to: dst)
                            }
                            .onDelete { idxs in
                                for i in idxs.sorted(by: >) { playback.removeFromQueue(at: i) }
                            }
                        } header: {
                            HStack {
                                Text("接下来播放").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                                Spacer()
                                Text("\(playback.queue.count) 首").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                if !playback.queue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            playback.clearQueue()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, track: Track) -> some View {
        let isCurrent = idx == playback.queueIndex
        HStack(spacing: 10) {
            // Leading: either an animated "now playing" indicator or the queue number
            ZStack {
                if isCurrent {
                    Image(systemName: playback.isPlaying ? "waveform" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)
                } else {
                    Text("\(idx + 1)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 24)

            Artwork(url: track.picURL, size: 38, radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.name)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                        .foregroundColor(isCurrent ? .accentColor : .primary)
                        .lineLimit(1)
                    if let style = QualityBadgeStyle(highestIn: track.qualities) {
                        QualityBadge(style: style)
                    }
                }
                HStack(spacing: 5) {
                    SourceChip(source: track.source)
                    Text(track.singer).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let d = track.duration {
                Text(format(d))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isCurrent {
                playback.togglePlayPause()
            } else {
                playback.jump(to: idx)
            }
        }
    }

    private var modeBar: some View {
        HStack(spacing: 12) {
            Button {
                playback.shuffle.toggle()
            } label: {
                Label(playback.shuffle ? "随机播放" : "顺序播放", systemImage: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(playback.shuffle ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                    .foregroundColor(playback.shuffle ? .white : .primary)
            }
            .buttonStyle(.plain)

            Button {
                let modes = PlaybackEngine.LoopMode.allCases
                let i = modes.firstIndex(of: playback.loopMode) ?? 0
                playback.loopMode = modes[(i + 1) % modes.count]
            } label: {
                Label(loopLabel, systemImage: playback.loopMode.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(playback.loopMode == .off ? Color(.secondarySystemBackground) : Color.accentColor, in: Capsule())
                    .foregroundColor(playback.loopMode == .off ? .primary : .white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var loopLabel: String {
        switch playback.loopMode {
        case .off: return "不循环"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }

    private func format(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}
