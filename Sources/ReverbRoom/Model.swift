//
//  Model.swift
//  App state and the on/off lifecycle.
//
//  The user picks any set of apps. While on, a timer checks twice a second which
//  of them are open and have audio, starts or rebuilds one tap covering all of
//  them, and watches the tap's health. All Core Audio setup and teardown happens
//  on one serial queue, off the main thread.
//

import AppKit
import CoreAudio
import Observation
import ReverbDSP

/// One app in the picker.
struct SourceChip: Identifiable, Equatable {
    let id: String
    let name: String
    let selected: Bool
    let running: Bool
    let playing: Bool
}

@MainActor
@Observable
final class Model {
    enum Status: Equatable {
        case off
        case noApps
        case waitingForApps(String)
        case waitingForPlay(String)
        case connecting
        case live(apps: String, device: String)
        case noSignal(apps: String, permission: Bool, atmos: Bool)
        case failed(String)

        var message: String {
            switch self {
            case .off:
                return "Off. Press the power button to add reverb."
            case .noApps:
                return "Pick an app below to add reverb to."
            case .waitingForApps(let apps):
                return "Waiting for \(apps) to open."
            case .waitingForPlay(let apps):
                return "Waiting for \(apps). Press play to start."
            case .connecting:
                return "Connecting to your speakers…"
            case .live(let apps, let device):
                return "Live on \(apps), playing through \(device)."
            case .noSignal(let apps, permission: true, _):
                return "\(apps) is playing but no sound is reaching Reverb Room. Allow it under Privacy & Security › Screen & System Audio Recording."
            case .noSignal(_, permission: false, atmos: true):
                return "This song isn't reaching Reverb Room. It's probably playing in Dolby Atmos: in Music, open Settings › Playback and set Dolby Atmos to Off."
            case .noSignal(let apps, permission: false, atmos: false):
                return "\(apps) is playing but no sound is reaching Reverb Room. Try pausing and playing again."
            case .failed(let reason):
                return "Couldn't start: \(reason)"
            }
        }

        var shortMessage: String {
            switch self {
            case .off: return "Off"
            case .noApps: return "No apps selected"
            case .waitingForApps, .waitingForPlay: return "Waiting for audio"
            case .connecting: return "Connecting…"
            case .live: return "Live"
            case .noSignal: return "No sound reaching Reverb Room"
            case .failed: return "Couldn't start"
            }
        }
    }

    /// The user's own settings: the preset they picked and sliders they moved. Saved.
    var base = ReverbSettings.load() {
        didSet {
            base.save()
            updateEffective()
        }
    }
    /// What's playing: `base`, fine-tuned to the song while adapting.
    private(set) var settings = ReverbSettings.load() {
        didSet { settingsChanged(from: oldValue) }
    }
    /// "Adapt to the song": tune amount, size, pre-delay and tone to what's playing.
    var adaptive = UserDefaults.standard.object(forKey: "adaptive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(adaptive, forKey: "adaptive")
            if !adaptive { tune = AutoTune() }
            updateEffective()
        }
    }
    /// The current offsets from `base`, eased toward what the song suggests.
    private(set) var tune = AutoTune()
    /// What the analyzer hears; nil until it has a few seconds of the song.
    private(set) var song: SongFeatures?
    /// Bundle IDs of the apps that get reverb.
    private(set) var sources: Set<String> = Model.loadSources()
    /// Apps shown in the picker: selected ones, ones that have played sound this
    /// session, and running media apps.
    private(set) var chips: [SourceChip] = []
    private(set) var isOn = false
    private(set) var status: Status = .off
    /// Smoothed input level, 0...1, for the meter.
    private(set) var level: Float = 0

    var selectedPreset: Preset? {
        Preset.allCases.first { $0.settings.matches(base) }
    }

    /// "FOR APPLE MUSIC", "FOR SPOTIFY + APPLE MUSIC", "FOR 3 APPS".
    var headerLabel: String {
        let ids = orderedSources
        switch ids.count {
        case 0: return "PICK AN APP"
        case 1: return "FOR " + AudioApps.name(ids[0]).uppercased()
        case 2: return "FOR " + ids.map { AudioApps.name($0).uppercased() }.joined(separator: " + ")
        default: return "FOR \(ids.count) APPS"
        }
    }

    var musicSelected: Bool { sources.contains(AudioApps.musicID) }

    @ObservationIgnored private var pipeline: AppTapPipeline?
    @ObservationIgnored private var tapped: [AudioObjectID] = []
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var needsRebuild = false
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var scanTimer: Timer?
    @ObservationIgnored private var heardFrom: Set<String> = []
    @ObservationIgnored private var lastSignalCycles: UInt32 = 0
    @ObservationIgnored private var lastSignal = Date()
    @ObservationIgnored private var shapeWork: DispatchWorkItem?
    @ObservationIgnored private let audioQueue = DispatchQueue(label: "ReverbRoom.audio", qos: .userInitiated)
    @ObservationIgnored private let shapeQueue = DispatchQueue(label: "ReverbRoom.shape", qos: .userInitiated)

    init() {
        refreshChips(AudioApps.scan())
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isOn else { return }   // while on, tick() refreshes
                self.refreshChips(AudioApps.scan())
            }
        }
    }

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
        analysisFrames = []
        song = nil
        tune = AutoTune()
        updateEffective()
    }

    func apply(_ preset: Preset) {
        base = preset.settings
    }

    enum Field { case amount, size, preDelay, tone, pitch }

    /// A slider moved. While adapting, the value the user sees includes the song's
    /// offset, so the offset is taken back out to find their new base value.
    func set(_ field: Field, to value: Double) {
        var new = base
        let adapting = adaptive
        switch field {
        case .amount: new.amount = (adapting ? value - tune.amount : value).clamped(to: ReverbSettings.amountRange)
        case .size: new.size = (adapting ? value / tune.size : value).clamped(to: ReverbSettings.sizeRange)
        case .preDelay: new.preDelay = value.clamped(to: ReverbSettings.preDelayRange)
        case .tone: new.tone = (adapting ? value - tune.tone : value).clamped(to: ReverbSettings.toneRange)
        case .pitch: new.pitch = value.clamped(to: ReverbSettings.pitchRange)
        }
        base = new
    }

    /// Whether the song is currently moving this slider away from the user's value.
    func isTuned(_ field: Field) -> Bool {
        guard adaptive else { return false }
        switch field {
        case .amount: return abs(settings.amount - base.amount) >= 0.01
        case .size: return abs(settings.size - base.size) >= 0.1
        case .preDelay: return abs(settings.preDelay - base.preDelay) >= 1
        case .tone: return abs(settings.tone - base.tone) >= 0.01
        case .pitch: return false
        }
    }

    /// One line describing what the analyzer hears.
    var songSummary: String? {
        guard adaptive, isOn else { return nil }
        guard let song else {
            if case .live = status { return "Listening to the song…" }
            return nil
        }
        var parts: [String] = []
        if let bpm = song.tempo { parts.append("≈\(Int(bpm.rounded())) BPM") }
        parts.append(song.onsetRate < 2.5 ? "sparse" : song.onsetRate < 4.5 ? "steady" : "busy")
        if song.crest < 8 { parts.append("loud master") }
        if song.brightness > 0.12 { parts.append("bright mix") } else if song.brightness < 0.04 { parts.append("warm mix") }
        return "Hearing " + parts.joined(separator: ", ")
    }

    private func updateEffective() {
        var effective = base
        if adaptive {
            func snap(_ v: Double, _ step: Double) -> Double { (v / step).rounded() * step }
            effective.amount = snap((base.amount + tune.amount).clamped(to: ReverbSettings.amountRange), 0.01)
            effective.size = snap((base.size * tune.size).clamped(to: ReverbSettings.sizeRange), 0.1)
            effective.tone = snap((base.tone + tune.tone).clamped(to: ReverbSettings.toneRange), 0.01)
            effective.preDelay = snap(tune.syncedPreDelay(near: base.preDelay)
                .clamped(to: ReverbSettings.preDelayRange), 1)
        }
        if effective != settings { settings = effective }
    }

    /// Feeds the last few seconds of the song to the analyzer and eases the offsets
    /// toward its suggestion (about a third of the way per second).
    @ObservationIgnored private var analysisFrames: [AnalysisFrame] = []

    private func adapt() {
        guard let analyzer = pipeline?.analyzer else { return }
        analyzer.drain(into: &analysisFrames)
        let keep = 10 * SongAnalyzer.framesPerSecond
        if analysisFrames.count > keep { analysisFrames.removeFirst(analysisFrames.count - keep) }
        guard adaptive,
              let features = SongFeatures.analyze(analysisFrames.suffix(8 * SongAnalyzer.framesPerSecond)[...]) else { return }
        if features != song { song = features }
        tune.approach(AutoTune.target(for: features), by: 0.18)
        updateEffective()
    }

    /// Selects or deselects an app. Takes effect within half a second while on.
    func toggleSource(_ id: String) {
        if sources.contains(id) { sources.remove(id) } else { sources.insert(id) }
        UserDefaults.standard.set(Array(sources).sorted(), forKey: Self.sourcesKey)
        refreshChips(AudioApps.scan())
        if isOn { tick() }
    }

    /// Stops audio before the app exits, so no app is left muted.
    func shutdown() {
        isOn = false
        tickTimer?.invalidate()
        meterTimer?.invalidate()
        scanTimer?.invalidate()
        generation += 1
        let old = pipeline
        pipeline = nil
        audioQueue.sync { old?.teardown() }
    }

    // MARK: Sources

    private static let sourcesKey = "sources"

    private static func loadSources() -> Set<String> {
        guard let saved = UserDefaults.standard.array(forKey: sourcesKey) as? [String] else {
            return [AudioApps.musicID]
        }
        return Set(saved)
    }

    /// Selected apps in picker order (Apple Music first, then by name).
    private var orderedSources: [String] {
        sources.sorted { a, b in
            if (a == AudioApps.musicID) != (b == AudioApps.musicID) { return a == AudioApps.musicID }
            return AudioApps.name(a).localizedCaseInsensitiveCompare(AudioApps.name(b)) == .orderedAscending
        }
    }

    private func refreshChips(_ apps: [String: AudioApp]) {
        for (id, app) in apps where app.playing { heardFrom.insert(id) }
        let running = AudioApps.runningIDs()
        var ids = sources.union(heardFrom)
        for id in AudioApps.suggested where running.contains(id) || id == AudioApps.musicID {
            ids.insert(id)
        }
        let fresh = ids.map { id in
            SourceChip(id: id, name: AudioApps.name(id), selected: sources.contains(id),
                       running: running.contains(id), playing: apps[id]?.playing ?? false)
        }
        .sorted { a, b in
            if (a.id == AudioApps.musicID) != (b.id == AudioApps.musicID) { return a.id == AudioApps.musicID }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if fresh != chips { chips = fresh }
    }

    // MARK: Lifecycle

    private func tick() {
        guard isOn else { return }
        pipeline?.processor?.collectGarbage()

        let apps = AudioApps.scan()
        refreshChips(apps)

        let selected = orderedSources
        guard !selected.isEmpty else {
            stopPipeline()
            status = .noApps
            return
        }
        let open = selected.filter(AudioApps.isRunning)
        guard !open.isEmpty else {
            stopPipeline()
            status = .waitingForApps(AudioApps.list(selected, conjunction: "or"))
            return
        }
        let objects = selected.flatMap { apps[$0]?.objects ?? [] }.sorted()
        guard !objects.isEmpty else {
            stopPipeline()
            status = .waitingForPlay(AudioApps.list(open, conjunction: "or"))
            return
        }
        guard !starting else { return }
        if let retryAt, Date() < retryAt { return }

        let withAudio = selected.filter { apps[$0] != nil }
        if pipeline == nil || needsRebuild || objects != tapped {
            needsRebuild = false
            startPipeline(objects, apps: AudioApps.list(withAudio))
            return
        }
        let playing = selected.filter { apps[$0]?.playing == true }
        checkHealth(playing: playing, apps: AudioApps.list(withAudio))
        adapt()
    }

    private func startPipeline(_ objects: [AudioObjectID], apps: String) {
        starting = true
        generation += 1
        let token = generation
        let old = pipeline
        pipeline = nil
        if case .live = status {} else { status = .connecting }
        let settings = self.settings

        audioQueue.async { [weak self] in
            old?.teardown()
            let fresh = AppTapPipeline()
            do {
                try fresh.start(processes: objects, settings: settings) {
                    Task { @MainActor in self?.needsRebuild = true }
                }
                Task { @MainActor in
                    self?.started(fresh, objects: objects, apps: apps, settings: settings, token: token)
                }
            } catch {
                fresh.teardown()
                let reason = error.localizedDescription
                diag("Start failed: \(reason)")
                Task { @MainActor in self?.startFailed(reason, token: token) }
            }
        }
    }

    private func started(_ fresh: AppTapPipeline, objects: [AudioObjectID], apps: String,
                         settings used: ReverbSettings, token: Int) {
        guard token == generation, isOn else {
            audioQueue.async { fresh.teardown() }
            return
        }
        starting = false
        pipeline = fresh
        tapped = objects
        retryAt = nil
        lastSignalCycles = 0
        lastSignal = Date()
        status = .live(apps: apps, device: fresh.deviceName)

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

    /// Spots a tap that delivers only silence while a selected app is playing:
    /// the permission is missing, or Music is sending the song down its Dolby
    /// Atmos path, which taps can't hear.
    private func checkHealth(playing: [String], apps: String) {
        guard let pipeline else { return }
        let cycles = pipeline.meter.signalCycles.value
        if cycles != lastSignalCycles || playing.isEmpty {
            lastSignalCycles = cycles
            lastSignal = Date()
            status = .live(apps: apps, device: pipeline.deviceName)
        } else if Date().timeIntervalSince(lastSignal) > 3 {
            status = .noSignal(apps: AudioApps.list(playing),
                               permission: AudioCapturePermission.status() != .authorized,
                               atmos: playing == [AudioApps.musicID])
        }
    }

    private func updateMeter() {
        let peak = pipeline?.meter.peak.value ?? 0
        level = max(min(peak, 1), level * 0.82)
    }

    // MARK: Settings

    private func settingsChanged(from old: ReverbSettings) {
        guard let pipeline else { return }
        push(settings, from: old, to: pipeline)
    }

    private func push(_ new: ReverbSettings, from old: ReverbSettings, to pipeline: AppTapPipeline) {
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
