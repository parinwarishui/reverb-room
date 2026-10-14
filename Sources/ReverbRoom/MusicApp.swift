//
//  MusicApp.swift
//  Finds the Apple Music app's audio processes.
//

import AppKit
import CoreAudio

enum MusicApp {
    static let bundleID = "com.apple.Music"

    struct Processes: Equatable {
        /// Every Core Audio process object that belongs to Music, sorted.
        var objects: [AudioObjectID] = []
        /// Whether any of them is producing sound right now.
        var playing = false
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Music's process objects: the app itself plus any helper that carries its
    /// bundle ID prefix. A process only gets an object once it has opened audio.
    static func processes() -> Processes {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        var result = Processes()
        for object in AudioHW.objectList(AudioHW.system, kAudioHardwarePropertyProcessObjectList) {
            let pid = AudioHW.read(object, kAudioProcessPropertyPID, as: pid_t(-1)) ?? -1
            let bundle = AudioHW.string(object, kAudioProcessPropertyBundleID) ?? ""
            guard pids.contains(pid) || bundle == bundleID || bundle.hasPrefix(bundleID + ".") else { continue }
            result.objects.append(object)
            if (AudioHW.read(object, kAudioProcessPropertyIsRunningOutput, as: UInt32(0)) ?? 0) != 0 {
                result.playing = true
            }
        }
        result.objects.sort()
        return result
    }
}
