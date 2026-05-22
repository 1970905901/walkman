import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering: Bool = false
    @Published var queue: [Track] = []
    @Published private(set) var queueIndex: Int = 0
    @Published var loopMode: LoopMode = .all
    @Published var shuffle: Bool = false
    @Published var lastError: String?  // surfaced to UI when URL resolution / playback fails
    @Published private(set) var currentOrigin: ResolveOrigin?  // which mechanism produced the playing URL
    @Published private(set) var currentQuality: Quality?  // actual quality of the playing URL (after cascade)

    enum LoopMode: String, CaseIterable {
        case off, all, one
        var icon: String {
            switch self {
            case .off: return "arrow.right.to.line"
            case .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var newAccessLogObserver: NSObjectProtocol?
    private var newErrorLogObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var currentArtwork: MPMediaItemArtwork?
    /// Per-track cap on quality. When AVPlayer rejects a high-bitrate file (e.g. Kugou's
    /// 24-bit FLAC that AVFoundation can't decode), we cascade down: flac24bit → flac → 320k → 128k.
    /// `nil` means "respect the user's preferred quality" — set when a new track starts.
    @Published private(set) var qualityCap: Quality? = nil
    /// Tracks which qualities we've already tried on the current track so we don't loop.
    private var triedQualities: Set<Quality> = []
    private var resolveURLHandler: ((Track) async throws -> ResolvedTrack)?

    init() {
        configureAudioSession()
        setupRemoteCommands()
    }

    func setURLResolver(_ resolver: @escaping (Track) async throws -> ResolvedTrack) {
        self.resolveURLHandler = resolver
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[PlaybackEngine] AudioSession setup failed: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let evt = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: evt.positionTime) }
            return .success
        }
    }

    func playDirectURL(_ url: URL, asTrack: Track) {
        currentTrack = asTrack
        currentOrigin = .localFile
        currentQuality = nil
        startPlayback(url: url)
    }

    func play(track: Track, in newQueue: [Track]? = nil, startIndex: Int? = nil) {
        print("[PlaybackEngine] play(\(track.source.rawValue)_\(track.songmid) \(track.name)) queue.count=\(newQueue?.count ?? queue.count) currentQueueSize=\(queue.count)")
        if let nq = newQueue {
            queue = nq
            queueIndex = startIndex ?? (nq.firstIndex(where: { $0.id == track.id }) ?? 0)
        } else if let idx = queue.firstIndex(where: { $0.id == track.id }) {
            queueIndex = idx
        } else {
            queue = [track]
            queueIndex = 0
        }
        Task { await loadAndPlayCurrent() }
    }

    private func loadAndPlayCurrent() async {
        guard queueIndex >= 0, queueIndex < queue.count else { return }
        let track = queue[queueIndex]
        // Reset per-track state when actually switching songs.
        if currentTrack?.id != track.id {
            qualityCap = nil
            triedQualities = []
        }
        if let q = currentQuality { triedQualities.insert(q) }
        currentTrack = track
        currentOrigin = nil
        currentQuality = nil
        isBuffering = true
        lastError = nil
        do {
            let url: URL
            if track.source == .local, let directURL = URL(string: track.songmid) {
                url = directURL
                currentOrigin = .localFile
            } else if let resolver = resolveURLHandler {
                let resolved = try await resolver(track)
                url = resolved.url
                currentOrigin = resolved.origin
                currentQuality = resolved.quality
                if let warning = resolved.warning {
                    lastError = warning   // ErrorBanner shows it as an orange notice
                }
            } else {
                throw NSError(domain: "Playback", code: -1, userInfo: [NSLocalizedDescriptionKey: "No URL resolver"])
            }
            startPlayback(url: url)
        } catch {
            isBuffering = false
            isPlaying = false
            lastError = "无法播放《\(track.name)》: \(error.localizedDescription)"
            print("[PlaybackEngine] resolve URL failed for \(track.name): \(error)")
        }
    }

    private func startPlayback(url: URL) {
        cleanupPlayer()
        print("[PlaybackEngine] startPlayback url=\(url.absoluteString)")
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        self.player = p

        // KVO: AVPlayerItem.status — fires when item loads / fails.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    print("[PlaybackEngine] item ready, duration=\(item.duration.seconds)")
                    self.qualityCap = nil   // success → next time use user's preferred again
                case .failed:
                    let err = item.error?.localizedDescription ?? "未知错误"
                    let nsErr = item.error as NSError?
                    print("[PlaybackEngine] item failed: \(err) [domain=\(nsErr?.domain ?? "?") code=\(nsErr?.code ?? 0)]")
                    // Recover from "format not recognised" by trying a lower quality.
                    // -11828 = AVErrorFileFormatNotRecognized (Hi-Res FLAC etc. AVFoundation rejects).
                    let isFormatErr = (nsErr?.domain == AVFoundationErrorDomain) && (nsErr?.code == -11828 || nsErr?.code == -11829)
                    if isFormatErr, let track = self.currentTrack, track.source != .local,
                       let nextQ = self.nextLowerQuality(below: self.currentQuality ?? .flac24, supportedBy: track),
                       !self.triedQualities.contains(nextQ) {
                        print("[PlaybackEngine] format not supported at \(self.currentQuality?.rawValue ?? "?"), retrying at \(nextQ.rawValue)")
                        self.qualityCap = nextQ
                        Task { await self.loadAndPlayCurrent() }
                        return
                    }
                    self.isBuffering = false
                    self.isPlaying = false
                    self.lastError = isFormatErr
                        ? "AVFoundation 无法解码这首歌的任何音质版本(可能是 Kugou Hi-Res FLAC 的私有封装)"
                        : "播放失败: \(err)"
                case .unknown:
                    print("[PlaybackEngine] item status unknown")
                @unknown default: break
                }
            }
        }
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { item, _ in
            if item.isPlaybackBufferEmpty {
                print("[PlaybackEngine] buffer empty (likely stall)")
            }
        }
        newErrorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main
        ) { [weak self] _ in
            if let last = (self?.player?.currentItem?.errorLog()?.events ?? []).last {
                print("[PlaybackEngine] AVPlayerItem error event: domain=\(last.errorDomain) code=\(last.errorStatusCode) uri=\(last.uri ?? "?") comment=\(last.errorComment ?? "?")")
            }
        }

        // Watch for AVPlayerItem failures so we don't silently spin forever.
        let failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "未知错误"
            Task { @MainActor in
                print("[PlaybackEngine] failed-to-play-to-end: \(err)")
                self?.isBuffering = false
                self?.isPlaying = false
                self?.lastError = "播放失败: \(err)"
            }
        }
        self.failObserver = failObserver
        stalledObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main
        ) { _ in
            print("[PlaybackEngine] playback stalled")
        }

        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                if let total = self.player?.currentItem?.duration.seconds, total.isFinite, total > 0 {
                    self.duration = total
                }
                self.isBuffering = (self.player?.currentItem?.isPlaybackLikelyToKeepUp == false)
                self.updateNowPlayingTime()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnded() }
        }
        p.play()
        isPlaying = true
        isBuffering = true
        updateNowPlayingInfo()
        loadArtwork()
    }

    private func cleanupPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = failObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = stalledObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = newAccessLogObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = newErrorLogObserver { NotificationCenter.default.removeObserver(obs) }
        statusObservation?.invalidate(); statusObservation = nil
        bufferEmptyObservation?.invalidate(); bufferEmptyObservation = nil
        timeObserver = nil
        endObserver = nil
        failObserver = nil
        stalledObserver = nil
        newAccessLogObserver = nil
        newErrorLogObserver = nil
        player?.pause()
        player = nil
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingTime()
    }

    func resume() {
        if currentTrack == nil, !queue.isEmpty {
            queueIndex = max(0, min(queueIndex, queue.count - 1))
            Task { await loadAndPlayCurrent() }
            return
        }
        player?.play()
        isPlaying = true
        updateNowPlayingTime()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
        updateNowPlayingTime()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffle {
            queueIndex = Int.random(in: 0..<queue.count)
        } else {
            queueIndex = (queueIndex + 1) % queue.count
        }
        Task { await loadAndPlayCurrent() }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0); return
        }
        if shuffle {
            queueIndex = Int.random(in: 0..<queue.count)
        } else {
            queueIndex = (queueIndex - 1 + queue.count) % queue.count
        }
        Task { await loadAndPlayCurrent() }
    }

    private func handleItemEnded() {
        switch loopMode {
        case .one:
            seek(to: 0); player?.play()
        case .all:
            next()
        case .off:
            if queueIndex + 1 < queue.count { next() } else { pause(); seek(to: 0) }
        }
    }

    /// Jump to a specific index in the current queue without changing the queue itself.
    func jump(to index: Int) {
        guard !queue.isEmpty else { return }
        queueIndex = max(0, min(index, queue.count - 1))
        Task { await loadAndPlayCurrent() }
    }

    /// Remove a track at `index`. If it was the current one, advance to the next (or stop).
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let wasCurrent = (index == queueIndex)
        queue.remove(at: index)
        if queue.isEmpty {
            clearQueue()
            return
        }
        if wasCurrent {
            // Keep the same index — that's now the next track. Clamp first.
            queueIndex = min(queueIndex, queue.count - 1)
            Task { await loadAndPlayCurrent() }
        } else if index < queueIndex {
            // Removed a track before the current one; shift index back so currentTrack is unchanged.
            queueIndex -= 1
        }
    }

    /// Move a track within the queue (drag-reorder).
    func moveInQueue(from source: Int, to destination: Int) {
        guard queue.indices.contains(source) else { return }
        let track = queue.remove(at: source)
        let target = min(destination, queue.count)
        queue.insert(track, at: target)
        if source == queueIndex {
            queueIndex = target
        } else if source < queueIndex, target >= queueIndex {
            queueIndex -= 1
        } else if source > queueIndex, target <= queueIndex {
            queueIndex += 1
        }
    }

    func clearQueue() {
        cleanupPlayer()
        queue = []
        currentTrack = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = track.name
        info[MPMediaItemPropertyArtist] = track.singer
        if let album = track.albumName { info[MPMediaItemPropertyAlbumTitle] = album }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let art = currentArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyPlaybackDuration] = duration
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork() {
        currentArtwork = nil
        guard let urlStr = currentTrack?.picURL, let url = URL(string: urlStr) else { return }
        Task.detached { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data) else { return }
            await MainActor.run { [weak self] in
                self?.currentArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self?.updateNowPlayingInfo()
            }
        }
    }

    /// Cascade: flac24bit → flac → 320k → 128k. Returns next quality below `current` that
    /// the track lists; if none listed, returns the next cascade entry anyway (the resolver
    /// will try and either succeed or trigger another retry).
    nonisolated func nextLowerQuality(below current: Quality, supportedBy track: Track) -> Quality? {
        let cascade: [Quality] = [.flac24, .flac, .k320, .k128]
        guard let idx = cascade.firstIndex(of: current), idx + 1 < cascade.count else { return nil }
        for q in cascade[(idx + 1)...] where track.qualities.contains(q) {
            return q
        }
        return cascade.dropFirst(idx + 1).first
    }
}
