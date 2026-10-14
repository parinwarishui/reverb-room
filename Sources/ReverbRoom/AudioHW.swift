//
//  AudioHW.swift
//  Thin helpers over the Core Audio object API, the system-audio permission
//  check, and logging.
//

import AppKit
import CoreAudio
import os

private let logger = Logger(subsystem: "local.reverbroom.app", category: "Reverb Room diag")

/// Logs states, counts and error codes only. Device and app names stay out of
/// the unified log, which any process can read.
func diag(_ message: String) {
    logger.log("[ReverbRoom] \(message, privacy: .public)")
}

enum AudioHW {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as initial: T) -> T? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        objectList(device, kAudioDevicePropertyStreams, scope: scope).count
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = read(system, kAudioHardwarePropertyDefaultOutputDevice, as: unknown), id != unknown else {
            return nil
        }
        return id
    }

    static func sampleRate(_ device: AudioObjectID) -> Double? {
        guard let rate = read(device, kAudioDevicePropertyNominalSampleRate, as: Float64(0)), rate > 0 else {
            return nil
        }
        return rate
    }

    static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let transport = read(device, kAudioDevicePropertyTransportType, as: UInt32(0)) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (read(device, kAudioDevicePropertyDeviceIsAlive, as: UInt32(0)) ?? 0) != 0
    }
}

// MARK: - System audio recording permission

/// macOS has no public call to check the "System Audio Recording" permission.
/// This asks TCC directly (read-only), only to pick the right message when the
/// tap goes quiet. It isn't App Store-safe, which is fine for a personal app.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

    private static let preflight: Preflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Preflight.self)
    }()

    static func status() -> Status {
        guard let preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
