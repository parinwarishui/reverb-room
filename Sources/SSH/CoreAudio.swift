//
//  CoreAudio.swift
//  Thin helpers over the Core Audio C API, plus the system-audio permission check.
//

import AppKit
import CoreAudio
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ReverbRoom", category: "ReverbRoom")

/// Logs a message with nothing personal in it (states, counts, error codes). It's
/// readable by any process in the unified log, so app and device names go through
/// `dlog(_:private:)` instead.
func dlog(_ message: String) {
    logger.log("[Reverb Room] \(message, privacy: .public)")
}

/// Logs `message` in the clear and `detail` (app names, device names and UIDs)
/// redacted, so the log shows `<private>` in its place.
func dlog(_ message: String, private detail: String) {
    logger.log("[Reverb Room] \(message, privacy: .public) \(detail, privacy: .private)")
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        fallback: T) -> T? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        return err == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let unmanaged = value else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    static func objectIDs(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope).count
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = read(system, kAudioHardwarePropertyDefaultOutputDevice, fallback: unknown),
              id != unknown else { return nil }
        return id
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Float64? {
        guard let rate = read(device, kAudioDevicePropertyNominalSampleRate, fallback: Float64(0)),
              rate > 0 else { return nil }
        return rate
    }

    static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let t = read(device, kAudioDevicePropertyTransportType, fallback: UInt32(0)) ?? 0
        return t == UInt32(kAudioDeviceTransportTypeBluetooth) || t == UInt32(kAudioDeviceTransportTypeBluetoothLE)
    }
}

// MARK: - System audio recording permission (TCC)

/// There's no public API to check/request "System Audio Recording" permission, so
/// this uses the same TCC SPI that AudioCap uses. Fine for a personal/open-source
/// tool, not App Store-safe.
enum AudioCapturePermission {
    enum Status { case authorized, denied, unknown }

    // Exact C signatures: `int TCCAccessPreflight(CFStringRef, CFDictionaryRef)` and
    // `void TCCAccessRequest(CFStringRef, CFDictionaryRef, void (^)(Bool))`.
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFn: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    private static let requestFn: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()

    static func status() -> Status {
        guard let preflightFn else { return .unknown }
        switch preflightFn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Calls back on the main queue with whether we're allowed to capture.
    static func ensure(_ completion: @escaping (Bool) -> Void) {
        switch status() {
        case .authorized:
            completion(true)
        case .denied:
            completion(false)
        case .unknown:
            guard let requestFn else {
                // Can't ask explicitly; macOS prompts on first capture instead.
                // The silence watchdog covers the case where that goes wrong.
                completion(true)
                return
            }
            dlog("Requesting system audio recording permission")
            requestFn(service, nil) { granted in
                dlog("Permission request result: \(granted)")
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
