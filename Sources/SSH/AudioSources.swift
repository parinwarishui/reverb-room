//
//  AudioSources.swift
//  Finds the Core Audio processes that belong to an app (used for Music).
//
//  Core Audio reports *processes*, not apps, and an app may play sound from a helper
//  process. Each audio process is mapped back to the app that owns it (same approach
//  as FineTune):
//    1. the process is itself a .app            → that app
//    2. macOS's "responsible process" is a .app → that app (Safari/WebKit case)
//    3. walk up the parent processes            → first .app (Chrome-style helpers)
//

import AppKit
import CoreAudio

struct AudioSourceApp {
    let id: String                       // bundle identifier, unique in a scan
    let processObjects: [AudioObjectID]
    let isPlaying: Bool
}

enum AudioSources {
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Every app that currently has at least one Core Audio process object, grouped
    /// by bundle ID, so several running copies of one app (e.g. `open -n`) become one
    /// entry and are tapped together.
    static func scan() -> [AudioSourceApp] {
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appsByPID[app.processIdentifier] = app
        }

        var groups: [String: (app: NSRunningApplication, objects: [AudioObjectID], playing: Bool)] = [:]
        for object in CA.objectIDs(CA.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CA.read(object, kAudioProcessPropertyPID, fallback: pid_t(-1)),
                  pid > 0, pid != ownPID,
                  let app = owningApp(for: pid, appsByPID: appsByPID),
                  app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier else { continue }

            let playing = (CA.read(object, kAudioProcessPropertyIsRunningOutput, fallback: UInt32(0)) ?? 0) != 0
            var entry = groups[bundleID] ?? (app: app, objects: [], playing: false)
            entry.objects.append(object)
            entry.playing = entry.playing || playing
            groups[bundleID] = entry
        }

        return groups.map { bundleID, entry in
            AudioSourceApp(id: bundleID, processObjects: entry.objects.sorted(), isPlaying: entry.playing)
        }
    }

    static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    // MARK: Helper-process → app mapping

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t

    /// Private libsystem function Activity Monitor uses to attribute XPC services
    /// (e.g. Safari's WebKit processes) to the app that launched them.
    private static let responsibilityFn: ResponsibilityFn? = {
        // RTLD_DEFAULT is ((void *)-2) on Darwin.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    private static func owningApp(for pid: pid_t,
                                  appsByPID: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        func appBundle(_ candidate: pid_t) -> NSRunningApplication? {
            guard let app = appsByPID[candidate], app.bundleURL?.pathExtension == "app" else { return nil }
            return app
        }

        if let app = appBundle(pid) { return app }

        if let responsibilityFn {
            let responsible = responsibilityFn(pid)
            if responsible > 0, responsible != pid, let app = appBundle(responsible) { return app }
        }

        var current = pid
        var visited = Set<pid_t>()
        while current > 1, !visited.contains(current) {
            visited.insert(current)
            if let app = appBundle(current) { return app }

            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { break }
            let parent = info.kp_eproc.e_ppid
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
