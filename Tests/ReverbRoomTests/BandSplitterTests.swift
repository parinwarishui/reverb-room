import Darwin  // not Foundation: it pulls in a Testing overlay the Command Line Tools lack
import Testing
@testable import ReverbRoom

private let sampleRate = 48_000.0

/// One second of a stereo sine at `frequency`, interleaved L R L R.
private func stereoSine(_ frequency: Double, amplitude: Float = 0.5) -> [Float] {
    (0..<Int(sampleRate)).flatMap { i -> [Float] in
        let s = amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
        return [s, s]
    }
}

/// Band mean squares over the last half of the signal (after the filters settle).
private func bands(of samples: [Float]) -> (bass: Float, treble: Float) {
    var splitter = BandSplitter(sampleRate: sampleRate)
    let frames = samples.count / 2
    return samples.withUnsafeBufferPointer { buffer in
        _ = splitter.meanSquares(buffer.baseAddress!, frameCount: frames / 2, channels: 2)
        return splitter.meanSquares(buffer.baseAddress! + frames, frameCount: frames / 2, channels: 2)
    }
}

@Suite struct BandSplitterTests {
    // A sine of amplitude 0.5 has a mean square of 0.125.
    @Test func kickDrumRangeLandsInTheBassBand() {
        let (bass, treble) = bands(of: stereoSine(60))
        #expect(bass > 0.1)
        #expect(treble < 0.0001)
    }

    @Test func hiHatRangeLandsInTheTrebleBand() {
        let (bass, treble) = bands(of: stereoSine(12_000))
        #expect(treble > 0.1)
        #expect(bass < 0.0001)
    }

    @Test func midrangeIsInNeither() {
        let (bass, treble) = bands(of: stereoSine(1_000))
        #expect(bass < 0.005)
        #expect(treble < 0.005)
    }

    @Test func silenceGivesNothing() {
        let (bass, treble) = bands(of: [Float](repeating: 0, count: 96_000))
        #expect(bass == 0 && treble == 0)
    }
}

@Suite struct HitResponseTests {
    private func rms(_ dB: Double) -> Float { Float(pow(10, dB / 20)) }

    /// A steady level, then a 0.1 s hit 6 dB louder, at 30 fps.
    private func hit(_ response: LoudnessTone.Response) -> (peak: Double, after: Double) {
        var tone = LoudnessTone(response)
        let dt = 1.0 / 30
        for _ in 0..<300 { tone.update(.active(rms: rms(-30)), dt: dt) }
        var peak = 0.0
        for _ in 0..<3 { peak = max(peak, tone.update(.active(rms: rms(-24)), dt: dt)) }
        for _ in 0..<15 { tone.update(.active(rms: rms(-30)), dt: dt) }   // 0.5 s later
        return (peak, tone.tone)
    }

    @Test func aDrumHitPopsAndDrops() {
        let (peak, after) = hit(.hits)
        #expect(peak > 0.85)
        #expect(after < 0.6)
    }

    @Test func theSongResponseBarelyNoticesASingleHit() {
        #expect(hit(.song).peak < hit(.hits).peak - 0.2)
    }
}

@Suite struct HitDetectorTests {
    private func rms(_ dB: Double) -> Float { Float(pow(10, dB / 20)) }
    private let dt = 1.0 / 30

    /// Feeds `beats` kicks (one frame 8 dB up) over a steady level, `gap` frames apart.
    /// Returns, per kick, the pulse right at the kick, its peak before the next
    /// kick, and the pulse just before the next kick.
    private func kicks(_ beats: Int, gap: Int, response: HitDetector.Response = .drums)
        -> (atHit: [Double], peak: [Double], beforeNext: [Double]) {
        var detector = HitDetector(response)
        for _ in 0..<60 { detector.update(rms: rms(-30), dt: dt) }
        var atHit: [Double] = [], peak: [Double] = [], beforeNext: [Double] = []
        for _ in 0..<beats {
            let first = detector.update(rms: rms(-22), dt: dt)
            atHit.append(first)
            var highest = first, last = first
            for _ in 0..<(gap - 1) {
                last = detector.update(rms: rms(-30), dt: dt)
                highest = max(highest, last)
            }
            peak.append(highest)
            beforeNext.append(last)
        }
        return (atHit, peak, beforeNext)
    }

    @Test func everyKickGivesItsOwnPulse() {
        // 120 BPM: a kick every 15 frames.
        let (_, peak, beforeNext) = kicks(8, gap: 15)
        #expect(peak.allSatisfy { $0 > 0.75 })
        #expect(beforeNext.allSatisfy { $0 < 0.3 })   // mostly faded before the next one
    }

    @Test func aKickEasesInInsteadOfSnapping() {
        let (atHit, peak, _) = kicks(1, gap: 15)
        #expect(atHit[0] < 0.75 * peak[0])
        #expect(atHit[0] > 0.25)   // but still visibly on the beat
    }

    @Test func fastHiHatsStillSeparate() {
        // 16th notes at 120 BPM: one every 4 frames.
        let (_, peak, beforeNext) = kicks(16, gap: 4, response: .hats)
        #expect(peak.allSatisfy { $0 > 0.6 })
        #expect(zip(peak, beforeNext).allSatisfy { $1 < 0.7 * $0 })
    }

    @Test func aSteadyLoudBandIsNotAHit() {
        var detector = HitDetector(.drums)
        for _ in 0..<60 { detector.update(rms: rms(-30), dt: dt) }
        // A bass line comes in 2 dB louder and stays: below the threshold, no pulse.
        for _ in 0..<60 { detector.update(rms: rms(-28), dt: dt) }
        #expect(detector.pulse < 0.01)
    }

    @Test func aBigJumpThatStaysFadesOut() {
        var detector = HitDetector(.drums)
        for _ in 0..<60 { detector.update(rms: rms(-30), dt: dt) }
        var highest = 0.0
        for _ in 0..<5 { highest = max(highest, detector.update(rms: rms(-15), dt: dt)) }
        #expect(highest > 0.8)
        for _ in 0..<45 { detector.update(rms: rms(-15), dt: dt) }   // 1.5 s at the new level
        #expect(detector.pulse < 0.1)
    }

    @Test func noAudioMeansNoHits() {
        var detector = HitDetector(.drums)
        for _ in 0..<30 { detector.update(rms: nil, dt: dt) }
        #expect(detector.pulse == 0)
        // Coming back from silence isn't a hit either: the first reading sets the level.
        #expect(detector.update(rms: rms(-20), dt: dt) == 0)
    }
}

@Suite struct HitToneTests {
    @Test func blobsRestDimAndAHitLiftsThemToFull() {
        #expect(TankTone.hitTone(level: 0.5, hit: 0) <= TankTone.hitRestTone.upperBound)
        #expect(TankTone.hitTone(level: 1, hit: 0) <= TankTone.hitRestTone.upperBound)
        #expect(abs(TankTone.hitTone(level: 0, hit: 1) - TankTone.hitPeakTone) < 1e-9)
        #expect(TankTone.hitPeakTone < 1)   // never the full white flash
        #expect(TankTone.hitTone(level: 0.5, hit: 0.5) > TankTone.hitTone(level: 0.5, hit: 0))
    }

    @Test func onlyBassAndTrebleSwellOnHits() {
        #expect(TankBand.song.hitSwell == 0)
        #expect(TankBand.bass.hitSwell > 0 && TankBand.treble.hitSwell > 0)
    }
}
