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

    private let dir: URL
    private let foldersURL: URL
    private let recordsURL: URL
    private var runners: [String: FileDownloader] = [:]   // trackID → active downloader

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        self.foldersURL = docs.appendingPathComponent("downloadFolders.json")
        self.recordsURL = docs.appendingPathComponent("downloadRecords.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        if folders.isEmpty {
            folders = [DownloadFolder(name: "默认")]
            save()
        }
    }

    // MARK: - Queries

    func isDownloaded(_ trackID: String) -> Bool { records[trackID]?.status == .completed }

    /// Local file URL for a completed download, or nil.
    func localURL(for trackID: String) -> URL? {
        guard let rec = records[trackID], rec.status == .completed else { return nil }
        let url = dir.appendingPathComponent(rec.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
        let dest = dir.appendingPathComponent(fileName)
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
                    case .failure(let err):
                        self.fail(track.id, err.localizedDescription)
                    }
                    self.save()
                }
            }
        )
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
        let url = dir.appendingPathComponent(rec.fileName)
        try? FileManager.default.removeItem(at: url)
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
