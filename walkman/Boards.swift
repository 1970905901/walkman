import Foundation

/// Mirrors lx-music-mobile's `musicSdk/[source]/leaderboard.js`. Each source exposes a static
/// list of boards (酷我飙升榜, 抖音热歌榜, ...) and a per-board song-fetch endpoint.
nonisolated struct BoardInfo: Identifiable, Hashable, Sendable {
    let id: String       // "kw__93"
    let source: SourceID
    let bangid: String   // platform-side id
    let name: String
    var picURL: String?  // filled by service either statically or on-demand
}

nonisolated protocol BoardService: Sendable {
    var source: SourceID { get }
    var list: [BoardInfo] { get }
    /// Optionally fetch a fresh list (with covers) from the platform.
    /// Default impl returns the static `list`.
    func fetchBoards() async -> [BoardInfo]
    func fetchTracks(bangid: String, page: Int) async throws -> [Track]
}

extension BoardService {
    func fetchBoards() async -> [BoardInfo] { list }
}

nonisolated enum Boards {
    static let all: [any BoardService] = [
        KuwoBoardService(),
        NetEaseBoardService(),
    ]
    static func service(for source: SourceID) -> (any BoardService)? {
        all.first { $0.source == source }
    }
    static var allBoards: [BoardInfo] {
        all.flatMap { $0.list }
    }
}

// MARK: - Kuwo

/// Uses Kuwo's legacy `kbangserver.kuwo.cn/ksong.s` endpoint (the modern `wbd.kuwo.cn`
/// route in lx-music-mobile needs a private signing routine we don't have).
nonisolated struct KuwoBoardService: BoardService {
    let source: SourceID = .kw

    // Trimmed subset of `boardList` from musicSdk/kw/leaderboard.js — top picks first.
    let list: [BoardInfo] = [
        BoardInfo(id: "kw__93",  source: .kw, bangid: "93",  name: "飙升榜"),
        BoardInfo(id: "kw__16",  source: .kw, bangid: "16",  name: "热歌榜"),
        BoardInfo(id: "kw__17",  source: .kw, bangid: "17",  name: "新歌榜"),
        BoardInfo(id: "kw__158", source: .kw, bangid: "158", name: "抖音热歌榜"),
        BoardInfo(id: "kw__187", source: .kw, bangid: "187", name: "流行趋势榜"),
        BoardInfo(id: "kw__104", source: .kw, bangid: "104", name: "华语榜"),
        BoardInfo(id: "kw__182", source: .kw, bangid: "182", name: "粤语榜"),
        BoardInfo(id: "kw__22",  source: .kw, bangid: "22",  name: "欧美榜"),
        BoardInfo(id: "kw__184", source: .kw, bangid: "184", name: "韩语榜"),
        BoardInfo(id: "kw__183", source: .kw, bangid: "183", name: "日语榜"),
        BoardInfo(id: "kw__26",  source: .kw, bangid: "26",  name: "经典怀旧榜"),
        BoardInfo(id: "kw__278", source: .kw, bangid: "278", name: "古风音乐榜"),
        BoardInfo(id: "kw__242", source: .kw, bangid: "242", name: "电音榜"),
        BoardInfo(id: "kw__186", source: .kw, bangid: "186", name: "ACG神曲榜"),
        BoardInfo(id: "kw__185", source: .kw, bangid: "185", name: "最强翻唱榜"),
        BoardInfo(id: "kw__284", source: .kw, bangid: "284", name: "热评榜"),
        BoardInfo(id: "kw__283", source: .kw, bangid: "283", name: "枕边轻音乐榜"),
        BoardInfo(id: "kw__280", source: .kw, bangid: "280", name: "家务进行曲榜"),
        BoardInfo(id: "kw__64",  source: .kw, bangid: "64",  name: "影视金曲榜"),
        BoardInfo(id: "kw__12",  source: .kw, bangid: "12",  name: "Billboard榜"),
    ]

    func fetchBoards() async -> [BoardInfo] {
        // `qukudata.kuwo.cn` returns the full board tree with `sourceid` + `pic` per board.
        // We merge those covers into our static list (so users see real icons, not text badges).
        let urlStr = "http://qukudata.kuwo.cn/q.k?op=query&cont=tree&node=2&pn=0&rn=200&fmt=json&level=2"
        guard let url = URL(string: urlStr) else { return list }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let children = json["child"] as? [[String: Any]] else { return list }
        var picByBangid: [String: String] = [:]
        for c in children {
            let bangid = (c["sourceid"] as? String) ?? ""
            let pic = (c["pic"] as? String) ?? ""
            if !bangid.isEmpty, !pic.isEmpty { picByBangid[bangid] = pic }
        }
        return list.map { board in
            var b = board
            b.picURL = picByBangid[board.bangid] ?? board.picURL
            return b
        }
    }

    func fetchTracks(bangid: String, page: Int) async throws -> [Track] {
        let pn = max(0, page - 1)
        let urlStr = "http://kbangserver.kuwo.cn/ksong.s?from=pc&fmt=json&pn=\(pn)&rn=100&type=bang&data=content&id=\(bangid)&show_copyright_off=0&pcmp4=1&isbang=1"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["musiclist"] as? [[String: Any]] else { return [] }
        let tracks = list.compactMap(buildTrack)
        // Fill cover for each — search results already do this via artistpicserver.
        return await KuwoBoardService.fillKuwoCovers(tracks)
    }

    /// Resolve per-song cover URLs via Kuwo's artistpicserver in parallel (matches Catalogs.swift).
    static func fillKuwoCovers(_ tracks: [Track]) async -> [Track] {
        await withTaskGroup(of: (Int, String?).self) { group -> [Track] in
            for (idx, t) in tracks.enumerated() where t.picURL == nil {
                group.addTask {
                    let urlStr = "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=\(t.songmid)"
                    guard let u = URL(string: urlStr) else { return (idx, nil) }
                    var req = URLRequest(url: u)
                    req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                    req.timeoutInterval = 6
                    if let (data, _) = try? await URLSession.shared.data(for: req),
                       let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       s.hasPrefix("http") {
                        return (idx, s)
                    }
                    return (idx, nil)
                }
            }
            var out = tracks
            for await (idx, pic) in group {
                if let pic, idx < out.count { out[idx].picURL = pic }
            }
            return out
        }
    }

    /// `formats` is a pipe-separated codename list. We only care about audio quality codes here.
    private func buildTrack(_ d: [String: Any]) -> Track? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let rawName = (d["name"] as? String) ?? "未知"
        let artist = (d["artist"] as? String) ?? ""
        let album = d["album"] as? String
        let durationStr = (d["duration"] as? String) ?? (d["song_duration"] as? String) ?? "0"
        let duration = Int(durationStr) ?? 0

        var qualities: [Quality] = []
        let formats = (d["formats"] as? String) ?? ""
        let codes = Set(formats.split(separator: "|").map(String.init))
        if codes.contains("MP3128") { qualities.append(.k128) }
        if codes.contains("MP3H")  { qualities.append(.k320) }
        if codes.contains("ALFLAC") { qualities.append(.flac) }
        if codes.contains("AC4256") || codes.contains("DDJOC768") { qualities.append(.flac24) }
        if qualities.isEmpty { qualities = [.k128, .k320] }

        return Track(
            id: Track.makeID(source: .kw, songmid: id),
            name: decodeKuwo(rawName),
            singer: decodeKuwo(artist),
            albumName: album.map(decodeKuwo),
            albumId: d["albumid"] as? String,
            source: .kw,
            songmid: id,
            duration: duration > 0 ? duration : nil,
            picURL: nil,
            qualities: qualities
        )
    }

    private func decodeKuwo(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - NetEase

/// `music.163.com/api/toplist` returns the full board list with covers.
/// `music.163.com/api/playlist/detail?id=X` returns songs.
nonisolated struct NetEaseBoardService: BoardService {
    let source: SourceID = .wy

    /// Static fallback — the API call below replaces this with the live list.
    let list: [BoardInfo] = [
        BoardInfo(id: "wy__19723756", source: .wy, bangid: "19723756", name: "飙升榜", picURL: nil),
        BoardInfo(id: "wy__3779629",  source: .wy, bangid: "3779629",  name: "新歌榜", picURL: nil),
        BoardInfo(id: "wy__3778678",  source: .wy, bangid: "3778678",  name: "热歌榜", picURL: nil),
        BoardInfo(id: "wy__2884035",  source: .wy, bangid: "2884035",  name: "原创榜", picURL: nil),
    ]

    func fetchBoards() async -> [BoardInfo] {
        guard let url = URL(string: "https://music.163.com/api/toplist") else { return list }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["list"] as? [[String: Any]] else { return list }
        return arr.compactMap { item -> BoardInfo? in
            guard let idAny = item["id"] else { return nil }
            let id = String(describing: idAny)
            let name = (item["name"] as? String) ?? "未知"
            let cover = item["coverImgUrl"] as? String
            return BoardInfo(id: "wy__\(id)", source: .wy, bangid: id, name: name, picURL: cover)
        }
    }

    func fetchTracks(bangid: String, page: Int) async throws -> [Track] {
        // NetEase top lists are playlists themselves — `playlist/detail` works.
        let urlStr = "https://music.163.com/api/playlist/detail?id=\(bangid)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let tracks = result["tracks"] as? [[String: Any]] else { return [] }
        return tracks.compactMap(buildTrack)
    }

    private func buildTrack(_ d: [String: Any]) -> Track? {
        guard let idAny = d["id"] else { return nil }
        let id = String(describing: idAny)
        let name = (d["name"] as? String) ?? "未知"
        let artists = (d["artists"] as? [[String: Any]]) ?? []
        let singer = artists.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let albumD = d["album"] as? [String: Any]
        let albumName = albumD?["name"] as? String
        let albumId = albumD.flatMap { $0["id"].map { String(describing: $0) } }
        let pic = albumD?["picUrl"] as? String
        let duration = (d["duration"] as? Int).map { $0 / 1000 }
        var qs: [Quality] = [.k128]
        if (d["mMusic"] as? [String: Any]) != nil { qs.append(.k320) }
        if (d["hMusic"] as? [String: Any]) != nil { qs.append(.flac) }
        return Track(
            id: Track.makeID(source: .wy, songmid: id),
            name: name,
            singer: singer.isEmpty ? "未知歌手" : singer,
            albumName: albumName,
            albumId: albumId,
            source: .wy,
            songmid: id,
            duration: duration,
            picURL: pic,
            qualities: qs
        )
    }
}
