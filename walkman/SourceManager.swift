import Foundation
import Combine

enum ResolveOrigin: Equatable, Sendable {
    case script(name: String)
    case directFallback
    case otherSource(SourceID)
    case localFile

    var displayLabel: String {
        switch self {
        case .script(let name): return "脚本: \(name)"
        case .directFallback: return "内置直连"
        case .otherSource(let s): return "换源: \(s.displayName)"
        case .localFile: return "本地"
        }
    }
    var iconName: String {
        switch self {
        case .script: return "doc.text.fill"
        case .directFallback: return "bolt.horizontal.fill"
        case .otherSource: return "arrow.triangle.2.circlepath"
        case .localFile: return "internaldrive.fill"
        }
    }
}

struct ResolvedTrack: Sendable {
    let url: URL
    let origin: ResolveOrigin
    let quality: Quality
    let warning: String?  // soft notice surfaced to UI; nil if everything looks fine
}

@MainActor
final class SourceManager: ObservableObject {
    @Published private(set) var loadedScripts: [LoadedScript] = []
    @Published private(set) var isLoading: Bool = false
    @Published var lastError: String?
    @Published var fallbackEnabled: Bool = true

    struct LoadedScript: Identifiable {
        let id: UUID
        let script: UserScript
        let runtime: JSScriptRuntime
        let capabilities: ScriptCapabilities
    }

    enum SourceError: LocalizedError {
        case noScriptForSource(SourceID)
        case actionUnsupported(SourceID, String)
        case invalidResult
        case songNotInAPIServer(SourceID)

        var errorDescription: String? {
            switch self {
            case .noScriptForSource(let s):
                return "没有脚本提供 \(s.displayName) 源,请到设置 → 自定义音源 导入脚本"
            case .actionUnsupported(let s, let a):
                return "\(s.displayName) 不支持动作 \(a)"
            case .invalidResult:
                return "脚本返回了无效结果"
            case .songNotInAPIServer(let s):
                return "这首 \(s.displayName) 歌曲不在 v4 脚本的 API 服务器数据库里,换一首或换个能用的脚本"
            }
        }
    }

    /// Bundled lx-music v4 source — auto-loaded on launch as the "built-in" source.
    func loadBundledSource() async {
        guard let url = Bundle.main.url(forResource: "builtin-lx-source-v4", withExtension: "js"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "未找到内置脚本"
            return
        }
        let bundled = UserScript(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "内置音源 v4",
            description: "lx-music 默认 v4 音源",
            version: "4.0.0",
            author: "lx-music",
            homepage: "https://github.com/lyswhut/lx-music-mobile",
            rawScript: raw,
            enabled: true
        )
        await load(script: bundled)
    }

    func load(script: UserScript) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let meta = JSScriptRuntime.ScriptMetadata(
                id: script.id.uuidString,
                name: script.name,
                description: script.description,
                version: script.version,
                author: script.author,
                homepage: script.homepage
            )
            let runtime = try JSScriptRuntime(metadata: meta, rawScript: script.rawScript)
            let caps = try await runtime.waitForInit(timeout: 10)
            loadedScripts.removeAll { $0.script.id == script.id }
            loadedScripts.append(LoadedScript(id: script.id, script: script, runtime: runtime, capabilities: caps))
        } catch {
            lastError = "加载脚本失败: \(error.localizedDescription)"
            print("[SourceManager] load failed: \(error)")
        }
    }

    func unload(scriptID: UUID) {
        loadedScripts.removeAll { $0.script.id == scriptID }
    }

    /// Pick a script that supports `source` + `action`.
    private func pickScript(for source: SourceID, action: String) -> LoadedScript? {
        loadedScripts.first { ls in
            guard let cap = ls.capabilities.sources[source] else { return false }
            return cap.actions.contains(action)
        }
    }

    /// Resolve a track URL — mirrors lx-music-mobile `handleGetOnlineMusicUrl`:
    ///   1) Try the user script for this source.
    ///   2) On failure, search other platforms for the same song and try those.
    ///   3) Last resort: platform direct fallback for kw/wy (off in strict mode).
    /// Returns both the URL and which mechanism produced it so the UI can be transparent.
    func resolveMusicURL(track: Track, quality: Quality? = nil) async throws -> ResolvedTrack {
        let preferred = quality ?? .k320
        // 1) Try the script on the original source.
        if let ls = pickScript(for: track.source, action: "musicUrl") {
            let q = SourceManager.pickPlayQuality(
                preferred: preferred,
                trackQualities: Set(track.qualities),
                scriptQualities: Set(ls.capabilities.sources[track.source]?.qualities ?? [])
            )
            print("[SourceManager] script musicUrl source=\(track.source.rawValue) songmid=\(track.songmid) prefer=\(preferred.rawValue) → effective=\(q.rawValue)")
            do {
                let url = try await resolveViaScript(track: track, quality: q, loaded: ls)
                return ResolvedTrack(url: url, origin: .script(name: ls.script.name), quality: q, warning: nil)
            } catch {
                print("[SourceManager] script musicUrl failed (\(error.localizedDescription)) — trying other sources")
            }
        }
        // 2) lx-music's `getOtherSource`: search the same song name+singer on EVERY other
        // platform, then try the script on each in match-quality order. First playable wins.
        if let resolved = await tryOtherSources(for: track, preferred: preferred) {
            return resolved
        }
        // 3) Direct fallback (kw/wy only) — non-official, but useful when no scripts cover anything.
        if fallbackEnabled {
            let qForFallback: Quality = track.qualities.contains(preferred) ? preferred : (track.qualities.first ?? .k128)
            do {
                let resolved = try await BuiltInResolver.resolve(track: track, quality: qForFallback)
                print("[SourceManager] resolved via direct fallback => \(resolved.url.host ?? "?")\(resolved.warning.map { " ⚠ \($0)" } ?? "")")
                return ResolvedTrack(url: resolved.url, origin: .directFallback, quality: qForFallback, warning: resolved.warning)
            } catch {
                // fall through
            }
        }
        if pickScript(for: track.source, action: "musicUrl") == nil {
            throw SourceError.noScriptForSource(track.source)
        }
        throw SourceError.songNotInAPIServer(track.source)
    }

    /// Search for the same song on other platforms and try resolving via each one's script.
    /// Returns the first successful URL, or nil if no alternative worked.
    private func tryOtherSources(for track: Track, preferred: Quality) async -> ResolvedTrack? {
        let alternatives = await OtherSourceFinder.findMatches(for: track)
        guard !alternatives.isEmpty else {
            print("[SourceManager] no other-source matches for \(track.name)")
            return nil
        }
        print("[SourceManager] other-source candidates: \(alternatives.map { "\($0.source.rawValue)/\($0.songmid)" }.joined(separator: ", "))")
        for alt in alternatives.prefix(5) {
            guard let altLS = pickScript(for: alt.source, action: "musicUrl") else { continue }
            let q = SourceManager.pickPlayQuality(
                preferred: preferred,
                trackQualities: Set(alt.qualities),
                scriptQualities: Set(altLS.capabilities.sources[alt.source]?.qualities ?? [])
            )
            do {
                print("[SourceManager] other-source try \(alt.source.rawValue)/\(alt.songmid) (\(alt.name) - \(alt.singer))")
                let url = try await resolveViaScript(track: alt, quality: q, loaded: altLS)
                print("[SourceManager] ✓ other-source hit \(alt.source.rawValue) -> \(url.host ?? "?")")
                let warn = "原 \(track.source.displayName) 源无法获取播放地址,已换到 \(alt.source.displayName)"
                return ResolvedTrack(url: url, origin: .otherSource(alt.source), quality: q, warning: warn)
            } catch {
                continue
            }
        }
        return nil
    }

    /// Mirrors lx-music-mobile/src/core/music/utils.ts#getPlayQuality.
    /// `TRY_QUALITYS_LIST` is ['flac24bit', 'flac', '320k'] — 128k falls through directly.
    nonisolated static func pickPlayQuality(preferred: Quality,
                                             trackQualities: Set<Quality>,
                                             scriptQualities: Set<Quality>) -> Quality {
        let tryList: [Quality] = [.flac24, .flac, .k320]
        guard let startIdx = tryList.firstIndex(of: preferred) else {
            return .k128
        }
        for q in tryList[startIdx...] {
            if trackQualities.contains(q) && scriptQualities.contains(q) {
                return q
            }
        }
        return .k128
    }

    private func resolveViaScript(track: Track, quality: Quality, loaded ls: LoadedScript) async throws -> URL {
        let info: [String: Any] = [
            "type": quality.rawValue,
            "musicInfo": SourceManager.makeOldMusicInfo(track: track),
        ]
        if UserDefaults.standard.bool(forKey: "debug.logScriptInfo") {
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]),
               let s = String(data: data, encoding: .utf8) {
                print("[SourceManager] → script info:\n\(s)")
            }
        }
        // The ScriptHTTPClient already has a 12s request timeout, so a hung backend (e.g. mg)
        // surfaces an error in ~12s instead of hanging forever.
        let result = try await ls.runtime.requestAction(source: track.source, action: "musicUrl", info: info)
        if UserDefaults.standard.bool(forKey: "debug.logScriptInfo") {
            print("[SourceManager] ← script result: \(result)")
        }
        if let dict = result as? [String: Any] {
            if let data = dict["data"] as? [String: Any], let urlStr = data["url"] as? String, let u = URL(string: urlStr) {
                return u
            }
            if let urlStr = dict["url"] as? String, let u = URL(string: urlStr) {
                return u
            }
        }
        throw SourceError.invalidResult
    }


    /// Builds the "old format" music info object that lx-music v4 user scripts expect.
    /// Mirrors `toOldMusicInfo` from lx-music-mobile/src/utils/index.ts.
    nonisolated static func makeOldMusicInfo(track: Track) -> [String: Any] {
        let interval: String = track.duration.map { secs in
            String(format: "%02d:%02d", secs / 60, secs % 60)
        } ?? ""
        var types: [[String: String]] = []
        var _types: [String: [String: String]] = [:]
        // Officially the order is highest → lowest; the script iterates the array.
        let ordered: [Quality] = [.flac24, .flac, .k320, .k128].filter { track.qualities.contains($0) }
        for q in ordered {
            types.append(["type": q.rawValue, "size": ""])
            _types[q.rawValue] = ["size": ""]
        }
        var info: [String: Any] = [
            "name": track.name,
            "singer": track.singer,
            "source": track.source.rawValue,
            "songmid": track.songmid,
            "interval": interval,
            "albumName": track.albumName ?? "",
            "img": track.picURL ?? "",
            "typeUrl": [String: String](),
            "albumId": track.albumId ?? "",
            "types": types,
            "_types": _types,
        ]
        // Source-specific fields the official `toOldMusicInfo` merges in.
        // Scripts read these from musicInfo (e.g. kg.hash, tx.strMediaMid).
        for (k, v) in track.extras { info[k] = v }
        return info
    }

    /// Ask a user script for lyric data. Returns the raw `{lyric, tlyric, rlyric, lxlyric}` dict.
    /// Mirrors lx-music-mobile init/userApi/index.ts line ~123: info = { type, musicInfo }.
    func requestLyric(track: Track) async throws -> Any {
        guard let ls = pickScript(for: track.source, action: "lyric") else {
            throw SourceError.noScriptForSource(track.source)
        }
        let info: [String: Any] = [
            "type": "",
            "musicInfo": SourceManager.makeOldMusicInfo(track: track),
        ]
        return try await ls.runtime.requestAction(source: track.source, action: "lyric", info: info)
    }

    func availableQualities(for source: SourceID) -> [Quality] {
        var set = Set<Quality>()
        for ls in loadedScripts {
            if let cap = ls.capabilities.sources[source] {
                cap.qualities.forEach { set.insert($0) }
            }
        }
        return Quality.allCases.filter { set.contains($0) }
    }

    func supportedSources() -> [SourceID] {
        var set = Set<SourceID>()
        for ls in loadedScripts {
            for (src, cap) in ls.capabilities.sources where cap.actions.contains("musicUrl") {
                set.insert(src)
            }
        }
        return SourceID.allCases.filter { set.contains($0) }
    }
}
