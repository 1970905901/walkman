import SwiftUI

@main
struct walkmanApp: App {
    @StateObject private var playback = PlaybackEngine()
    @StateObject private var sources = SourceManager()
    @StateObject private var playlists = PlaylistStore()
    @StateObject private var scripts = ScriptStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var downloads = DownloadStore.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(playback)
                .environmentObject(sources)
                .environmentObject(playlists)
                .environmentObject(scripts)
                .environmentObject(settings)
                .environmentObject(downloads)
                .task { await bootstrap() }
        }
    }

    private func bootstrap() async {
        sources.fallbackEnabled = settings.enableDirectFallback
        // Downloads reuse the same URL resolution as playback (script → other-source → direct).
        downloads.urlResolver = { [sources] track, quality in
            try await sources.resolveMusicURL(track: track, quality: quality).url
        }
        playback.setURLResolver { [sources, settings, playback, downloads] track in
            // Prefer a local downloaded file — plays offline and skips the network entirely.
            if let local = await MainActor.run(body: { downloads.localURL(for: track.id) }) {
                let q = await MainActor.run { downloads.quality(for: track.id) } ?? .k320
                return ResolvedTrack(url: local, origin: .localFile, quality: q, warning: nil)
            }
            sources.fallbackEnabled = settings.enableDirectFallback
            // `qualityCap` is set by PlaybackEngine when AVPlayer rejects a higher format
            // (e.g. 24-bit Hi-Res FLAC). When set, we resolve at the lower quality instead.
            let q = await MainActor.run { playback.qualityCap } ?? settings.preferredQuality
            return try await sources.resolveMusicURL(track: track, quality: q)
        }
        for s in scripts.scripts where s.enabled {
            await sources.load(script: s)
        }
        // Debug: auto-play a kw track end-to-end.
        // Debug: probe lxmusic API server reachability from inside the simulator's network stack.
        if UserDefaults.standard.bool(forKey: "debug.probeLxApi") {
            for url in [
                "https://88.lxmusic.世界/script?key=lxmusic&checkUpdate=",
                "https://lxmusic.世界/",
                "https://88.lxmusic.xn--fiqs8s/script?key=lxmusic&checkUpdate=",
            ] {
                guard let u = URL(string: url) else { continue }
                do {
                    let (data, resp) = try await URLSession.shared.data(from: u)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    let body = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                    print("[PROBE] \(url) → HTTP \(code), \(data.count) bytes\n  body: \(body)")
                } catch {
                    print("[PROBE] \(url) → ERROR: \(error.localizedDescription)")
                }
            }
        }

        if let kwMID = UserDefaults.standard.string(forKey: "debug.autoPlayKw") {
            let track = Track(
                id: Track.makeID(source: .kw, songmid: kwMID),
                name: UserDefaults.standard.string(forKey: "debug.autoPlayKwName") ?? "Kuwo Track",
                singer: UserDefaults.standard.string(forKey: "debug.autoPlayKwArtist") ?? "Unknown",
                source: .kw,
                songmid: kwMID,
                qualities: [.k128, .k320, .flac]
            )
            playback.play(track: track)
        }

        if let wyMID = UserDefaults.standard.string(forKey: "debug.autoPlayWy") {
            let track = Track(
                id: Track.makeID(source: .wy, songmid: wyMID),
                name: UserDefaults.standard.string(forKey: "debug.autoPlayWyName") ?? "NetEase Track",
                singer: UserDefaults.standard.string(forKey: "debug.autoPlayWyArtist") ?? "Unknown",
                source: .wy,
                songmid: wyMID,
                qualities: [.k128, .k320]
            )
            playback.play(track: track)
        }

        // Debug: auto-play a whole Kuwo board (queue gets ~100 tracks)
        if let bangid = UserDefaults.standard.string(forKey: "debug.autoPlayBoard") {
            if let svc = Boards.service(for: .kw),
               let tracks = try? await svc.fetchTracks(bangid: bangid, page: 1),
               let first = tracks.first {
                playback.play(track: first, in: tracks, startIndex: 0)
            }
        }

        // Generic debug auto-play for any source: debug.autoPlay = "kg:audioid:hash" or "tx:mid" etc.
        if let raw = UserDefaults.standard.string(forKey: "debug.autoPlayAny") {
            let parts = raw.split(separator: ":").map(String.init)
            if parts.count >= 2, let source = SourceID(rawValue: parts[0]) {
                let songmid = parts[1]
                var extras: [String: String] = [:]
                if source == .kg, parts.count >= 3 {
                    extras["hash"] = parts[2]
                }
                let track = Track(
                    id: Track.makeID(source: source, songmid: songmid),
                    name: UserDefaults.standard.string(forKey: "debug.autoPlayAnyName") ?? "Debug",
                    singer: UserDefaults.standard.string(forKey: "debug.autoPlayAnyArtist") ?? "Debug",
                    source: source,
                    songmid: songmid,
                    qualities: [.k128, .k320, .flac, .flac24],
                    extras: extras
                )
                playback.play(track: track)
            }
        }

        if let demoURL = UserDefaults.standard.string(forKey: "debug.demoTrackURL"),
           let url = URL(string: demoURL) {
            let demo = Track(
                id: "debug-demo",
                name: UserDefaults.standard.string(forKey: "debug.demoTrackName") ?? "Demo Song",
                singer: UserDefaults.standard.string(forKey: "debug.demoTrackArtist") ?? "Walkman",
                albumName: "Sample Album",
                source: .local,
                songmid: demoURL,
                picURL: UserDefaults.standard.string(forKey: "debug.demoTrackPic")
            )
            if let lyricLRC = UserDefaults.standard.string(forKey: "debug.demoLyrics") {
                let lines = LRCParser.parse(lyricLRC)
                LyricsFetcher.shared.injectCache(lines, for: demo.id)
            }
            playback.playDirectURL(url, asTrack: demo)
        }
    }
}
