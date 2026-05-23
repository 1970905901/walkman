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
        cloudCancellable = CloudSync.shared.didReceiveRemoteChange.sink { [weak self] in
            self?.pullFromCloud()
        }
    }

    private func pullFromCloud() {
        if let remote: [PlaylistMeta] = CloudSync.shared.pull([PlaylistMeta].self, forKey: CloudSync.Keys.playlists) {
            // Merge: take remote if newer, otherwise keep local. Simple last-write-wins.
            var merged = playlists
            for r in remote {
                if let i = merged.firstIndex(where: { $0.id == r.id }) {
                    if r.updatedAt > merged[i].updatedAt { merged[i] = r }
                } else {
                    merged.append(r)
                }
            }
            playlists = merged
        }
        if let bank: [String: Track] = CloudSync.shared.pull([String: Track].self, forKey: CloudSync.Keys.trackBank) {
            trackBank.merge(bank) { local, _ in local }
        }
        save(skipCloud: true)
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
            CloudSync.shared.push(playlists, forKey: CloudSync.Keys.playlists)
            CloudSync.shared.push(trackBank, forKey: CloudSync.Keys.trackBank)
        }
    }
}

@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [UserScript] = []

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.url = dir.appendingPathComponent("scripts.json")
        load()
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
        for line in header.split(separator: "\n") {
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
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: url, options: .atomic)
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
    }
}
