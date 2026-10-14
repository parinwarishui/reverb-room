//
//  ReverbProcessor.swift
//  Everything after the pitch shifter, in one real-time object:
//
//    in ─┬──────────────────────────────────────────── dry gain ─┐
//        └─ crossfeed ─ de-ess + soften ─ convolution ─ wet gain ─┴─► match ─► wall ─► limiter ─► out
//
//  Audio moves in blocks of B samples, so the output is B samples late (21 ms at
//  48 kHz), plus 5 ms of limiter lookahead. Dry and wet are delayed together,
//  so the pre-delay stays exact.
//
//  Gain staging, so loud masters stay clean:
//  - An equal-power dry/wet mix keeps loudness steady as the amount changes.
//  - The reverb ducks by up to 5 dB under loud passages and blooms back in the
//    gaps (sidechain ducking), so it doesn't pile on top of an already-full mix.
//  - Loudness matching: K-weighted loudness (ITU-R BS.1770, over EBU R128's 3 s
//    short-term window) is measured going in and after the mix, and the mix is
//    slowly corrected to match, so reverb never makes a song louder or quieter.
//    The next-room wall comes after, so it still sounds like it's next door.
//  - A lookahead true-peak limiter holds peaks, including the inter-sample peaks
//    a DAC reconstructs, at -1 dBTP (the streaming target), with a smooth gain
//    curve and program-dependent release, instead of clipping or pumping.
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
    private var send: SendConditioner
    private let conditionSend: Bool

    // Loudness matching (BS.1770 K-weighted, R128 short-term): the mix is nudged so
    // it's as loud as what came in, whatever the reverb amount or room.
    private var inputLoudness: LoudnessMeter
    private var mixLoudness: LoudnessMeter
    private var matchGain: Float = 1
    private var matchTarget: Float = 1
    private let matchSmoothing: Float
    private var matchCounter = 0
    /// Below about -60 LUFS (silence, a fading tail) the correction holds still.
    private static let matchGate: Float = 1.2e-6
    private static let matchRange: ClosedRange<Float> = 0.5...2      // ±6 dB

    // Reverb ducking: follows the dry level and turns the wet down under loud parts.
    private var duckEnvelope: Float = 0
    private let duckAttack: Float
    private let duckRelease: Float
    private static let duckFloor: Float = 0.1         // -20 dBFS: no ducking below this
    private static let duckSpan: Float = 0.6          // full ducking from -3 dBFS up
    private static let duckDepth: Float = 0.45        // ≈ -5 dB at most

    // Impulse-response handoff. `submit` parks a retained response in `pending`; the
    // audio thread adopts it, crossfades over one block and parks the old one in
    // `retired`; `collectGarbage` releases it off the audio thread.
    private let pending = AtomicPointerSlot()
    private let retired = AtomicPointerSlot()
    private var current: UnsafeMutableRawPointer?

    /// `conditionSend: false` turns off the send de-esser and transient softener
    /// (for A/B checks).
    public init(sampleRate: Double, blockSize: Int = 1024, mix: Float, nextRoom: Bool,
                conditionSend: Bool = true) {
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

        limiter = LookaheadLimiter(sampleRate: sampleRate, ceilingDB: -1, lookahead: 0.005)
        send = SendConditioner(sampleRate: sampleRate)
        self.conditionSend = conditionSend
        inputLoudness = LoudnessMeter(sampleRate: sampleRate)
        mixLoudness = LoudnessMeter(sampleRate: sampleRate)
        matchSmoothing = Float(1 - exp(-1 / (1.5 * sampleRate)))
        duckAttack = Float(1 - exp(-1 / (0.01 * sampleRate)))
        duckRelease = Float(1 - exp(-1 / (0.35 * sampleRate)))
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
            var l = (inLeft[i] + Self.crossfeed * inRight[i]) * feedScale
            var r = (inRight[i] + Self.crossfeed * inLeft[i]) * feedScale
            if conditionSend { send.process(&l, &r) }
            feedLeft[i] = l
            feedRight[i] = r
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

            let level = max(abs(inLeft[i]), abs(inRight[i]))
            duckEnvelope += (level - duckEnvelope) * (level > duckEnvelope ? duckAttack : duckRelease)
            let loudness = min(max((duckEnvelope - Self.duckFloor) / Self.duckSpan, 0), 1)
            let wet = wetGain * (1 - Self.duckDepth * loudness)

            var l = inLeft[i] * dryGain + wetLeft[i] * wet
            var r = inRight[i] * dryGain + wetRight[i] * wet

            inputLoudness.process(inLeft[i], inRight[i])
            mixLoudness.process(l, r)
            matchCounter += 1
            if matchCounter == 64 {
                matchCounter = 0
                if inputLoudness.power > Self.matchGate, mixLoudness.power > Self.matchGate {
                    let ratio = (inputLoudness.power / mixLoudness.power).squareRoot()
                    matchTarget = min(max(ratio, Self.matchRange.lowerBound), Self.matchRange.upperBound)
                }
            }
            matchGain += (matchTarget - matchGain) * matchSmoothing
            l *= matchGain
            r *= matchGain

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

/// Stereo-linked lookahead true-peak limiter, built so it never distorts and
/// never pumps on dense, loud masters:
///
/// - Gain computer: the gain each sample needs to keep its true peak (BS.1770,
///   4× oversampled, so inter-sample peaks count too) under the ceiling.
/// - Hold the lowest of those over the lookahead window, then average over the
///   same window. The gain curve is smooth (a linear ramp, no corners), and it
///   reaches the full reduction exactly when the peak leaves the delay line, so
///   peaks are always caught.
/// - Program-dependent release: brief peaks recover in 60 ms; sustained limiting
///   (a loud chorus) recovers over 600 ms, so the level doesn't swell and duck.
final class LookaheadLimiter {
    /// Audio delay, in frames.
    let delay: Int
    private let window: Int
    private let ceiling: Float
    private let fastRelease: Float
    private let slowRelease: Float
    private let reductionSmoothing: Float

    private let required, held: UnsafeMutablePointer<Float>
    private var index = 0
    /// Audio waits `window - 1` frames for the gain plus the detector's own lag.
    private let delayLeft, delayRight: UnsafeMutablePointer<Float>
    private let delaySize: Int
    private var delayIndex = 0
    private let peakLeft = TruePeakDetector()
    private let peakRight = TruePeakDetector()
    private var heldSum: Float
    private var gain: Float = 1
    /// Smoothed amount of gain reduction, 0...1, to pick the release speed.
    private var recentReduction: Float = 0

    init(sampleRate: Double, ceilingDB: Double, lookahead: Double) {
        let size = max(2, Int(lookahead * sampleRate))
        window = size
        delaySize = size + TruePeakDetector.latency
        delay = delaySize - 1
        ceiling = Float(pow(10, ceilingDB / 20))
        fastRelease = Float(1 - exp(-1 / (0.06 * sampleRate)))
        slowRelease = Float(1 - exp(-1 / (0.6 * sampleRate)))
        reductionSmoothing = Float(1 - exp(-1 / (0.3 * sampleRate)))
        func ring(_ value: Float) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: size)
            p.initialize(repeating: value, count: size)
            return p
        }
        required = ring(1); held = ring(1)
        delayLeft = .allocate(capacity: delaySize)
        delayRight = .allocate(capacity: delaySize)
        delayLeft.initialize(repeating: 0, count: delaySize)
        delayRight.initialize(repeating: 0, count: delaySize)
        heldSum = Float(size)
    }

    deinit {
        for p in [delayLeft, delayRight, required, held] { p.deallocate() }
    }

    @inline(__always)
    func process(_ l: inout Float, _ r: inout Float) {
        let peak = max(peakLeft.process(l), peakRight.process(r))
        required[index] = peak > ceiling ? ceiling / peak : 1

        var lowest: Float = 1
        for k in 0..<window { lowest = min(lowest, required[k]) }
        heldSum += lowest - held[index]
        held[index] = lowest
        let smooth = heldSum / Float(window)

        if smooth < gain {
            gain = smooth
        } else {
            let sustained = min(recentReduction * 12, 1)       // ~1 dB of average reduction → slow
            gain += (smooth - gain) * (fastRelease + (slowRelease - fastRelease) * sustained)
        }
        recentReduction += ((1 - gain) - recentReduction) * reductionSmoothing

        delayLeft[delayIndex] = l
        delayRight[delayIndex] = r
        delayIndex += 1
        if delayIndex == delaySize { delayIndex = 0 }
        index += 1
        if index == window {
            index = 0
            // Re-sum now and then so rounding can't drift.
            heldSum = 0
            for k in 0..<window { heldSum += held[k] }
        }
        // The oldest sample in the delay ring, written `delay` samples ago.
        l = min(max(delayLeft[delayIndex] * gain, -1), 1)
        r = min(max(delayRight[delayIndex] * gain, -1), 1)
    }
}

/// Cleans up what goes *into* the reverb, the way a mix engineer treats a reverb
/// send. The dry signal never passes through here.
///
/// - De-esser: when the band above 5 kHz dominates ("s" sounds, hi-hats), that
///   band is turned down by up to 8 dB, so the tail doesn't fill with hiss.
/// - Transient softener: when a fast envelope jumps above a slow one (a drum
///   hit), the send dips by up to 6 dB, so drums stay punchy instead of smearing
///   into the room. Sustained notes still feed the reverb fully.
struct SendConditioner {
    private var highLeft, highRight: Biquad
    private var highEnvelope: Float = 0
    private var fullEnvelope: Float = 0
    private var deessGain: Float = 1
    private var fastEnvelope: Float = 0
    private var slowEnvelope: Float = 0
    private var transientGain: Float = 1

    private let fastAttack, envelopeRelease, slowAttack, slowRelease, fastRelease: Float
    private let gainAttack, gainRelease: Float

    init(sampleRate fs: Double) {
        highLeft = .highpass(cutoff: 5_000, q: 0.707, sampleRate: fs)
        highRight = highLeft
        func coefficient(_ seconds: Double) -> Float { Float(1 - exp(-1 / (seconds * fs))) }
        fastAttack = coefficient(0.0005)
        envelopeRelease = coefficient(0.05)
        fastRelease = coefficient(0.02)
        slowAttack = coefficient(0.02)
        slowRelease = coefficient(0.2)
        gainAttack = coefficient(0.001)
        gainRelease = coefficient(0.04)
    }

    @inline(__always)
    private static func follow(_ envelope: inout Float, _ level: Float, _ attack: Float, _ release: Float) {
        envelope += (level - envelope) * (level > envelope ? attack : release)
    }

    @inline(__always)
    mutating func process(_ l: inout Float, _ r: inout Float) {
        // De-esser: complementary split, so with no reduction the sum is exact.
        let highL = highLeft.process(l), highR = highRight.process(r)
        Self.follow(&highEnvelope, max(abs(highL), abs(highR)), fastAttack, envelopeRelease)
        Self.follow(&fullEnvelope, max(abs(l), abs(r)), fastAttack, envelopeRelease)
        let share = highEnvelope / (fullEnvelope + 1e-6)
        let sibilance = min(max((share - 0.35) / 0.3, 0), 1)
        let deessTarget = 1 - 0.6 * sibilance                       // down to ≈ -8 dB
        deessGain += (deessTarget - deessGain) * (deessTarget < deessGain ? gainAttack : gainRelease)
        l += highL * (deessGain - 1)
        r += highR * (deessGain - 1)

        // Transient softener.
        let level = max(abs(l), abs(r))
        Self.follow(&fastEnvelope, level, fastAttack, fastRelease)
        Self.follow(&slowEnvelope, level, slowAttack, slowRelease)
        let jump = fastEnvelope / (slowEnvelope + 1e-6)
        let transient = min(max((jump - 1.4) / 1.6, 0), 1)
        let transientTarget = 1 - 0.5 * transient                   // down to ≈ -6 dB
        transientGain += (transientTarget - transientGain) * (transientTarget < transientGain ? gainAttack : gainRelease)
        l *= transientGain
        r *= transientGain
    }
}
