import Foundation

/// Mirrors lx-music-mobile's `musicSdk/[source]/songList.js`:
///   - get recommended / tagged playlists (we keep it simple — hot/new recommended only)
///   - get tracks inside a specific playlist
nonisolated struct SonglistInfo: Identifiable, Hashable, Sendable {
    let id: String          // platform-side playlist id (e.g. Kuwo's pid)
    let source: SourceID
    let name: String
    let author: String
    let picURL: String?
    let trackCount: Int?
    let playCount: String?  // formatted "1.2万" etc
}

nonisolated struct SonglistDetail: Sendable {
    let info: SonglistInfo
    let tracks: [Track]
}

nonisolated enum SonglistOrder: String, CaseIterable, Hashable, Sendable {
    case hot, new
    var displayName: String {
        switch self {
        case .hot: return "最热"
        case .new: return "最新"
        }
    }
}

nonisolated protocol SonglistService: Sendable {
    var source: SourceID { get }
    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo]
    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail
}

nonisolated enum Songlists {
    static let all: [any SonglistService] = [
        KuwoSonglistService(),
        NetEaseSonglistService(),
    ]
    static func service(for source: SourceID) -> (any SonglistService)? {
        all.first { $0.source == source }
    }
}

// MARK: - Kuwo

nonisolated struct KuwoSonglistService: SonglistService {
    let source: SourceID = .kw

    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo] {
        let urlStr = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=\(page)&rn=36&order=\(order.rawValue)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["code"] as? Int) == 200,
              let outer = json["data"] as? [String: Any],
              let raw = outer["data"] as? [[String: Any]] else { return [] }
        return raw.compactMap(buildInfo)
    }

    private func buildInfo(_ d: [String: Any]) -> SonglistInfo? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let total: Int? = (d["total"] as? Int) ?? Int(d["total"] as? String ?? "")
        let plays = d["listencnt"] as? Int ?? Int(d["listencnt"] as? String ?? "") ?? 0
        return SonglistInfo(
            id: id,
            source: .kw,
            name: (d["name"] as? String) ?? "未知歌单",
            author: (d["uname"] as? String) ?? "",
            picURL: d["img"] as? String,
            trackCount: total,
            playCount: KuwoSonglistService.formatPlayCount(plays)
        )
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        let urlStr = "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid=\(list.id)&pn=0&rn=300&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1"
        guard let url = URL(string: urlStr) else { return SonglistDetail(info: list, tracks: []) }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["result"] as? String) == "ok",
              let musiclist = json["musiclist"] as? [[String: Any]] else {
            return SonglistDetail(info: list, tracks: [])
        }
        let rawTracks = musiclist.compactMap(buildTrack)
        // Resolve per-song covers via Kuwo's artistpicserver (reuses board helper).
        let tracks = await KuwoBoardService.fillKuwoCovers(rawTracks)
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (json["title"] as? String) ?? list.name,
            author: (json["uname"] as? String) ?? list.author,
            picURL: (json["pic"] as? String) ?? list.picURL,
            trackCount: (json["total"] as? Int) ?? tracks.count,
            playCount: list.playCount
        )
        return SonglistDetail(info: updated, tracks: tracks)
    }

    /// Same format codes as KuwoBoardService — extracted into helper later if needed.
    private func buildTrack(_ d: [String: Any]) -> Track? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let name = decode((d["name"] as? String) ?? "未知")
        let artist = decode((d["artist"] as? String) ?? "")
        let album = (d["album"] as? String).map(decode)
        let duration = Int((d["duration"] as? String) ?? "0") ?? 0

        var qs: [Quality] = []
        let codes = Set(((d["formats"] as? String) ?? "").split(separator: "|").map(String.init))
        if codes.contains("MP3128") { qs.append(.k128) }
        if codes.contains("MP3H") { qs.append(.k320) }
        if codes.contains("ALFLAC") { qs.append(.flac) }
        if codes.contains("HIRFLAC") || codes.contains("AC4256") { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128, .k320] }

        return Track(
            id: Track.makeID(source: .kw, songmid: id),
            name: name,
            singer: artist,
            albumName: album,
            albumId: d["albumid"] as? String,
            source: .kw,
            songmid: id,
            duration: duration > 0 ? duration : nil,
            picURL: nil,
            qualities: qs
        )
    }

    private func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func formatPlayCount(_ n: Int) -> String {
        if n > 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
        if n > 10_000 { return String(format: "%.1f万", Double(n) / 10_000) }
        return String(n)
    }
}

// MARK: - NetEase

nonisolated struct NetEaseSonglistService: SonglistService {
    let source: SourceID = .wy

    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo] {
        // NetEase's `playlist/list` takes cat+order+limit+offset. We map walkman's
        // "hot"/"new" → NetEase's "hot"/"new" directly.
        let limit = 36
        let offset = (page - 1) * limit
        let cat = "全部".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "全部"
        let urlStr = "https://music.163.com/api/playlist/list?cat=\(cat)&order=\(order.rawValue)&limit=\(limit)&offset=\(offset)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["playlists"] as? [[String: Any]] else { return [] }
        return arr.compactMap(buildInfo)
    }

    private func buildInfo(_ d: [String: Any]) -> SonglistInfo? {
        guard let idAny = d["id"] else { return nil }
        let id = String(describing: idAny)
        let creator = d["creator"] as? [String: Any]
        let plays = (d["playCount"] as? Int) ?? 0
        return SonglistInfo(
            id: id,
            source: .wy,
            name: (d["name"] as? String) ?? "未知歌单",
            author: (creator?["nickname"] as? String) ?? "",
            picURL: d["coverImgUrl"] as? String,
            trackCount: d["trackCount"] as? Int,
            playCount: KuwoSonglistService.formatPlayCount(plays)
        )
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        let urlStr = "https://music.163.com/api/playlist/detail?id=\(list.id)"
        guard let url = URL(string: urlStr) else { return SonglistDetail(info: list, tracks: []) }
        var req = URLRequest(url: url)
        req.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return SonglistDetail(info: list, tracks: [])
        }
        let trackArr = (result["tracks"] as? [[String: Any]]) ?? []
        let tracks = trackArr.compactMap(buildTrack)
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (result["name"] as? String) ?? list.name,
            author: ((result["creator"] as? [String: Any])?["nickname"] as? String) ?? list.author,
            picURL: (result["coverImgUrl"] as? String) ?? list.picURL,
            trackCount: (result["trackCount"] as? Int) ?? tracks.count,
            playCount: list.playCount
        )
        return SonglistDetail(info: updated, tracks: tracks)
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
