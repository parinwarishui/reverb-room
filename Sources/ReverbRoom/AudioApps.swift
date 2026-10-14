//
//  AudioApps.swift
//  Finds which apps have audio, so the user can pick which ones get reverb.
//
//  Core Audio reports processes, not apps, and many apps play sound from a helper
//  process: Chrome from "Google Chrome Helper", Safari from a WebKit process that
//  launchd starts on its behalf. Each process is traced back to its app by:
//    1. the process itself being a .app,
//    2. the app macOS holds responsible for it (Safari's WebKit processes),
//    3. walking up its parent processes (Chrome-style helpers).
//

import AppKit
import CoreAudio

struct AudioApp: Equatable {
    let id: String                  // bundle identifier
    var objects: [AudioObjectID] = []
    var playing = false
}

enum AudioApps {
    static let musicID = "com.apple.Music"

    /// Media apps offered as soon as they're running, before they've made a sound.
    static let suggested: [String] = [
        musicID,
        "com.spotify.client",
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",       // Arc
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.apple.TV",
        "com.apple.podcasts",
        "com.tidal.desktop",
        "com.amazon.music",
        "com.colliderli.iina",
        "org.videolan.vlc"
    ]

    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "local.reverbroom.app"
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Every app that owns at least one Core Audio process object, keyed by bundle ID.
    static func scan() -> [String: AudioApp] {
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.pathExtension == "app" {
            appsByPID[app.processIdentifier] = app
        }

        var result: [String: AudioApp] = [:]
        for object in AudioHW.objectList(AudioHW.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = AudioHW.read(object, kAudioProcessPropertyPID, as: pid_t(-1)), pid > 0, pid != ownPID,
                  let app = owner(of: pid, appsByPID: appsByPID),
                  app.processIdentifier != ownPID,
                  let id = app.bundleIdentifier, id != ownBundleID else { continue }
            var entry = result[id] ?? AudioApp(id: id)
            entry.objects.append(object)
            if (AudioHW.read(object, kAudioProcessPropertyIsRunningOutput, as: UInt32(0)) ?? 0) != 0 {
                entry.playing = true
            }
            result[id] = entry
        }
        for id in result.keys { result[id]?.objects.sort() }
        return result
    }

    static func isRunning(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    static func runningIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    static func name(_ id: String) -> String {
        if id == musicID { return "Apple Music" }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(_ id: String) -> NSImage? {
        if let cached = iconCache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[id] = icon
        return icon
    }

    static func open(_ id: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// "Spotify", "Spotify and Apple Music", "Spotify, Chrome and Apple Music", "4 apps".
    static func list(_ ids: [String], conjunction: String = "and") -> String {
        let names = ids.map(name)
        switch names.count {
        case 0: return "no apps"
        case 1: return names[0]
        case 2: return "\(names[0]) \(conjunction) \(names[1])"
        case 3: return "\(names[0]), \(names[1]) \(conjunction) \(names[2])"
        default: return "\(names.count) apps"
        }
    }

    // MARK: Helper process → app

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Private libsystem call Activity Monitor uses to attribute XPC services (like
    /// Safari's WebKit processes) to the app that asked for them. Read-only.
    private static let responsible: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),   // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    private static func owner(of pid: pid_t, appsByPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        if let app = appsByPID[pid] { return app }
        if let responsible {
            let owner = responsible(pid)
            if owner > 0, owner != pid, let app = appsByPID[owner] { return app }
        }
        var current = pid
        for _ in 0..<16 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, parent != current else { return nil }
            if let app = appsByPID[parent] { return app }
            current = parent
        }
        return nil
    }
}
