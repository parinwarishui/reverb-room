//
//  SSHController.swift
//
//  UI-facing state. Mutated only on the main thread. All Core Audio work runs on
//  `work`, a serial background queue, so the UI never freezes.
//

import AppKit
import AVFoundation
import CoreAudio
import Observation
import SwiftUI

enum ReverbPresets {
    static let all: [(name: String, value: AVAudioUnitReverbPreset)] = [
        ("Room", .mediumRoom),
        ("Chamber", .mediumChamber),
        ("Plate", .plate),
        ("Hall", .largeHall),
        ("Cathedral", .cathedral)
    ]
}

/// Apple Music's built-in EQ presets (Music › Window › Equalizer). Apple doesn't
/// expose these through an API; these are the published iTunes/Music values,
/// one gain per band in EqualizerBands order (32 Hz … 16 kHz).
enum EqualizerPresets {
    static let all: [(name: String, gains: [Float])] = [
        ("Flat",           [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Acoustic",       [5, 4.9, 3.95, 1.05, 2.15, 1.75, 3.5, 4.1, 3.55, 2.15]),
        ("Bass Booster",   [5.5, 4.35, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0]),
        ("Bass Reducer",   [-5.5, -4.35, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0]),
        ("Classical",      [4.75, 3.75, 3, 2.5, -1.75, -1.75, 0, 2.25, 3.25, 3.75]),
        ("Dance",          [3.57, 6.55, 4.99, 0, 1.92, 3.65, 5.15, 4.54, 3.59, 0]),
        ("Deep",           [4.95, 3.55, 1.75, 1, 2.85, 2.5, 1.45, -2.15, -3.55, -4.6]),
        ("Electronic",     [4.25, 3.8, 1.2, 0, -2.15, 2.25, 0.85, 1.25, 3.95, 4.8]),
        ("Hip-Hop",        [5, 4.25, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        ("Jazz",           [4, 3, 1.5, 2.25, -1.5, -1.5, 0, 1.5, 3, 3.75]),
        ("Latin",          [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        ("Loudness",       [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        ("Lounge",         [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
        ("Piano",          [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        ("Pop",            [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        ("R&B",            [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65, 3, 3.75]),
        ("Rock",           [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        ("Small Speakers", [5.5, 4.25, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -4.25]),
        ("Spoken Word",    [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0]),
        ("Treble Booster", [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.25, 5.5]),
        ("Treble Reducer", [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.25, -5.5]),
        ("Vocal Booster",  [-1.5, -3, -3, 1.5, 3.75, 3.75, 3, 1.5, 0, -1.5])
    ]
}

@Observable
final class SSHController {
    /// The one app Reverb Room works with.
    static let musicBundleID = "com.apple.Music"
    static let sourceName = "Music"

    enum Phase { case idle, starting, running, stopping }

    private enum Keys {
        static let wet = "wetDryMix"
        static let preset = "reverbPreset"
        static let reverbEnabled = "reverbEnabled"
        static let filterEnabled = "filterEnabled"
        static let highPassCutoff = "highPassCutoff"
        static let lowPassCutoff = "lowPassCutoff"
        static let eqEnabled = "eqEnabled"
        static let eqGains = "eqGains"
    }

    // MARK: State the UI reads

    private(set) var phase: Phase = .idle
    private(set) var outputName = ""
    private(set) var permission: AudioCapturePermission.Status = .unknown
    var errorMessage: String?
    var showPermissionHelp = false

    var wetDryMix: Float = SSHController.savedMix() {
        didSet {
            let value = wetDryMix
            UserDefaults.standard.set(value, forKey: Keys.wet)
            work.async { [weak self] in self?.pipeline?.setWetDryMix(value) }
        }
    }

    var preset: AVAudioUnitReverbPreset = SSHController.savedPreset() {
        didSet {
            let value = preset
            UserDefaults.standard.set(value.rawValue, forKey: Keys.preset)
            work.async { [weak self] in self?.pipeline?.setPreset(value) }
        }
    }

    var reverbEnabled: Bool = SSHController.savedBool(Keys.reverbEnabled, default: true) {
        didSet {
            let value = reverbEnabled
            UserDefaults.standard.set(value, forKey: Keys.reverbEnabled)
            work.async { [weak self] in self?.pipeline?.setReverbEnabled(value) }
        }
    }

    var filterEnabled: Bool = SSHController.savedBool(Keys.filterEnabled, default: false) {
        didSet {
            let value = filterEnabled
            UserDefaults.standard.set(value, forKey: Keys.filterEnabled)
            work.async { [weak self] in self?.pipeline?.setFilterEnabled(value) }
        }
    }
    var highPassCutoff: Float = SSHController.savedFloat(Keys.highPassCutoff, default: 20, in: 20...2000) {
        didSet {
            let value = highPassCutoff
            UserDefaults.standard.set(value, forKey: Keys.highPassCutoff)
            work.async { [weak self] in self?.pipeline?.setHighPassCutoff(value) }
        }
    }
    var lowPassCutoff: Float = SSHController.savedFloat(Keys.lowPassCutoff, default: 20000, in: 200...20000) {
        didSet {
            let value = lowPassCutoff
            UserDefaults.standard.set(value, forKey: Keys.lowPassCutoff)
            work.async { [weak self] in self?.pipeline?.setLowPassCutoff(value) }
        }
    }

    var eqEnabled: Bool = SSHController.savedBool(Keys.eqEnabled, default: false) {
        didSet {
            let value = eqEnabled
            UserDefaults.standard.set(value, forKey: Keys.eqEnabled)
            work.async { [weak self] in self?.pipeline?.setEQEnabled(value) }
        }
    }
    var eqGains: [Float] = SSHController.savedEQGains() {
        didSet {
            let value = eqGains
            UserDefaults.standard.set(value.map { NSNumber(value: $0) }, forKey: Keys.eqGains)
            work.async { [weak self] in self?.pipeline?.setEQGains(value) }
        }
    }

    static let customEQPresetName = "Custom"

    /// The Apple Music preset the current gains match, or "Custom" once any
    /// slider has been moved off it. Derived, not stored, so it can't drift.
    var eqPresetName: String {
        EqualizerPresets.all.first { preset in
            zip(preset.gains, eqGains).allSatisfy { abs($0 - $1) < 0.01 }
        }?.name ?? Self.customEQPresetName
    }

    /// Picking a preset also turns the EQ on, like it does in Music.
    func applyEQPreset(named name: String) {
        guard let preset = EqualizerPresets.all.first(where: { $0.name == name }) else { return }
        eqGains = preset.gains
        eqEnabled = true
    }

    /// A binding to one band's gain, for the EQ's per-band sliders.
    func eqGainBinding(band index: Int) -> Binding<Float> {
        Binding(
            get: { self.eqGains[index] },
            set: { self.eqGains[index] = $0 }
        )
    }

    let meter = Meter()

    // MARK: Internals

    private let work = DispatchQueue(label: "SSH.control", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "SSH.scan", qos: .utility)
    private let listenerQueue = DispatchQueue(label: "SSH.system-listener")
    @ObservationIgnored private var pipeline: TapPipeline?            // work queue only
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var currentOutputID = CA.unknown
    @ObservationIgnored private var tappedObjects = Set<AudioObjectID>()
    @ObservationIgnored private var music: AudioSourceApp?   // latest scan result for Music
    @ObservationIgnored private var restartToken = 0
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    /// Bumped by every start, stop and rebuild. An async completion (permission
    /// answer, finished build) only applies if the generation it began in is still
    /// current; otherwise a newer action owns the state.
    @ObservationIgnored private var generation = 0

    init() {
        refreshPermission()
        refreshMusic()
        startScanning()
        observeDefaultOutputDevice()
        observeServiceRestart()
        observeSourceQuitting()
    }

    /// Only presets the picker offers. Imported Objective-C enums accept any raw
    /// value, so a hand-edited preference could otherwise reach the reverb unit.
    private static func savedPreset() -> AVAudioUnitReverbPreset {
        let raw = UserDefaults.standard.object(forKey: Keys.preset) as? Int
        return ReverbPresets.all.first { $0.value.rawValue == raw }?.value ?? .largeHall
    }

    /// The saved mix, clamped to 0...100. Falls back to 35 if it's missing or not a number.
    private static func savedMix() -> Float {
        guard let number = UserDefaults.standard.object(forKey: Keys.wet) as? NSNumber else { return 35 }
        let value = number.floatValue
        return value.isFinite ? min(max(value, 0), 100) : 35
    }

    private static func savedBool(_ key: String, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    /// A saved float, clamped to `range`. Falls back to `fallback` if it's missing or not a number.
    private static func savedFloat(_ key: String, default fallback: Float, in range: ClosedRange<Float>) -> Float {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return fallback }
        let value = number.floatValue
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    /// One gain per EQ band, clamped to ±12dB. Falls back to all-zero (flat) if
    /// missing or the wrong length (e.g. the band count ever changes).
    private static func savedEQGains() -> [Float] {
        guard let numbers = UserDefaults.standard.array(forKey: Keys.eqGains) as? [NSNumber],
              numbers.count == EqualizerBands.frequencies.count else {
            return [Float](repeating: 0, count: EqualizerBands.frequencies.count)
        }
        return numbers.map { min(max($0.floatValue, -12), 12) }
    }

    // MARK: Public actions

    func refreshPermission() {
        permission = AudioCapturePermission.status()
    }

    func start() {
        guard phase == .idle else { return }
        errorMessage = nil
        showPermissionHelp = false
        phase = .starting
        generation += 1
        let current = generation

        AudioCapturePermission.ensure { [weak self] granted in
            guard let self else { return }
            self.refreshPermission()
            // The user may have turned reverb off while the permission prompt was open.
            guard self.generation == current, self.phase == .starting else { return }
            guard granted else {
                self.phase = .idle
                self.errorMessage = "Reverb Room isn't allowed to capture system audio."
                self.showPermissionHelp = true
                return
            }
            self.buildPipeline()
        }
    }

    func stop() {
        guard phase == .running || phase == .starting else { return }
        phase = .stopping
        generation += 1
        let current = generation
        stopWatchdog()
        // Queued behind any build in flight, so whatever that build creates is torn down here.
        work.async { [weak self] in
            self?.pipeline?.teardown()
            self?.pipeline = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.phase = .idle
            }
        }
    }

    /// Synchronous teardown for app termination — guarantees the source is
    /// un-muted before the process exits.
    func shutdownNow() {
        generation += 1
        stopWatchdog()
        work.sync {
            pipeline?.teardown()
            pipeline = nil
        }
    }

    // MARK: Pipeline lifecycle

    private func rebuild(reason: String) {
        dlog("Rebuilding pipeline: \(reason)")
        stopWatchdog()
        phase = .starting
        generation += 1
        buildPipeline()
    }

    private func buildPipeline() {
        let current = generation
        let settings = EffectsSettings(
            reverbEnabled: reverbEnabled, wetDryMix: wetDryMix, preset: preset,
            filterEnabled: filterEnabled, highPassCutoff: highPassCutoff, lowPassCutoff: lowPassCutoff,
            eqEnabled: eqEnabled, eqGains: eqGains)

        work.async { [weak self] in
            guard let self else { return }
            self.pipeline?.teardown()
            self.pipeline = nil
            // Only now has the old IOProc stopped, so it can't mark this run as having signal.
            self.meter.reset()

            let pipeline = TapPipeline(meter: self.meter) { [weak self] in
                self?.scheduleRestart(onlyIfOutputChanged: false)
            }
            do {
                let processes = try Self.musicProcesses()
                try pipeline.start(processes: processes, settings: settings)
                self.pipeline = pipeline

                let tapped = Set(processes)
                let name = pipeline.outputName
                let outputID = pipeline.outputDeviceID
                DispatchQueue.main.async {
                    // A stop or a newer rebuild came in while this was building. It has
                    // already queued its own teardown or build behind this one.
                    guard self.generation == current else { return }
                    self.outputName = name
                    self.currentOutputID = outputID
                    self.tappedObjects = tapped
                    self.startedAt = Date()
                    self.phase = .running
                    self.startWatchdog()
                }
            } catch {
                pipeline.teardown()
                let code = (error as? PipelineError)?.logCode ?? "error"
                dlog("Start failed: \(code)", private: error.localizedDescription)
                DispatchQueue.main.async {
                    guard self.generation == current else { return }
                    self.phase = .idle
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Music's Core Audio process objects, to tap. Work queue.
    private static func musicProcesses() throws -> [AudioObjectID] {
        guard AudioSources.isRunning(bundleID: musicBundleID) else {
            throw PipelineError.sourceNotRunning(sourceName)
        }
        let objects = AudioSources.scan().first { $0.id == musicBundleID }?.processObjects ?? []
        guard !objects.isEmpty else { throw PipelineError.sourceHasNoAudio(sourceName) }
        return objects
    }

    /// Coalesces bursts of device notifications into one rebuild.
    private func scheduleRestart(onlyIfOutputChanged: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .running else { return }
            self.restartToken += 1
            let token = self.restartToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, token == self.restartToken, self.phase == .running else { return }
                if onlyIfOutputChanged, CA.defaultOutputDevice() == self.currentOutputID { return }
                self.rebuild(reason: "output device changed")
            }
        }
    }

    // MARK: Music process tracking

    private func startScanning() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshMusic()
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    private func refreshMusic() {
        scanQueue.async { [weak self] in
            let found = AudioSources.scan().first { $0.id == Self.musicBundleID }
            DispatchQueue.main.async {
                guard let self else { return }
                self.music = found
                self.followNewProcesses()
            }
        }
    }

    /// Music can start new audio processes at any time. If it grows one we aren't
    /// tapping, rebuild to include it.
    private func followNewProcesses() {
        guard phase == .running, let music else { return }
        if !Set(music.processObjects).isSubset(of: tappedObjects) {
            rebuild(reason: "Music started a new audio process")
        }
    }

    // MARK: System observers

    /// Safe to call again: replaces the previous listener (needed after coreaudiod restarts).
    private func observeDefaultOutputDevice() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        if let old = defaultOutputListener {
            AudioObjectRemovePropertyListenerBlock(CA.system, &addr, listenerQueue, old)
            defaultOutputListener = nil
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(onlyIfOutputChanged: true)
        }
        if AudioObjectAddPropertyListenerBlock(CA.system, &addr, listenerQueue, block) == noErr {
            defaultOutputListener = block
        }
    }

    private func observeServiceRestart() {
        var addr = CA.address(kAudioHardwarePropertyServiceRestarted)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleServiceRestart() }
        }
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, listenerQueue, block)
    }

    /// coreaudiod crashed or was restarted, so every AudioObjectID from before is
    /// gone: the tap, the aggregate, the process objects, the device listeners.
    private func handleServiceRestart() {
        dlog("Core Audio service restarted")
        observeDefaultOutputDevice()
        refreshMusic()
        if phase == .running { rebuild(reason: "Core Audio restarted") }
    }

    private func observeSourceQuitting() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.musicBundleID,
                  self.phase == .running || self.phase == .starting else { return }
            // Another copy of Music is still running: keep going with its processes.
            if self.phase == .running, AudioSources.isRunning(bundleID: Self.musicBundleID) {
                self.rebuild(reason: "one copy of Music quit")
                return
            }
            self.stop()
            self.errorMessage = "\(Self.sourceName) quit, so the effects turned off."
        }
    }

    // MARK: Health check

    /// Runs every 0.5 s while reverb is on. Two checks:
    /// - The engine keeps failing to render (Renderer plays the dry tap meanwhile): stop.
    /// - The source is actively playing but the tap has delivered nothing but zeros
    ///   for a few seconds, which almost always means capture permission is missing:
    ///   stop, so the source isn't left muted, and say why.
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private var sourceIsPlaying: Bool { music?.isPlaying ?? false }

    private func checkHealth() {
        guard phase == .running, let startedAt else { return }
        if meter.renderFailed {
            dlog("Health check: the reverb engine keeps failing to render — stopping")
            stop()
            errorMessage = "The reverb engine stopped working, so Reverb Room turned reverb off. Turn it on again to retry."
            return
        }
        if meter.receivedSignal { return }   // audio is flowing; permission is fine
        guard Date().timeIntervalSince(startedAt) > 3, sourceIsPlaying else { return }
        dlog("Watchdog: source is playing but the tap delivered only silence — stopping")
        stop()
        errorMessage = "\(Self.sourceName) is playing but the tap only delivered silence, which usually means macOS hasn't granted system audio access to this build. Stopped so it isn't left muted."
        showPermissionHelp = true
        refreshPermission()
    }
}
