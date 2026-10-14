//
//  Loudness.swift
//  Measurement after ITU-R BS.1770 / EBU R128: true peak and K-weighted loudness.
//

import Foundation

/// Estimates the true (inter-sample) peak per BS.1770-4 Annex 2: upsample 4× and
/// take the largest magnitude. A DAC reconstructs the waveform between samples,
/// and on loud masters it can swing well past the largest sample value.
///
/// The interpolator is a 48-tap windowed-sinc lowpass split into four 12-tap
/// phases, the same structure the standard describes. Its estimate lags the
/// input by `latency` samples.
public final class TruePeakDetector {
    public static let latency = 6
    private static let taps = 12
    private static let phases = 4
    /// [phase][tap]
    private static let filter: [Float] = {
        let length = taps * phases
        let center = Double(length - 1) / 2
        return (0..<length).map { n -> Float in
            let x = (Double(n) - center) / Double(phases)
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            // Blackman-Harris window keeps the stopband deep with few taps.
            let w = 2 * Double.pi * Double(n) / Double(length - 1)
            let window = 0.35875 - 0.48829 * cos(w) + 0.14128 * cos(2 * w) - 0.01168 * cos(3 * w)
            return Float(sinc * window)
        }
    }()

    private let coefficients: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>   // doubled ring: no wrap in the inner loop
    private var index = 0

    public init() {
        let filter = Self.filter
        coefficients = .allocate(capacity: filter.count)
        // Reorder so each phase's taps are contiguous: coefficients[p * taps + k] = h[k * phases + p].
        for p in 0..<Self.phases {
            for k in 0..<Self.taps {
                coefficients[p * Self.taps + k] = filter[k * Self.phases + p]
            }
        }
        history = .allocate(capacity: 2 * Self.taps)
        history.initialize(repeating: 0, count: 2 * Self.taps)
    }

    deinit {
        coefficients.deallocate()
        history.deallocate()
    }

    /// Feeds one sample; returns the largest magnitude among the four
    /// interpolated points around the sample `latency` samples ago.
    @inline(__always)
    public func process(_ x: Float) -> Float {
        history[index] = x
        history[index + Self.taps] = x
        index += 1
        if index == Self.taps { index = 0 }
        // history[index ..< index + taps] now runs oldest → newest.
        let window = history + index
        var peak: Float = 0
        for p in 0..<Self.phases {
            let c = coefficients + p * Self.taps
            var sum: Float = 0
            for k in 0..<Self.taps { sum += window[Self.taps - 1 - k] * c[k] }
            peak = max(peak, abs(sum))
        }
        // The original sample at the same moment, so a peak is never under-read.
        return max(peak, abs(window[Self.taps - 1 - Self.latency]))
    }

    public func reset() {
        history.update(repeating: 0, count: 2 * Self.taps)
        index = 0
    }
}

/// K-weighted mean-square power of a stereo signal, smoothed like R128's
/// short-term loudness (about 3 s).
struct LoudnessMeter {
    private var leftShelf, leftHighpass, rightShelf, rightHighpass: Biquad
    private let smoothing: Float
    private(set) var power: Float = 0

    init(sampleRate: Double, seconds: Double = 3) {
        let k = Biquad.kWeighting(sampleRate: sampleRate)
        leftShelf = k.shelf; leftHighpass = k.highpass
        rightShelf = k.shelf; rightHighpass = k.highpass
        smoothing = Float(1 - exp(-1 / (seconds * sampleRate)))
    }

    @inline(__always)
    mutating func process(_ l: Float, _ r: Float) {
        let kl = leftHighpass.process(leftShelf.process(l))
        let kr = rightHighpass.process(rightShelf.process(r))
        power += (kl * kl + kr * kr - power) * smoothing
    }

    /// BS.1770 loudness of the smoothed power, in LUFS.
    var lufs: Float { -0.691 + 10 * log10(max(power, 1e-12)) }
}
