import Foundation
import AppKit

// MARK: - Now playing provider (macOS Tahoe MediaRemote JXA Bridge + Browser YouTube Music + Apple Music/Spotify)

final class MediaProvider: ObservableObject {
    @Published var info = MediaInfo()
    var onTrackChanged: ((MediaInfo) -> Void)?

    private var mrHandle: UnsafeMutableRawPointer?
    private var pollTick: Timer?
    private var elapsedTicker: Timer?
    private var usingFallback = false
    private var lastTrackKey: String = ""

    // Monotonic wall-clock anchor so the elapsed time counter ticks every second without resetting
    private var playbackAnchorDate: Date = Date()
    private var playbackAnchorElapsed: TimeInterval = 0
    // Grace window after user seeks so background polls never snap the scrubber back
    private var lastSeekDate: Date = .distantPast
    private var userPausedTrackKey: String? = nil

    // MediaRemote C symbols (used when available in-process, supplemented by MediaRemoteJXABridge on macOS 15.4+/Tahoe)
    private typealias MRGetNowPlayingInfoFunc = @convention(c) (DispatchQueue?, @escaping (CFDictionary?) -> Void) -> Void
    private typealias MRRegisterFunc = @convention(c) (@escaping () -> Void) -> Void
    private typealias MRSendCommandFunc = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias MRSetElapsedTimeFunc = @convention(c) (Double) -> Void

    private let commandPlay: UInt32 = 0
    private let commandPause: UInt32 = 1
    private let commandTogglePlayPause: UInt32 = 2
    private let commandNext: UInt32 = 4
    private let commandPrev: UInt32 = 5

    private var getNowPlaying: MRGetNowPlayingInfoFunc?
    private var registerForChanges: MRRegisterFunc?
    private var sendCommand: MRSendCommandFunc?
    private var mrSetElapsedTime: MRSetElapsedTimeFunc?

    init() {
        loadMediaRemote()
    }

    deinit {
        pollTick?.invalidate()
        elapsedTicker?.invalidate()
        if let h = mrHandle { dlclose(h) }
    }

    // MARK: - MediaRemote dynamic loading

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        if ProcessInfo.processInfo.environment["OPENNOOK_NO_MEDIAREMOTE"] != nil { return }
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        mrHandle = handle
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlaying = unsafeBitCast(sym, to: MRGetNowPlayingInfoFunc?.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerForChanges = unsafeBitCast(sym, to: MRRegisterFunc?.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(sym, to: MRSendCommandFunc?.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            mrSetElapsedTime = unsafeBitCast(sym, to: MRSetElapsedTimeFunc?.self)
        }
    }

    // MARK: - Reading state

    func startObserving() {
        if let register = registerForChanges {
            register {
                DispatchQueue.main.async { self.refresh() }
            }
        }
        let poll = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTick = poll

        let tick = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.info.playing && self.info.hasContent {
                    let live = self.currentMonotonicElapsed()
                    if self.info.duration > 0 && live > self.info.duration {
                        self.info.duration = live + 10
                    }
                    self.info.elapsedTime = live
                }
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        elapsedTicker = tick

        refresh()
    }

    private func currentMonotonicElapsed() -> TimeInterval {
        guard info.playing else { return playbackAnchorElapsed }
        return playbackAnchorElapsed + max(0, Date().timeIntervalSince(playbackAnchorDate))
    }

    private func setElapsedAnchor(_ seconds: TimeInterval, playing: Bool) {
        playbackAnchorElapsed = max(0, seconds)
        playbackAnchorDate = Date()
        info.elapsedTime = playbackAnchorElapsed
        info.playing = playing
    }

    func refresh() {
        // 1. Query macOS system-wide Now Playing via MediaRemoteJXABridge first (works across Safari, Brave, Chrome, Music, Spotify on macOS Tahoe)
        MediaRemoteJXABridge.queryNowPlaying { [weak self] mrInfo in
            guard let self = self else { return }
            if let mr = mrInfo, mr.hasContent, mr.playing {
                DispatchQueue.main.async {
                    self.usingFallback = false
                    self.applyInfo(mr)
                }
                return
            }

            let desktopRunning = MusicAppleScript.isMusicRunning || MusicAppleScript.isSpotifyRunning
            let browserRunning = YouTubeMusicDetector.isAnySupportedBrowserRunning

            if desktopRunning {
                MusicAppleScript.queryNowPlaying { [weak self] desktopInfo in
                    guard let self = self else { return }
                    if let d = desktopInfo, d.playing {
                        DispatchQueue.main.async {
                            self.usingFallback = true
                            self.applyInfo(d)
                        }
                        return
                    }
                    if browserRunning {
                        YouTubeMusicDetector.queryNowPlaying { [weak self] ytInfo in
                            guard let self = self else { return }
                            if let yt = ytInfo, yt.hasContent {
                                var combined = yt
                                // Merge exact elapsed/duration from MediaRemoteJXA if same song
                                if let mr = mrInfo, self.isSameTrackTitle(mr.title, yt.title) {
                                    if mr.duration > 0 { combined.duration = mr.duration }
                                    if mr.elapsedTime > 0 { combined.elapsedTime = mr.elapsedTime }
                                }
                                DispatchQueue.main.async {
                                    self.usingFallback = true
                                    self.applyInfo(combined)
                                }
                                return
                            }
                            if let d = desktopInfo, d.hasContent {
                                DispatchQueue.main.async {
                                    self.usingFallback = true
                                    self.applyInfo(d)
                                }
                            } else if let mr = mrInfo, mr.hasContent {
                                DispatchQueue.main.async {
                                    self.usingFallback = false
                                    self.applyInfo(mr)
                                }
                            } else {
                                self.queryMediaRemoteOnly()
                            }
                        }
                    } else if let d = desktopInfo, d.hasContent {
                        DispatchQueue.main.async {
                            self.usingFallback = true
                            self.applyInfo(d)
                        }
                    } else if let mr = mrInfo, mr.hasContent {
                        DispatchQueue.main.async {
                            self.usingFallback = false
                            self.applyInfo(mr)
                        }
                    } else {
                        self.queryMediaRemoteOnly()
                    }
                }
                return
            }

            if browserRunning {
                YouTubeMusicDetector.queryNowPlaying { [weak self] yt in
                    guard let self = self else { return }
                    if var m = yt, m.hasContent {
                        if let mr = mrInfo, self.isSameTrackTitle(mr.title, m.title) {
                            if mr.duration > 0 { m.duration = mr.duration }
                            if mr.elapsedTime > 0 { m.elapsedTime = mr.elapsedTime }
                        }
                        self.usingFallback = true
                        self.applyInfo(m)
                        return
                    }
                    if let mr = mrInfo, mr.hasContent {
                        DispatchQueue.main.async {
                            self.usingFallback = false
                            self.applyInfo(mr)
                        }
                        return
                    }
                    self.queryMediaRemoteOnly()
                }
                return
            }

            if let mr = mrInfo, mr.hasContent {
                DispatchQueue.main.async {
                    self.usingFallback = false
                    self.applyInfo(mr)
                }
                return
            }

            self.queryMediaRemoteOnly()
        }
    }

    private func queryMediaRemoteOnly() {
        if let get = getNowPlaying {
            get(DispatchQueue.main) { [weak self] dict in
                guard let self = self, let dict = dict as? [String: Any] else {
                    DispatchQueue.main.async {
                        if !(self?.info.hasContent ?? false) {
                            self?.info = MediaInfo()
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    if var parsed = MediaInfo.fromMRDictionary(dict) {
                        if parsed.artworkData == nil,
                           self.isSameTrackTitle(parsed.title, self.info.title) {
                            parsed.artworkData = self.info.artworkData
                            parsed.dominantColorHex = self.info.dominantColorHex
                        }
                        parsed.isLiked = self.info.isLiked
                        parsed.isShuffling = self.info.isShuffling
                        parsed.isRepeating = self.info.isRepeating
                        self.usingFallback = false
                        self.applyInfo(parsed)
                    } else if !(self.info.hasContent) {
                        self.info = MediaInfo()
                    }
                }
            }
        } else {
            if !self.info.hasContent {
                self.info = MediaInfo()
            }
        }
    }

    private func normalizeTrackTitle(_ raw: String) -> String {
        var s = raw.lowercased()
            .replacingOccurrences(of: " - youtube music", with: "")
            .replacingOccurrences(of: " - youtube", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parenRange = s.range(of: " (official") {
            s = String(s[..<parenRange.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSameTrackTitle(_ a: String, _ b: String) -> Bool {
        let na = normalizeTrackTitle(a)
        let nb = normalizeTrackTitle(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        if na.count >= 4 && nb.count >= 4 && (na.contains(nb) || nb.contains(na)) {
            return true
        }
        return false
    }

    private func applyInfo(_ next: MediaInfo) {
        guard !next.title.isEmpty else {
            if !info.hasContent {
                info = next
            }
            return
        }

        let isSameTrack = info.hasContent && isSameTrackTitle(next.title, info.title)
        let key = normalizeTrackTitle(next.title)
        let trackChanged = !isSameTrack && !lastTrackKey.isEmpty && key != lastTrackKey

        lastTrackKey = key
        let recentlySeeked = Date().timeIntervalSince(lastSeekDate) < 3.0

        if isSameTrack {
            var merged = next
            merged.artworkData = next.artworkData ?? info.artworkData
            merged.dominantColorHex = next.dominantColorHex ?? info.dominantColorHex
            merged.isLiked = info.isLiked
            merged.isShuffling = info.isShuffling
            merged.isRepeating = info.isRepeating

            if (merged.artist.isEmpty || merged.artist == "YouTube Music") && !info.artist.isEmpty && info.artist != "YouTube Music" {
                merged.artist = info.artist
            }

            if next.duration > 0 && next.duration != 210 {
                merged.duration = next.duration
            } else if info.duration > 0 && info.duration != 210 {
                merged.duration = info.duration
            } else {
                merged.duration = max(info.duration, next.duration)
            }

            if recentlySeeked {
                // Keep the user's explicit seek position during the 3.0s grace window
                merged.playing = info.playing
                merged.elapsedTime = currentMonotonicElapsed()
            } else if next.app == "YouTube Music" && next.elapsedTime <= 1.0 {
                let isUserPaused = (userPausedTrackKey == key)
                let shouldPlay = isUserPaused ? false : next.playing
                if shouldPlay != info.playing {
                    setElapsedAnchor(currentMonotonicElapsed(), playing: shouldPlay)
                }
                merged.playing = shouldPlay
                merged.elapsedTime = currentMonotonicElapsed()
            } else if next.elapsedTime <= 1.0 {
                merged.playing = next.playing
                merged.elapsedTime = currentMonotonicElapsed()
            } else {
                if next.playing != info.playing {
                    setElapsedAnchor(next.elapsedTime, playing: next.playing)
                } else if abs(next.elapsedTime - currentMonotonicElapsed()) > 3.0 {
                    setElapsedAnchor(next.elapsedTime, playing: next.playing)
                }
                merged.elapsedTime = currentMonotonicElapsed()
            }

            info = merged
        } else {
            // New song started! Reset wall-clock anchor and start ticking immediately.
            userPausedTrackKey = nil
            playbackAnchorElapsed = max(0, next.elapsedTime)
            playbackAnchorDate = Date()
            info = next
        }

        if trackChanged {
            onTrackChanged?(info)
        }
    }

    // MARK: - Playback Controls (Skip, Play/Pause, & Seek)

    private var isCurrentSourceBrowser: Bool {
        let b = info.bundleIdentifier.lowercased()
        let a = info.app.lowercased()
        return a.contains("youtube")
            || b.contains("safari")
            || b.contains("brave")
            || b.contains("chrome")
            || b.contains("edgemac")
            || b.contains("thebrowser")
    }

    private func scheduleRapidRefreshes() {
        for delay in [0.22, 0.55, 1.1, 1.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    func togglePlay() {
        let nextPlaying = !info.playing
        let currentKey = normalizeTrackTitle(info.title)
        if !nextPlaying && !currentKey.isEmpty {
            userPausedTrackKey = currentKey
        } else {
            userPausedTrackKey = nil
        }
        setElapsedAnchor(currentMonotonicElapsed(), playing: nextPlaying)

        if info.bundleIdentifier == "com.apple.Music" || info.bundleIdentifier == "com.spotify.client" {
            MusicAppleScript.runCommand("toggle", preferredBundleId: info.bundleIdentifier)
        } else {
            // Send via macOS MediaRemote JXA Controller (works for Safari, Brave, Chrome, Music, Spotify)
            MediaRemoteJXABridge.sendCommand(2) // kMRTogglePlayPause
            if isCurrentSourceBrowser {
                YouTubeMusicDetector.runTransportCommand("toggle")
            } else if MusicAppleScript.isMusicRunning || MusicAppleScript.isSpotifyRunning {
                MusicAppleScript.runCommand("toggle")
            }
        }
        scheduleRapidRefreshes()
    }

    func next() {
        userPausedTrackKey = nil
        setElapsedAnchor(0, playing: true)

        if info.bundleIdentifier == "com.apple.Music" || info.bundleIdentifier == "com.spotify.client" {
            MusicAppleScript.runCommand("next", preferredBundleId: info.bundleIdentifier)
        } else {
            // Send via macOS MediaRemote JXA Controller (kMRNextTrack = 4)
            MediaRemoteJXABridge.sendCommand(4)
            if isCurrentSourceBrowser {
                YouTubeMusicDetector.runTransportCommand("next")
            } else if MusicAppleScript.isMusicRunning || MusicAppleScript.isSpotifyRunning {
                MusicAppleScript.runCommand("next")
            }
        }
        scheduleRapidRefreshes()
    }

    func previous() {
        userPausedTrackKey = nil
        setElapsedAnchor(0, playing: true)

        if info.bundleIdentifier == "com.apple.Music" || info.bundleIdentifier == "com.spotify.client" {
            MusicAppleScript.runCommand("previous", preferredBundleId: info.bundleIdentifier)
        } else {
            // Send via macOS MediaRemote JXA Controller (kMRPreviousTrack = 5)
            MediaRemoteJXABridge.sendCommand(5)
            if isCurrentSourceBrowser {
                YouTubeMusicDetector.runTransportCommand("previous")
            } else if MusicAppleScript.isMusicRunning || MusicAppleScript.isSpotifyRunning {
                MusicAppleScript.runCommand("previous")
            }
        }
        scheduleRapidRefreshes()
    }

    func seek(to position: TimeInterval) {
        let maxDur = info.duration > 0 ? info.duration : 180
        let clamped = max(0, min(maxDur, position))
        lastSeekDate = Date()
        setElapsedAnchor(clamped, playing: info.playing)

        // 1. Seek via MediaRemote JXA Controller (kMRSeekToPlaybackPosition = 24, works on Safari, Brave, Chrome, Music, Spotify)
        MediaRemoteJXABridge.seek(to: clamped)
        mrSetElapsedTime?(clamped)

        // 2. Seek via Chromium DOM <video>.currentTime if playing in a Chromium browser
        if isCurrentSourceBrowser || YouTubeMusicDetector.isAnySupportedBrowserRunning {
            YouTubeMusicDetector.seek(to: clamped)
        }

        // 3. Seek via AppleScript for Apple Music & Spotify
        if info.bundleIdentifier == "com.apple.Music" || info.bundleIdentifier == "com.spotify.client" {
            MusicAppleScript.seek(to: clamped, preferredBundleId: info.bundleIdentifier)
        } else if MusicAppleScript.isMusicRunning || MusicAppleScript.isSpotifyRunning {
            MusicAppleScript.seek(to: clamped)
        }

        scheduleRapidRefreshes()
    }

    func skip(by deltaSeconds: TimeInterval) {
        let target = currentMonotonicElapsed() + deltaSeconds
        seek(to: target)
    }

    func toggleShuffle() {
        info.isShuffling.toggle()
        MusicAppleScript.setShuffle(info.isShuffling)
    }

    func toggleRepeat() {
        info.isRepeating.toggle()
        MusicAppleScript.setRepeat(info.isRepeating)
    }

    func toggleFavorite() {
        info.isLiked.toggle()
        MusicAppleScript.setLoved(info.isLiked)
    }

    func openActivePlayerApp() {
        if !info.bundleIdentifier.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: info.bundleIdentifier) {
            NSWorkspace.shared.open(url)
            return
        }
        if MusicAppleScript.isSpotifyRunning,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - macOS Sequoia / Tahoe Entitled MediaRemote Bridge (via /usr/bin/osascript JXA)

enum MediaRemoteJXABridge {
    private static var artworkCache: [String: (Data, UInt32?)] = [:]
    private static var isQuerying = false

    static func queryNowPlaying(completion: @escaping (MediaInfo?) -> Void) {
        guard !isQuerying else {
            completion(nil)
            return
        }
        isQuerying = true

        let jxa = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
        var reqCls = $.NSClassFromString('MRNowPlayingRequest');
        if (!reqCls) { ''; } else {
            var item = reqCls.localNowPlayingItem;
            var meta = item ? item.metadata : nil;
            var title = meta ? (ObjC.unwrap(meta.title) || '') : '';
            if (!title) { ''; } else {
                var path = reqCls.localNowPlayingPlayerPath;
                var client = path ? path.client : nil;
                var bid = client ? (ObjC.unwrap(client.parentApplicationBundleIdentifier) || ObjC.unwrap(client.bundleIdentifier) || '') : '';
                var artist = meta ? (ObjC.unwrap(meta.trackArtistName) || ObjC.unwrap(meta.albumArtistName) || '') : '';
                var album = meta ? (ObjC.unwrap(meta.albumName) || '') : '';
                var dur = meta ? Number(meta.duration || 0) : 0;
                var el = meta ? Number(meta.calculatedPlaybackPosition || meta.elapsedTime || 0) : 0;
                var playing = Boolean(reqCls.localIsPlaying);
                JSON.stringify({
                    title: title,
                    artist: artist,
                    album: album,
                    bundleId: bid,
                    playing: playing,
                    duration: dur,
                    elapsed: el
                });
            }
        }
        """

        DispatchQueue.global(qos: .utility).async {
            defer { isQuerying = false }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-l", "JavaScript", "-e", jxa]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                completion(nil)
                return
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let jsonData = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let title = dict["title"] as? String, !title.isEmpty else {
                completion(nil)
                return
            }

            let artistRaw = (dict["artist"] as? String ?? "").replacingOccurrences(of: " - Topic", with: "")
            let album = dict["album"] as? String ?? ""
            let bundleId = dict["bundleId"] as? String ?? ""
            let playing = dict["playing"] as? Bool ?? false
            let duration = dict["duration"] as? Double ?? 0
            let elapsed = dict["elapsed"] as? Double ?? 0

            let lowerBid = bundleId.lowercased()
            let appName: String
            if lowerBid.contains("music") {
                appName = "Music"
            } else if lowerBid.contains("spotify") {
                appName = "Spotify"
            } else if lowerBid.contains("safari") || lowerBid.contains("brave") || lowerBid.contains("chrome") || lowerBid.contains("edgemac") || lowerBid.contains("thebrowser") {
                appName = "YouTube Music"
            } else {
                appName = "Now Playing"
            }

            var info = MediaInfo(
                title: title,
                artist: artistRaw,
                album: album,
                app: appName,
                bundleIdentifier: bundleId,
                playing: playing,
                duration: duration,
                elapsedTime: max(0, elapsed)
            )

            let cacheKey = "\(title.lowercased())|\(artistRaw.lowercased())"
            if let cachedArt = artworkCache[cacheKey] {
                info.artworkData = cachedArt.0
                info.dominantColorHex = cachedArt.1
                completion(info)
            } else {
                completion(info)
                fetchArtworkFromiTunes(title: title, artist: artistRaw, cacheKey: cacheKey)
            }
        }
    }

    static func sendCommand(_ commandCode: Int) {
        let jxa = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
        var ctrlCls = $.NSClassFromString('MRNowPlayingController');
        if (ctrlCls) {
            var ctrl = ctrlCls.localRouteController;
            ctrl.sendCommandOptionsCompletion(\(commandCode), $(), $());
            $.NSThread.sleepForTimeInterval(0.06);
        }
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-l", "JavaScript", "-e", jxa]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    static func seek(to positionSeconds: TimeInterval) {
        let posStr = String(format: "%.2f", max(0, positionSeconds))
        let jxa = """
        ObjC.import('Foundation');
        $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
        var ctrlCls = $.NSClassFromString('MRNowPlayingController');
        if (ctrlCls) {
            var ctrl = ctrlCls.localRouteController;
            var opts = $.NSDictionary.dictionaryWithObjectForKey($(\(posStr)), $('kMRMediaRemoteOptionPlaybackPosition'));
            ctrl.sendCommandOptionsCompletion(24, opts, $());
            $.NSThread.sleepForTimeInterval(0.06);
        }
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-l", "JavaScript", "-e", jxa]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    private static func fetchArtworkFromiTunes(title: String, artist: String, cacheKey: String) {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artStr = (first["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "300x300bb"),
                  let artUrl = URL(string: artStr) else { return }
            URLSession.shared.dataTask(with: artUrl) { imgData, _, _ in
                guard let imgData = imgData else { return }
                let dom = ArtworkColorExtractor.extractDominantHex(from: imgData)
                artworkCache[cacheKey] = (imgData, dom)
            }.resume()
        }.resume()
    }
}

// MARK: - AppleScript helper (Apple Music & Spotify with Artwork & Precise Seek)

enum MusicAppleScript {
    private static var artworkCache: [String: (Data, UInt32?)] = [:]

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil
    }

    static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    static func queryNowPlaying(completion: @escaping (MediaInfo?) -> Void) {
        let musicActive = isMusicRunning
        let spotifyActive = isSpotifyRunning

        guard musicActive || spotifyActive else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            var musicInfo: MediaInfo? = nil
            var spotifyInfo: MediaInfo? = nil

            if musicActive {
                musicInfo = querySingleDesktopApp(isMusic: true)
            }
            if spotifyActive {
                spotifyInfo = querySingleDesktopApp(isMusic: false)
            }

            let chosen: MediaInfo?
            if let m = musicInfo, m.playing {
                chosen = m
            } else if let s = spotifyInfo, s.playing {
                chosen = s
            } else {
                chosen = musicInfo ?? spotifyInfo
            }

            guard var result = chosen else {
                completion(nil)
                return
            }

            let cacheKey = "\(result.bundleIdentifier)|\(result.title)|\(result.artist)"
            if let cachedArt = artworkCache[cacheKey] {
                result.artworkData = cachedArt.0
                result.dominantColorHex = cachedArt.1
                completion(result)
            } else {
                completion(result)
                fetchArtworkForDesktopTrack(info: result, cacheKey: cacheKey)
            }
        }
    }

    private static func querySingleDesktopApp(isMusic: Bool) -> MediaInfo? {
        let script: String
        if isMusic {
            script = """
            tell application id "com.apple.Music"
                try
                    if player state is not stopped and exists (current track) then
                        set out to {name of current track, artist of current track, player state is playing, "Music", player position, duration of current track, album of current track, shuffle enabled, favorited of current track}
                        return out
                    end if
                end try
                return {"", "", false, "", 0, 0, "", false, false}
            end tell
            """
        } else {
            script = """
            tell application id "com.spotify.client"
                try
                    if player state is not stopped then
                        set out to {name of current track, artist of current track, player state is playing, "Spotify", player position, ((duration of current track) / 1000), album of current track, shuffling, repeating}
                        return out
                    end if
                end try
                return {"", "", false, "", 0, 0, "", false, false}
            end tell
            """
        }

        var err: NSDictionary?
        guard let desc = NSAppleScript(source: script)?.executeAndReturnError(&err),
              desc.descriptorType == typeAEList, desc.numberOfItems >= 4 else {
            return nil
        }
        let title = desc.atIndex(1)?.stringValue ?? ""
        guard !title.isEmpty else { return nil }
        let artist = desc.atIndex(2)?.stringValue ?? ""
        let playing = desc.atIndex(3)?.booleanValue ?? false
        let app = desc.atIndex(4)?.stringValue ?? ""
        let elapsed = desc.numberOfItems >= 5 ? (desc.atIndex(5)?.doubleValue ?? Double(desc.atIndex(5)?.int32Value ?? 0)) : 0
        let duration = desc.numberOfItems >= 6 ? (desc.atIndex(6)?.doubleValue ?? Double(desc.atIndex(6)?.int32Value ?? 0)) : 0
        let album = desc.numberOfItems >= 7 ? desc.atIndex(7)?.stringValue ?? "" : ""
        let shuffling = desc.numberOfItems >= 8 ? desc.atIndex(8)?.booleanValue ?? false : false
        let extraBool = desc.numberOfItems >= 9 ? desc.atIndex(9)?.booleanValue ?? false : false

        return MediaInfo(
            title: title,
            artist: artist,
            album: album,
            app: app,
            bundleIdentifier: isMusic ? "com.apple.Music" : "com.spotify.client",
            playing: playing,
            duration: duration,
            elapsedTime: elapsed,
            isShuffling: shuffling,
            isRepeating: !isMusic && extraBool,
            isLiked: isMusic && extraBool
        )
    }

    private static func fetchArtworkForDesktopTrack(info: MediaInfo, cacheKey: String) {
        if info.bundleIdentifier == "com.spotify.client" {
            let sc = "tell application id \"com.spotify.client\" to try\nreturn artwork url of current track\nend try"
            if let urlStr = NSAppleScript(source: sc)?.executeAndReturnError(nil).stringValue,
               let url = URL(string: urlStr) {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data = data else { return }
                    let dom = ArtworkColorExtractor.extractDominantHex(from: data)
                    artworkCache[cacheKey] = (data, dom)
                }.resume()
                return
            }
        }
        let query = "\(info.title) \(info.artist)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artStr = (first["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "300x300bb"),
                  let artUrl = URL(string: artStr) else { return }
            URLSession.shared.dataTask(with: artUrl) { imgData, _, _ in
                guard let imgData = imgData else { return }
                let dom = ArtworkColorExtractor.extractDominantHex(from: imgData)
                artworkCache[cacheKey] = (imgData, dom)
            }.resume()
        }.resume()
    }

    static func runCommand(_ action: String, preferredBundleId: String? = nil) {
        let targetBundleId: String
        if let pref = preferredBundleId, (pref == "com.apple.Music" || pref == "com.spotify.client") {
            targetBundleId = pref
        } else if isMusicRunning {
            targetBundleId = "com.apple.Music"
        } else if isSpotifyRunning {
            targetBundleId = "com.spotify.client"
        } else {
            return
        }

        let verb: String
        switch action {
        case "toggle": verb = "playpause"
        case "next": verb = "next track"
        case "previous": verb = "previous track"
        default: return
        }

        let sc = "tell application id \"\(targetBundleId)\" to \(verb)"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    static func seek(to position: TimeInterval, preferredBundleId: String? = nil) {
        let targetBundleId: String
        if let pref = preferredBundleId, (pref == "com.apple.Music" || pref == "com.spotify.client") {
            targetBundleId = pref
        } else if isMusicRunning {
            targetBundleId = "com.apple.Music"
        } else if isSpotifyRunning {
            targetBundleId = "com.spotify.client"
        } else {
            return
        }

        let pos = String(format: "%.1f", position)
        let sc = "tell application id \"\(targetBundleId)\" to set player position to \(pos)"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    static func setShuffle(_ enabled: Bool) {
        let musicActive = isMusicRunning
        let spotifyActive = isSpotifyRunning
        guard musicActive || spotifyActive else { return }
        let sc = musicActive
            ? "tell application id \"com.apple.Music\" to set shuffle enabled to \(enabled ? "true" : "false")"
            : "tell application id \"com.spotify.client\" to set shuffling to \(enabled ? "true" : "false")"
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    static func setRepeat(_ enabled: Bool) {
        let musicActive = isMusicRunning
        let spotifyActive = isSpotifyRunning
        guard musicActive || spotifyActive else { return }
        let sc = musicActive
            ? "tell application id \"com.apple.Music\" to set song repeat to \(enabled ? "all" : "off")"
            : "tell application id \"com.spotify.client\" to set repeating to \(enabled ? "true" : "false")"
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }

    static func setLoved(_ loved: Bool) {
        guard isMusicRunning else { return }
        let sc = "tell application id \"com.apple.Music\" to try\nset favorited of current track to \(loved ? "true" : "false")\nend try"
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: sc)?.executeAndReturnError(nil)
        }
    }
}

typealias MediaAppleScript = MusicAppleScript

// MARK: - Safe Per-Browser YouTube Music Detector & Controller

enum YouTubeMusicDetector {
    private static var cache: [String: (MediaInfo, Date)] = [:]
    private static var lastKnownPlayingInfo: MediaInfo? = nil
    private static var isFetching = false

    private struct SupportedBrowser {
        let name: String
        let bundleId: String
        let usesSafariTabSyntax: Bool
    }

    private static let supportedBrowsers: [SupportedBrowser] = [
        SupportedBrowser(name: "Brave Browser", bundleId: "com.brave.Browser", usesSafariTabSyntax: false),
        SupportedBrowser(name: "Safari", bundleId: "com.apple.Safari", usesSafariTabSyntax: true),
        SupportedBrowser(name: "Google Chrome", bundleId: "com.google.Chrome", usesSafariTabSyntax: false),
        SupportedBrowser(name: "Microsoft Edge", bundleId: "com.microsoft.edgemac", usesSafariTabSyntax: false),
        SupportedBrowser(name: "Arc", bundleId: "company.thebrowser.Browser", usesSafariTabSyntax: false)
    ]

    private static func isBrowserRunningAndInstalled(_ bundleId: String) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    static var isAnySupportedBrowserRunning: Bool {
        supportedBrowsers.contains { isBrowserRunningAndInstalled($0.bundleId) }
    }

    struct BrowserTabInfo {
        let browserName: String
        let bundleId: String
        let usesSafariSyntax: Bool
        let url: String
        let tabTitle: String
    }

    static func scanBrowserTabs() -> BrowserTabInfo? {
        let activeBrowsers = supportedBrowsers.filter { isBrowserRunningAndInstalled($0.bundleId) }
        guard !activeBrowsers.isEmpty else { return nil }

        for browser in activeBrowsers {
            let titleProp = browser.usesSafariTabSyntax ? "name of t" : "title of t"

            let script = """
            tell application id "\(browser.bundleId)"
                try
                    -- Pass 1: Prefer a music.youtube.com tab that has an active song title
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to URL of t
                            set ttl to (\(titleProp))
                            if u contains "music.youtube.com" and ttl is not "YouTube Music" and ttl is not "" then
                                return "\(browser.name)|||\(browser.bundleId)|||" & u & "|||" & ttl
                            end if
                        end repeat
                    end repeat
                    -- Pass 2: Any music.youtube.com tab (e.g. paused tab where title is "YouTube Music")
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to URL of t
                            if u contains "music.youtube.com" then
                                return "\(browser.name)|||\(browser.bundleId)|||" & u & "|||" & (\(titleProp))
                            end if
                        end repeat
                    end repeat
                    -- Pass 3: Standard youtube.com/watch tab
                    repeat with w in windows
                        repeat with t in tabs of w
                            set u to URL of t
                            if u contains "youtube.com/watch" then
                                return "\(browser.name)|||\(browser.bundleId)|||" & u & "|||" & (\(titleProp))
                            end if
                        end repeat
                    end repeat
                end try
                return ""
            end tell
            """

            var error: NSDictionary?
            if let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
               !output.isEmpty {
                let parts = output.components(separatedBy: "|||")
                if parts.count >= 4 {
                    return BrowserTabInfo(
                        browserName: parts[0],
                        bundleId: parts[1],
                        usesSafariSyntax: browser.usesSafariTabSyntax,
                        url: parts[2],
                        tabTitle: parts[3]
                    )
                }
            }
        }
        return nil
    }

    /// Sends next / previous / toggle play-pause to Chromium YouTube Music tabs if JS execution is allowed
    static func runTransportCommand(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let activeBrowsers = supportedBrowsers.filter { !$0.usesSafariTabSyntax && isBrowserRunningAndInstalled($0.bundleId) }
            guard !activeBrowsers.isEmpty else { return }

            let jsSnippet: String
            switch command {
            case "next":
                jsSnippet = "(function(){var b=document.querySelector('.next-button.ytmusic-player-bar')||document.querySelector('.ytp-next-button');if(b){b.click();}})()"
            case "previous":
                jsSnippet = "(function(){var b=document.querySelector('.previous-button.ytmusic-player-bar')||document.querySelector('.ytp-prev-button');if(b){b.click();}else{var v=document.querySelector('video');if(v)v.currentTime=0;}})()"
            case "toggle":
                jsSnippet = "(function(){var b=document.querySelector('#play-pause-button.ytmusic-player-bar')||document.querySelector('.ytp-play-button');if(b){b.click();}else{var v=document.querySelector('video');if(v){if(v.paused)v.play();else v.pause();}}})()"
            default:
                return
            }

            for browser in activeBrowsers {
                let script = """
                tell application id "\(browser.bundleId)"
                    try
                        repeat with w in windows
                            repeat with t in tabs of w
                                set u to URL of t
                                if u contains "music.youtube.com" or u contains "youtube.com/watch" then
                                    try
                                        execute t javascript "\(jsSnippet)"
                                    end try
                                    return
                                end if
                            end repeat
                        end repeat
                    end try
                end tell
                """
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        }
    }

    /// Seeks Chromium YouTube Music / YouTube `<video>` element to `position` seconds if JS execution is allowed
    static func seek(to position: TimeInterval) {
        let targetSec = Int(round(max(0, position)))
        DispatchQueue.global(qos: .userInitiated).async {
            let activeBrowsers = supportedBrowsers.filter { !$0.usesSafariTabSyntax && isBrowserRunningAndInstalled($0.bundleId) }
            guard !activeBrowsers.isEmpty else { return }

            let jsSnippet = "(function(){var v=document.querySelector('video');if(v){v.currentTime=\(targetSec);}})()"

            for browser in activeBrowsers {
                let script = """
                tell application id "\(browser.bundleId)"
                    try
                        repeat with w in windows
                            repeat with t in tabs of w
                                set u to URL of t
                                if u contains "music.youtube.com" or u contains "youtube.com/watch" then
                                    try
                                        execute t javascript "\(jsSnippet)"
                                    end try
                                    return
                                end if
                            end repeat
                        end repeat
                    end try
                end tell
                """
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        }
    }

    static func extractVideoId(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "v" })?.value
    }

    static func queryNowPlaying(completion: @escaping (MediaInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let tab = scanBrowserTabs() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let isYTMusicTab = tab.url.contains("music.youtube.com")
            let vid = extractVideoId(from: tab.url) ?? ""
            let cleanTabTitle = tab.tabTitle
                .replacingOccurrences(of: " - YouTube Music", with: "")
                .replacingOccurrences(of: " - YouTube", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if isYTMusicTab && (cleanTabTitle.isEmpty || cleanTabTitle.lowercased() == "youtube music") {
                if var pausedInfo = lastKnownPlayingInfo {
                    pausedInfo.playing = false
                    DispatchQueue.main.async { completion(pausedInfo) }
                    return
                }
                if vid.isEmpty {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
            }

            let cacheKey = "\(vid)|\(cleanTabTitle.lowercased())"

            if let cached = cache[cacheKey], Date().timeIntervalSince(cached.1) < 600 {
                var info = cached.0
                info.playing = true
                lastKnownPlayingInfo = info
                DispatchQueue.main.async { completion(info) }
                return
            }

            if vid.isEmpty {
                guard !cleanTabTitle.isEmpty, cleanTabTitle.lowercased() != "youtube music" else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                fetchFromiTunesCatalog(
                    songTitle: cleanTabTitle,
                    bundleId: tab.bundleId,
                    cacheKey: cacheKey,
                    completion: completion
                )
                return
            }

            guard !isFetching else {
                if let cached = cache[cacheKey]?.0 {
                    DispatchQueue.main.async { completion(cached) }
                } else {
                    DispatchQueue.main.async { completion(lastKnownPlayingInfo) }
                }
                return
            }
            isFetching = true

            guard let oembedUrl = URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(vid)&format=json") else {
                isFetching = false
                DispatchQueue.main.async { completion(nil) }
                return
            }

            var req = URLRequest(url: oembedUrl)
            req.timeoutInterval = 2.5
            let task = URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { isFetching = false }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oembedTitle = json["title"] as? String else {
                    if !cleanTabTitle.isEmpty && cleanTabTitle.lowercased() != "youtube music" {
                        fetchFromiTunesCatalog(
                            songTitle: cleanTabTitle,
                            bundleId: tab.bundleId,
                            cacheKey: cacheKey,
                            completion: completion
                        )
                    } else {
                        DispatchQueue.main.async { completion(nil) }
                    }
                    return
                }

                if !cleanTabTitle.isEmpty,
                   cleanTabTitle.lowercased() != "youtube music",
                   !oembedTitle.lowercased().contains(cleanTabTitle.lowercased()),
                   !cleanTabTitle.lowercased().contains(oembedTitle.lowercased()) {
                    fetchFromiTunesCatalog(
                        songTitle: cleanTabTitle,
                        bundleId: tab.bundleId,
                        cacheKey: cacheKey,
                        completion: completion
                    )
                    return
                }

                let authorRaw = json["author_name"] as? String ?? ""
                let cleanArtist = authorRaw.replacingOccurrences(of: " - Topic", with: "").trimmingCharacters(in: .whitespaces)
                let thumbStr = json["thumbnail_url"] as? String ?? "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg"

                let info = MediaInfo(
                    title: oembedTitle,
                    artist: cleanArtist.isEmpty ? "YouTube Music" : cleanArtist,
                    album: "YouTube Music",
                    app: "YouTube Music",
                    bundleIdentifier: tab.bundleId,
                    playing: true,
                    duration: 210,
                    elapsedTime: 0
                )

                cache[cacheKey] = (info, Date())
                lastKnownPlayingInfo = info
                DispatchQueue.main.async { completion(info) }

                let searchQuery = "\(oembedTitle) \(cleanArtist)"
                if let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let itunesUrl = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") {
                    URLSession.shared.dataTask(with: itunesUrl) { iData, _, _ in
                        if let iData = iData,
                           let iJson = try? JSONSerialization.jsonObject(with: iData) as? [String: Any],
                           let results = iJson["results"] as? [[String: Any]],
                           let first = results.first,
                           let millis = first["trackTimeMillis"] as? Double, millis > 0 {
                            var updated = cache[cacheKey]?.0 ?? info
                            updated.duration = round(millis / 1000.0)
                            cache[cacheKey] = (updated, Date())
                            lastKnownPlayingInfo = updated
                            DispatchQueue.main.async { completion(updated) }
                        }
                    }.resume()
                }

                if let thumbUrl = URL(string: thumbStr) {
                    var imgReq = URLRequest(url: thumbUrl)
                    imgReq.timeoutInterval = 3.0
                    URLSession.shared.dataTask(with: imgReq) { imgData, _, _ in
                        guard let imgData = imgData else { return }
                        let domHex = ArtworkColorExtractor.extractDominantHex(from: imgData)
                        var updated = cache[cacheKey]?.0 ?? info
                        updated.artworkData = imgData
                        updated.dominantColorHex = domHex
                        cache[cacheKey] = (updated, Date())
                        lastKnownPlayingInfo = updated
                        DispatchQueue.main.async { completion(updated) }
                    }.resume()
                }
            }
            task.resume()
        }
    }

    private static func fetchFromiTunesCatalog(
        songTitle: String,
        bundleId: String,
        cacheKey: String,
        completion: @escaping (MediaInfo?) -> Void
    ) {
        let initial = MediaInfo(
            title: songTitle,
            artist: "YouTube Music",
            album: "YouTube Music",
            app: "YouTube Music",
            bundleIdentifier: bundleId,
            playing: true,
            duration: 210,
            elapsedTime: 0
        )
        cache[cacheKey] = (initial, Date())
        lastKnownPlayingInfo = initial
        DispatchQueue.main.async { completion(initial) }

        guard let encoded = songTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=1") else {
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 2.5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first else { return }

            var enriched = cache[cacheKey]?.0 ?? initial
            if let artist = first["artistName"] as? String, !artist.isEmpty {
                enriched.artist = artist
            }
            if let album = first["collectionName"] as? String, !album.isEmpty {
                enriched.album = album
            }
            if let millis = first["trackTimeMillis"] as? Double, millis > 0 {
                enriched.duration = round(millis / 1000.0)
            }
            cache[cacheKey] = (enriched, Date())
            lastKnownPlayingInfo = enriched
            DispatchQueue.main.async { completion(enriched) }

            if let artStr = (first["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "300x300bb"),
               let artUrl = URL(string: artStr) {
                URLSession.shared.dataTask(with: artUrl) { imgData, _, _ in
                    guard let imgData = imgData else { return }
                    let domHex = ArtworkColorExtractor.extractDominantHex(from: imgData)
                    var withArt = cache[cacheKey]?.0 ?? enriched
                    withArt.artworkData = imgData
                    withArt.dominantColorHex = domHex
                    cache[cacheKey] = (withArt, Date())
                    lastKnownPlayingInfo = withArt
                    DispatchQueue.main.async { completion(withArt) }
                }.resume()
            }
        }.resume()
    }
}
