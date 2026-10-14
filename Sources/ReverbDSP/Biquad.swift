//
//  Biquad.swift
//  RBJ cookbook biquads, transposed direct form II.
//

import Foundation

public struct Biquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    public static func lowpass(cutoff: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let (cosw, alpha) = shape(cutoff, q, fs)
        return normalized(b0: (1 - cosw) / 2, b1: 1 - cosw, b2: (1 - cosw) / 2,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func highpass(cutoff: Double, q: Double, sampleRate fs: Double) -> Biquad {
        let (cosw, alpha) = shape(cutoff, q, fs)
        return normalized(b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    /// Bell boost or cut of `gain` dB around `frequency`.
    public static func peaking(frequency: Double, q: Double, gain: Double, sampleRate fs: Double) -> Biquad {
        let (cosw, alpha) = shape(frequency, q, fs)
        let a = pow(10, gain / 40)
        return normalized(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                          a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    /// ITU-R BS.1770 K-weighting: a +4 dB high shelf (the head's acoustic effect)
    /// followed by the "RLB" highpass. Derived for any sample rate from the
    /// standard's analog prototypes; at 48 kHz it reproduces the published coefficients.
    public static func kWeighting(sampleRate fs: Double) -> (shelf: Biquad, highpass: Biquad) {
        // Stage 1: high shelf.
        var k = tan(Double.pi * 1681.974450955533 / fs)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = normalized(b0: vh + vb * k / q + k * k, b1: 2 * (k * k - vh), b2: vh - vb * k / q + k * k,
                               a0: a0, a1: 2 * (k * k - 1), a2: 1 - k / q + k * k)
        // Stage 2: highpass (numerator fixed at 1, -2, 1 as in the standard).
        k = tan(Double.pi * 38.13547087602444 / fs)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highpass = Biquad(b0: 1, b1: -2, b2: 1,
                              a1: Float(2 * (k * k - 1) / a0), a2: Float((1 - k / q + k * k) / a0))
        return (shelf, highpass)
    }

    /// The raw coefficients, for checking against published values.
    public var coefficients: [Float] { [b0, b1, b2, a1, a2] }

    private static func shape(_ frequency: Double, _ q: Double, _ fs: Double) -> (cosw: Double, alpha: Double) {
        let w = 2 * Double.pi * min(frequency, 0.45 * fs) / fs
        return (cos(w), sin(w) / (2 * q))
    }

    private static func normalized(b0: Double, b1: Double, b2: Double,
                                   a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
               a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        // Flush values that would decay into denormals during silence.
        if abs(z1) < 1e-20 { z1 = 0 }
        if abs(z2) < 1e-20 { z2 = 0 }
        return y
    }

    /// Filters a whole array in place (for building impulse responses).
    public mutating func process(_ x: inout [Float]) {
        for i in x.indices { x[i] = process(x[i]) }
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
