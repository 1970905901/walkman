import Foundation
import Combine
import WidgetKit

/// Watches PlaybackEngine for track changes and keeps the home-screen widget's
/// data fresh: downloads the cover to the App Group container, pushes a
/// `SharedRecentTrack` entry, and asks WidgetCenter to reload timelines.
///
/// This was previously folded into `LiveActivityController`; now that LA is
/// gone, the widget still needs the same data flow, so it lives here as a
/// dedicated, single-responsibility component.
@MainActor
final class RecentTracksRecorder: ObservableObject {
    private weak var playback: PlaybackEngine?
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackID: String?

    func bind(to playback: PlaybackEngine) {
        self.playback = playback
        // Two observers:
        //   1. Track identity → triggers cover download + recents push.
        //   2. isPlaying → updates SharedNowPlaying so the home-screen widget
        //      reflects the latest play/pause state and forces a refresh.
        playback.$currentTrack
            .removeDuplicates(by: { $0?.id == $1?.id })
            .sink { [weak self] track in self?.handleTrackChange(track) }
            .store(in: &cancellables)
        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.snapshotNowPlaying() }
            .store(in: &cancellables)
    }

    /// Writes the current snapshot (title/artist/cover/isPlaying/elapsed) into
    /// the App-Group store and reloads widget timelines. The widget extrapolates
    /// `elapsed` from `updatedAt` so we don't need to write every second.
    private func snapshotNowPlaying() {
        guard let playback else { return }
        guard let track = playback.currentTrack else {
            SharedNowPlayingStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let snapshot = SharedNowPlaying(
            trackID: track.id,
            title: track.name,
            artist: track.singer.isEmpty ? track.source.displayName : track.singer,
            coverLocalPath: SharedRecentStore.read().first(where: { $0.id == track.id })?.coverLocalPath,
            isPlaying: playback.isPlaying,
            elapsed: playback.currentTime,
            duration: playback.duration,
            updatedAt: Date()
        )
        SharedNowPlayingStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func handleTrackChange(_ track: Track?) {
        guard let track else {
            SharedNowPlayingStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard track.id != lastTrackID else { return }
        lastTrackID = track.id

        let id = track.id
        let title = track.name
        let artist = track.singer.isEmpty ? track.source.displayName : track.singer
        let sourceName = track.source.displayName
        let coverURL = track.picURL

        // Push immediately without cover so widget can show *something* within
        // seconds (brand-gradient + first-character placeholder), then update
        // again once the real image is on disk.
        SharedRecentStore.push(SharedRecentTrack(
            id: id, title: title, artist: artist,
            coverLocalPath: nil, sourceName: sourceName))
        snapshotNowPlaying()

        Task {
            guard let localPath = await CoverCache.fetch(coverURL)?.path else { return }
            await MainActor.run {
                guard self.lastTrackID == id else { return }
                SharedRecentStore.push(SharedRecentTrack(
                    id: id, title: title, artist: artist,
                    coverLocalPath: localPath, sourceName: sourceName))
                self.snapshotNowPlaying()  // refresh NowPlaying with cover path
            }
        }
    }
}
