import Foundation
import Combine

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [PlaylistMeta] = []
    @Published private(set) var trackBank: [String: Track] = [:]

    private let playlistsURL: URL
    private let trackBankURL: URL

    private var cloudCancellable: AnyCancellable?

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.playlistsURL = dir.appendingPathComponent("playlists.json")
        self.trackBankURL = dir.appendingPathComponent("trackBank.json")
        load()
        if playlists.isEmpty {
            if let remote: [PlaylistMeta] = CloudSync.shared.pull([PlaylistMeta].self, forKey: CloudSync.Keys.playlists) {
                playlists = remote
            }
            if let bank: [String: Track] = CloudSync.shared.pull([String: Track].self, forKey: CloudSync.Keys.trackBank) {
                trackBank = bank
            }
        }
        if playlists.isEmpty {
            playlists.append(PlaylistMeta(name: "我喜欢的"))
            save()
        }
        // 清理已经存在的同名重复 — 上一版 pullFromCloud 有 dedupe bug 时
        // 已经写到磁盘的两个 "我喜欢的" 在 load() 后会都被读进 playlists。
        // 这里调一次 dedupeByName 让本地数据收敛。
        let before = playlists.count
        dedupeByName()
        if playlists.count != before { save() }
        cloudCancellable = CloudSync.shared.didReceiveRemoteChange.sink { [weak self] in
            self?.pullFromCloud()
        }
    }

    /// 按名字归并 playlists — 同名的合并曲目(union)、updatedAt 取最大。
    /// 用于:
    ///   1. App 启动时清理之前 bug 写入的重复数据
    ///   2. pullFromCloud 第二遍 dedupe
    private func dedupeByName() {
        var deduped: [PlaylistMeta] = []
        for p in playlists {
            if let i = deduped.firstIndex(where: { $0.name == p.name }) {
                var combined = deduped[i]
                for tid in p.trackIDs where !combined.trackIDs.contains(tid) {
                    combined.trackIDs.append(tid)
                }
                combined.updatedAt = max(combined.updatedAt, p.updatedAt)
                deduped[i] = combined
            } else {
                deduped.append(p)
            }
        }
        playlists = deduped
    }

    private func pullFromCloud() {
        if let remote: [PlaylistMeta] = CloudSync.shared.pull([PlaylistMeta].self, forKey: CloudSync.Keys.playlists) {
            // 合并:同名歌单当成同一个,避免各端 init 时本地默认创建的
            // "我喜欢的" 跟从其它设备同步过来的 "我喜欢的" 出现两条。
            //   1. 先按 UUID 直接匹配 — 取 updatedAt 较新的
            //   2. UUID 不匹配但同名 → 合并曲目(union),取最新 updatedAt
            //   3. 既无 UUID 匹配也无同名 → 作为新歌单加入
            // 最后再走一遍同名 dedupe(防止 remote 内部就有同名重复 +
            // local 与 remote 之间的 dedupe 顺序问题)。
            var merged = playlists
            for r in remote {
                if let i = merged.firstIndex(where: { $0.id == r.id }) {
                    if r.updatedAt > merged[i].updatedAt {
                        // 本地导入的歌不上云,远端版本里必然没有 — 合并回来防丢。
                        var newer = r
                        for tid in merged[i].trackIDs
                        where isLocalImport(tid) && !newer.trackIDs.contains(tid) {
                            newer.trackIDs.append(tid)
                        }
                        merged[i] = newer
                    }
                } else if let i = merged.firstIndex(where: { $0.name == r.name }) {
                    var combined = r
                    for tid in merged[i].trackIDs where !combined.trackIDs.contains(tid) {
                        combined.trackIDs.append(tid)
                    }
                    combined.updatedAt = max(combined.updatedAt, merged[i].updatedAt)
                    merged[i] = combined
                } else {
                    merged.append(r)
                }
            }
            playlists = merged
            // 第二遍 dedupe — 防止 remote 内部就有同名重复 + local 与 remote
            // 之间的 dedupe 处理顺序在某些 case 下漏掉的歧义
            dedupeByName()
        }
        if let bank: [String: Track] = CloudSync.shared.pull([String: Track].self, forKey: CloudSync.Keys.trackBank) {
            trackBank.merge(bank) { local, _ in local }
        }
        // 推回 iCloud — 让所有设备最终收敛到同一份 UUID 列表,不会再分叉
        save(skipCloud: false)
    }

    func tracks(in playlist: PlaylistMeta) -> [Track] {
        playlist.trackIDs.compactMap { trackBank[$0] }
    }

    func addTracks(_ tracks: [Track], to playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for t in tracks {
            trackBank[t.id] = t
            if !playlists[idx].trackIDs.contains(t.id) {
                playlists[idx].trackIDs.append(t.id)
            }
        }
        playlists[idx].updatedAt = Date()
        save()
    }

    func remove(trackIDs: [String], from playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].trackIDs.removeAll { trackIDs.contains($0) }
        playlists[idx].updatedAt = Date()
        save()
        cleanTrackBank()
    }

    func createPlaylist(name: String) -> PlaylistMeta {
        let p = PlaylistMeta(name: name)
        playlists.append(p)
        save()
        return p
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
        cleanTrackBank()
    }

    func renamePlaylist(_ id: UUID, name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
        playlists[idx].updatedAt = Date()
        save()
    }

    private func cleanTrackBank() {
        let keep = Set(playlists.flatMap { $0.trackIDs })
        trackBank = trackBank.filter { keep.contains($0.key) }
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: playlistsURL),
           let decoded = try? JSONDecoder().decode([PlaylistMeta].self, from: data) {
            playlists = decoded
        }
        if let data = try? Data(contentsOf: trackBankURL),
           let decoded = try? JSONDecoder().decode([String: Track].self, from: data) {
            trackBank = decoded
        }
    }

    private func save(skipCloud: Bool = false) {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: playlistsURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(trackBank) {
            try? data.write(to: trackBankURL, options: .atomic)
        }
        if !skipCloud {
            // 本地文件夹导入的歌(lf://)的 bookmark 只在本机有效,同步到其它设备
            // 也播不了,所以歌曲和纯本地歌单都不上云。
            let cloudBank = trackBank.filter { !isLocalImport($0.key) }
            let cloudPlaylists: [PlaylistMeta] = playlists.compactMap { p in
                var copy = p
                copy.trackIDs = p.trackIDs.filter { !isLocalImport($0) }
                if copy.trackIDs.isEmpty && !p.trackIDs.isEmpty { return nil }
                return copy
            }
            CloudSync.shared.push(cloudPlaylists, forKey: CloudSync.Keys.playlists)
            CloudSync.shared.push(cloudBank, forKey: CloudSync.Keys.trackBank)
        }
    }

    /// 本地文件夹导入的歌(songmid 是 lf:// 引用)。
    private func isLocalImport(_ trackID: String) -> Bool {
        trackBank[trackID]?.songmid.hasPrefix(LocalMusicStore.scheme) ?? false
    }
}

@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [UserScript] = []

    private let url: URL
    private var cloudCancellable: AnyCancellable?

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.url = dir.appendingPathComponent("scripts.json")
        load()
        // Migrate from cloud if local is empty (fresh install on a 2nd device).
        if scripts.isEmpty,
           let remote: [UserScript] = CloudSync.shared.pull([UserScript].self, forKey: CloudSync.Keys.scripts) {
            scripts = remote
            save(skipCloud: true)
        }
        cloudCancellable = CloudSync.shared.didReceiveRemoteChange.sink { [weak self] in
            self?.pullFromCloud()
        }
    }

    private func pullFromCloud() {
        guard let remote: [UserScript] = CloudSync.shared.pull([UserScript].self, forKey: CloudSync.Keys.scripts) else { return }
        // Last-write-wins by `name + version` — script identity is the bundle,
        // not the UUID (UUIDs differ across devices for the same script source).
        var merged = scripts
        for r in remote {
            if !merged.contains(where: { $0.name == r.name && $0.version == r.version }) {
                merged.append(r)
            }
        }
        if merged.count != scripts.count {
            scripts = merged
            save(skipCloud: true)
        }
    }

    func add(_ script: UserScript) {
        scripts.removeAll { $0.id == script.id }
        scripts.append(script)
        save()
    }

    func remove(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: UUID, enabled: Bool) {
        guard let idx = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[idx].enabled = enabled
        save()
    }

    /// Parse standard lx-music user-script header comment for metadata.
    static func parseMetadata(from raw: String) -> UserScript {
        var name = "未命名脚本"
        var description = ""
        var version = "1.0.0"
        var author = "未知"
        var homepage = ""
        let header = String(raw.prefix(2000))
        // split(whereSeparator:) instead of split(separator: "\n") — "\r\n" is a
        // single Character in Swift, so splitting on "\n" misses CRLF line endings
        // and glues lines together (real scripts in the wild mix CRLF/LF).
        for line in header.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*") || trimmed.hasPrefix("//") else { continue }
            let body = trimmed.replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "//", with: "")
                .trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("@name") {
                name = body.replacingOccurrences(of: "@name", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@description") {
                description = body.replacingOccurrences(of: "@description", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@version") {
                version = body.replacingOccurrences(of: "@version", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@author") {
                author = body.replacingOccurrences(of: "@author", with: "").trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("@homepage") || body.hasPrefix("@repository") {
                homepage = body.replacingOccurrences(of: "@homepage", with: "")
                    .replacingOccurrences(of: "@repository", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return UserScript(name: name, description: description, version: version,
                          author: author, homepage: homepage, rawScript: raw)
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([UserScript].self, from: data) {
            scripts = decoded
            // Self-heal entries imported before the CRLF parsing fix: re-derive
            // metadata from the stored script body if the name never parsed.
            var healed = false
            for idx in scripts.indices where scripts[idx].name == "未命名脚本" {
                let reparsed = Self.parseMetadata(from: scripts[idx].rawScript)
                guard reparsed.name != "未命名脚本" else { continue }
                scripts[idx].name = reparsed.name
                scripts[idx].description = reparsed.description
                scripts[idx].version = reparsed.version
                scripts[idx].author = reparsed.author
                scripts[idx].homepage = reparsed.homepage
                healed = true
            }
            if healed { save() }
        }
    }

    private func save(skipCloud: Bool = false) {
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: url, options: .atomic)
        }
        // Push to iCloud KV — 1 MB total limit; CloudSync.push silently
        // refuses oversize payloads so a single very large script just won't
        // sync rather than breaking the rest of the store.
        if !skipCloud {
            CloudSync.shared.push(scripts, forKey: CloudSync.Keys.scripts)
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var preferredQuality: Quality {
        didSet { UserDefaults.standard.set(preferredQuality.rawValue, forKey: "pref.quality") }
    }
    @Published var enableDirectFallback: Bool {
        didSet { UserDefaults.standard.set(enableDirectFallback, forKey: "pref.enableDirectFallback") }
    }
    /// When on, the UI surfaces informational notices like "换源播放" / "已降级音质" / "已用 libFLAC 解码".
    /// Real playback errors are always shown regardless of this flag.
    @Published var showDebugNotices: Bool {
        didSet { UserDefaults.standard.set(showDebugNotices, forKey: "pref.showDebugNotices") }
    }
    /// Show the synced current lyric line in the CarPlay / lock-screen album field instead of the album name.
    @Published var showLyricsOnNowPlaying: Bool {
        didSet { UserDefaults.standard.set(showLyricsOnNowPlaying, forKey: "pref.showLyricsOnNowPlaying") }
    }
    /// Which sources contribute to the iPad/Mac "发现" page's recommendation
    /// + leaderboard feeds. Defaults to all four mainstream sources. Stored
    /// as a comma-joined rawValue list since UserDefaults doesn't carry Set.
    @Published var homeSources: Set<SourceID> {
        didSet {
            let raw = homeSources.map(\.rawValue).sorted().joined(separator: ",")
            UserDefaults.standard.set(raw, forKey: "pref.homeSources")
        }
    }

    init() {
        let q = UserDefaults.standard.string(forKey: "pref.quality") ?? Quality.k320.rawValue
        self.preferredQuality = Quality(rawValue: q) ?? .k320
        if UserDefaults.standard.object(forKey: "pref.enableDirectFallback") == nil {
            // Default ON — the bundled v4.0.js script's API server only implements `checkUpdate`
            // and 404s `/lxmusicv4/url/...`, so strict-script mode currently can't play anything.
            // Users who deploy their own lx-music-api-server can disable this.
            self.enableDirectFallback = true
        } else {
            self.enableDirectFallback = UserDefaults.standard.bool(forKey: "pref.enableDirectFallback")
        }
        self.showDebugNotices = UserDefaults.standard.bool(forKey: "pref.showDebugNotices")  // default off
        if UserDefaults.standard.object(forKey: "pref.showLyricsOnNowPlaying") == nil {
            self.showLyricsOnNowPlaying = true  // default on
        } else {
            self.showLyricsOnNowPlaying = UserDefaults.standard.bool(forKey: "pref.showLyricsOnNowPlaying")
        }
        // 发现页源:首次启动 4 个主流源全开,后续按用户勾选持久化
        if let raw = UserDefaults.standard.string(forKey: "pref.homeSources") {
            let ids = raw.split(separator: ",").compactMap { SourceID(rawValue: String($0)) }
            self.homeSources = Set(ids.isEmpty ? [.kw, .wy, .kg, .tx] : ids)
        } else {
            self.homeSources = [.kw, .wy, .kg, .tx]
        }
    }
}
