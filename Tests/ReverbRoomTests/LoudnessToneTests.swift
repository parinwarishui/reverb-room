import Darwin  // not Foundation: it pulls in a Testing overlay the Command Line Tools lack
import Testing
@testable import ReverbRoom

/// RMS for a level in dBFS.
private func rms(_ dB: Double) -> Float { Float(pow(10, dB / 20)) }

/// Runs `seconds` of updates at the tank's 30 fps.
private func run(_ tone: inout LoudnessTone, _ input: LoudnessTone.Input, seconds: Double) {
    let dt = 1.0 / 30
    for _ in 0..<Int(seconds * 30) { tone.update(input, dt: dt) }
}

@Suite struct LoudnessToneTests {
    @Test func steadyLevelSettlesAtMidTone() {
        for level in [-30.0, -18.0, -8.0] {   // quiet classical to loud pop: same result
            var tone = LoudnessTone()
            run(&tone, .active(rms: rms(level)), seconds: 30)
            #expect(abs(tone.tone - 0.5) < 0.02, "level \(level) dB")
        }
    }

    @Test func louderThanUsualBrightensQuickly() {
        var tone = LoudnessTone()
        run(&tone, .active(rms: rms(-20)), seconds: 30)
        run(&tone, .active(rms: rms(-12)), seconds: 1)
        #expect(tone.tone > 0.85)
    }

    @Test func quieterThanUsualDarkens() {
        var tone = LoudnessTone()
        run(&tone, .active(rms: rms(-20)), seconds: 30)
        run(&tone, .active(rms: rms(-28)), seconds: 4)
        #expect(tone.tone < 0.2)
    }

    @Test func risesFasterThanItFalls() {
        var rising = LoudnessTone()
        run(&rising, .active(rms: rms(-20)), seconds: 30)
        var falling = rising
        run(&rising, .active(rms: rms(-12)), seconds: 0.5)
        run(&falling, .active(rms: rms(-28)), seconds: 0.5)
        #expect(rising.tone - 0.5 > 0.5 - falling.tone)
    }

    @Test func swingIsCappedAtTheRange() {
        var tone = LoudnessTone()
        run(&tone, .active(rms: rms(-40)), seconds: 30)
        run(&tone, .active(rms: rms(0)), seconds: 2)   // +40 dB, far past the ±8 dB range
        #expect(tone.tone <= 1.0)
        #expect(tone.tone > 0.9)
    }

    @Test func aLoudSongSettlesBackOnceItIsTheNewUsual() {
        var tone = LoudnessTone()
        run(&tone, .active(rms: rms(-25)), seconds: 30)
        run(&tone, .active(rms: rms(-10)), seconds: 60)
        #expect(abs(tone.tone - 0.5) < 0.05)
    }

    @Test func silenceDoesNotDragTheAverageDown() {
        var tone = LoudnessTone()
        run(&tone, .active(rms: rms(-20)), seconds: 30)
        let before = tone.baselineDB
        run(&tone, .active(rms: 0), seconds: 5)
        #expect(tone.baselineDB == before)
    }

    @Test func effectsOffRestsAtMidToneAndForgetsTheSong() {
        var tone = LoudnessTone()
        run(&tone, .active(rms: rms(-12)), seconds: 5)
        run(&tone, .idle, seconds: 10)
        #expect(abs(tone.tone - LoudnessTone.restingTone) < 0.01)
        #expect(tone.baselineDB == nil)
    }

    @Test func pausedDims() {
        var tone = LoudnessTone()
        run(&tone, .paused, seconds: 10)
        #expect(abs(tone.tone - LoudnessTone.pausedTone) < 0.01)
    }
}
