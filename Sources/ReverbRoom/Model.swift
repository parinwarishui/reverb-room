//
//  Model.swift
//  App state and the on/off lifecycle.
//
//  While on, a timer checks twice a second whether Music is open and has audio,
//  starts or rebuilds the pipeline as needed, and watches the tap's health. All
//  Core Audio setup and teardown happens on one serial queue, off the main thread.
//

import AppKit
import CoreAudio
import Observation
import ReverbDSP

@MainActor
@Observable
final class Model {
    enum Status: Equatable {
        case off
        case waitingForMusic
        case waitingForPlay
        case connecting
        case live(device: String)
        case noSignal(permission: Bool)
        case failed(String)

        var message: String {
            switch self {
            case .off:
                return "Off. Press the power button to add reverb to Apple Music."
            case .waitingForMusic:
                return "Waiting for the Music app to open."
            case .waitingForPlay:
                return "Waiting for Music. Press play to start."
            case .connecting:
                return "Connecting to your speakers…"
            case .live(let device):
                return "Live on Apple Music, playing through \(device)."
            case .noSignal(permission: true):
                return "Music is playing but no sound is reaching Reverb Room. Allow it under Privacy & Security › Screen & System Audio Recording."
            case .noSignal(permission: false):
                return "This song isn't reaching Reverb Room. It's probably playing in Dolby Atmos: in Music, open Settings › Playback and set Dolby Atmos to Off."
            case .failed(let reason):
                return "Couldn't start: \(reason)"
            }
        }

        var shortMessage: String {
            switch self {
            case .off: return "Off"
            case .waitingForMusic, .waitingForPlay: return "Waiting for Music"
            case .connecting: return "Connecting…"
            case .live: return "Live on Apple Music"
            case .noSignal: return "Song not reaching Reverb Room"
            case .failed: return "Couldn't start"
            }
        }
    }

    var settings = ReverbSettings.load() {
        didSet { settingsChanged(from: oldValue) }
    }
    private(set) var isOn = false
    private(set) var status: Status = .off
    /// Smoothed input level, 0...1, for the meter.
    private(set) var level: Float = 0

    var selectedPreset: Preset? {
        Preset.allCases.first { $0.settings.matches(settings) }
    }

    @ObservationIgnored private var pipeline: MusicTapPipeline?
    @ObservationIgnored private var tapped: [AudioObjectID] = []
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var needsRebuild = false
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var lastSignalCycles: UInt32 = 0
    @ObservationIgnored private var lastSignal = Date()
    @ObservationIgnored private var lastUnderflows: UInt32 = 0
    @ObservationIgnored private var shapeWork: DispatchWorkItem?
    @ObservationIgnored private let audioQueue = DispatchQueue(label: "ReverbRoom.audio", qos: .userInitiated)
    @ObservationIgnored private let shapeQueue = DispatchQueue(label: "ReverbRoom.shape", qos: .userInitiated)

    // MARK: Actions

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard !isOn else { return }
        isOn = true
        retryAt = nil
        status = .connecting
        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeter() }
        }
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        tickTimer?.invalidate()
        meterTimer?.invalidate()
        tickTimer = nil
        meterTimer = nil
        stopPipeline()
        level = 0
        status = .off
    }

    func apply(_ preset: Preset) {
        settings = preset.settings
    }

    /// Stops audio before the app exits, so Music is never left muted.
    func shutdown() {
        isOn = false
        tickTimer?.invalidate()
        meterTimer?.invalidate()
        generation += 1
        let old = pipeline
        pipeline = nil
        audioQueue.sync { old?.teardown() }
    }

    // MARK: Lifecycle

    private func tick() {
        guard isOn else { return }
        pipeline?.processor?.collectGarbage()

        guard MusicApp.isRunning else {
            stopPipeline()
            status = .waitingForMusic
            return
        }
        let music = MusicApp.processes()
        guard !music.objects.isEmpty else {
            stopPipeline()
            status = .waitingForPlay
            return
        }
        guard !starting else { return }
        if let retryAt, Date() < retryAt { return }

        if pipeline == nil || needsRebuild || music.objects != tapped {
            needsRebuild = false
            startPipeline(music.objects)
            return
        }
        checkHealth(playing: music.playing)
    }

    private func startPipeline(_ processes: [AudioObjectID]) {
        starting = true
        generation += 1
        let token = generation
        let old = pipeline
        pipeline = nil
        if case .live = status {} else { status = .connecting }
        let settings = self.settings

        audioQueue.async { [weak self] in
            old?.teardown()
            let fresh = MusicTapPipeline()
            do {
                try fresh.start(processes: processes, settings: settings) {
                    Task { @MainActor in self?.needsRebuild = true }
                }
                Task { @MainActor in self?.started(fresh, processes: processes, settings: settings, token: token) }
            } catch {
                fresh.teardown()
                let reason = error.localizedDescription
                diag("Start failed: \(reason)")
                Task { @MainActor in self?.startFailed(reason, token: token) }
            }
        }
    }

    private func started(_ fresh: MusicTapPipeline, processes: [AudioObjectID],
                         settings used: ReverbSettings, token: Int) {
        guard token == generation, isOn else {
            audioQueue.async { fresh.teardown() }
            return
        }
        starting = false
        pipeline = fresh
        tapped = processes
        retryAt = nil
        lastSignalCycles = 0
        lastSignal = Date()
        lastUnderflows = 0
        status = .live(device: fresh.deviceName)

        // Catch up with anything the user changed while it was starting.
        if settings != used { push(settings, from: used, to: fresh) }
    }

    private func startFailed(_ reason: String, token: Int) {
        guard token == generation else { return }
        starting = false
        tapped = []
        retryAt = Date().addingTimeInterval(3)
        status = .failed(reason)
    }

    private func stopPipeline() {
        generation += 1
        starting = false
        tapped = []
        guard let old = pipeline else { return }
        pipeline = nil
        audioQueue.async { old.teardown() }
    }

    /// Spots a tap that delivers only silence while Music is playing: either the
    /// permission is missing or Music is sending the song down its Dolby Atmos path.
    private func checkHealth(playing: Bool) {
        guard let pipeline else { return }
        let cycles = pipeline.meter.signalCycles.value
        if cycles != lastSignalCycles || !playing {
            lastSignalCycles = cycles
            lastSignal = Date()
            if case .noSignal = status { status = .live(device: pipeline.deviceName) }
        } else if Date().timeIntervalSince(lastSignal) > 3 {
            status = .noSignal(permission: AudioCapturePermission.status() != .authorized)
        }

        if let fifo = pipeline.fifo {
            let underflows = fifo.underflows.value
            if underflows != lastUnderflows {
                diag("pitch pulls ran dry \(underflows - lastUnderflows) time(s)")
                lastUnderflows = underflows
            }
        }
    }

    private func updateMeter() {
        let peak = pipeline?.meter.peak.value ?? 0
        level = max(min(peak, 1), level * 0.82)
    }

    // MARK: Settings

    private func settingsChanged(from old: ReverbSettings) {
        settings.save()
        guard let pipeline else { return }
        push(settings, from: old, to: pipeline)
    }

    private func push(_ new: ReverbSettings, from old: ReverbSettings, to pipeline: MusicTapPipeline) {
        if new.amount != old.amount { pipeline.processor?.setMix(Float(new.amount)) }
        if new.nextRoom != old.nextRoom { pipeline.processor?.setNextRoom(new.nextRoom) }
        if new.pitch != old.pitch { pipeline.setPitch(new.pitch) }
        if new.shape != old.shape {
            // Coalesce slider drags: only the latest shape gets built.
            shapeWork?.cancel()
            let shape = new.shape
            let work = DispatchWorkItem { pipeline.loadShape(shape) }
            shapeWork = work
            shapeQueue.asyncAfter(deadline: .now() + 0.04, execute: work)
        }
    }
}
