//
//  AppTapPipeline.swift
//
//    selected apps ──► one process tap (their own output muted while tapped)
//                      │
//                      ▼
//    private aggregate device   [clock = your output device]
//                      │  IOProc, real-time
//                      ▼
//    queue ─► AVAudioEngine (manual rendering): source ─► pitch shifter
//                      │
//                      ▼
//    ReverbProcessor: convolution reverb, next-room filter, limiter
//                      │
//                      ▼
//    aggregate output ─► your speakers or headphones
//
//  One pipeline per start; teardown() destroys everything, which un-mutes the apps.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import ReverbDSP

enum PipelineError: LocalizedError {
    case noOutputDevice
    case tapFailed(OSStatus)
    case unsupportedFormat
    case aggregateFailed(OSStatus)
    case aggregateNotReady
    case engineFailed(String)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "No speakers or headphones found."
        case .tapFailed(let s): return "Couldn't listen to the app (error \(s))."
        case .unsupportedFormat: return "The app's audio arrived in an unexpected format."
        case .aggregateFailed(let s): return "Couldn't connect to your speakers (error \(s))."
        case .aggregateNotReady: return "Your speakers didn't respond in time."
        case .engineFailed(let detail): return "The pitch shifter failed: \(detail)."
        case .ioProcFailed(let s), .startFailed(let s): return "Couldn't start audio (error \(s))."
        }
    }
}

/// Values the real-time thread reports to the UI.
final class TapMeter {
    let peak = AtomicFloat(0)
    /// IO cycles in which the tap delivered anything but digital silence.
    let signalCycles = AtomicCounter()
    let renderFailures = AtomicCounter()
}

/// Sendable by contract: start() and teardown() run only on the model's serial
/// audio queue, and the rest is either set before start() returns or atomic.
final class AppTapPipeline: @unchecked Sendable {
    private static let maxFrames = 4096

    let meter = TapMeter()
    private(set) var processor: ReverbProcessor?
    private(set) var fifo: StereoFIFO?
    private(set) var deviceName = ""
    private(set) var sampleRate: Double = 0

    private var tapID = AudioHW.unknown
    private var aggregateID = AudioHW.unknown
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var pitch: AVAudioUnitTimePitch?
    private let ioQueue = DispatchQueue(label: "ReverbRoom.io", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "ReverbRoom.listeners")
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                             block: AudioObjectPropertyListenerBlock)] = []

    deinit { teardown() }

    /// Builds and starts everything. The apps are only muted by the final step, so
    /// if anything throws they keep playing normally. Call teardown() after a throw.
    func start(processes: [AudioObjectID], settings: ReverbSettings,
               onDeviceChange: @escaping () -> Void) throws {
        guard let output = AudioHW.defaultOutputDevice(),
              let outputUID = AudioHW.string(output, kAudioDevicePropertyDeviceUID) else {
            throw PipelineError.noOutputDevice
        }
        deviceName = AudioHW.string(output, kAudioObjectPropertyName) ?? "your speakers"
        let bluetooth = AudioHW.isBluetooth(output)

        // 1. Tap the apps. Their normal output goes silent once we start reading the tap.
        let tap = CATapDescription(stereoMixdownOfProcesses: processes)
        tap.uuid = UUID()
        tap.name = "Reverb Room"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        var newTap = AudioHW.unknown
        let tapStatus = AudioHardwareCreateProcessTap(tap, &newTap)
        guard tapStatus == noErr, newTap != AudioHW.unknown else { throw PipelineError.tapFailed(tapStatus) }
        tapID = newTap

        if let format = AudioHW.read(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription()) {
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw PipelineError.unsupportedFormat }
        }

        // 2. A private aggregate device: the output device (which sets the clock)
        // plus the tap as an input. Drift compensation stays off for Bluetooth,
        // where tap and output already share a clock and resampling crackles.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Reverb Room",
            kAudioAggregateDeviceUIDKey: "ReverbRoom-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: false]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: !bluetooth]
            ]
        ]
        var newAggregate = AudioHW.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard aggregateStatus == noErr, newAggregate != AudioHW.unknown else {
            throw PipelineError.aggregateFailed(aggregateStatus)
        }
        aggregateID = newAggregate

        let deadline = Date().addingTimeInterval(2)
        while AudioHW.streamCount(aggregateID, kAudioObjectPropertyScopeOutput) == 0 {
            guard Date() < deadline else { throw PipelineError.aggregateNotReady }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let inputStreams = AudioHW.streamCount(aggregateID, kAudioObjectPropertyScopeInput)
        guard inputStreams > 0 else { throw PipelineError.aggregateNotReady }
        sampleRate = AudioHW.sampleRate(aggregateID) ?? AudioHW.sampleRate(output) ?? 48_000
        diag("Aggregate ready: \(inputStreams) input stream(s), \(Int(sampleRate)) Hz, bluetooth=\(bluetooth)")

        // 3. Reverb, with the first impulse response loaded before audio starts.
        let processor = ReverbProcessor(sampleRate: sampleRate, mix: Float(settings.amount),
                                        nextRoom: settings.nextRoom)
        processor.submit(processor.makeSpectra(settings.shape))
        self.processor = processor

        // 4. Pitch shifter.
        let context = try buildEngine(settings: settings, processor: processor)

        // 5. The real-time callback.
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { _, input, _, output, _ in
            context.process(input, output)
        }
        guard procStatus == noErr, let newProc else { throw PipelineError.ioProcFailed(procStatus) }
        procID = newProc
        useOnlyTapStream(inputStreams: inputStreams, procID: newProc)

        // 6. Go. From here on the apps are muted and we're the ones playing them.
        let startStatus = AudioDeviceStart(aggregateID, newProc)
        guard startStatus == noErr else { throw PipelineError.startFailed(startStatus) }

        watch(output, onChange: onDeviceChange)
        diag("Pipeline running")
    }

    /// Semitones; 0 bypasses the shifter so it adds no artifacts.
    func setPitch(_ semitones: Double) {
        pitch?.pitch = Float(semitones * 100)
        pitch?.bypass = abs(semitones) < 0.05
    }

    /// Builds a new impulse response and hands it to the audio thread. Slow; call
    /// it off the main thread.
    func loadShape(_ shape: ReverbShape) {
        guard let processor else { return }
        processor.submit(processor.makeSpectra(shape))
    }

    /// Idempotent. Stopping the IOProc and destroying the tap un-mutes the apps.
    func teardown() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, listenerQueue, listener.block)
        }
        listeners.removeAll()
        if let procID, aggregateID != AudioHW.unknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioHW.unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioHW.unknown
        }
        if tapID != AudioHW.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioHW.unknown
        }
        engine?.stop()
        engine = nil
        pitch = nil
    }

    // MARK: Engine

    private func buildEngine(settings: ReverbSettings, processor: ReverbProcessor) throws -> IOContext {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw PipelineError.engineFailed("no stereo format at \(sampleRate) Hz")
        }
        let engine = AVAudioEngine()
        do {
            try engine.enableManualRenderingMode(.realtime, format: format,
                                                 maximumFrameCount: AVAudioFrameCount(Self.maxFrames))
        } catch {
            throw PipelineError.engineFailed(error.localizedDescription)
        }

        // The pitch shifter pulls input in its own chunk sizes; this cushion covers it.
        let fifo = StereoFIFO(capacity: 32_768, prefill: 2_048)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            fifo.pop(left, right, frames: Int(frameCount))
            return noErr
        }

        // More overlapping analysis windows than the default 8: smoother, less
        // "phasey" pitch shifting for a little more CPU.
        let pitch = AVAudioUnitTimePitch()
        pitch.overlap = 16
        pitch.pitch = Float(settings.pitch * 100)
        pitch.bypass = abs(settings.pitch) < 0.05

        engine.attach(source)
        engine.attach(pitch)
        engine.connect(source, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw PipelineError.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.pitch = pitch
        self.fifo = fifo
        return IOContext(engine: engine, maxFrames: Self.maxFrames, fifo: fifo, processor: processor, meter: meter)
    }

    // MARK: Device

    /// Turns on only the tap's input stream (the last one). Leaving the output
    /// device's own inputs off keeps AirPods out of their low-quality headset mode
    /// and avoids a microphone prompt.
    private func useOnlyTapStream(inputStreams: Int, procID: AudioDeviceIOProcID) {
        guard inputStreams > 1 else { return }
        // struct AudioHardwareIOProcStreamUsage { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let pointerSize = MemoryLayout<UnsafeMutableRawPointer>.size
        let size = pointerSize + MemoryLayout<UInt32>.size * (1 + inputStreams)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputStreams), toByteOffset: pointerSize, as: UInt32.self)
        for i in 0..<inputStreams {
            let on: UInt32 = i == inputStreams - 1 ? 1 : 0
            raw.storeBytes(of: on, toByteOffset: pointerSize + MemoryLayout<UInt32>.size * (1 + i), as: UInt32.self)
        }
        var addr = AudioHW.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(size), raw)
        diag(status == noErr ? "Turned off \(inputStreams - 1) device input stream(s)"
                             : "Couldn't turn off device inputs (\(status))")
    }

    /// Calls `onChange` when the pipeline has to be rebuilt: the default output
    /// changes, the device switches sample rate (Bluetooth does) or disappears.
    private func watch(_ device: AudioObjectID, onChange: @escaping () -> Void) {
        let builtRate = sampleRate
        listen(AudioHW.system, kAudioHardwarePropertyDefaultOutputDevice) {
            if AudioHW.defaultOutputDevice() != device {
                diag("Default output changed")
                onChange()
            }
        }
        listen(device, kAudioDevicePropertyNominalSampleRate) {
            if let rate = AudioHW.sampleRate(device), rate != builtRate {
                diag("Output sample rate changed to \(Int(rate)) Hz")
                onChange()
            }
        }
        listen(device, kAudioDevicePropertyDeviceIsAlive) {
            if !AudioHW.isAlive(device) {
                diag("Output device went away")
                onChange()
            }
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ handler: @escaping () -> Void) {
        var addr = AudioHW.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, block) == noErr {
            listeners.append((object, addr, block))
        }
    }
}

// MARK: - Real-time callback

/// Everything the IOProc touches. Holds no reference back to the pipeline.
private final class IOContext {
    private let render: AVAudioEngineManualRenderingBlock
    private let renderBuffer: AVAudioPCMBuffer      // owns the memory below
    private let renderList: UnsafeMutablePointer<AudioBufferList>
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let maxFrames: Int
    private let fifo: StereoFIFO
    private let processor: ReverbProcessor
    private let meter: TapMeter

    init(engine: AVAudioEngine, maxFrames: Int, fifo: StereoFIFO, processor: ReverbProcessor, meter: TapMeter) {
        render = engine.manualRenderingBlock
        renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                        frameCapacity: AVAudioFrameCount(maxFrames))!
        renderList = renderBuffer.mutableAudioBufferList
        left = renderBuffer.floatChannelData![0]
        right = renderBuffer.floatChannelData![1]
        self.maxFrames = maxFrames
        self.fifo = fifo
        self.processor = processor
        self.meter = meter
    }

    /// Where one output channel lives inside the device's buffers.
    private struct Channel {
        let base: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    /// Finds output channel `index` whether channels are interleaved in one buffer
    /// or split across several.
    private static func channel(_ index: Int, in buffers: UnsafeMutableAudioBufferListPointer) -> Channel? {
        var remaining = index
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData else { return nil }
                return Channel(base: data.assumingMemoryBound(to: Float.self) + remaining,
                               stride: channels,
                               frames: Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            }
            remaining -= channels
        }
        return nil
    }

    /// Real-time: no locks, no allocation, no logging.
    func process(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // The tap is the last input stream; any before it are the device's own inputs.
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if let tap = ins.last, let data = tap.mData, tap.mNumberChannels > 0 {
            let channels = Int(tap.mNumberChannels)
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            var peak: Float = 0
            for i in 0..<(frames * channels) { peak = max(peak, abs(samples[i])) }
            meter.peak.value = peak
            if peak > 0 { meter.signalCycles.increment() }
            fifo.push(interleaved: samples, channels: channels, frames: frames)
        }

        guard let outLeft = Self.channel(0, in: outs) else { return }
        let outRight = Self.channel(1, in: outs)
        let frames = min(outLeft.frames, outRight?.frames ?? outLeft.frames)
        let rendered = UnsafeMutableAudioBufferListPointer(renderList)

        var done = 0
        while done < frames {
            let n = min(frames - done, maxFrames)
            let bytes = UInt32(n * MemoryLayout<Float>.size)
            if rendered.count >= 2 {
                rendered[0].mData = UnsafeMutableRawPointer(left)
                rendered[0].mDataByteSize = bytes
                rendered[1].mData = UnsafeMutableRawPointer(right)
                rendered[1].mDataByteSize = bytes
            }
            var error: OSStatus = noErr
            let status = render(AVAudioFrameCount(n), renderList, &error)
            if status == .success, rendered.count >= 2,
               let l = rendered[0].mData?.assumingMemoryBound(to: Float.self),
               let r = rendered[1].mData?.assumingMemoryBound(to: Float.self) {
                if l != left { left.update(from: l, count: n) }
                if r != right { right.update(from: r, count: n) }
            } else {
                // The apps are muted, so never go silent: skip the pitch shifter instead.
                meter.renderFailures.increment()
                fifo.pop(left, right, frames: n)
            }

            processor.process(left: left, right: right, frames: n)

            for f in 0..<n {
                let o = done + f
                if let outRight {
                    outLeft.base[o * outLeft.stride] = left[f]
                    outRight.base[o * outRight.stride] = right[f]
                } else {
                    outLeft.base[o * outLeft.stride] = (left[f] + right[f]) * 0.5
                }
            }
            done += n
        }
    }
}
