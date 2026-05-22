import Foundation

nonisolated struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: Double
    let text: String
    let translation: String?
}

nonisolated enum LRCParser {
    /// Parse standard LRC text into time-sorted lines. Combines main lyrics with translation `tlyric` if present.
    static func parse(_ raw: String, translation: String? = nil) -> [LyricLine] {
        let main = parseLines(raw)
        let trans = translation.map { parseLines($0) } ?? []
        let transMap: [Int: String] = Dictionary(uniqueKeysWithValues: trans.map { (Int($0.time * 100), $0.text) })

        var lines: [LyricLine] = []
        var nextID = 0
        for l in main {
            let key = Int(l.time * 100)
            let tr = transMap[key]
            lines.append(LyricLine(id: nextID, time: l.time, text: l.text, translation: tr))
            nextID += 1
        }
        if lines.isEmpty {
            let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "\n")
            for chunk in normalised.split(separator: "\n", omittingEmptySubsequences: true) {
                lines.append(LyricLine(id: nextID, time: -1, text: String(chunk).trimmingCharacters(in: .whitespaces), translation: nil))
                nextID += 1
            }
        }
        return lines
    }

    private struct ParsedLine { let time: Double; let text: String }

    private static let timeTagRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{1,2})(?:[\.:](\d{1,3}))?\]"#)

    private static func parseLines(_ raw: String) -> [ParsedLine] {
        var out: [ParsedLine] = []
        // CRITICAL: Swift treats `\r\n` as a single extended-grapheme `Character`, so
        // `raw.split(separator: "\n")` silently fails when the lyric has CRLF endings
        // (Kugou's LRC does). Normalise first.
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalised.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = timeTagRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // Text is the remainder after the last timestamp tag.
            let last = matches.last!
            let textStart = last.range.location + last.range.length
            let text: String
            if textStart < ns.length {
                text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            } else {
                text = ""
            }
            for m in matches {
                let mins = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let secs = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var msStr = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : "0"
                if msStr.count == 2 { msStr += "0" }
                let ms = Double(msStr) ?? 0
                let time = mins * 60 + secs + ms / 1000
                out.append(ParsedLine(time: time, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Find the index of the active line at `time`. Returns nil if none yet.
    static func activeIndex(at time: Double, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }
}

/// Lyrics fetcher — uses a loaded JS source's `lyric` action when available; falls back to source-specific HTTP endpoints.
@MainActor
final class LyricsFetcher {
    static let shared = LyricsFetcher()
    private var cache: [String: [LyricLine]] = [:]

    func fetch(for track: Track, sources: SourceManager) async -> [LyricLine] {
        if let hit = cache[track.id] {
            print("[Lyrics] cache hit for \(track.id) (\(hit.count) lines, first: \"\(hit.first?.text ?? "")\")")
            return hit
        }
        // Try user script first
        if let lines = await tryScript(track: track, sources: sources) {
            print("[Lyrics] from script: \(lines.count) lines, first 3: \(lines.prefix(3).map { $0.text })")
            cache[track.id] = lines
            return lines
        }
        // Fallback by source
        if let lines = await tryFallback(track: track) {
            print("[Lyrics] from fallback: \(lines.count) lines, first 3: \(lines.prefix(3).map { $0.text })")
            cache[track.id] = lines
            return lines
        }
        print("[Lyrics] no lyric for \(track.id)")
        return []
    }

    private func tryScript(track: Track, sources: SourceManager) async -> [LyricLine]? {
        do {
            let result = try await sources.requestLyric(track: track)
            if let dict = result as? [String: Any] {
                let lyric = (dict["lyric"] as? String) ?? ""
                let tlyric = dict["tlyric"] as? String
                let parsed = LRCParser.parse(lyric, translation: tlyric)
                return parsed.isEmpty ? nil : parsed
            }
        } catch {
            print("[Lyrics] script lyric failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func tryFallback(track: Track) async -> [LyricLine]? {
        switch track.source {
        case .kw: return await BuiltInLyricResolver.kuwo(songmid: track.songmid)
        case .tx: return await BuiltInLyricResolver.qq(songmid: track.songmid)
        case .wy: return await BuiltInLyricResolver.netease(songmid: track.songmid)
        case .kg:
            // Kugou wants (name, hash, durationMs) to find the right candidate.
            return await BuiltInLyricResolver.kugou(
                name: track.name,
                hash: track.extras["hash"] ?? track.songmid,
                durationMs: (track.duration ?? 0) * 1000
            )
        default: return nil
        }
    }

    func clear() { cache.removeAll() }

    func injectCache(_ lines: [LyricLine], for trackID: String) {
        cache[trackID] = lines
    }
}
