//
//  MusicEvents.swift
//  Talks to Apple Music with raw Apple Events instead of AppleScript. Unlike
//  NSAppleScript, which may only be used on the main thread, sending an Apple
//  Event is safe from any thread, so `MusicNowPlaying` runs these on a
//  background queue and the window never stalls while Music answers (40–80 ms
//  per script on the main thread before). Codes are from Music's scripting
//  dictionary (Music.app/Contents/Resources/com.apple.Music.sdef).
//

import AppKit

enum MusicEvents {
    /// What the Now Playing panel needs about the current track.
    struct Track {
        var state: String
        var name = ""
        var artist = ""
        var album = ""
        /// The cover in its original format, if the track has one.
        var artwork: Data?
    }

    struct Playback {
        var state: String
        var position = 0.0
        var duration = 0.0
        var shuffle = false
        var repeatMode = RepeatMode.off
    }

    /// The error Music's Apple Events fail with; `code` is the OSStatus
    /// (errAEEventNotPermitted when Automation is denied, procNotFound when
    /// Music has quit).
    struct Failure: Error {
        let code: Int
    }

    static func track() throws -> Track {
        let state = try playerState()
        guard state != "stopped" else { return Track(state: state) }
        var track = Track(state: state)
        // Each read is guarded, as in Music's own scripts: between songs, or for
        // a stream, any of these can fail without the rest being wrong.
        let current = property("pTrk")
        track.name = (try? get(property("pnam", of: current)).stringValue) ?? ""
        track.artist = (try? get(property("pArt", of: current)).stringValue) ?? ""
        track.album = (try? get(property("pAlb", of: current)).stringValue) ?? ""
        let artwork = element("cArt", index: 1, of: current)
        if let cover = (try? get(property("pRaw", of: artwork))) ?? (try? get(property("pPCT", of: artwork))),
           cover.descriptorType != typeType {   // 'missing value' comes back as a type, not data
            track.artwork = cover.data
        }
        return track
    }

    static func playback() throws -> Playback {
        let state = try playerState()
        guard state != "stopped" else { return Playback(state: state) }
        var playback = Playback(state: state)
        playback.position = (try? get(property("pPos")).doubleValue) ?? 0
        playback.duration = (try? get(property("pDur", of: property("pTrk"))).doubleValue) ?? 0
        playback.shuffle = (try? get(property("pShE")).booleanValue) ?? false
        if let code = try? get(property("pRpt")).enumCodeValue {
            playback.repeatMode = code == fourCC("kRp1") ? .one : code == fourCC("kAll") ? .all : .off
        }
        return playback
    }

    // MARK: Commands

    static func playPause() throws { try command("hook", "PlPs") }
    static func nextTrack() throws { try command("hook", "Next") }
    static func backTrack() throws { try command("hook", "Back") }

    static func seek(to seconds: Double) throws {
        try set(property("pPos"), to: NSAppleEventDescriptor(double: seconds))
    }

    static func setShuffle(_ on: Bool) throws {
        try set(property("pShE"), to: NSAppleEventDescriptor(boolean: on))
    }

    static func setRepeat(_ mode: RepeatMode) throws {
        let code: String
        switch mode {
        case .off: code = "kRpO"
        case .one: code = "kRp1"
        case .all: code = "kAll"
        }
        try set(property("pRpt"), to: NSAppleEventDescriptor(enumCode: fourCC(code)))
    }

    // MARK: Sending

    private static let timeout: TimeInterval = 5

    private static func playerState() throws -> String {
        switch try get(property("pPlS")).enumCodeValue {
        case fourCC("kPSP"): return "playing"
        case fourCC("kPSp"): return "paused"
        case fourCC("kPSS"): return "stopped"
        default: return "other"   // fast forwarding or rewinding
        }
    }

    private static func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = makeEvent(kAECoreSuite, kAEGetData)
        event.setParam(specifier, forKeyword: keyDirectObject)
        return try send(event)
    }

    private static func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        let event = makeEvent(kAECoreSuite, kAESetData)
        event.setParam(specifier, forKeyword: keyDirectObject)
        event.setParam(value, forKeyword: keyAEData)
        _ = try send(event)
    }

    private static func command(_ eventClass: String, _ eventID: String) throws {
        _ = try send(makeEvent(fourCC(eventClass), fourCC(eventID)))
    }

    private static func makeEvent(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: SSHController.musicBundleID),
                               returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends and waits for the reply, without ever launching Music or showing UI
    /// (a permission prompt is raised separately, ahead of time).
    private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch let error as NSError {
            throw Failure(code: error.code)
        }
        // Music reports script errors (e.g. no artwork) in the reply, not as a send failure.
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            throw Failure(code: Int(number))
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    // MARK: Object specifiers

    /// `<code> of <container>`; the container defaults to the application.
    private static func property(_ code: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        specifier(want: typeProperty, form: formPropertyID,
                  key: NSAppleEventDescriptor(typeCode: fourCC(code)), of: container)
    }

    /// `<class> <index> of <container>`, e.g. artwork 1 of the current track.
    private static func element(_ classCode: String, index: Int32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: fourCC(classCode), form: formAbsolutePosition,
                  key: NSAppleEventDescriptor(int32: index), of: container)
    }

    private static func specifier(want: DescType, form: Int, key: NSAppleEventDescriptor,
                                  of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(form)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier) ?? record
    }

    private static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
