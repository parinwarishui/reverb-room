//
//  TankMotion.swift
//  How things move in each visualizer style: the water drops' wobble and the
//  rain's ripples. Pure value code
//  (positions are 0...1 of the tank, or points for a given size), unit-tested.
//  Drawing is in TankScenes.swift.
//

import CoreGraphics
import Foundation

/// The visualizer styles, picked from the menu under the tank.
enum TankMode: String, CaseIterable, Identifiable {
    case bokeh, drops, rain

    var id: Self { self }

    /// How strongly Focus blurs this style. Small or thin things vanish under a
    /// blur that suits big soft shapes, so each style gets one that looks about
    /// as hazy as the others at the same slider position.
    var blurAmount: Double {
        switch self {
        case .bokeh: return 0.4
        case .drops: return 0.6
        case .rain: return 0.28
        }
    }

    var title: String {
        switch self {
        case .bokeh: return "Bokeh"
        case .drops: return "Water drops"
        case .rain: return "Rain"
        }
    }
}

/// A repeatable 0..<1 number for `index`, so "random" drops and wobbles look the
/// same every time they're drawn at the same moment (SplitMix64).
func tankHash(_ index: Int, salt: UInt64 = 0) -> Double {
    var z = UInt64(bitPattern: Int64(index)) &+ (salt &+ 1) &* 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(UInt64(1) << 53)
}

// MARK: - Water drops

/// A water drop drawn as overlapping circles that are blurred together and cut
/// at half opacity, so they merge like liquid with surface tension. Lobes
/// orbiting the core reshape the drop all the time; a satellite droplet drifts
/// off, pinches away and rejoins.
enum DropShape {
    struct Circle: Equatable {
        var center: CGPoint
        var radius: CGFloat
    }

    static let lobeCount = 4
    /// How long a satellite droplet takes to break away and come back.
    static let satellitePeriod = 9.0

    /// `splash` (0...1, a kick) throws the lobes outward.
    static func circles(center: CGPoint, radius: CGFloat, time: Double, seed: Double,
                        splash: Double) -> [Circle] {
        var circles = [Circle(center: center, radius: radius * 0.62)]
        for j in 0..<lobeCount {
            let k = Double(j)
            let angle = seed * 7 + k * .pi / 2 + 0.8 * sin(time * (0.35 + 0.11 * k) + seed + k)
            let reach = radius * CGFloat((0.36 + 0.16 * sin(time * (0.6 + 0.17 * k) + seed * 3 + k)) * (1 + 0.45 * splash))
            let size = radius * CGFloat(0.42 + 0.07 * sin(time * (0.5 + 0.13 * k) + seed * k))
            circles.append(Circle(center: CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle)),
                                  radius: size))
        }
        // The satellite: sits inside, drifts out until it pinches off, drifts back.
        let phase = (time / satellitePeriod + seed).truncatingRemainder(dividingBy: 1)
        let out = pow(sin(.pi * phase), 2)
        let angle = seed * 11 + time * 0.15
        let reach = radius * CGFloat(0.5 + 1.0 * out)
        circles.append(Circle(center: CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle)),
                              radius: radius * 0.2))
        return circles
    }
}

// MARK: - Rain

/// One raindrop's ripple on the water.
struct Ripple: Equatable {
    /// Where it landed, 0...1 of the tank.
    var x: Double
    var y: Double
    /// When it landed (tank time).
    var born: Double
    var band: TankBand
    /// 0...1: how big and bright its rings get.
    var strength: Double

    struct Ring: Equatable {
        var radius: CGFloat
        var opacity: Double
        var lineWidth: CGFloat
    }

    static let lifetime = 2.6
    static let ringCount = 4

    /// The rings at `time`, outermost first: they spread fast, then slow, and
    /// fade as they go. Empty before the drop lands and after it has died away.
    func rings(at time: Double, scale: CGFloat) -> [Ring] {
        let age = time - born
        guard age >= 0, age < Self.lifetime else { return [] }
        let progress = age / Self.lifetime
        let reach = scale * CGFloat(0.30 + 0.62 * strength) * CGFloat(pow(progress, 0.55))
        let fade = pow(1 - progress, 1.6) * (0.45 + 0.55 * strength)
        return (0..<Self.ringCount).compactMap { k in
            let radius = reach * (1 - 0.22 * CGFloat(k))
            guard radius > 1 else { return nil }
            return Ring(radius: radius, opacity: fade * (1 - 0.25 * Double(k)),
                        lineWidth: CGFloat(1.5 + 4.5 * (1 - progress)))
        }
    }
}

/// The rain: steady drops whose rate follows the song's loudness, a big drop on
/// each kick and a small one on each hi-hat. Stateful (drops land on hits), so
/// it lives in the tank model. Seeded, so tests can replay it.
struct RainField: Equatable {
    static let maxRipples = 48

    private(set) var ripples: [Ripple] = []
    private var seed: UInt64
    /// Drops owed so far: the rate is fractional, so whole drops land as it adds up.
    private var owed = 0.0

    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.seed = seed
    }

    /// Steady drops per second at a song tone (0 quiet ... 1 loud).
    static func dropsPerSecond(songTone: Double) -> Double {
        0.8 + 5 * pow(min(max(songTone, 0), 1), 2)
    }

    mutating func update(time: Double, dt: Double, songTone: Double, kick: Bool, hat: Bool) {
        ripples.removeAll { time - $0.born >= Ripple.lifetime }
        owed += Self.dropsPerSecond(songTone: songTone) * dt
        while owed >= 1 {
            owed -= 1
            land(time: time, band: .song, strength: 0.2 + 0.35 * random())
        }
        if kick { land(time: time, band: .bass, strength: 1) }
        if hat { land(time: time, band: .treble, strength: 0.45) }
        if ripples.count > Self.maxRipples { ripples.removeFirst(ripples.count - Self.maxRipples) }
    }

    private mutating func land(time: Double, band: TankBand, strength: Double) {
        ripples.append(Ripple(x: 0.08 + 0.84 * random(), y: 0.08 + 0.84 * random(),
                              born: time, band: band, strength: strength))
    }

    private mutating func random() -> Double {
        seed &+= 1
        return tankHash(Int(bitPattern: UInt(truncatingIfNeeded: seed)), salt: 99)
    }
}
