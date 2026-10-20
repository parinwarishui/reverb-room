import CoreGraphics
import Darwin  // not Foundation: it pulls in a Testing overlay the Command Line Tools lack
import Testing
@testable import ReverbRoom

@Suite struct DropShapeTests {
    @Test func theDropKeepsChangingShape() {
        let a = DropShape.circles(center: .zero, radius: 100, time: 10, seed: 1, splash: 0)
        let b = DropShape.circles(center: .zero, radius: 100, time: 11, seed: 1, splash: 0)
        #expect(a != b)
    }

    @Test func aKickThrowsTheLobesOutward() {
        func reach(_ splash: Double) -> CGFloat {
            DropShape.circles(center: .zero, radius: 100, time: 10, seed: 1, splash: splash)
                .dropFirst().prefix(DropShape.lobeCount).map { hypot($0.center.x, $0.center.y) }.reduce(0, +)
        }
        #expect(reach(1) > reach(0) * 1.3)
    }

    @Test func theSatelliteBreaksAwayAndComesBack() {
        func satelliteDistance(_ time: Double) -> CGFloat {
            let s = DropShape.circles(center: .zero, radius: 100, time: time, seed: 0, splash: 0).last!
            return hypot(s.center.x, s.center.y)
        }
        let period = DropShape.satellitePeriod
        #expect(satelliteDistance(0) < 60)                // inside the drop
        #expect(satelliteDistance(period / 2) > 140)      // pinched off
        #expect(abs(satelliteDistance(period) - satelliteDistance(0)) < 1)   // back again
    }
}

@Suite struct RainTests {
    @Test func ringsSpreadThenFadeAway() {
        let drop = Ripple(x: 0.5, y: 0.5, born: 10, band: .song, strength: 0.5)
        #expect(drop.rings(at: 9.9, scale: 300).isEmpty)                       // not landed yet
        let early = drop.rings(at: 10.3, scale: 300), late = drop.rings(at: 11.8, scale: 300)
        #expect(early[0].radius < late[0].radius)
        #expect(early[0].opacity > late[0].opacity)
        #expect(drop.rings(at: 10.01 + Ripple.lifetime, scale: 300).isEmpty)   // gone
    }

    @Test func aKickDropIsBiggerThanRain() {
        let rain = Ripple(x: 0.5, y: 0.5, born: 0, band: .song, strength: 0.3)
        let kick = Ripple(x: 0.5, y: 0.5, born: 0, band: .bass, strength: 1)
        #expect(kick.rings(at: 1, scale: 300)[0].radius > rain.rings(at: 1, scale: 300)[0].radius * 1.5)
    }

    @Test func louderSongsRainHarder() {
        #expect(RainField.dropsPerSecond(songTone: 1) > 3 * RainField.dropsPerSecond(songTone: 0.2))
    }

    @Test func kicksAndHatsEachLandADrop() {
        var field = RainField(seed: 7)
        field.update(time: 0, dt: 0, songTone: 0, kick: true, hat: true)
        #expect(field.ripples.map(\.band) == [.bass, .treble])
    }

    @Test func steadyRainMatchesTheRateAndOldDropsGo() {
        var field = RainField(seed: 7)
        let dt = 1.0 / 30
        for frame in 1...300 {   // 10 s
            field.update(time: Double(frame) * dt, dt: dt, songTone: 0.5, kick: false, hat: false)
        }
        // Drops alive at once: the rate times how long each lasts.
        let alive = field.ripples.count
        let expected = RainField.dropsPerSecond(songTone: 0.5) * Ripple.lifetime
        #expect(abs(Double(alive) - expected) <= 3)
        #expect(field.ripples.allSatisfy { 10 - $0.born < Ripple.lifetime })
        #expect(field.ripples.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    @Test func neverMoreThanTheCap() {
        var field = RainField(seed: 1)
        for frame in 0..<100 {
            field.update(time: Double(frame) * 0.01, dt: 0.01, songTone: 1, kick: true, hat: true)
        }
        #expect(field.ripples.count <= RainField.maxRipples)
    }
}

@Suite struct HitCountTests {
    @Test func eachHitIsCountedOnce() {
        var detector = HitDetector(.drums)
        let quiet = Float(pow(10, -30.0 / 20)), loud = Float(pow(10, -22.0 / 20))
        for _ in 0..<60 { detector.update(rms: quiet, dt: 1.0 / 30) }
        for _ in 0..<4 {
            detector.update(rms: loud, dt: 1.0 / 30)
            for _ in 0..<14 { detector.update(rms: quiet, dt: 1.0 / 30) }
        }
        #expect(detector.count == 4)
    }
}
