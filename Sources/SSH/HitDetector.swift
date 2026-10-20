//
//  HitDetector.swift
//  Finds drum hits in one band's level. A hit is a sudden jump above the band's
//  last fraction of a second, not a loud stretch, so a steady bass line or a
//  wall of cymbals doesn't keep the blobs lit: each kick or hi-hat gives its
//  own pulse, which then dies away. Pure value code, unit-tested.
//

import Foundation

struct HitDetector {
    struct Response {
        /// A jump this many dB above the recent level counts as a hit.
        var thresholdDB: Double
        /// A jump this far past the threshold gives a full pulse. Smaller hits
        /// give at least half of one.
        var fullHitDB: Double
        /// How far back "recent" reaches.
        var averageSeconds: Double
        /// How fast a pulse eases in: quick enough to land on the beat, not so
        /// quick that the blob snaps.
        var attackSeconds: Double
        /// How fast a pulse dies away.
        var decaySeconds: Double
        /// After a hit, ignore new ones for this long, so one hit can't fire twice.
        var holdSeconds: Double

        /// Kick drums: hits a few times a second, each pulse long enough to see.
        static let drums = Response(thresholdDB: 2.5, fullHitDB: 6, averageSeconds: 0.35,
                                    attackSeconds: 0.06, decaySeconds: 0.22, holdSeconds: 0.12)
        /// Hi-hats and cymbals: faster, shorter flicks.
        static let hats = Response(thresholdDB: 2.5, fullHitDB: 6, averageSeconds: 0.2,
                                   attackSeconds: 0.03, decaySeconds: 0.08, holdSeconds: 0.06)
    }

    let response: Response

    init(_ response: Response) {
        self.response = response
    }

    /// Up to 1 just after a hit, dying away to 0.
    private(set) var pulse = 0.0
    /// What the pulse eases towards: set by a hit, then decaying.
    private var target = 0.0
    /// Hits found so far, so a caller can tell when a new one lands.
    private(set) var count = 0
    private var averageDB: Double?
    private var sinceHit = Double.infinity

    /// Advances by `dt` seconds with the band's latest RMS (linear), or nil when
    /// there's no audio reading (effects off, Music paused). Returns the pulse.
    @discardableResult
    mutating func update(rms: Float?, dt: Double) -> Double {
        // Hold the target while the pulse eases up to it, then let it die away.
        if sinceHit >= response.attackSeconds {
            target *= exp(-dt / response.decaySeconds)
        }
        sinceHit += dt
        detect(rms, dt: dt)
        // Ease up towards a hit; follow the decay down directly.
        if target > pulse {
            pulse += (target - pulse) * (1 - exp(-dt / response.attackSeconds))
        } else {
            pulse = target
        }
        return pulse
    }

    private mutating func detect(_ rms: Float?, dt: Double) {
        guard let rms else {
            averageDB = nil   // the next listen starts fresh
            return
        }
        let level = 20 * log10(max(Double(rms), 1e-7))
        // Silence (a gap between songs) is neither a hit nor part of the average.
        guard level >= LoudnessTone.silenceDB else { return }

        let average = averageDB ?? level
        let jump = level - average
        if jump > response.thresholdDB, sinceHit >= response.holdSeconds {
            let strength = 0.5 + 0.5 * min(1, (jump - response.thresholdDB) / response.fullHitDB)
            target = max(target, strength)
            sinceHit = 0
            count += 1
        }
        averageDB = average + (level - average) * (1 - exp(-dt / response.averageSeconds))
    }
}
