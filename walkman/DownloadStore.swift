import Foundation
import Combine

/// A named sub-playlist under "已下载". Downloads are organised into these folders.
nonisolated struct DownloadFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var trackIDs: [String]

    init(id: UUID = UUID(), name: String, trackIDs: [String] = []) {
        self.id = id; self.name = name; self.trackIDs = trackIDs
    }
}

nonisolated enum DownloadStatus: String, Codable, Sendable {
    case downloading, completed, failed
}

/// One downloaded (or in-flight) track: its metadata, the chosen quality, the local file name,
/// and which sub-playlist it belongs to.
nonisolated struct DownloadRecord: Codable, Hashable, Sendable {
    var track: Track
    var quality: Quality
    var fileName: String          // relative name inside the Downloads directory
    var status: DownloadStatus
    var folderID: UUID
    var errorMessage: String?
}

@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    @Published private(set) var folders: [DownloadFolder] = []
    @Published private(set) var records: [String: DownloadRecord] = [:]   // trackID → record
    @Published private(set) var progress: [String: Double] = [:]          // trackID → 0...1 while active

    /// Injected by the app so downloads reuse the same URL resolution as playback.
    var urlResolver: ((Track, Quality) async throws -> URL)?
    /// 拉歌词 —— 沿用 PlaybackEngine.setLyricsResolver 同款依赖注入,DownloadStore
    /// 不直接知道 SourceManager / LyricsFetcher 是什么。下载完会用这个去拉歌词,
    /// 然后跟封面一起写进文件 metadata。
    var lyricsResolver: ((Track) async -> [LyricLine])?

    /// 新下载会落到这里。
    /// - iPad / iPhone: 沙盒 `Documents/Downloads/`
    /// - Mac Catalyst: `~/Music/Walkman/` —— 用户能直接在 Finder / 系统音乐 app 里看到
    private let primaryDir: URL
    /// 旧位置(沙盒 `Documents/Downloads/`)。只在 Mac 上有值,作为 lazy fallback ——
    /// 用户切换到新版本之前已经存在的下载不会消失,localURL 会先查 primary 再查 legacy。
    private let legacyDir: URL?
    private let foldersURL: URL
    private let recordsURL: URL
    private var runners: [String: FileDownloader] = [:]   // trackID → active downloader

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacy = docs.appendingPathComponent("Downloads", isDirectory: true)
        // JSON 状态文件永远跟 app 走(沙盒 Documents),不动它,免得迁移踩坑。
        self.foldersURL = docs.appendingPathComponent("downloadFolders.json")
        self.recordsURL = docs.appendingPathComponent("downloadRecords.json")

        #if targetEnvironment(macCatalyst)
        // Mac 走 ~/Music/Walkman。如果建不出来(权限 / sandbox 没批 entitlement),
        // 落回沙盒 Documents/Downloads,功能不至于挂。
        let musicRoot = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        let preferred = musicRoot?.appendingPathComponent("Walkman", isDirectory: true)
        if let preferred,
           ((try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil) {
            self.primaryDir = preferred
            self.legacyDir = legacy
        } else {
            self.primaryDir = legacy
            self.legacyDir = nil
        }
        #else
        self.primaryDir = legacy
        self.legacyDir = nil
        #endif

        try? FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        load()
        if folders.isEmpty {
            folders = [DownloadFolder(name: "默认")]
            save()
        }
    }

    /// 解析一个 trackID 对应的本地文件 URL —— primary 先看,没有再去 legacy(只 Mac 有)。
    private func resolveExistingURL(fileName: String) -> URL? {
        let primary = primaryDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        if let legacy = legacyDir?.appendingPathComponent(fileName),
           FileManager.default.fileExists(atPath: legacy.path) {
            return legacy
        }
        return nil
    }

    // MARK: - Queries

    func isDownloaded(_ trackID: String) -> Bool { records[trackID]?.status == .completed }

    /// Local file URL for a completed download, or nil.
    func localURL(for trackID: String) -> URL? {
        guard let rec = records[trackID], rec.status == .completed else { return nil }
        return resolveExistingURL(fileName: rec.fileName)
    }

    func quality(for trackID: String) -> Quality? { records[trackID]?.quality }

    func tracks(in folder: DownloadFolder) -> [Track] {
        folder.trackIDs.compactMap { records[$0]?.track }
    }

    var activeDownloads: [DownloadRecord] {
        records.values.filter { $0.status == .downloading }.sorted { $0.track.name < $1.track.name }
    }
    var completedCount: Int { records.values.filter { $0.status == .completed }.count }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String) -> DownloadFolder {
        let f = DownloadFolder(name: name)
        folders.append(f)
        save()
        return f
    }

    func renameFolder(_ id: UUID, name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        save()
    }

    /// Delete a folder and every download inside it (files + records).
    func deleteFolder(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        for tid in folders[i].trackIDs { removeDownload(trackID: tid, persist: false) }
        folders.remove(at: i)
        save()
    }

    // MARK: - Download

    func download(track: Track, quality: Quality, folderID: UUID) {
        guard records[track.id]?.status != .downloading else { return }
        // Re-downloading a completed track at a new quality: drop the old file first.
        if records[track.id] != nil { removeFile(for: track.id) }

        let ext = (quality == .flac || quality == .flac24) ? "flac" : "mp3"
        let fileName = "\(track.id.replacingOccurrences(of: "/", with: "_")).\(ext)"
        var rec = DownloadRecord(track: track, quality: quality, fileName: fileName, status: .downloading, folderID: folderID)
        rec.errorMessage = nil
        records[track.id] = rec
        progress[track.id] = 0
        if let fi = folders.firstIndex(where: { $0.id == folderID }), !folders[fi].trackIDs.contains(track.id) {
            folders[fi].trackIDs.append(track.id)
        }
        save()

        Task { await self.runDownload(track: track, quality: quality, fileName: fileName) }
    }

    private func runDownload(track: Track, quality: Quality, fileName: String) async {
        guard let resolver = urlResolver else {
            fail(track.id, "下载未就绪")
            return
        }
        let url: URL
        do {
            url = try await resolver(track, quality)
        } catch {
            fail(track.id, error.localizedDescription)
            return
        }
        let dest = primaryDir.appendingPathComponent(fileName)
        let runner = FileDownloader()
        runners[track.id] = runner
        runner.start(
            url: url,
            to: dest,
            progress: { [weak self] p in
                Task { @MainActor in self?.progress[track.id] = p }
            },
            finish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.runners[track.id] = nil
                    self.progress[track.id] = nil
                    switch result {
                    case .success:
                        self.records[track.id]?.status = .completed
                        self.records[track.id]?.errorMessage = nil
                        // 元数据写入是 best-effort 的后置步骤:歌曲已经是"下载完成"
                        // 状态了,标签写不上属于次要问题,失败不回滚成功状态。
                        self.embedMetadata(for: track, at: dest)
                    case .failure(let err):
                        self.fail(track.id, err.localizedDescription)
                    }
                    self.save()
                }
            }
        )
    }

    // MARK: - Metadata embedding

    /// 下载完成后异步拉封面 + 歌词,把它们 + track 信息一起写进音频文件 (ID3v2 或 FLAC tag)。
    /// 这一步是 fire-and-forget —— 失败不影响下载状态,日志输出而已。
    private func embedMetadata(for track: Track, at fileURL: URL) {
        let lyricsResolver = self.lyricsResolver
        Task.detached(priority: .utility) {
            // 1) 封面 —— track.picURL 不一定有,有的话 URLSession 抓字节;
            //    MIME 类型尽量从 HTTP response 拿,拿不到就按 URL 后缀猜。
            var coverData: Data? = nil
            var coverMIME: String? = nil
            if let urlStr = track.picURL, let url = URL(string: urlStr) {
                do {
                    var req = URLRequest(url: url)
                    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                                 forHTTPHeaderField: "User-Agent")
                    req.timeoutInterval = 15
                    let (data, response) = try await URLSession.shared.data(for: req)
                    coverData = data
                    if let http = response as? HTTPURLResponse,
                       let ct = http.value(forHTTPHeaderField: "Content-Type"),
                       ct.hasPrefix("image/") {
                        // 形如 "image/jpeg; charset=binary" —— 取分号前。
                        coverMIME = ct.split(separator: ";").first.map(String.init)
                    } else {
                        switch url.pathExtension.lowercased() {
                        case "png":  coverMIME = "image/png"
                        case "webp": coverMIME = "image/webp"
                        default:     coverMIME = "image/jpeg"
                        }
                    }
                } catch {
                    print("[Download] 封面抓取失败: \(error.localizedDescription)")
                }
            }

            // 2) 歌词 —— resolver 是注入的 LyricsFetcher 入口。
            var lrcText: String? = nil
            if let resolver = lyricsResolver {
                let lines = await resolver(track)
                if !lines.isEmpty {
                    lrcText = LRCSerializer.serialize(lines)
                }
            }

            // 3) 写入,扩展名分发到 MP3 / FLAC writer。
            AudioMetadataWriter.apply(
                to: fileURL,
                track: track,
                coverData: coverData,
                coverMIME: coverMIME,
                lrcText: lrcText
            )
        }
    }

    private func fail(_ trackID: String, _ message: String) {
        records[trackID]?.status = .failed
        records[trackID]?.errorMessage = message
        progress[trackID] = nil
        save()
    }

    /// Remove a single download (file + record + folder membership).
    func removeDownload(trackID: String, persist: Bool = true) {
        runners[trackID]?.cancel()
        runners[trackID] = nil
        progress[trackID] = nil
        removeFile(for: trackID)
        records[trackID] = nil
        for i in folders.indices { folders[i].trackIDs.removeAll { $0 == trackID } }
        if persist { save() }
    }

    func retry(trackID: String) {
        guard let rec = records[trackID] else { return }
        download(track: rec.track, quality: rec.quality, folderID: rec.folderID)
    }

    private func removeFile(for trackID: String) {
        guard let rec = records[trackID] else { return }
        // 两个位置都试着删 —— Mac 上可能存在 legacy 留下的老文件。
        try? FileManager.default.removeItem(at: primaryDir.appendingPathComponent(rec.fileName))
        if let legacy = legacyDir?.appendingPathComponent(rec.fileName) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: foldersURL),
           let decoded = try? JSONDecoder().decode([DownloadFolder].self, from: data) {
            folders = decoded
        }
        if let data = try? Data(contentsOf: recordsURL),
           let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            // Anything left as `.downloading` from a previous run never finished — mark failed.
            records = decoded.mapValues { rec in
                var r = rec
                if r.status == .downloading { r.status = .failed; r.errorMessage = "已中断" }
                return r
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: foldersURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: recordsURL, options: .atomic)
        }
    }
}

// MARK: - File downloader (progress via URLSessionDownloadDelegate)

/// Downloads a URL to a destination file, reporting progress. Kept separate from the @MainActor
/// store because URLSession delegate callbacks arrive on a background queue.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<Void, Error>) -> Void)?
    private var destination: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    func start(url: URL, to dest: URL, progress: @escaping (Double) -> Void, finish: @escaping (Result<Void, Error>) -> Void) {
        onProgress = progress
        onFinish = finish
        destination = dest
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: req)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        onProgress = nil
        onFinish = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onFinish?(.success(()))
        } catch {
            onFinish?(.failure(error))
        }
        onFinish = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            onFinish?(.failure(error))
            onFinish = nil
        }
        session.finishTasksAndInvalidate()
    }
}
