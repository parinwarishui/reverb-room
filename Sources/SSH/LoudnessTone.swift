//
//  LoudnessTone.swift
//  Turns RMS readings into the tank's 0...1 tone. Loudness is judged relative to
//  the song's own recent average, so a quiet verse darkens and a chorus lightens
//  in any genre, however loud the track was mastered. Pure value code, unit-tested.
//

import Foundation

struct LoudnessTone {
    /// How a tracker reacts.
    struct Response {
        /// How far back the "usual level" reaches.
        var baselineSeconds: Double
        /// A level this far above (below) the usual level gives full light (dark).
        var rangeDB: Double
        /// How fast the tone follows a rise, and lets go after it.
        var riseSeconds: Double
        var fallSeconds: Double

        /// The song as a whole: a long average, so verses and choruses swell.
        static let song = Response(baselineSeconds: 12, rangeDB: 5, riseSeconds: 0.15, fallSeconds: 0.8)
        /// Drum and hi-hat bands: a short average, an almost instant rise and a
        /// quick fall, so each hit pops and drops instead of blurring together.
        static let hits = Response(baselineSeconds: 2.5, rangeDB: 6, riseSeconds: 0.03, fallSeconds: 0.25)
    }

    let response: Response

    init(_ response: Response = .song) {
        self.response = response
    }

    /// RMS below this is treated as silence (a gap between tracks): it doesn't
    /// pull the song's average down.
    static let silenceDB = -60.0

    /// The song's usual loudness, and the tone when the effects are off.
    static let restingTone = 0.5
    /// Music paused or stopped.
    static let pausedTone = 0.1

    enum Input {
        /// Effects running: the latest RMS of Music's audio (linear, 0...1).
        case active(rms: Float)
        /// Effects off: there's no audio reading, so rest at mid-tone.
        case idle
        /// Music paused or stopped.
        case paused
    }

    private(set) var tone = LoudnessTone.restingTone
    private(set) var baselineDB: Double?

    /// Advances by `dt` seconds and returns the new tone.
    @discardableResult
    mutating func update(_ input: Input, dt: Double) -> Double {
        let target: Double
        switch input {
        case .idle:
            // The next run is a fresh listen; don't carry the old average into it.
            baselineDB = nil
            target = Self.restingTone
        case .paused:
            target = Self.pausedTone
        case .active(let rms):
            let level = 20 * log10(max(Double(rms), 1e-7))
            if level < Self.silenceDB {
                target = Self.restingTone
            } else {
                let previous = baselineDB ?? level
                let baseline = previous + (level - previous) * (1 - exp(-dt / response.baselineSeconds))
                baselineDB = baseline
                let relative = min(max(level - baseline, -response.rangeDB), response.rangeDB)
                target = 0.5 + relative / (2 * response.rangeDB)
            }
        }
        let timeConstant = target > tone ? response.riseSeconds : response.fallSeconds
        tone += (target - tone) * (1 - exp(-dt / timeConstant))
        return tone
    }
}
