//
//  BandSplitter.swift
//  Splits the tapped audio into the frequency bands the tank's blobs follow:
//  bass (kick drums, bass lines) and treble (hi-hats, cymbals). Each band is two
//  second-order filters in series (24 dB/octave), so mids and vocals barely leak
//  in. Cheap, allocation-free and safe on the real-time thread.
//  Pure value code, unit-tested.
//

import Foundation

/// A second-order IIR filter (RBJ cookbook), transposed direct form II.
struct Biquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    enum Kind { case lowPass, highPass }

    init(_ kind: Kind, cutoff: Double, sampleRate: Double, q: Double = 0.7071) {
        let w0 = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        let (nb0, nb1, nb2): (Double, Double, Double)
        switch kind {
        case .lowPass:
            nb1 = 1 - cosW0
            nb0 = nb1 / 2
            nb2 = nb0
        case .highPass:
            nb1 = -(1 + cosW0)
            nb0 = (1 + cosW0) / 2
            nb2 = nb0
        }
        b0 = Float(nb0 / a0); b1 = Float(nb1 / a0); b2 = Float(nb2 / a0)
        a1 = Float(-2 * cosW0 / a0); a2 = Float((1 - alpha) / a0)
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// The bands the tank follows, and how loud each one was over one IO cycle.
struct BandSplitter {
    /// Kick drums sit below this (the body of a kick is about 50–100 Hz).
    static let bassCutoff = 120.0
    /// Hi-hats and cymbals sit above this; most vocal sibilance is below it.
    static let trebleCutoff = 7000.0

    private var bass: (Biquad, Biquad)
    private var treble: (Biquad, Biquad)

    init(sampleRate: Double) {
        let low = Biquad(.lowPass, cutoff: Self.bassCutoff, sampleRate: sampleRate)
        let high = Biquad(.highPass, cutoff: Self.trebleCutoff, sampleRate: sampleRate)
        bass = (low, low)
        treble = (high, high)
    }

    /// Mean square of each band over `frameCount` frames of interleaved samples
    /// (stereo is mixed to mono first). Real-time safe.
    mutating func meanSquares(_ samples: UnsafePointer<Float>, frameCount: Int,
                              channels: Int) -> (bass: Float, treble: Float) {
        guard frameCount > 0 else { return (0, 0) }
        var bassSum: Float = 0
        var trebleSum: Float = 0
        for frame in 0..<frameCount {
            let first = samples[frame * channels]
            let mono = channels > 1 ? (first + samples[frame * channels + 1]) * 0.5 : first
            let low = bass.1.process(bass.0.process(mono))
            let high = treble.1.process(treble.0.process(mono))
            bassSum += low * low
            trebleSum += high * high
        }
        let n = Float(frameCount)
        return (bassSum / n, trebleSum / n)
    }
}
