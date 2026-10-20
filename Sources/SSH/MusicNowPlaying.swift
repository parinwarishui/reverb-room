//
//  MusicNowPlaying.swift
//  Follows Apple Music's current track for the Now Playing panel and the tank,
//  and sends it player commands (play/pause, skip, seek, shuffle, repeat).
//
//  - Track changes, title/artist/length and play/pause come from Music's
//    `com.apple.Music.playerInfo` distributed notification (no permission needed).
//  - The artwork, the playhead, shuffle/repeat and every command go through
//    Apple Events (`MusicEvents`, on a background queue so the window never
//    waits on Music), which need a one-time Automation approval. The prompt is raised
//    with AEDeterminePermissionToAutomateTarget on a background queue, because the
//    first Apple Event would otherwise block the main thread until the user answers.
//  - If Music has no artwork for the track (often the case for streamed songs),
//    the cover is looked up in Apple's public iTunes Search API, cached per album.
//  - Music is never scripted unless it's already running: `tell application
//    "Music"` would launch it.
//

import AppKit
import CoreServices
import ImageIO
import Observation
import QuartzCore

@Observable
final class MusicNowPlaying {
    enum Access { case unknown, granted, denied }

    // Track
    private(set) var isRunning = false
    private(set) var trackName = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artwork: NSImage?
    private(set) var palette = TankPalette.neutral

    // Playback
    private(set) var isPlaying = false
    private(set) var clock = PlaybackClock()
    /// Advanced every half second while playing, so views showing the playhead redraw.
    private(set) var now = CACurrentMediaTime()
    private(set) var shuffle = false
    private(set) var repeatMode = RepeatMode.off

    private(set) var access = Access.unknown

    var hasTrack: Bool { !trackName.isEmpty || !artist.isEmpty }
    /// Commands need Automation approval and a running Music.
    var canControl: Bool { access == .granted && isRunning }

    @ObservationIgnored private var trackKey: String?
    @ObservationIgnored private var coverCache: [String: Cover?] = [:]
    @ObservationIgnored private var checkingPermission = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var holdPlayStateUntil = 0.0
    @ObservationIgnored private var holdShuffleUntil = 0.0
    @ObservationIgnored private var holdRepeatUntil = 0.0
    @ObservationIgnored private var emptyReadRetries = 0
    /// Every Apple Event to Music goes through this queue, in order, off the main thread.
    @ObservationIgnored private let eventQueue = DispatchQueue(label: "SSH.music", qos: .userInitiated)

    private struct Cover {
        let palette: TankPalette
        let image: NSImage?
    }

    private static let bundleID = SSHController.musicBundleID
    /// How often the playhead is re-read from Music while playing (in half-second ticks).
    private static let resyncTicks = 10
    /// After a button changes play state, shuffle or repeat here, Music can still
    /// report the old value for a moment. For this long, re-reads don't override
    /// what the user just set, so the button doesn't flick back and forth.
    private static let holdSeconds = 2.0

    init() {
        isRunning = AudioSources.isRunning(bundleID: Self.bundleID)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] note in
            self?.playerInfoChanged(note.userInfo ?? [:])
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isMusic(note) else { return }
            self?.isRunning = true
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isMusic(note) else { return }
            self?.isRunning = false
            self?.clearTrack()
        }
        refresh()
    }

    private static func isMusic(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleID
    }

    // MARK: Following Music

    private func playerInfoChanged(_ info: [AnyHashable: Any]) {
        isRunning = true
        let state = info["Player State"] as? String ?? ""
        guard state != "Stopped" else {
            clearTrack()
            return
        }
        isPlaying = state == "Playing"
        trackName = info["Name"] as? String ?? ""
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        if let milliseconds = info["Total Time"] as? NSNumber {
            clock.duration = milliseconds.doubleValue / 1000
        }
        clock.setPlaying(isPlaying, at: CACurrentMediaTime())
        updateTicker()

        let key = Self.key(name: trackName, artist: artist, album: album)
        if key != trackKey {
            refresh()
        } else if access == .granted {
            readPlayback()
        }
    }

    private func clearTrack() {
        isPlaying = false
        trackName = ""
        artist = ""
        album = ""
        artwork = nil
        trackKey = nil
        clock = PlaybackClock()
        updateTicker()
    }

    /// Reads the current track, its artwork and the playhead. Called on the main
    /// thread; the reads themselves happen on `eventQueue`.
    func refresh() {
        guard AudioSources.isRunning(bundleID: Self.bundleID) else {
            isRunning = false
            clearTrack()
            return
        }
        isRunning = true
        guard !checkingPermission else { return }
        checkingPermission = true
        DispatchQueue.global(qos: .utility).async {
            // Shows the one-time prompt if the user hasn't decided yet; otherwise
            // returns straight away.
            let status = Self.automationPermission(askIfNeeded: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkingPermission = false
                switch status {
                case noErr:
                    if self.access != .granted { dlog("Automation: allowed to use Music") }
                    self.access = .granted
                    self.readCurrentTrack()
                    self.readPlayback()
                case OSStatus(errAEEventNotPermitted):
                    if self.access != .denied { dlog("Automation: not allowed to use Music") }
                    self.markDenied()
                default:
                    // procNotFound: Music quit in the meantime. Anything else: try
                    // again on the next track change.
                    dlog("Automation check returned \(status)")
                }
            }
        }
    }

    private func markDenied() {
        access = .denied
        palette = .neutral
        artwork = nil
    }

    private func readCurrentTrack() {
        // The cover is decoded and its colours picked on the queue too.
        perform({ () -> (MusicEvents.Track, Cover?) in
            let track = try MusicEvents.track()
            return (track, track.artwork.flatMap { Self.cover(fromImage: $0) })
        }, then: { [weak self] in self?.applyTrack($0.0, cover: $0.1) })
    }

    private func applyTrack(_ track: MusicEvents.Track, cover: Cover?) {
        guard track.state != "stopped" else {
            clearTrack()
            return
        }
        let name = track.name, artist = track.artist, album = track.album

        // Asked mid-change, Music can answer before the new song is ready, with no
        // name, artist or album. Ask again shortly instead of dropping the cover.
        if name.isEmpty, artist.isEmpty, album.isEmpty {
            if emptyReadRetries < 3 {
                emptyReadRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.readCurrentTrack() }
                return
            }
            dlog("Artwork: Music reports no song details, using the neutral palette")
            apply(nil)
            return
        }
        emptyReadRetries = 0

        trackName = name
        self.artist = artist
        self.album = album
        let key = Self.key(name: name, artist: artist, album: album)
        trackKey = key

        if let cover, let bytes = track.artwork?.count {
            dlog("Artwork: from Music (\(bytes) bytes)")
            apply(cover)
        } else {
            dlog("Artwork: Music has none for this song, looking it up online")
            self.artwork = nil
            lookUpCover(name: name, artist: artist, album: album, forTrack: key)
        }
    }

    /// Playhead, length, shuffle and repeat.
    private func readPlayback() {
        perform({ (try MusicEvents.playback(), CACurrentMediaTime()) },
                then: { [weak self] in self?.applyPlayback($0.0, readAt: $0.1) })
    }

    /// `readAt` is when Music answered, so the playhead lines up with the clock.
    private func applyPlayback(_ playback: MusicEvents.Playback, readAt: Double) {
        guard playback.state != "stopped" else {
            clearTrack()
            return
        }
        if readAt >= holdPlayStateUntil { isPlaying = playback.state == "playing" }
        if playback.duration > 0 { clock.duration = playback.duration }
        clock.sync(position: playback.position, playing: isPlaying, at: readAt)
        if readAt >= holdShuffleUntil { shuffle = playback.shuffle }
        if readAt >= holdRepeatUntil { repeatMode = playback.repeatMode }
        now = CACurrentMediaTime()
        updateTicker()
    }

    private func apply(_ cover: Cover?) {
        palette = cover?.palette ?? .neutral
        artwork = cover?.image
    }

    private static func key(name: String, artist: String, album: String) -> String {
        "\(name)\u{1F}\(artist)\u{1F}\(album)"
    }

    // MARK: Playhead ticking

    private func updateTicker() {
        if isPlaying, ticker == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
            ticks = 0
        } else if !isPlaying, let ticker {
            ticker.invalidate()
            self.ticker = nil
            now = CACurrentMediaTime()
        }
    }

    private func tick() {
        now = CACurrentMediaTime()
        ticks += 1
        // Catch seeks and skips made in Music itself, and any drift.
        if ticks % Self.resyncTicks == 0, access == .granted { readPlayback() }
    }

    // MARK: Commands

    /// Flips the button at once (and holds it), then tells Music.
    func playPause() {
        guard ensureControl() else { return }
        let at = CACurrentMediaTime()
        isPlaying.toggle()
        clock.setPlaying(isPlaying, at: at)
        holdPlayStateUntil = at + Self.holdSeconds
        updateTicker()
        send { try MusicEvents.playPause() }
    }
    /// Like Music's own back button: restarts the song, or goes back if it just started.
    func previous() {
        guard ensureControl() else { return }
        send { try MusicEvents.backTrack() }
    }

    func next() {
        guard ensureControl() else { return }
        send { try MusicEvents.nextTrack() }
    }

    func seek(to seconds: Double) {
        guard ensureControl() else { return }
        clock.sync(position: seconds, playing: isPlaying, at: CACurrentMediaTime())
        send { try MusicEvents.seek(to: seconds) }
    }

    // Shuffle and repeat skip the read-back: the button already shows the new value,
    // and the regular resync corrects it if Music didn't take the change.
    func toggleShuffle() {
        guard ensureControl() else { return }
        shuffle.toggle()
        holdShuffleUntil = CACurrentMediaTime() + Self.holdSeconds
        let on = shuffle
        send(readBack: false) { try MusicEvents.setShuffle(on) }
    }

    func cycleRepeat() {
        guard ensureControl() else { return }
        repeatMode = repeatMode.next
        holdRepeatUntil = CACurrentMediaTime() + Self.holdSeconds
        let mode = repeatMode
        send(readBack: false) { try MusicEvents.setRepeat(mode) }
    }

    /// False when commands can't go through yet; asks for permission if undecided.
    private func ensureControl() -> Bool {
        if canControl { return true }
        if access == .unknown { refresh() }
        return false
    }

    /// Sends a command, then (unless `readBack` is false) re-reads playback, both
    /// on `eventQueue`, so a press never waits on Music.
    private func send(readBack: Bool = true, _ command: @escaping () throws -> Void) {
        perform({ () -> (MusicEvents.Playback, Double)? in
            try command()
            return readBack ? (try MusicEvents.playback(), CACurrentMediaTime()) : nil
        }, then: { [weak self] in
            if let (playback, readAt) = $0 { self?.applyPlayback(playback, readAt: readAt) }
        })
    }

    /// Runs `work` on `eventQueue` and hands its result to `then` on the main
    /// thread. Skipped if Music isn't running (an Apple Event would launch it);
    /// a failure is logged, and a revoked permission noted.
    private func perform<T>(_ work: @escaping () throws -> T, then: @escaping (T) -> Void) {
        guard isRunning, AudioSources.isRunning(bundleID: Self.bundleID) else { return }
        eventQueue.async { [weak self] in
            do {
                let result = try work()
                DispatchQueue.main.async { then(result) }
            } catch {
                let code = (error as? MusicEvents.Failure)?.code ?? 0
                dlog("Music event failed (\(code))")
                guard code == Int(errAEEventNotPermitted) else { return }
                DispatchQueue.main.async { self?.markDenied() }
            }
        }
    }

    // MARK: Online fallback (iTunes Search API)

    /// Sends only the artist, album and song name to Apple's public search API, and
    /// only when Music itself has no artwork. Results (including "not found") are
    /// cached for the session, so each album or single is looked up once.
    private func lookUpCover(name: String, artist: String, album: String, forTrack key: String) {
        let cacheKey = "\(artist)\u{1F}\(album.isEmpty ? name : album)".lowercased()
        if let cached = coverCache[cacheKey] {
            apply(cached)
            return
        }
        let attempts = CoverSearch.attempts(name: name, artist: artist, album: album,
                                            region: Locale.current.region?.identifier)
        guard !attempts.isEmpty else {
            apply(nil)
            return
        }
        Self.fetchCover(attempts[...]) { [weak self] found, how in
            DispatchQueue.main.async {
                guard let self else { return }
                self.coverCache[cacheKey] = found
                dlog(found == nil ? "Artwork: online lookup found nothing" : "Artwork: found online (\(how))")
                if self.trackKey == key { self.apply(found) }
            }
        }
    }

    /// Tries each query in turn until one gives a believable match with a usable
    /// image. Calls `completion` on a background queue with the cover and which
    /// query found it (e.g. "th store, song search"), or nil.
    private static func fetchCover(_ attempts: ArraySlice<CoverSearch.Attempt>,
                                   completion: @escaping (Cover?, String) -> Void) {
        guard let attempt = attempts.first else {
            completion(nil, "")
            return
        }
        let tryNext = { fetchCover(attempts.dropFirst(), completion: completion) }
        URLSession.shared.dataTask(with: attempt.url) { data, _, _ in
            let items = data.flatMap { try? JSONDecoder().decode(CoverSearch.Response.self, from: $0) }?.results ?? []
            guard let link = CoverSearch.bestArtwork(in: items, kind: attempt.kind, artist: attempt.artist, title: attempt.title),
                  let imageURL = URL(string: link) else {
                tryNext()
                return
            }
            URLSession.shared.dataTask(with: imageURL) { imageData, _, _ in
                if let cover = imageData.flatMap({ cover(fromImage: $0) }) {
                    completion(cover, "\(attempt.country) store, \(attempt.kind.rawValue) search")
                } else {
                    tryNext()
                }
            }.resume()
        }.resume()
    }

    // MARK: Helpers

    private static func cover(fromImage data: Data) -> Cover? {
        guard let colours = evidentColors(fromImage: data) else { return nil }
        return Cover(palette: TankPalette(first: colours.0, second: colours.1, third: colours.2), image: NSImage(data: data))
    }

    /// The cover shrunk to 32 × 32 sRGB pixels, then its three most evident colours.
    static func evidentColors(fromImage data: Data) -> (RGB, RGB, RGB)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 32
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let pixels = stride(from: 0, to: bytes.count, by: 4).map { i in
            RGB(r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i + 2]) / 255)
        }
        return PalettePicker.evidentColors(in: pixels)
    }

    /// noErr, errAEEventNotPermitted (denied), or procNotFound (Music not running).
    private static func automationPermission(askIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundleID.withCString { pointer in
            AECreateDesc(DescType(typeApplicationBundleID), pointer, bundleID.utf8.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                     AEEventID(typeWildCard), askIfNeeded)
    }
}
