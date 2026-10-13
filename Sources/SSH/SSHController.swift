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

enum ReverbPresets {
    static let all: [(name: String, value: AVAudioUnitReverbPreset)] = [
        ("Room", .mediumRoom),
        ("Chamber", .mediumChamber),
        ("Plate", .plate),
        ("Hall", .largeHall),
        ("Cathedral", .cathedral)
    ]
}

@Observable
final class SSHController {
    static let everythingID = "__everything__"

    enum Phase { case idle, starting, running, stopping }

    private enum Keys {
        static let source = "selectedSource"
        static let wet = "wetDryMix"
        static let preset = "reverbPreset"
    }

    // MARK: State the UI reads

    private(set) var phase: Phase = .idle
    private(set) var outputName = ""
    private(set) var permission: AudioCapturePermission.Status = .unknown
    private(set) var sources: [AudioSourceApp] = []
    var errorMessage: String?
    var showPermissionHelp = false

    /// Bundle ID of the app to reverb, or `everythingID`. Remembered across launches.
    var selectedSourceID: String = UserDefaults.standard.string(forKey: Keys.source) ?? "com.apple.Music" {
        didSet {
            guard selectedSourceID != oldValue else { return }
            UserDefaults.standard.set(selectedSourceID, forKey: Keys.source)
            errorMessage = nil
            showPermissionHelp = false
            // While starting, the build in flight notices the change when it finishes.
            if phase == .running { rebuild(reason: "source changed") }
        }
    }

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

    let meter = Meter()

    var isEverythingSelected: Bool { selectedSourceID == Self.everythingID }

    var selectedSourceName: String {
        isEverythingSelected ? "Everything" : AudioSources.displayName(forBundleID: selectedSourceID)
    }

    // MARK: Internals

    private let work = DispatchQueue(label: "SSH.control", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "SSH.scan", qos: .utility)
    private let listenerQueue = DispatchQueue(label: "SSH.system-listener")
    @ObservationIgnored private var pipeline: TapPipeline?            // work queue only
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var currentOutputID = CA.unknown
    @ObservationIgnored private var tappedObjects = Set<AudioObjectID>()
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
        refreshSources()
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

    // MARK: Public actions

    func refreshPermission() {
        permission = AudioCapturePermission.status()
    }

    func toggle() {
        switch phase {
        case .idle: start()
        case .starting, .running: stop()
        case .stopping: break
        }
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
                self.errorMessage = "SSH isn't allowed to capture system audio."
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
        let wet = wetDryMix
        let preset = self.preset
        let sourceID = selectedSourceID

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
                let spec = try Self.resolveSpec(for: sourceID)
                try pipeline.start(spec: spec, wetDryMix: wet, preset: preset)
                self.pipeline = pipeline

                var tapped = Set<AudioObjectID>()
                if case .processes(let objects) = spec { tapped = Set(objects) }
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
                    if self.selectedSourceID != sourceID {
                        self.rebuild(reason: "source changed while starting")
                    }
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

    /// Turns the selection into concrete Core Audio process objects. Work queue.
    private static func resolveSpec(for sourceID: String) throws -> TapSpec {
        if sourceID == everythingID {
            guard let own = AudioSources.ownProcessObject() else { throw PipelineError.cannotExcludeSelf }
            return .everythingExcept([own])
        }
        let name = AudioSources.displayName(forBundleID: sourceID)
        guard AudioSources.isRunning(bundleID: sourceID) else { throw PipelineError.sourceNotRunning(name) }
        let objects = AudioSources.scan().first { $0.id == sourceID }?.processObjects ?? []
        guard !objects.isEmpty else { throw PipelineError.sourceHasNoAudio(name) }
        return .processes(objects)
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

    // MARK: Source list

    private func startScanning() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshSources()
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    private func refreshSources() {
        scanQueue.async { [weak self] in
            let found = AudioSources.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                if found != self.sources { self.sources = found }
                self.followNewProcesses(in: found)
            }
        }
    }

    /// Apps like Chrome start new helper processes for audio at any time. If the
    /// tapped app grows a process we aren't tapping, rebuild to include it.
    private func followNewProcesses(in found: [AudioSourceApp]) {
        guard phase == .running, !isEverythingSelected,
              let target = found.first(where: { $0.id == selectedSourceID }) else { return }
        if !Set(target.processObjects).isSubset(of: tappedObjects) {
            rebuild(reason: "selected app started a new audio process")
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
        refreshSources()
        if phase == .running { rebuild(reason: "Core Audio restarted") }
    }

    private func observeSourceQuitting() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  !self.isEverythingSelected,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == self.selectedSourceID,
                  self.phase == .running || self.phase == .starting else { return }
            // Another copy of the app is still running: keep going with its processes.
            if self.phase == .running, AudioSources.isRunning(bundleID: self.selectedSourceID) {
                self.rebuild(reason: "one copy of the selected app quit")
                return
            }
            self.stop()
            self.errorMessage = "\(app.localizedName ?? "The app") quit, so reverb turned off."
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

    private var sourceIsPlaying: Bool {
        if isEverythingSelected { return sources.contains { $0.isPlaying } }
        return sources.first { $0.id == selectedSourceID }?.isPlaying ?? false
    }

    private func checkHealth() {
        guard phase == .running, let startedAt else { return }
        if meter.renderFailed {
            dlog("Health check: the reverb engine keeps failing to render — stopping")
            stop()
            errorMessage = "The reverb engine stopped working, so SSH turned reverb off. Turn it on again to retry."
            return
        }
        if meter.receivedSignal { return }   // audio is flowing; permission is fine
        guard Date().timeIntervalSince(startedAt) > 3, sourceIsPlaying else { return }
        dlog("Watchdog: source is playing but the tap delivered only silence — stopping")
        stop()
        errorMessage = "\(selectedSourceName) is playing but the tap only delivered silence, which usually means macOS hasn't granted system audio access to this build. Stopped so it isn't left muted."
        showPermissionHelp = true
        refreshPermission()
    }
}
