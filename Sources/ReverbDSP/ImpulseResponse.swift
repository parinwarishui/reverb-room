//
//  ImpulseResponse.swift
//  Builds a stereo room impulse response from three numbers.
//
//  - Early reflections: two dozen echoes off nearby walls, growing denser over
//    time, softened by the walls, and louder in small rooms.
//  - A diffuse tail: independent noise per ear (so the reverb is wide), shaped by
//    an exponential decay that reaches -60 dB after `decay` seconds and a short
//    build-up at the start.
//  - Air and wall absorption: a two-pole lowpass whose cutoff falls over time, so
//    highs die away sooner than lows. `tone` sets how bright it starts and how
//    slowly it darkens.
//  - Return EQ: highpass at 120 Hz, a cut at 300 Hz (mud) and 3.2 kHz (harshness),
//    then unit energy so every room sits at about the same loudness.
//
//  Deterministic: the same shape always gives the same response.
//

import Foundation

public struct ReverbShape: Equatable, Sendable {
    /// Seconds to fall by 60 dB (RT60).
    public var decay: Double
    /// Seconds of silence before the reverb starts.
    public var preDelay: Double
    /// 0 = dark, 1 = bright.
    public var tone: Double

    public init(decay: Double, preDelay: Double, tone: Double) {
        self.decay = decay
        self.preDelay = preDelay
        self.tone = tone
    }
}

public enum ImpulseResponse {
    public static let minDecay = 0.2
    public static let maxDecay = 10.0
    public static let maxPreDelay = 0.15

    public static func make(_ shape: ReverbShape, sampleRate fs: Double) -> (left: [Float], right: [Float]) {
        let decay = min(max(shape.decay, minDecay), maxDecay)
        let tone = min(max(shape.tone, 0), 1)
        let preDelay = Int(min(max(shape.preDelay, 0), maxPreDelay) * fs)
        let tailLength = Int(decay * fs)
        let length = preDelay + tailLength

        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        var rng = SplitMix64(seed: 0x5EED_2EE7_B0B0)

        // Diffuse tail.
        let decayPerSample = -6.907755 / (decay * fs)          // ln(10^-3)
        let buildUp = min(0.05, 0.004 + 0.008 * decay) * fs
        let startCutoff = min(2_500 * pow(16_000 / 2_500, tone), 0.45 * fs)
        let cutoffHalfLife = decay * (0.12 + 0.38 * tone)        // seconds
        let fadeOutStart = Int(Double(tailLength) * 0.9)

        var l1 = 0.0, l2 = 0.0, r1 = 0.0, r2 = 0.0
        var a = 0.0
        for i in 0..<tailLength {
            if i % 32 == 0 {
                let t = Double(i) / fs
                let cutoff = max(180, startCutoff * pow(0.5, t / cutoffHalfLife))
                a = exp(-2 * Double.pi * cutoff / fs)
            }
            var envelope = exp(decayPerSample * Double(i)) * (1 - exp(-Double(i) / buildUp))
            if i >= fadeOutStart {
                envelope *= 1 - Double(i - fadeOutStart) / Double(tailLength - fadeOutStart)
            }
            l1 = (1 - a) * rng.bipolar() + a * l1
            l2 = (1 - a) * l1 + a * l2
            r1 = (1 - a) * rng.bipolar() + a * r1
            r2 = (1 - a) * r1 + a * r2
            left[preDelay + i] = Float(l2 * envelope)
            right[preDelay + i] = Float(r2 * envelope)
        }

        // Early reflections: discrete echoes off nearby surfaces, arriving denser
        // as time goes on (their count grows with the square of distance). Each wall
        // soaks up some treble, so they're softened before mixing in; raw single-sample
        // clicks would sound metallic. They carry more of the energy in small rooms.
        let smallness = min(max((2.0 - decay) / 1.7, 0), 1)
        let earlyShare = 0.08 + 0.22 * smallness
        normalize(&left, &right, toEnergy: 1 - earlyShare)

        let span = min(0.08, 0.008 + 0.022 * decay)            // seconds
        let earlyEnd = min(length, preDelay + Int((span + 0.004) * fs) + 1)
        var earlyLeft = [Float](repeating: 0, count: earlyEnd)
        var earlyRight = [Float](repeating: 0, count: earlyEnd)
        for _ in 0..<24 {
            let t = 0.0015 + span * cbrt(rng.unit())
            let index = preDelay + Int(t * fs)
            guard index < earlyEnd else { continue }
            let gain = (0.5 + 0.5 * rng.unit()) / (1 + t / 0.01) * (rng.unit() < 0.5 ? -1 : 1)
            let pan = rng.unit()
            earlyLeft[index] += Float(gain * sqrt(1 - pan))
            earlyRight[index] += Float(gain * sqrt(pan))
        }
        var wallLeft = Biquad.lowpass(cutoff: startCutoff * 0.7, q: 0.6, sampleRate: fs)
        var wallRight = wallLeft
        wallLeft.process(&earlyLeft)
        wallRight.process(&earlyRight)
        normalize(&earlyLeft, &earlyRight, toEnergy: earlyShare)
        for i in 0..<earlyEnd {
            left[i] += earlyLeft[i]
            right[i] += earlyRight[i]
        }

        // EQ the reverb the way a mix engineer EQs a reverb return: no rumble or boom
        // under 120 Hz, less mud around 300 Hz, a touch less harshness near 3 kHz.
        // That keeps the bass and vocals of the song clear under a long tail.
        for channel in 0..<2 {
            var chain = [
                Biquad.highpass(cutoff: 120, q: 0.707, sampleRate: fs),
                Biquad.peaking(frequency: 300, q: 1.0, gain: -2.5, sampleRate: fs),
                Biquad.peaking(frequency: 3_200, q: 1.0, gain: -1.5, sampleRate: fs)
            ]
            for i in chain.indices {
                if channel == 0 { chain[i].process(&left) } else { chain[i].process(&right) }
            }
        }

        normalize(&left, &right, toEnergy: 1)
        return (left, right)
    }

    /// Scales both channels so their average energy is `target`.
    private static func normalize(_ left: inout [Float], _ right: inout [Float], toEnergy target: Double) {
        var energy = 0.0
        for v in left { energy += Double(v) * Double(v) }
        for v in right { energy += Double(v) * Double(v) }
        energy /= 2
        guard energy > 0 else { return }
        let scale = Float(sqrt(target / energy))
        for i in left.indices { left[i] *= scale }
        for i in right.indices { right[i] *= scale }
    }
}

/// Small, fast, seedable random numbers (SplitMix64).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    /// Uniform in [-1, 1).
    mutating func bipolar() -> Double { unit() * 2 - 1 }
}
