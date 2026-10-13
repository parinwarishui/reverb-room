//
//  AudioPipeline.swift
//
//  Signal flow (one clock, one real-time callback — same shape as FineTune/Mimir):
//
//    chosen app(s) ──► process tap (their direct output muted while tapped)
//                        │
//                        ▼
//    private aggregate device  [clock = your real output device, e.g. AirPods]
//                        │  IOProc (real-time)
//                        ▼
//    AVAudioEngine in manual rendering mode: source ─► reverb ─► peak limiter ─► mixer
//                        │
//                        ▼
//    aggregate output stream ─► your speakers / AirPods
//

import AVFoundation
import AudioToolbox
import CoreAudio
import SSHAtomics

/// What to tap.
enum TapSpec {
    /// Only these process objects (one app and its helpers).
    case processes([AudioObjectID])
    /// Everything on the system except these process objects (always includes us).
    case everythingExcept([AudioObjectID])
}

// MARK: - Real-time shared state

/// Input level, a "have we ever seen non-zero audio" flag and a "rendering keeps
/// failing" flag. Written by the real-time thread, read by the UI and the health
/// check. Backed by C11 relaxed atomics (SSHAtomics): no locks, no torn values.
final class Meter {
    private let state: OpaquePointer

    init() {
        guard let state = ssh_meter_create() else { fatalError("Couldn't allocate the level meter") }
        self.state = state
    }
    deinit { ssh_meter_destroy(state) }

    var peak: Float { ssh_meter_peak(state) }
    var receivedSignal: Bool { ssh_meter_received_signal(state) }
    var renderFailed: Bool { ssh_meter_render_failed(state) }

    func reset() { ssh_meter_reset(state) }

    @inline(__always) func update(cyclePeak: Float) { ssh_meter_update(state, cyclePeak) }
    @inline(__always) func markRenderFailure() { ssh_meter_mark_render_failure(state) }
}

/// Points the engine's source node at the current IO cycle's tap samples.
/// Touched only on the real-time thread.
final class SourceContext {
    var samples: UnsafeMutablePointer<Float>?
    var channels = 2
    var frames = 0
}

/// Everything the IOProc needs, captured strongly by the IO block. Holds no
/// reference back to the pipeline, so there's no retain cycle.
final class Renderer {
    private let renderBlock: AVAudioEngineManualRenderingBlock
    private let renderBuffer: AVAudioPCMBuffer   // keeps the channel memory alive
    private let renderABL: UnsafeMutablePointer<AudioBufferList>
    private let channelData: UnsafePointer<UnsafeMutablePointer<Float>>
    private let channelCount: Int
    private let maxFrames: Int
    private let source: SourceContext
    private let meter: Meter

    init?(engine: AVAudioEngine, format: AVAudioFormat, maxFrames: Int, source: SourceContext, meter: Meter) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames)),
              let channels = buffer.floatChannelData else { return nil }
        self.renderBlock = engine.manualRenderingBlock
        self.renderBuffer = buffer
        self.renderABL = buffer.mutableAudioBufferList
        self.channelData = channels
        self.channelCount = Int(format.channelCount)
        self.maxFrames = maxFrames
        self.source = source
        self.meter = meter
    }

    /// Consecutive failed render calls before the health check is told to stop
    /// (about a second at 512-frame cycles).
    private static let failureLimit = 100
    private var renderFailures = 0       // real-time thread only

    /// Where one output channel lives: its first sample and the distance between frames.
    private struct ChannelSlot {
        let base: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    /// Finds output channel `index`, counting channels across the buffers in order.
    /// Works for one interleaved buffer (L R L R) and for one buffer per channel.
    @inline(__always)
    private static func slot(_ buffers: UnsafeMutableAudioBufferListPointer, channel index: Int) -> ChannelSlot? {
        var remaining = index
        for i in 0..<buffers.count {
            let channels = Int(buffers[i].mNumberChannels)
            if remaining < channels {
                guard let raw = buffers[i].mData else { return nil }
                let frames = Int(buffers[i].mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return ChannelSlot(base: raw.assumingMemoryBound(to: Float.self) + remaining,
                                   stride: channels, frames: frames)
            }
            remaining -= channels
        }
        return nil
    }

    /// Hard clip to full scale (and drop NaN), so nothing louder than 0 dBFS
    /// ever reaches the device.
    @inline(__always)
    private static func safe(_ sample: Float) -> Float {
        sample.isNaN ? 0 : min(max(sample, -1), 1)
    }

    @inline(__always)
    private static func write(_ l: Float, _ r: Float, frame: Int, left: ChannelSlot, right: ChannelSlot?) {
        if let right {
            left.base[frame * left.stride] = safe(l)
            right.base[frame * right.stride] = safe(r)
        } else {
            left.base[frame * left.stride] = safe((l + r) * 0.5)   // mono output: downmix
        }
    }

    /// Real-time: no allocation, no locks, no logging, no Objective-C.
    func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard ins.count > 0, outs.count > 0 else { return }

        // The tap's stream is the last input buffer; any earlier ones belong to the
        // output device's own inputs (e.g. the AirPods mic) and are ignored.
        let tap = ins[ins.count - 1]
        guard let tapRaw = tap.mData else { return }
        let tapChannels = max(Int(tap.mNumberChannels), 1)
        let tapSamples = tapRaw.assumingMemoryBound(to: Float.self)
        let inFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * tapChannels)

        // Output channels 0 and 1 may share one interleaved buffer or sit in separate
        // buffers (common on USB interfaces). Anything past channel 1 stays silent.
        guard let left = Self.slot(outs, channel: 0) else { return }
        let right = Self.slot(outs, channel: 1)          // nil on a mono output
        let outFrames = min(left.frames, right?.frames ?? left.frames)

        let frames = min(inFrames, outFrames)

        var peak: Float = 0
        for i in 0..<(inFrames * tapChannels) {
            let a = abs(tapSamples[i])
            if a > peak { peak = a }
        }
        meter.update(cyclePeak: peak)

        let rendered = UnsafeMutableAudioBufferListPointer(renderABL)
        var done = 0
        while done < frames {
            let n = min(frames - done, maxFrames)

            source.samples = tapSamples + done * tapChannels
            source.channels = tapChannels
            source.frames = n

            // Re-point at our own buffers each time in case the engine swapped them.
            for i in 0..<min(rendered.count, channelCount) {
                rendered[i].mData = UnsafeMutableRawPointer(channelData[i])
                rendered[i].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
            }

            var err: OSStatus = noErr
            let status = renderBlock(AVAudioFrameCount(n), renderABL, &err)

            if status == .success, rendered.count >= 2,
               let wetL = rendered[0].mData?.assumingMemoryBound(to: Float.self),
               let wetR = rendered[1].mData?.assumingMemoryBound(to: Float.self) {
                renderFailures = 0
                for f in 0..<n {
                    Self.write(wetL[f], wetR[f], frame: done + f, left: left, right: right)
                }
            } else {
                // The source is muted while tapped, so silence here would mean the user
                // hears nothing. Play the dry tap instead, and if this keeps happening,
                // flag it so the health check turns reverb off.
                renderFailures += 1
                if renderFailures >= Self.failureLimit { meter.markRenderFailure() }
                for f in 0..<n {
                    let s = tapSamples + (done + f) * tapChannels
                    Self.write(s[0], tapChannels > 1 ? s[1] : s[0], frame: done + f, left: left, right: right)
                }
            }
            done += n
        }
        source.samples = nil
    }
}

// MARK: - Errors

enum PipelineError: LocalizedError {
    case sourceNotRunning(String)
    case sourceHasNoAudio(String)
    case cannotExcludeSelf
    case noOutputDevice
    case tapFailed(OSStatus)
    case unsupportedTapFormat(String)
    case aggregateFailed(OSStatus)
    case aggregateNotReady
    case tapMissingFromAggregate
    case engineFailed(String)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sourceNotRunning(let name): return "Open \(name) first."
        case .sourceHasNoAudio(let name): return "Press play in \(name), then turn reverb on. (An app only becomes tappable after it has produced some audio.)"
        case .cannotExcludeSelf: return "Couldn't identify SSH's own audio process, so a system-wide tap would feed back into itself. Pick a specific app instead."
        case .noOutputDevice: return "No output device found."
        case .tapFailed(let s): return "Couldn't create the audio tap (OSStatus \(s))."
        case .unsupportedTapFormat(let d): return "Unexpected tap audio format: \(d)"
        case .aggregateFailed(let s): return "Couldn't create the aggregate device (OSStatus \(s))."
        case .aggregateNotReady: return "Aggregate device never became ready."
        case .tapMissingFromAggregate: return "The tap didn't attach to the aggregate device."
        case .engineFailed(let d): return "Audio engine failed: \(d)"
        case .ioProcFailed(let s): return "Couldn't install the audio callback (OSStatus \(s))."
        case .startFailed(let s): return "Couldn't start audio I/O (OSStatus \(s))."
        }
    }

    /// The error without app names, for the public part of the log.
    var logCode: String {
        switch self {
        case .sourceNotRunning: return "sourceNotRunning"
        case .sourceHasNoAudio: return "sourceHasNoAudio"
        case .cannotExcludeSelf: return "cannotExcludeSelf"
        case .noOutputDevice: return "noOutputDevice"
        case .tapFailed(let s): return "tapFailed(\(s))"
        case .unsupportedTapFormat(let d): return "unsupportedTapFormat(\(d))"
        case .aggregateFailed(let s): return "aggregateFailed(\(s))"
        case .aggregateNotReady: return "aggregateNotReady"
        case .tapMissingFromAggregate: return "tapMissingFromAggregate"
        case .engineFailed(let d): return "engineFailed(\(d))"
        case .ioProcFailed(let s): return "ioProcFailed(\(s))"
        case .startFailed(let s): return "startFailed(\(s))"
        }
    }
}

// MARK: - Pipeline (one per Start; torn down completely on Stop)

/// Touch only from the controller's work queue (except the IO block, which uses Renderer).
final class TapPipeline {
    private static let maxFrames = 4096

    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var renderer: Renderer?
    private let reverb = AVAudioUnitReverb()
    private let meter: Meter
    private let ioQueue = DispatchQueue(label: "SSH.io", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "SSH.listener")
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                             block: AudioObjectPropertyListenerBlock)] = []
    private let onDeviceChange: () -> Void

    private(set) var outputDeviceID = CA.unknown
    private(set) var outputName = ""
    private(set) var sampleRate: Float64 = 0

    /// `onDeviceChange` fires (on a listener queue) when the output device changes
    /// sample rate or disappears. Either way the pipeline needs rebuilding.
    init(meter: Meter, onDeviceChange: @escaping () -> Void) {
        self.meter = meter
        self.onDeviceChange = onDeviceChange
    }

    deinit { teardown() }

    func setWetDryMix(_ value: Float) { reverb.wetDryMix = value }
    /// Runs on the work queue while the IO thread renders. Setting an Audio Unit
    /// property from outside the render thread is the standard host pattern (the AU
    /// synchronizes internally); AVAudioUnitReverb has no real-time-safe alternative.
    func setPreset(_ preset: AVAudioUnitReverbPreset) { reverb.loadFactoryPreset(preset) }

    /// Builds everything. The source is only muted at the very last step
    /// (AudioDeviceStart), so any earlier failure leaves it playing normally.
    /// Caller must call teardown() if this throws.
    func start(spec: TapSpec, wetDryMix: Float, preset: AVAudioUnitReverbPreset) throws {
        guard let output = CA.defaultOutputDevice(),
              let outputUID = CA.string(output, kAudioDevicePropertyDeviceUID) else {
            throw PipelineError.noOutputDevice
        }
        outputDeviceID = output
        outputName = CA.string(output, kAudioObjectPropertyName) ?? "Output"
        let bluetooth = CA.isBluetooth(output)
        dlog("Output (bluetooth=\(bluetooth)):", private: "\(outputName) [\(outputUID)]")

        // 1. Process tap. Muting only kicks in once the tap is actually being read.
        let tapDescription: CATapDescription
        switch spec {
        case .processes(let objects):
            dlog("Tapping process objects \(objects)")
            tapDescription = CATapDescription(stereoMixdownOfProcesses: objects)
        case .everythingExcept(let excluded):
            dlog("Tapping everything except \(excluded)")
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        }
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        var newTap = CA.unknown
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard tapErr == noErr, newTap != CA.unknown else { throw PipelineError.tapFailed(tapErr) }
        tapID = newTap

        if let asbd = CA.read(tapID, kAudioTapPropertyFormat, fallback: AudioStreamBasicDescription()) {
            let desc = "\(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags)"
            dlog("Tap format: \(desc)")
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            guard asbd.mFormatID == kAudioFormatLinearPCM, isFloat, asbd.mBitsPerChannel == 32 else {
                throw PipelineError.unsupportedTapFormat(desc)
            }
        }

        // 2. Aggregate device: real output device as clock + the tap as input.
        // Drift compensation OFF for Bluetooth — tap and output share the BT clock,
        // and turning it on causes periodic crackle (per FineTune's findings).
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SSH",
            kAudioAggregateDeviceUIDKey: "SSH-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: !bluetooth
                ]
            ]
        ]
        var newAggregate = CA.unknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard aggErr == noErr, newAggregate != CA.unknown else { throw PipelineError.aggregateFailed(aggErr) }
        aggregateID = newAggregate

        guard waitUntilReady(aggregateID, timeout: 2.0) else { throw PipelineError.aggregateNotReady }
        let inputStreams = CA.streamCount(aggregateID, kAudioObjectPropertyScopeInput)
        let outputStreams = CA.streamCount(aggregateID, kAudioObjectPropertyScopeOutput)
        dlog("Aggregate ready: \(inputStreams) input stream(s), \(outputStreams) output stream(s)")
        guard inputStreams >= 1 else { throw PipelineError.tapMissingFromAggregate }

        sampleRate = CA.nominalSampleRate(aggregateID) ?? CA.nominalSampleRate(output) ?? 48_000
        dlog("Running at \(sampleRate) Hz")

        // 3. Reverb engine in manual rendering mode — never touches hardware itself,
        // and we never access engine.inputNode, so it can't open a microphone.
        try buildEngine(wetDryMix: wetDryMix, preset: preset)

        // 4. IOProc on the aggregate.
        guard let renderer else { throw PipelineError.engineFailed("renderer missing") }
        var newProc: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { _, inInputData, _, outOutputData, _ in
            renderer.process(inInputData, outOutputData)
        }
        guard procErr == noErr, let createdProc = newProc else { throw PipelineError.ioProcFailed(procErr) }
        procID = createdProc

        // Don't power on the output device's own inputs (AirPods mic would force
        // the low-quality hands-free Bluetooth profile and a mic permission prompt).
        disableHardwareInputStreams(inputCount: inputStreams, procID: createdProc)

        // 5. Go. From here the source's direct output is muted and we own playback.
        let startErr = AudioDeviceStart(aggregateID, createdProc)
        guard startErr == noErr else { throw PipelineError.startFailed(startErr) }

        installDeviceListeners()
        dlog("Pipeline running")
    }

    private func buildEngine(wetDryMix: Float, preset: AVAudioUnitReverbPreset) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw PipelineError.engineFailed("couldn't create format")
        }
        let engine = AVAudioEngine()
        do {
            // Must happen before touching mainMixerNode/outputNode.
            try engine.enableManualRenderingMode(.realtime, format: format,
                                                 maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        } catch {
            throw PipelineError.engineFailed("manual rendering: \(error.localizedDescription)")
        }

        let source = SourceContext()
        let sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList -> OSStatus in
            let outs = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard let src = source.samples, outs.count >= 2,
                  let left = outs[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = outs[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in outs {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                isSilence.pointee = true
                return noErr
            }
            let ch = source.channels
            let available = min(n, source.frames)
            for f in 0..<available {
                left[f] = src[f * ch]
                right[f] = ch > 1 ? src[f * ch + 1] : src[f * ch]
            }
            if available < n {
                for f in available..<n {
                    left[f] = 0
                    right[f] = 0
                }
            }
            isSilence.pointee = false
            return noErr
        }

        // Catches peaks before the hard clip in Renderer, so loud passages (or a
        // feedback loop with another loopback app) are held near full scale instead
        // of distorting.
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0))

        engine.attach(sourceNode)
        engine.attach(reverb)
        engine.attach(limiter)
        reverb.loadFactoryPreset(preset)
        reverb.wetDryMix = wetDryMix

        engine.connect(sourceNode, to: reverb, format: format)
        engine.connect(reverb, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PipelineError.engineFailed("start: \(error.localizedDescription)")
        }

        guard let renderer = Renderer(engine: engine, format: format, maxFrames: Self.maxFrames,
                                      source: source, meter: meter) else {
            engine.stop()
            throw PipelineError.engineFailed("couldn't allocate render buffer")
        }
        self.engine = engine
        self.renderer = renderer
    }

    /// Idempotent. Stopping the IOProc is what un-mutes the source.
    func teardown() {
        removeListeners()
        if let procID, aggregateID != CA.unknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != CA.unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = CA.unknown
        }
        if tapID != CA.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = CA.unknown
        }
        engine?.stop()
        engine = nil
        renderer = nil
    }

    // MARK: Helpers

    private func waitUntilReady(_ device: AudioObjectID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CA.streamCount(device, kAudioObjectPropertyScopeOutput) > 0 { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Marks only the trailing (tap) input stream as used. Same technique as FineTune.
    private func disableHardwareInputStreams(inputCount: Int, procID: AudioDeviceIOProcID) {
        guard inputCount > 1 else { return }

        // AudioHardwareIOProcStreamUsage: { void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize,
                                                   alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        let flags = raw.advanced(by: headerSize)
        for i in 0..<inputCount {
            let isOn: UInt32 = (i == inputCount - 1) ? 1 : 0
            flags.advanced(by: i * MemoryLayout<UInt32>.size).storeBytes(of: isOn, as: UInt32.self)
        }

        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let err = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(totalSize), raw)
        dlog(err == noErr
             ? "Disabled \(inputCount - 1) hardware input stream(s)"
             : "Couldn't disable hardware input streams (\(err)) — a mic prompt may appear")
    }

    private func installDeviceListeners() {
        guard outputDeviceID != CA.unknown else { return }
        let builtRate = sampleRate
        let device = outputDeviceID
        let callback = onDeviceChange

        // Bluetooth devices can change rate mid-session (A2DP <-> hands-free).
        addListener(device, kAudioDevicePropertyNominalSampleRate) {
            if let rate = CA.nominalSampleRate(device), rate != builtRate {
                dlog("Output sample rate changed \(builtRate) -> \(rate)")
                callback()
            }
        }
        // The device went away (unplugged, AirPods disconnected). The aggregate is
        // dead even if the device comes back later with the same ID.
        addListener(device, kAudioDevicePropertyDeviceIsAlive) {
            let alive = CA.read(device, kAudioDevicePropertyDeviceIsAlive, fallback: UInt32(0)) ?? 0
            if alive == 0 {
                dlog("Output device is no longer available")
                callback()
            }
        }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ handler: @escaping () -> Void) {
        var addr = CA.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, block) == noErr {
            listeners.append((object: object, address: addr, block: block))
        }
    }

    private func removeListeners() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, listenerQueue, listener.block)
        }
        listeners.removeAll()
    }
}
