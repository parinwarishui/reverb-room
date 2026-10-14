//
//  SongAnalyzer.swift
//  Listens to the song and suggests how to tune the reverb for it.
//
//  Real-time side (SongAnalyzer): every 10 ms it sums the energy of the mono
//  mix in three bands (under 200 Hz, 200 Hz–4 kHz, over 4 kHz) and the peak, and
//  queues that frame lock-free. Nothing else happens on the audio thread.
//
//  Analysis side (SongFeatures, off the audio thread), over the last ~8 s:
//  - Onset strength: band-wise spectral flux, the rise in log energy from one
//    frame to the next, summed over the three bands (as in onset detectors like
//    librosa's, with three bands instead of an FFT).
//  - Tempo: autocorrelation of onset strength between 60 and 180 BPM, weighted
//    toward 120 BPM so it doesn't jump an octave, refined by parabolic
//    interpolation.
//  - Density: onsets per second. Crest factor: peak over RMS, i.e. how squashed
//    the master is. Brightness and low end: each band's share of the energy.
//
//  AutoTune turns those into offsets around the user's own settings.
//

import Foundation
import RRAtomics

public struct AnalysisFrame {
    public var low: Float
    public var mid: Float
    public var high: Float
    public var peak: Float

    public var total: Float { low + mid + high }
}

public final class SongAnalyzer {
    public static let framesPerSecond = 100

    private let hop: Int
    private var count = 0
    private var low: Float = 0, mid: Float = 0, high: Float = 0, peak: Float = 0
    private var lowpass: Biquad
    private var highpass: Biquad

    // Single-producer, single-consumer ring of frames.
    private let capacity = 4096
    private let ring: UnsafeMutablePointer<AnalysisFrame>
    private let writeIndex = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private let readIndex = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    public init(sampleRate: Double) {
        hop = max(1, Int(sampleRate) / Self.framesPerSecond)
        lowpass = .lowpass(cutoff: 200, q: 0.707, sampleRate: sampleRate)
        highpass = .highpass(cutoff: 4_000, q: 0.707, sampleRate: sampleRate)
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: AnalysisFrame(low: 0, mid: 0, high: 0, peak: 0), count: capacity)
        writeIndex.initialize(to: 0)
        readIndex.initialize(to: 0)
    }

    deinit {
        ring.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    /// Real-time: no locks, no allocation.
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let x = (left[i] + right[i]) * 0.5
            let l = lowpass.process(x)
            let h = highpass.process(x)
            let m = x - l - h
            low += l * l
            mid += m * m
            high += h * h
            peak = max(peak, abs(left[i]), abs(right[i]))
            count += 1
            if count == hop {
                let scale = 1 / Float(hop)
                push(AnalysisFrame(low: low * scale, mid: mid * scale, high: high * scale, peak: peak))
                low = 0; mid = 0; high = 0; peak = 0; count = 0
            }
        }
    }

    private func push(_ frame: AnalysisFrame) {
        let write = rr_load_u32(writeIndex)
        let read = rr_load_u32_acquire(readIndex)
        guard write &- read < UInt32(capacity) else { return }   // full: drop (reader is behind)
        ring[Int(write % UInt32(capacity))] = frame
        rr_store_u32_release(writeIndex, write &+ 1)
    }

    /// Off the audio thread: moves every queued frame into `frames`.
    public func drain(into frames: inout [AnalysisFrame]) {
        var read = rr_load_u32(readIndex)
        let write = rr_load_u32_acquire(writeIndex)
        while read != write {
            frames.append(ring[Int(read % UInt32(capacity))])
            read &+= 1
        }
        rr_store_u32_release(readIndex, read)
    }
}

public struct SongFeatures: Equatable {
    /// Beats per minute, when the beat is clear enough to trust.
    public var tempo: Double?
    /// Onsets (hits, attacks) per second.
    public var onsetRate: Double
    /// Peak-to-RMS ratio in dB; low means a heavily compressed master.
    public var crest: Double
    /// Share of energy above 4 kHz and below 200 Hz.
    public var brightness: Double
    public var lowEnd: Double

    /// Needs about 4 s of non-silent audio; returns nil before that.
    public static func analyze(_ frames: ArraySlice<AnalysisFrame>) -> SongFeatures? {
        let silence: Float = 1e-6                                  // about -60 dBFS
        let audible = frames.filter { $0.total > silence }
        guard audible.count >= 4 * SongAnalyzer.framesPerSecond else { return nil }
        let frames = Array(frames)

        // Energy balance.
        let sums = audible.reduce((low: 0.0, mid: 0.0, high: 0.0)) {
            ($0.low + Double($1.low), $0.mid + Double($1.mid), $0.high + Double($1.high))
        }
        let total = sums.low + sums.mid + sums.high
        let brightness = sums.high / total
        let lowEnd = sums.low / total

        // Crest factor per second, median.
        var crests: [Double] = []
        let second = SongAnalyzer.framesPerSecond
        for start in stride(from: 0, to: frames.count - second + 1, by: second) {
            let chunk = frames[start..<(start + second)]
            let energy = chunk.reduce(0.0) { $0 + Double($1.total) } / Double(second)
            let peak = Double(chunk.map(\.peak).max() ?? 0)
            if energy > Double(silence), peak > 0 { crests.append(20 * log10(peak / energy.squareRoot())) }
        }
        let crest = crests.isEmpty ? 12 : crests.sorted()[crests.count / 2]

        // Onset strength: band-wise spectral flux on log energy.
        func log(_ x: Float) -> Double { Foundation.log(Double(x) + 1e-9) }
        var onset = [Double](repeating: 0, count: frames.count)
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            onset[i] = max(0, log(b.low) - log(a.low)) + max(0, log(b.mid) - log(a.mid))
                + max(0, log(b.high) - log(a.high))
        }

        // Onsets: local maxima clearly above the typical level, at least 60 ms apart.
        let sorted = onset.sorted()
        let median = sorted[sorted.count / 2]
        let deviation = onset.map { abs($0 - median) }.sorted()[onset.count / 2]
        let threshold = median + 3 * max(deviation, 0.05)
        var onsets = 0
        var last = -1000
        for i in 1..<(onset.count - 1)
        where onset[i] > threshold && onset[i] >= onset[i - 1] && onset[i] >= onset[i + 1] && i - last >= 6 {
            onsets += 1
            last = i
        }
        let onsetRate = Double(onsets) / (Double(audible.count) / Double(second))

        // Tempo: autocorrelation of the mean-removed onset strength.
        let mean = onset.reduce(0, +) / Double(onset.count)
        let centered = onset.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        var tempo: Double?
        if energy > 0 {
            let minLag = Int((60.0 / 180 * Double(second)).rounded(.down))   // 180 BPM
            let maxLag = Int((60.0 / 60 * Double(second)).rounded(.up))      // 60 BPM
            var scores: [Double] = []
            for lag in minLag...maxLag {
                var sum = 0.0
                for i in lag..<centered.count { sum += centered[i] * centered[i - lag] }
                scores.append(sum / energy)
            }
            func weight(_ lag: Double) -> Double {
                let bpm = 60 * Double(second) / lag
                let octaves = log2(bpm / 120)
                return exp(-0.5 * octaves * octaves / (0.9 * 0.9))
            }
            var best = 0
            for k in scores.indices where scores[k] * weight(Double(k + minLag)) > scores[best] * weight(Double(best + minLag)) {
                best = k
            }
            if scores[best] > 0.12 {
                var lag = Double(best + minLag)
                if best > 0, best < scores.count - 1 {
                    let (a, b, c) = (scores[best - 1], scores[best], scores[best + 1])
                    let denominator = a - 2 * b + c
                    if denominator != 0 { lag += 0.5 * (a - c) / denominator }
                }
                tempo = 60 * Double(second) / lag
            }
        }

        return SongFeatures(tempo: tempo, onsetRate: onsetRate, crest: crest,
                            brightness: brightness, lowEnd: lowEnd)
    }
}

/// How far to move the user's settings for a song. Bounded, so the user's choice
/// of room always stays recognisable.
public struct AutoTune: Equatable {
    /// Added to the reverb amount (0...1).
    public var amount: Double = 0
    /// Multiplies the room size.
    public var size: Double = 1
    /// Added to the tone (0...1).
    public var tone: Double = 0
    /// The beat length in seconds, for tempo-synced pre-delay; nil when unknown.
    public var beat: Double?

    public init() {}

    public static func target(for song: SongFeatures) -> AutoTune {
        var tune = AutoTune()
        // How busy the song is: many hits per second, or a squashed master.
        let density = min(max((song.onsetRate - 1.5) / 4.5, 0), 1)
        let squashed = min(max((14 - song.crest) / 8, 0), 1)
        let busy = 0.6 * density + 0.4 * squashed
        tune.amount = 0.12 - 0.30 * busy                              // +12 % sparse … −18 % dense

        // Slower songs leave room for longer tails; busy ones need shorter rooms.
        var size = 1.25 - 0.5 * busy
        if let bpm = song.tempo { size *= min(max(100 / bpm, 0.75), 1.3) }
        tune.size = min(max(size, 0.6), 1.5)

        // Bright, harsh mixes get a darker reverb; dull mixes a brighter one. A
        // heavy low end nudges it brighter too, so the tail doesn't add mud.
        tune.tone = min(max((0.08 - song.brightness) * 3 + max(song.lowEnd - 0.45, 0) * 0.4, -0.25), 0.2)

        if let bpm = song.tempo { tune.beat = 60 / bpm }
        return tune
    }

    /// Moves part of the way toward `target`, so changes are gradual.
    public mutating func approach(_ target: AutoTune, by fraction: Double) {
        amount += (target.amount - amount) * fraction
        size += (target.size - size) * fraction
        tone += (target.tone - tone) * fraction
        beat = target.beat ?? beat
    }

    /// The note length (a 1/128, 1/64, 1/32 or 1/16 note at the song's tempo)
    /// nearest to the user's pre-delay, in milliseconds.
    public func syncedPreDelay(near milliseconds: Double) -> Double {
        guard let beat, milliseconds > 0 else { return milliseconds }
        let options = [beat / 32, beat / 16, beat / 8, beat / 4].map { $0 * 1000 }   // 1/128 … 1/16 notes
        return options.min { abs($0 - milliseconds) < abs($1 - milliseconds) } ?? milliseconds
    }
}
