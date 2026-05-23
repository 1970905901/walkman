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

/// A platform-specific sort option. `id` is the value the platform's API expects
/// (e.g. "hot"/"new" for Kuwo, "5"/"6"/"7" for Kugou); `name` is the Chinese label.
nonisolated struct SonglistOrder: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
}

nonisolated protocol SonglistService: Sendable {
    var source: SourceID { get }
    /// The sort tabs this platform supports (varies per source: 推荐/最热/最新/热藏/飙升…).
    var orders: [SonglistOrder] { get }
    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo]
    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail
}

nonisolated enum Songlists {
    static let all: [any SonglistService] = [
        KuwoSonglistService(),
        NetEaseSonglistService(),
        KugouSonglistService(),
        QQSonglistService(),
    ]
    static func service(for source: SourceID) -> (any SonglistService)? {
        all.first { $0.source == source }
    }
}

// MARK: - Kuwo

nonisolated struct KuwoSonglistService: SonglistService {
    let source: SourceID = .kw
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "new", name: "最新"),
        SonglistOrder(id: "hot", name: "最热"),
    ]

    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo] {
        let urlStr = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0&appUid=76039576&pn=\(page)&rn=36&order=\(order.id)"
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
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "hot", name: "最热"),
    ]

    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo] {
        let limit = 36
        let offset = (page - 1) * limit
        let cat = "全部".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "全部"
        let urlStr = "https://music.163.com/api/playlist/list?cat=\(cat)&order=\(order.id)&limit=\(limit)&offset=\(offset)"
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

// MARK: - QQ Music

/// Mirrors musicSdk/tx/songList.js. Recommended via `get_playlist_by_tag`,
/// detail via `fcg_ucc_getcdinfo_byids_cp.fcg`.
nonisolated struct QQSonglistService: SonglistService {
    let source: SourceID = .tx
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "5", name: "最热"),
        SonglistOrder(id: "2", name: "最新"),
    ]
    private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"

    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo] {
        let size = 36
        let orderId = Int(order.id) ?? 5
        let inner: [String: Any] = [
            "comm": ["cv": 1602, "ct": 20],
            "playlist": [
                "method": "get_playlist_by_tag",
                "param": ["id": 10000000, "sin": size * (page - 1), "size": size, "order": orderId, "cur_page": page],
                "module": "playlist.PlayListPlazaServer",
            ],
        ]
        guard let innerData = try? JSONSerialization.data(withJSONObject: inner),
              let dataStr = String(data: innerData, encoding: .utf8),
              let enc = dataStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json&needNewCode=0&data=\(enc)")
        else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlist = json["playlist"] as? [String: Any],
              let pdata = playlist["data"] as? [String: Any],
              let arr = pdata["v_playlist"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let tidAny = d["tid"] else { return nil }
            let id = String(describing: tidAny)
            let creator = d["creator_info"] as? [String: Any]
            return SonglistInfo(
                id: id, source: .tx,
                name: (d["title"] as? String) ?? "未知歌单",
                author: (creator?["nick"] as? String) ?? "",
                picURL: (d["cover_url_medium"] as? String) ?? (d["cover_url_big"] as? String),
                trackCount: (d["song_ids"] as? [Any])?.count,
                playCount: KuwoSonglistService.formatPlayCount(d["access_num"] as? Int ?? 0)
            )
        }
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        let urlStr = "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid=\(list.id)&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
        guard let url = URL(string: urlStr) else { return SonglistDetail(info: list, tracks: []) }
        var req = URLRequest(url: url)
        req.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        req.setValue("https://y.qq.com/n/yqq/playsquare/\(list.id).html", forHTTPHeaderField: "Referer")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdlist = json["cdlist"] as? [[String: Any]],
              let cd = cdlist.first,
              let songlist = cd["songlist"] as? [[String: Any]] else {
            return SonglistDetail(info: list, tracks: [])
        }
        let tracks = songlist.compactMap(QQTrackBuilder.build)
        let updated = SonglistInfo(
            id: list.id, source: list.source,
            name: (cd["dissname"] as? String) ?? list.name,
            author: (cd["nickname"] as? String) ?? list.author,
            picURL: (cd["logo"] as? String) ?? list.picURL,
            trackCount: tracks.count,
            playCount: list.playCount
        )
        return SonglistDetail(info: updated, tracks: tracks)
    }
}

// MARK: - Kugou

/// Mirrors musicSdk/kg/songList.js. Recommended via `getSpecial`; detail scrapes the playlist
/// HTML for song hashes, then resolves them through Kugou's gateway audio API.
nonisolated struct KugouSonglistService: SonglistService {
    let source: SourceID = .kg
    let orders: [SonglistOrder] = [
        SonglistOrder(id: "5", name: "推荐"),
        SonglistOrder(id: "6", name: "最热"),
        SonglistOrder(id: "7", name: "最新"),
        SonglistOrder(id: "3", name: "热藏"),
        SonglistOrder(id: "8", name: "飙升"),
    ]
    private let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1"

    func fetchRecommended(order: SonglistOrder, page: Int) async throws -> [SonglistInfo] {
        let urlStr = "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=\(order.id)&c=&p=\(page)"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["special_db"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let sidAny = d["specialid"] else { return nil }
            let id = String(describing: sidAny)
            let plays = (d["total_play_count"] as? String) ?? KuwoSonglistService.formatPlayCount(d["play_count"] as? Int ?? 0)
            let img = (d["img"] as? String) ?? (d["imgurl"] as? String)
            return SonglistInfo(
                id: id, source: .kg,
                name: (d["specialname"] as? String) ?? "未知歌单",
                author: (d["nickname"] as? String) ?? "",
                picURL: img?.replacingOccurrences(of: "{size}", with: "240"),
                trackCount: d["songcount"] as? Int,
                playCount: plays
            )
        }
    }

    func fetchDetail(_ list: SonglistInfo) async throws -> SonglistDetail {
        // 1) Scrape the playlist HTML for the song hash list (`global.data = [...]`).
        let htmlURLStr = "http://www2.kugou.kugou.com/yueku/v9/special/single/\(list.id)-5-9999.html"
        guard let htmlURL = URL(string: htmlURLStr) else { return SonglistDetail(info: list, tracks: []) }
        var htmlReq = URLRequest(url: htmlURL)
        htmlReq.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        htmlReq.timeoutInterval = 20
        let (htmlData, _) = try await URLSession.shared.data(for: htmlReq)
        guard let html = String(data: htmlData, encoding: .utf8) else { return SonglistDetail(info: list, tracks: []) }
        let hashes = Self.extractHashes(from: html)
        guard !hashes.isEmpty else { return SonglistDetail(info: list, tracks: []) }
        // 2) Resolve hashes to full song info via the gateway audio API.
        let tracks = try await resolveHashes(hashes)
        return SonglistDetail(info: list, tracks: tracks)
    }

    /// Parse `global.data = [ ... ];` and pull each item's `hash`.
    private static func extractHashes(from html: String) -> [String] {
        guard let r = html.range(of: "global.data = ") else { return [] }
        let after = html[r.upperBound...]
        guard let end = after.range(of: "];") else { return [] }
        let arrayLiteral = String(after[after.startIndex...end.lowerBound]) // up to and incl ']'
        guard let data = arrayLiteral.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { ($0["hash"] as? String)?.uppercased() }
    }

    /// Resolve all hashes (chunked by 100, like android's createTask) to full song info.
    /// Chunks run concurrently; results are re-ordered to preserve playlist order.
    private func resolveHashes(_ hashes: [String]) async throws -> [Track] {
        let capped = Array(hashes.prefix(500))   // guard against absurdly large playlists
        let chunks = stride(from: 0, to: capped.count, by: 100).map { Array(capped[$0..<min($0 + 100, capped.count)]) }
        let indexed = await withTaskGroup(of: (Int, [Track]).self) { group -> [(Int, [Track])] in
            for (i, chunk) in chunks.enumerated() {
                group.addTask { (i, (try? await Self.resolveChunk(chunk)) ?? []) }
            }
            var acc: [(Int, [Track])] = []
            for await r in group { acc.append(r) }
            return acc
        }
        return indexed.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    private static func resolveChunk(_ hashes: [String]) async throws -> [Track] {
        guard !hashes.isEmpty, let url = URL(string: "http://gateway.kugou.com/v2/album_audio/audio") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("13a3164", forHTTPHeaderField: "KG-THash")
        req.setValue("1", forHTTPHeaderField: "KG-RC")
        req.setValue("0", forHTTPHeaderField: "KG-Fake")
        req.setValue("00869891", forHTTPHeaderField: "KG-RF")
        req.setValue("Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi", forHTTPHeaderField: "User-Agent")
        req.setValue("kmr.service.kugou.com", forHTTPHeaderField: "x-router")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "area_code": "1", "show_privilege": 1, "show_album_info": "1", "is_publish": "",
            "appid": 1005, "clientver": 11451, "mid": "1", "dfid": "-",
            "clienttime": 1586163263991, "key": "OIlwieks28dk2k092lksi2UIkp",
            "fields": "album_info,author_name,audio_info,ori_audio_name,base,songname",
            "data": hashes.map { ["hash": $0] },
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = json["data"] as? [Any] else { return [] }
        // Loosely typed: a failed hash can come back as something other than an array, so we
        // must NOT cast the whole thing to [[Any]] (that fails wholesale). Handle each row.
        return outer.compactMap { row -> Track? in
            if let arr = row as? [Any], let d = arr.first as? [String: Any] { return buildTrack(d) }
            if let d = row as? [String: Any] { return buildTrack(d) }
            return nil
        }
    }

    private static func buildTrack(_ d: [String: Any]) -> Track? {
        let audio = d["audio_info"] as? [String: Any] ?? [:]
        let hash = (audio["hash"] as? String) ?? ""
        guard !hash.isEmpty else { return nil }
        let audioId = (audio["audio_id"] as? String) ?? (audio["audio_id"] as? Int).map(String.init) ?? hash
        let name = decode((d["songname"] as? String) ?? (d["ori_audio_name"] as? String) ?? "未知")
        let singer = decode((d["author_name"] as? String) ?? "")
        let albumInfo = d["album_info"] as? [String: Any]
        let albumName = (albumInfo?["album_name"] as? String).map(decode)
        let albumId = (albumInfo?["album_id"] as? String) ?? (albumInfo?["album_id"] as? Int).map(String.init)
        let durMs = Int((audio["timelength"] as? String) ?? "0") ?? (audio["timelength"] as? Int) ?? 0

        let nonZero: (Any?) -> Bool = { v in
            if let s = v as? String { return s != "0" && !s.isEmpty }
            if let i = v as? Int { return i != 0 }
            return false
        }
        var qs: [Quality] = []
        if nonZero(audio["filesize"]) { qs.append(.k128) }
        if nonZero(audio["filesize_320"]) { qs.append(.k320) }
        if nonZero(audio["filesize_flac"]) { qs.append(.flac) }
        if nonZero(audio["filesize_high"]) { qs.append(.flac24) }
        if qs.isEmpty { qs = [.k128] }

        var extras: [String: String] = ["hash": hash]
        if let albumId { extras["albumId"] = albumId }
        let pic: String? = (albumInfo?["sizable_cover"] as? String).flatMap {
            $0.isEmpty ? nil : $0.replacingOccurrences(of: "{size}", with: "240")
        }
        return Track(
            id: Track.makeID(source: .kg, songmid: audioId),
            name: name,
            singer: singer,
            albumName: albumName,
            albumId: albumId,
            source: .kg,
            songmid: audioId,
            duration: durMs > 0 ? durMs / 1000 : nil,
            picURL: pic,
            qualities: qs,
            extras: extras
        )
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
}
