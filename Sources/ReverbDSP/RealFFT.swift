//
//  RealFFT.swift
//  vDSP real FFT in its packed split-complex format: `size` reals become
//  `size / 2` complex bins, with the DC term in re[0] and the Nyquist term in im[0].
//

import Accelerate

public final class RealFFT {
    public let size: Int
    public let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    public init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        half = size / 2
        log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `size` reals in, `half` bins out. vDSP scales the result by 2.
    public func forward(_ time: UnsafePointer<Float>,
                        re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(time)), 2, &split, 1, vDSP_Length(half))
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }

    /// `half` bins in (overwritten), `size` reals out. vDSP scales the result by `size`.
    public func inverse(re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>,
                        into time: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        vDSP_ztoc(&split, 1, UnsafeMutablePointer<DSPComplex>(OpaquePointer(time)), 2, vDSP_Length(half))
    }
}
