//
//  ReverbProcessor.swift
//  Everything after the pitch shifter, in one real-time object:
//
//    in ─┬───────────────────────────── dry gain ─┐
//        └─ crossfeed ─ convolution ─── wet gain ─┴─► next-room wall ─► limiter ─► out
//
//  Audio moves in blocks of B samples, so the output is B samples late (21 ms at
//  48 kHz), plus 1.5 ms of limiter lookahead. Dry and wet are delayed together,
//  so the pre-delay stays exact.
//
//  Gain staging: an equal-power dry/wet mix keeps loudness steady as the amount
//  changes, and a lookahead limiter holds peaks at -1 dBFS (the streaming true-peak
//  target) by turning the gain down smoothly just before a peak, not by clipping it.
//
//  Control methods (setMix, setNextRoom, submit, collectGarbage) are safe from any
//  thread. process() is real-time safe: no locks, no allocation, and nothing
//  shared is freed on the audio thread.
//

import Foundation

public final class ReverbProcessor {
    public let sampleRate: Double
    public let blockSize: Int
    public let maxPartitions: Int

    private let convolver: StereoConvolver
    private let inLeft, inRight, outLeft, outRight: UnsafeMutablePointer<Float>
    private let feedLeft, feedRight: UnsafeMutablePointer<Float>
    private let wetLeft, wetRight, nextLeft, nextRight: UnsafeMutablePointer<Float>
    private var position = 0

    private let mixTarget: AtomicFloat
    private let nextRoomTarget: AtomicFloat
    private var dryGain: Float
    private var wetGain: Float
    private var muffle: Float

    /// Share of each side's input sent to the opposite side's reverb. Real rooms
    /// are "true stereo": a guitar panned left still excites the whole room.
    private static let crossfeed: Float = 0.4

    private static let wallStages = 4
    private let wallLeft: UnsafeMutablePointer<Biquad>
    private let wallRight: UnsafeMutablePointer<Biquad>
    /// Bass and low mids come through a wall, so a lowpassed signal sounds quieter
    /// than it measures. This makes up the difference.
    private static let wallMakeup: Float = 1.35

    private let limiter: LookaheadLimiter

    // Impulse-response handoff. `submit` parks a retained response in `pending`; the
    // audio thread adopts it, crossfades over one block and parks the old one in
    // `retired`; `collectGarbage` releases it off the audio thread.
    private let pending = AtomicPointerSlot()
    private let retired = AtomicPointerSlot()
    private var current: UnsafeMutableRawPointer?

    public init(sampleRate: Double, blockSize: Int = 1024, mix: Float, nextRoom: Bool) {
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        let longest = (ImpulseResponse.maxDecay + ImpulseResponse.maxPreDelay) * sampleRate
        maxPartitions = Int((longest / Double(blockSize)).rounded(.up)) + 1
        convolver = StereoConvolver(blockSize: blockSize, maxPartitions: maxPartitions)

        func buffer() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
            p.initialize(repeating: 0, count: blockSize)
            return p
        }
        inLeft = buffer(); inRight = buffer(); outLeft = buffer(); outRight = buffer()
        feedLeft = buffer(); feedRight = buffer()
        wetLeft = buffer(); wetRight = buffer(); nextLeft = buffer(); nextRight = buffer()

        let amount = min(max(mix, 0), 1)
        mixTarget = AtomicFloat(amount)
        dryGain = Self.dry(amount)
        wetGain = Self.wet(amount)
        nextRoomTarget = AtomicFloat(nextRoom ? 1 : 0)
        muffle = nextRoom ? 1 : 0

        // Through a wall: the wall passes bass, resonates a little in the low end,
        // and blocks almost everything above a few hundred hertz (24 dB/octave).
        // The sub-bass is trimmed so it thumps instead of booms.
        let wall: [Biquad] = [
            .highpass(cutoff: 35, q: 0.707, sampleRate: sampleRate),
            .peaking(frequency: 110, q: 0.9, gain: 3, sampleRate: sampleRate),
            .lowpass(cutoff: 380, q: 0.54, sampleRate: sampleRate),
            .lowpass(cutoff: 380, q: 1.31, sampleRate: sampleRate)
        ]
        wallLeft = .allocate(capacity: Self.wallStages)
        wallRight = .allocate(capacity: Self.wallStages)
        wallLeft.initialize(from: wall, count: Self.wallStages)
        wallRight.initialize(from: wall, count: Self.wallStages)

        limiter = LookaheadLimiter(sampleRate: sampleRate, ceilingDB: -1, lookahead: 0.0015, release: 0.15)
    }

    deinit {
        for slot in [pending, retired] {
            if let raw = slot.exchange(nil) { Unmanaged<IRSpectra>.fromOpaque(raw).release() }
        }
        if let current { Unmanaged<IRSpectra>.fromOpaque(current).release() }
        for p in [inLeft, inRight, outLeft, outRight, feedLeft, feedRight,
                  wetLeft, wetRight, nextLeft, nextRight] {
            p.deallocate()
        }
        wallLeft.deallocate()
        wallRight.deallocate()
    }

    // MARK: Control (any thread)

    /// Output delay added by the processor, in frames.
    public var latency: Int { blockSize + limiter.delay }

    /// 0 = dry only, 1 = reverb only.
    public func setMix(_ amount: Float) { mixTarget.value = min(max(amount, 0), 1) }

    public func setNextRoom(_ on: Bool) { nextRoomTarget.value = on ? 1 : 0 }

    /// Builds a response for this processor's sample rate and block size. Slow
    /// (tens of milliseconds for a long room): call it off the main thread.
    public func makeSpectra(_ shape: ReverbShape) -> IRSpectra {
        let ir = ImpulseResponse.make(shape, sampleRate: sampleRate)
        return IRSpectra(left: ir.left, right: ir.right, blockSize: blockSize, maxPartitions: maxPartitions)
    }

    /// Hands a response to the audio thread, which switches to it within one block.
    public func submit(_ spectra: IRSpectra) {
        precondition(spectra.blockSize == blockSize, "response built for another block size")
        let raw = Unmanaged.passRetained(spectra).toOpaque()
        if let stale = pending.exchange(raw) {
            Unmanaged<IRSpectra>.fromOpaque(stale).release()
        }
    }

    /// Frees the response the audio thread has finished with. Call it now and then.
    public func collectGarbage() {
        if let old = retired.exchange(nil) {
            Unmanaged<IRSpectra>.fromOpaque(old).release()
        }
    }

    // MARK: Real-time

    /// Processes `frames` samples per channel in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            let n = min(frames - done, blockSize - position)
            (inLeft + position).update(from: left + done, count: n)
            (inRight + position).update(from: right + done, count: n)
            (left + done).update(from: outLeft + position, count: n)
            (right + done).update(from: outRight + position, count: n)
            position += n
            done += n
            if position == blockSize {
                processBlock()
                position = 0
            }
        }
    }

    @inline(__always)
    private func spectra(_ raw: UnsafeMutableRawPointer) -> IRSpectra {
        Unmanaged<IRSpectra>.fromOpaque(raw).takeUnretainedValue()
    }

    private func processBlock() {
        let B = blockSize

        // True-stereo send, scaled so a centred signal reaches the reverb at unity.
        let feedScale = 1 / (1 + Self.crossfeed)
        for i in 0..<B {
            feedLeft[i] = (inLeft[i] + Self.crossfeed * inRight[i]) * feedScale
            feedRight[i] = (inRight[i] + Self.crossfeed * inLeft[i]) * feedScale
        }
        convolver.push(feedLeft, feedRight)

        if let current {
            convolver.render(spectra(current), wetLeft, wetRight)
        } else {
            wetLeft.update(repeating: 0, count: B)
            wetRight.update(repeating: 0, count: B)
        }

        // Adopt a new response only once the previous retired one has been collected,
        // so the audio thread never has to free anything.
        if retired.isEmpty, let next = pending.exchange(nil) {
            convolver.render(spectra(next), nextLeft, nextRight)
            if current == nil {
                wetLeft.update(from: nextLeft, count: B)
                wetRight.update(from: nextRight, count: B)
            } else {
                // Equal-power crossfade: the two tails are uncorrelated noise.
                let step = Float.pi / 2 / Float(B)
                for i in 0..<B {
                    let t = Float(i + 1) * step
                    wetLeft[i] = wetLeft[i] * cos(t) + nextLeft[i] * sin(t)
                    wetRight[i] = wetRight[i] * cos(t) + nextRight[i] * sin(t)
                }
            }
            if let old = current { _ = retired.exchange(old) }
            current = next
        }

        // Ramp gains across the block so slider moves don't click.
        let amount = mixTarget.value
        let dryStep = (Self.dry(amount) - dryGain) / Float(B)
        let wetStep = (Self.wet(amount) - wetGain) / Float(B)
        let muffleStep = (nextRoomTarget.value - muffle) / Float(B)

        for i in 0..<B {
            dryGain += dryStep
            wetGain += wetStep
            muffle += muffleStep

            var l = inLeft[i] * dryGain + wetLeft[i] * wetGain
            var r = inRight[i] * dryGain + wetRight[i] * wetGain

            var wallL = l, wallR = r
            for f in 0..<Self.wallStages {
                wallL = wallLeft[f].process(wallL)
                wallR = wallRight[f].process(wallR)
            }
            l += (wallL * Self.wallMakeup - l) * muffle
            r += (wallR * Self.wallMakeup - r) * muffle

            if !l.isFinite || !r.isFinite {
                // Never pass NaN or infinity on, and don't let it stick in filter state.
                l = 0; r = 0
                for f in 0..<Self.wallStages { wallLeft[f].reset(); wallRight[f].reset() }
            }
            limiter.process(&l, &r)
            outLeft[i] = l
            outRight[i] = r
        }
    }

    // Equal-power mix: 0 → all dry, 0.5 → both at -3 dB, 1 → all wet.
    private static func dry(_ amount: Float) -> Float { cos(amount * .pi / 2) }
    private static func wet(_ amount: Float) -> Float { sin(amount * .pi / 2) }
}

/// Stereo-linked lookahead peak limiter. Each sample is delayed by `delay` frames
/// while the gain glides down to what the loudest upcoming sample needs, so peaks
/// are caught without the distortion of an instant gain change. A final hard clip
/// at full scale is only a safety net.
final class LookaheadLimiter {
    let delay: Int
    private let ceiling: Float
    private let attack: Float
    private let release: Float
    private var gain: Float = 1

    private let delayLeft, delayRight, required: UnsafeMutablePointer<Float>
    private var index = 0

    init(sampleRate: Double, ceilingDB: Double, lookahead: Double, release releaseTime: Double) {
        delay = max(1, Int(lookahead * sampleRate))
        ceiling = Float(pow(10, ceilingDB / 20))
        // Reaches 99% of the needed reduction within the lookahead window.
        attack = Float(1 - exp(-5 / Double(delay)))
        release = Float(1 - exp(-1 / (releaseTime * sampleRate)))
        delayLeft = .allocate(capacity: delay)
        delayRight = .allocate(capacity: delay)
        required = .allocate(capacity: delay)
        delayLeft.initialize(repeating: 0, count: delay)
        delayRight.initialize(repeating: 0, count: delay)
        required.initialize(repeating: 1, count: delay)
    }

    deinit {
        delayLeft.deallocate()
        delayRight.deallocate()
        required.deallocate()
    }

    @inline(__always)
    func process(_ l: inout Float, _ r: inout Float) {
        let peak = max(abs(l), abs(r))
        required[index] = peak > ceiling ? ceiling / peak : 1

        var target: Float = 1
        for k in 0..<delay { target = min(target, required[k]) }
        gain += (target - gain) * (target < gain ? attack : release)

        let outL = delayLeft[index] * gain
        let outR = delayRight[index] * gain
        delayLeft[index] = l
        delayRight[index] = r
        index += 1
        if index == delay { index = 0 }

        l = min(max(outL, -1), 1)
        r = min(max(outR, -1), 1)
    }
}
