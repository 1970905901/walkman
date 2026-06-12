import Foundation
import Combine
import ShazamKit
import AVFAudio

/// ShazamKit 听歌识曲。SHManagedSession 自己管理麦克风采集和音频会话,
/// 这里只负责状态机:开始 → 聆听 → 命中/未命中/出错。
@MainActor
final class SongRecognizer: ObservableObject {
    struct Match: Equatable {
        let title: String
        let artist: String
        let artworkURL: URL?
    }

    enum State: Equatable {
        case idle
        case listening
        case matched(Match)
        case noMatch
        case micDenied
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var session: SHManagedSession?
    private var task: Task<Void, Never>?

    func start() {
        stop()
        state = .listening
        task = Task { [weak self] in
            guard let self else { return }
            let granted = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled else { return }
            guard granted else { self.state = .micDenied; return }

            let session = SHManagedSession()
            self.session = session
            let result = await session.result()
            session.cancel()
            self.session = nil
            guard !Task.isCancelled else { return }

            switch result {
            case .match(let match):
                if let item = match.mediaItems.first {
                    self.state = .matched(Match(
                        title: item.title ?? "未知歌曲",
                        artist: item.artist ?? "未知歌手",
                        artworkURL: item.artworkURL))
                } else {
                    self.state = .noMatch
                }
            case .noMatch:
                self.state = .noMatch
            case .error(let error, _):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.cancel()
        session = nil
        if state == .listening { state = .idle }
    }
}
