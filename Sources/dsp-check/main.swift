//
//  dsp-check: verifies the convolver against direct convolution, checks the
//  processor's latency and safety, and measures how much CPU the reverb needs.
//
//    swift run -c release dsp-check
//

import Foundation
import ReverbDSP

var failures = 0

func check(_ ok: Bool, _ message: String) {
    print(ok ? "  ok    \(message)" : "  FAIL  \(message)")
    if !ok { failures += 1 }
}

func noise(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state) >> 11) / Float(1 << 52)
    }
}

// 1. Convolver output equals direct convolution.
print("Convolver")
do {
    let B = 256
    let irLength = 3_000
    let blocks = 20
    let irL = noise(irLength, seed: 1), irR = noise(irLength, seed: 2)
    let inL = noise(B * blocks, seed: 3), inR = noise(B * blocks, seed: 4)

    let convolver = StereoConvolver(blockSize: B, maxPartitions: 16)
    let spectra = IRSpectra(left: irL, right: irR, blockSize: B, maxPartitions: 16)
    var outL = [Float](repeating: 0, count: B * blocks)
    var outR = outL

    for b in 0..<blocks {
        inL.withUnsafeBufferPointer { l in
            inR.withUnsafeBufferPointer { r in
                convolver.push(l.baseAddress! + b * B, r.baseAddress! + b * B)
            }
        }
        outL.withUnsafeMutableBufferPointer { l in
            outR.withUnsafeMutableBufferPointer { r in
                convolver.render(spectra, l.baseAddress! + b * B, r.baseAddress! + b * B)
            }
        }
    }

    var worst: Float = 0, peak: Float = 0
    for (input, ir, output) in [(inL, irL, outL), (inR, irR, outR)] {
        for n in 0..<(B * blocks) {
            var sum: Double = 0
            for k in 0...min(n, irLength - 1) { sum += Double(input[n - k]) * Double(ir[k]) }
            worst = max(worst, abs(Float(sum) - output[n]))
            peak = max(peak, abs(Float(sum)))
        }
    }
    check(worst / peak < 1e-4, String(format: "matches direct convolution (max relative error %.2e)", worst / peak))
}

// 2. Processor: dry path latency and gain, silence in → silence out.
print("Processor")
do {
    let fs = 48_000.0
    let processor = ReverbProcessor(sampleRate: fs, mix: 0, nextRoom: false)
    processor.submit(processor.makeSpectra(ReverbShape(decay: 2, preDelay: 0.02, tone: 0.5)))
    let frames = 4 * processor.latency
    var l = [Float](repeating: 0, count: frames), r = l
    l[10] = 0.5; r[10] = -0.5
    processor.process(left: &l, right: &r, frames: frames)
    let at = processor.latency + 10
    check(abs(l[at] - 0.5) < 1e-4 && abs(r[at] + 0.5) < 1e-4,
          "dry signal comes out \(processor.latency) frames late at unity gain")

    let silent = ReverbProcessor(sampleRate: fs, mix: 0.6, nextRoom: true)
    silent.submit(silent.makeSpectra(ReverbShape(decay: 5, preDelay: 0.03, tone: 0.5)))
    var zl = [Float](repeating: 0, count: 8192), zr = zl
    silent.process(left: &zl, right: &zr, frames: zl.count)
    check(zl.allSatisfy { $0 == 0 } && zr.allSatisfy { $0 == 0 }, "silence in gives silence out")

    let loud = ReverbProcessor(sampleRate: fs, mix: 0.5, nextRoom: false)
    loud.submit(loud.makeSpectra(ReverbShape(decay: 8, preDelay: 0, tone: 1)))
    var ll = noise(96_000, seed: 7), lr = noise(96_000, seed: 8)
    loud.process(left: &ll, right: &lr, frames: ll.count)
    let loudest = max(ll.map(abs).max() ?? 0, lr.map(abs).max() ?? 0)
    check(loudest <= 0.9, String(format: "full-scale input is held near -1 dBFS (peak %.2f dBFS)",
                                 20 * log10(Double(loudest))))

    // A hard-left signal should still put reverb on the right (true stereo).
    let wide = ReverbProcessor(sampleRate: fs, mix: 1, nextRoom: false)
    wide.submit(wide.makeSpectra(ReverbShape(decay: 2, preDelay: 0, tone: 0.5)))
    var wl = noise(48_000, seed: 5), wr = [Float](repeating: 0, count: 48_000)
    wide.process(left: &wl, right: &wr, frames: wl.count)
    let rightEnergy = wr.reduce(0) { $0 + $1 * $1 }, leftEnergy = wl.reduce(0) { $0 + $1 * $1 }
    check(rightEnergy > leftEnergy * 0.05, "a hard-left source fills both sides of the room")

    // Next room: highs blocked by the wall.
    let wall = ReverbProcessor(sampleRate: fs, mix: 0, nextRoom: true)
    var hl = (0..<48_000).map { Float(sin(2 * Double.pi * 4_000 * Double($0) / fs)) * 0.5 }, hr = hl
    wall.process(left: &hl, right: &hr, frames: hl.count)
    let through = hl.suffix(24_000).map(abs).max() ?? 1
    check(through < 0.5 * 0.01, String(format: "next room blocks 4 kHz by %.0f dB", 20 * log10(Double(through) / 0.5)))
}

// 2b. Limiter: holds the ceiling and doesn't pump on a sustained loud signal.
print("Limiter")
do {
    let fs = 48_000.0
    let processor = ReverbProcessor(sampleRate: fs, mix: 0, nextRoom: false)
    let n = Int(3 * fs)
    // A dense, loud "master": 60 Hz + 1 kHz, peaking ~5 dB over the ceiling.
    var l = (0..<n).map { i -> Float in
        let t = Double(i) / fs
        return Float(0.9 * sin(2 * .pi * 60 * t) + 0.6 * sin(2 * .pi * 1000 * t))
    }
    var r = l
    processor.process(left: &l, right: &r, frames: n)
    let peak = l.map(abs).max() ?? 0
    check(peak <= 0.892, String(format: "peaks held at -1 dBFS (%.2f dBFS)", 20 * log10(Double(peak))))
    // After settling, the level of each 60 Hz cycle should be steady (no pumping).
    let cycle = Int(fs / 60)
    let peaks = stride(from: Int(1.5 * fs), to: n - cycle, by: cycle).map { start in
        l[start..<(start + cycle)].map(abs).max() ?? 0
    }
    let swing = 20 * log10(Double((peaks.max() ?? 1) / (peaks.min() ?? 1)))
    check(swing < 0.3, String(format: "steady level under sustained limiting (%.2f dB swing)", swing))
}

// 2c. Pitch shifter.
print("Pitch shifter")
do {
    let fs = 48_000.0
    func dominantFrequency(_ x: ArraySlice<Float>) -> Double {
        var crossings = 0
        var previous = x.first ?? 0
        for v in x.dropFirst() {
            if previous < 0 && v >= 0 { crossings += 1 }
            previous = v
        }
        return Double(crossings) * fs / Double(x.count)
    }
    for semitones: Float in [-12, -2.8, 5] {
        let shifter = PitchShifter(sampleRate: fs, semitones: semitones)
        let n = Int(2 * fs)
        var l = (0..<n).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / fs)) }, r = l
        shifter.process(left: &l, right: &r, frames: n)
        let expected = 440 * pow(2, Double(semitones) / 12)
        let measured = dominantFrequency(l[n / 2..<n])
        check(abs(measured - expected) / expected < 0.01,
              String(format: "%+.1f st turns 440 Hz into %.1f Hz (expected %.1f)", semitones, measured, expected))
    }

    let bypass = PitchShifter(sampleRate: fs, semitones: 0)
    let input = noise(8192, seed: 11)
    var bl = input, br = input
    bypass.process(left: &bl, right: &br, frames: bl.count)
    check(bl == input && br == input, "0 semitones is bit-exact and adds no delay")
    print("  info  shifted path latency \(bypass.latency) frames (\(Int(Double(bypass.latency) / fs * 1000)) ms)")

    let busy = PitchShifter(sampleRate: fs, semitones: -2.8)
    let cycle = 512
    var cl = noise(cycle, seed: 12), cr = noise(cycle, seed: 13)
    var worst = 0.0
    let start = Date()
    let cycles = Int(20 * fs) / cycle
    for _ in 0..<cycles {
        let t = Date()
        busy.process(left: &cl, right: &cr, frames: cycle)
        worst = max(worst, Date().timeIntervalSince(t))
    }
    let load = Date().timeIntervalSince(start) / 20 * 100
    let budget = Double(cycle) / fs
    print(String(format: "  info  pitch shifting uses %.1f%% of one core; slowest callback %.2f ms of %.1f ms",
                 load, worst * 1000, budget * 1000))
    check(worst < budget * 0.5, "every callback finishes in under half its time budget")
}

// 3. Impulse responses.
print("Impulse responses")
do {
    let fs = 48_000.0
    let start = Date()
    let ir = ImpulseResponse.make(ReverbShape(decay: 10, preDelay: 0.15, tone: 0.5), sampleRate: fs)
    let seconds = Date().timeIntervalSince(start)
    check(ir.left.count == Int(10.15 * fs), "10 s room plus 150 ms pre-delay has the right length")
    check(ir.left.prefix(Int(0.149 * fs)).allSatisfy { $0 == 0 }, "pre-delay is silent")
    let energy = (ir.left + ir.right).reduce(0.0) { $0 + Double($1) * Double($1) } / 2
    check(abs(energy - 1) < 1e-3, String(format: "unit energy (%.4f)", energy))
    print(String(format: "  info  longest response builds in %.0f ms", seconds * 1000))
}

// 4. CPU cost of the longest room.
print("Performance")
do {
    let fs = 48_000.0
    let processor = ReverbProcessor(sampleRate: fs, mix: 0.5, nextRoom: false)
    processor.submit(processor.makeSpectra(ReverbShape(decay: 10, preDelay: 0.15, tone: 0.5)))
    let audioSeconds = 20.0
    let cycle = 512
    var l = noise(cycle, seed: 9), r = noise(cycle, seed: 10)
    let start = Date()
    for _ in 0..<Int(audioSeconds * fs) / cycle {
        processor.process(left: &l, right: &r, frames: cycle)
    }
    let used = Date().timeIntervalSince(start)
    let load = used / audioSeconds * 100
    print(String(format: "  info  10 s room uses %.1f%% of one core", load))
    check(load < 25, "fast enough for real time")
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
