//
//  Convolver.swift
//  Uniformly partitioned overlap-save convolution (UPOLS), stereo.
//
//  The impulse response is cut into partitions of B samples, each zero-padded to
//  2B and transformed once (IRSpectra). Every block of B input samples is
//  transformed once too and kept in a frequency-domain delay line (FDL). One
//  output block is then  IFFT( sum_p  X[now - p] * H[p] ),  of which the last B
//  samples are valid. The cost per sample doesn't depend on B; latency is B.
//
//  The FDL holds input, not reverb, so swapping to a new impulse response keeps
//  the full tail: the new response is applied to the input history at once.
//

import Accelerate

/// One impulse response, ready to convolve with. Immutable after init, so the
/// real-time thread can read it while other threads build the next one.
public final class IRSpectra {
    public let partitions: Int
    public let blockSize: Int
    /// Layout: [channel][partition][re: B][im: B].
    private let storage: UnsafeMutablePointer<Float>

    public init(left: [Float], right: [Float], blockSize: Int, maxPartitions: Int) {
        let B = blockSize
        let length = max(left.count, right.count)
        self.blockSize = B
        partitions = max(1, min(maxPartitions, (length + B - 1) / B))
        let count = 2 * partitions * 2 * B
        storage = .allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)

        let fft = RealFFT(size: 2 * B)
        let padded = UnsafeMutablePointer<Float>.allocate(capacity: 2 * B)
        defer { padded.deallocate() }

        // vDSP's forward transform scales by 2 (for X and for H) and its inverse by
        // 2B, so  inverse(2X · 2H · s) = 4 · 2B · s · (x ⊛ h).  Fold s into H.
        var scale = Float(1.0 / (4.0 * Double(2 * B)))

        for (channel, ir) in [left, right].enumerated() {
            ir.withUnsafeBufferPointer { samples in
                for p in 0..<partitions {
                    padded.update(repeating: 0, count: 2 * B)
                    let start = p * B
                    let n = max(0, min(B, samples.count - start))
                    if n > 0, let base = samples.baseAddress {
                        padded.update(from: base + start, count: n)
                    }
                    let re = self.re(channel, p)
                    fft.forward(padded, re: re, im: re + B)
                    vDSP_vsmul(re, 1, &scale, re, 1, vDSP_Length(2 * B))
                }
            }
        }
    }

    deinit { storage.deallocate() }

    /// Real parts of one partition's spectrum; the imaginary parts follow at +B.
    @inline(__always)
    func re(_ channel: Int, _ partition: Int) -> UnsafeMutablePointer<Float> {
        storage + (channel * partitions + partition) * 2 * blockSize
    }
}

/// Real-time convolution engine. Allocates only in init.
public final class StereoConvolver {
    public let blockSize: Int
    public let maxPartitions: Int
    private let fft: RealFFT
    /// [channel][slot][re: B][im: B], a ring of input spectra; `head` is the newest.
    private let fdl: UnsafeMutablePointer<Float>
    private var head = 0
    /// [channel][2B]: the previous input block followed by the current one.
    private let history: UnsafeMutablePointer<Float>
    private let accRe: UnsafeMutablePointer<Float>
    private let accIm: UnsafeMutablePointer<Float>
    private let time: UnsafeMutablePointer<Float>

    public init(blockSize: Int, maxPartitions: Int) {
        let B = blockSize
        self.blockSize = B
        self.maxPartitions = maxPartitions
        fft = RealFFT(size: 2 * B)
        fdl = Self.zeroed(2 * maxPartitions * 2 * B)
        history = Self.zeroed(2 * 2 * B)
        accRe = Self.zeroed(B)
        accIm = Self.zeroed(B)
        time = Self.zeroed(2 * B)
    }

    deinit {
        fdl.deallocate()
        history.deallocate()
        accRe.deallocate()
        accIm.deallocate()
        time.deallocate()
    }

    private static func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        p.initialize(repeating: 0, count: count)
        return p
    }

    @inline(__always)
    private func slot(_ channel: Int, _ index: Int) -> UnsafeMutablePointer<Float> {
        fdl + (channel * maxPartitions + index) * 2 * blockSize
    }

    /// Adds one block of B input samples per channel to the delay line.
    public func push(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>) {
        let B = blockSize
        head = (head + 1) % maxPartitions
        for channel in 0..<2 {
            let h = history + channel * 2 * B
            h.update(from: h + B, count: B)
            (h + B).update(from: channel == 0 ? left : right, count: B)
            let s = slot(channel, head)
            fft.forward(h, re: s, im: s + B)
        }
    }

    /// Writes B output samples per channel: the last pushed block convolved with `ir`.
    /// Can be called more than once per push (e.g. with two responses to crossfade).
    public func render(_ ir: IRSpectra, _ outLeft: UnsafeMutablePointer<Float>,
                       _ outRight: UnsafeMutablePointer<Float>) {
        let B = blockSize
        let partitions = min(ir.partitions, maxPartitions)
        var accA = DSPSplitComplex(realp: accRe, imagp: accIm)
        var accB = DSPSplitComplex(realp: accRe, imagp: accIm)

        for channel in 0..<2 {
            accRe.update(repeating: 0, count: B)
            accIm.update(repeating: 0, count: B)
            for p in 0..<partitions {
                var index = head - p
                if index < 0 { index += maxPartitions }
                let x = slot(channel, index)
                let h = ir.re(channel, p)

                // Bin 0 packs two real values (DC in re, Nyquist in im), which a
                // complex multiply would mix. Do them separately.
                let dc = accRe[0] + x[0] * h[0]
                let nyquist = accIm[0] + x[B] * h[B]
                var xs = DSPSplitComplex(realp: x, imagp: x + B)
                var hs = DSPSplitComplex(realp: h, imagp: h + B)
                vDSP_zvma(&xs, 1, &hs, 1, &accA, 1, &accB, 1, vDSP_Length(B))
                accRe[0] = dc
                accIm[0] = nyquist
            }
            fft.inverse(re: accRe, im: accIm, into: time)
            (channel == 0 ? outLeft : outRight).update(from: time + B, count: B)
        }
    }
}
