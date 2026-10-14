//
//  PitchShifter.swift
//  Polyphonic pitch shifting with Signalsmith Stretch.
//
//  Apple's time-pitch unit is a plain phase vocoder: on dense mixes it smears
//  transients and makes vocals sound watery and robotic. Signalsmith Stretch
//  tracks spectral peaks and keeps their phases locked together, so chords,
//  vocals and drums stay much more natural.
//
//  At 0 semitones the shifter is bypassed with no added latency, so plain reverb
//  stays in sync with video. Moving in or out of 0 crossfades the two paths over
//  60 ms; the shifter keeps running meanwhile, so it's always warmed up.
//

import Foundation
import RRStretch

public final class PitchShifter {
    /// Frames the shifted path lags behind the input.
    public let latency: Int

    private let engine: OpaquePointer
    private let maxFrames: Int
    private let inLeft, inRight, outLeft, outRight: UnsafeMutablePointer<Float>
    private let inputs: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    private let target = AtomicFloat(0)
    private var applied: Float = .nan
    /// 0 = bypass, 1 = shifted.
    private var blend: Float
    private let blendStep: Float

    public init(sampleRate: Double, semitones: Float, maxFrames: Int = 4096) {
        engine = rr_stretch_create(2, sampleRate)
        latency = Int(rr_stretch_latency(engine))
        self.maxFrames = maxFrames

        func buffer() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            p.initialize(repeating: 0, count: maxFrames)
            return p
        }
        inLeft = buffer(); inRight = buffer(); outLeft = buffer(); outRight = buffer()
        inputs = .allocate(capacity: 2)
        inputs.initialize(to: UnsafePointer(inLeft))
        (inputs + 1).initialize(to: UnsafePointer(inRight))
        outputs = .allocate(capacity: 2)
        outputs.initialize(to: outLeft)
        (outputs + 1).initialize(to: outRight)

        target.value = semitones
        blend = Self.shifting(semitones) ? 1 : 0
        blendStep = Float(1 / (0.06 * sampleRate))
    }

    deinit {
        rr_stretch_destroy(engine)
        for p in [inLeft, inRight, outLeft, outRight] { p.deallocate() }
        inputs.deallocate()
        outputs.deallocate()
    }

    /// Any thread. Takes effect at the next audio callback.
    public func setSemitones(_ semitones: Float) { target.value = semitones }

    private static func shifting(_ semitones: Float) -> Bool { abs(semitones) >= 0.05 }

    /// Real-time: processes `frames` samples per channel in place.
    public func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let semitones = target.value
        if semitones != applied {
            rr_stretch_set_semitones(engine, semitones)
            applied = semitones
        }
        let goal: Float = Self.shifting(semitones) ? 1 : 0

        var done = 0
        while done < frames {
            let n = min(frames - done, maxFrames)
            inLeft.update(from: left + done, count: n)
            inRight.update(from: right + done, count: n)
            rr_stretch_process(engine, inputs, outputs, Int32(n))

            if blend == goal {
                if goal == 1 {
                    (left + done).update(from: outLeft, count: n)
                    (right + done).update(from: outRight, count: n)
                }
            } else {
                for i in 0..<n {
                    blend = goal > blend ? min(goal, blend + blendStep) : max(goal, blend - blendStep)
                    // Equal-power: the two paths are offset in time, so they don't add coherently.
                    let shifted = sin(blend * .pi / 2), dry = cos(blend * .pi / 2)
                    left[done + i] = left[done + i] * dry + outLeft[i] * shifted
                    right[done + i] = right[done + i] * dry + outRight[i] * shifted
                }
            }
            done += n
        }
    }
}
