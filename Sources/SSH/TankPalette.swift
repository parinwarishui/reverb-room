//
//  TankPalette.swift
//  Colour logic for the album-art tank: picking the cover's three most evident
//  colours, the dark "water" base, cross-fades, the window tint, and how
//  loudness tones a colour.
//  Pure value code (no AppKit, no Core Audio), so it's covered by unit tests.
//

import Foundation

/// An sRGB colour, each channel 0...1.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 1, g: 1, b: 1)

    /// HSV value: the brightest channel.
    var value: Double { max(r, g, b) }
    /// Chroma (brightest minus darkest channel): how far from grey. 0 is grey.
    var chroma: Double { max(r, g, b) - min(r, g, b) }
    /// Rec. 709 relative luminance (on gamma-encoded values; close enough to rank colours).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func mixed(with other: RGB, amount t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func scaled(by factor: Double) -> RGB {
        RGB(r: clamp01(r * factor), g: clamp01(g * factor), b: clamp01(b * factor))
    }

    func distance(to other: RGB) -> Double {
        let (dr, dg, db) = (r - other.r, g - other.g, b - other.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

// MARK: - Palette

/// What the tank draws with: three blob colours (one per band) and the water
/// behind them.
struct TankPalette: Equatable {
    var first: RGB
    var second: RGB
    var third: RGB
    var water: RGB

    /// Shown when there's no cover (none found, Music closed, Automation denied).
    static let neutral = TankPalette(first: RGB(r: 0.42, g: 0.52, b: 0.66),
                                     second: RGB(r: 0.30, g: 0.36, b: 0.50),
                                     third: RGB(r: 0.50, g: 0.46, b: 0.62))

    /// The water is a very dark, slightly tinted version of the darkest colour.
    init(first: RGB, second: RGB, third: RGB) {
        self.first = first
        self.second = second
        self.third = third
        let darkest = [first, second, third].min { $0.luminance < $1.luminance }!
        self.water = darkest.mixed(with: .black, amount: 0.84)
    }

    init(first: RGB, second: RGB, third: RGB, water: RGB) {
        self.first = first
        self.second = second
        self.third = third
        self.water = water
    }

    var colors: [RGB] { [first, second, third] }

    /// The same colours in another order (`order` is a permutation of 0, 1, 2).
    /// The water doesn't depend on order, so it stays.
    func reordered(_ order: [Int]) -> TankPalette {
        let c = colors
        return TankPalette(first: c[order[0]], second: c[order[1]], third: c[order[2]], water: water)
    }

    /// For cross-fading between two tracks' palettes. `t` 0 is `from`, 1 is `to`.
    static func blend(_ from: TankPalette, _ to: TankPalette, _ t: Double) -> TankPalette {
        let t = clamp01(t)
        return TankPalette(first: from.first.mixed(with: to.first, amount: t),
                           second: from.second.mixed(with: to.second, amount: t),
                           third: from.third.mixed(with: to.third, amount: t),
                           water: from.water.mixed(with: to.water, amount: t))
    }
}

// MARK: - Window tint

/// The window background slowly drifts through the cover's three colours, as a
/// light wash so the controls keep the native light look.
enum AmbientTint {
    /// One full trip through all three colours.
    static let cycleSeconds = 45.0
    /// How strongly the wash covers the window background.
    static let opacity = 0.16
    /// Dark cover colours are raised to this brightness first, so the wash tints
    /// the window instead of greying it.
    static let minimumValue = 0.8

    /// The wash colour at `time`: each colour in turn, eased smoothly into the next.
    static func color(_ palette: TankPalette, time: Double) -> RGB {
        let colors = palette.colors
        let position = (time / cycleSeconds).truncatingRemainder(dividingBy: 1)
        let scaled = (position < 0 ? position + 1 : position) * Double(colors.count)
        let index = Int(scaled) % colors.count
        let t = scaled - Double(Int(scaled))
        let eased = t * t * (3 - 2 * t)   // smoothstep: lingers on each colour
        return brightened(colors[index]).mixed(with: brightened(colors[(index + 1) % colors.count]), amount: eased)
    }

    static func brightened(_ color: RGB) -> RGB {
        color.value < minimumValue ? color.scaled(by: minimumValue / max(color.value, 0.01)) : color
    }
}

// MARK: - Picking the cover's colours

enum PalettePicker {
    /// Clusters below this chroma count as grey and are skipped unless the whole
    /// cover is grey (a black-and-white photo, say).
    static let greyChroma = 0.08
    /// Clusters smaller than this share of the cover are ignored as noise.
    static let minimumShare = 0.03
    /// Two picks closer than this would look like one colour, so the next one moves on.
    static let minimumSeparation = 0.12

    /// The cover's three most evident colours: the clusters with the largest share,
    /// weighted towards vivid ones, each clearly different from the others. A cover
    /// with fewer distinct colours is filled out with lighter and darker shades of
    /// its own. `pixels` is the cover shrunk to about 32 × 32. Nil for an empty
    /// image. Deterministic: the same pixels always give the same answer.
    static func evidentColors(in pixels: [RGB], clusterCount: Int = 6) -> (RGB, RGB, RGB)? {
        guard !pixels.isEmpty else { return nil }
        let clusters = kMeans(pixels, k: min(clusterCount, pixels.count))
            .filter { $0.share >= minimumShare }
        guard !clusters.isEmpty else { return nil }

        let colourful = clusters.filter { $0.color.chroma >= greyChroma }
        let candidates = colourful.isEmpty ? clusters : colourful
        // Area matters most; vividness lifts a smaller bright patch above a big dull one.
        let ranked = candidates.sorted { score($0) > score($1) }
        let alternatives = ranked + clusters.sorted { $0.share > $1.share }

        var picked: [RGB] = []
        for cluster in alternatives where picked.count < 3 && isDistinct(cluster.color, from: picked) {
            picked.append(cluster.color)
        }
        // Too few distinct colours: add shades of the ones found, the most
        // different first.
        while picked.count < 3 {
            let shades = picked.flatMap { [$0.scaled(by: 0.55), $0.mixed(with: .white, amount: 0.45)] }
            let best = shades.max { distance($0, to: picked) < distance($1, to: picked) }!
            picked.append(best)
        }
        return (picked[0], picked[1], picked[2])
    }

    private static func isDistinct(_ color: RGB, from picked: [RGB]) -> Bool {
        picked.allSatisfy { color.distance(to: $0) >= minimumSeparation }
    }

    /// Distance to the nearest of `picked`.
    private static func distance(_ color: RGB, to picked: [RGB]) -> Double {
        picked.map { color.distance(to: $0) }.min() ?? .infinity
    }

    private static func score(_ cluster: Cluster) -> Double {
        cluster.share * (0.35 + cluster.color.chroma)
    }

    struct Cluster {
        var color: RGB
        var share: Double
    }

    /// Plain k-means. Seeded from luminance quantiles instead of at random, so
    /// results are repeatable.
    static func kMeans(_ pixels: [RGB], k: Int, iterations: Int = 12) -> [Cluster] {
        let byLuminance = pixels.sorted { $0.luminance < $1.luminance }
        var centers = (0..<k).map { i in
            byLuminance[min(byLuminance.count - 1, Int((Double(i) + 0.5) / Double(k) * Double(byLuminance.count)))]
        }
        var assignment = [Int](repeating: 0, count: pixels.count)

        for _ in 0..<iterations {
            var changed = false
            for (i, pixel) in pixels.enumerated() {
                var best = 0
                var bestDistance = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = pixel.distance(to: center)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if assignment[i] != best { assignment[i] = best; changed = true }
            }
            var sums = [RGB](repeating: .black, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, pixel) in pixels.enumerated() {
                let c = assignment[i]
                sums[c] = RGB(r: sums[c].r + pixel.r, g: sums[c].g + pixel.g, b: sums[c].b + pixel.b)
                counts[c] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                let n = Double(counts[c])
                centers[c] = RGB(r: sums[c].r / n, g: sums[c].g / n, b: sums[c].b / n)
            }
            if !changed { break }
        }

        var counts = [Int](repeating: 0, count: k)
        for c in assignment { counts[c] += 1 }
        return (0..<k).compactMap { c in
            counts[c] > 0 ? Cluster(color: centers[c], share: Double(counts[c]) / Double(pixels.count)) : nil
        }
    }
}

// MARK: - Loudness tone

enum TankTone {
    /// Brightness at the quietest tone (0) and loudest (1).
    static let dimBrightness = 0.25
    static let fullBrightness = 1.0
    /// Above this tone, loud peaks also lift towards white, by up to `maxWhiteLift`.
    static let whiteLiftStart = 0.7
    static let maxWhiteLift = 0.30
    /// Very dark cover colours are first raised to this brightness, so blobs stay
    /// visible against the dark water.
    static let minimumBlobValue = 0.65

    /// Blob size at the quietest and loudest tone, relative to the blob's own size.
    static let quietScale = 0.85
    static let loudScale = 1.20
    /// Blob opacity multiplier at the quietest and loudest tone (capped at fully opaque).
    static let quietOpacity = 0.7
    static let loudOpacity = 1.3

    /// Louder passages swell the blobs.
    static func radiusScale(tone: Double) -> Double {
        quietScale + (loudScale - quietScale) * clamp01(tone)
    }

    /// Louder passages make the blobs glow more strongly.
    static func opacity(_ base: Double, tone: Double) -> Double {
        clamp01(base * (quietOpacity + (loudOpacity - quietOpacity) * clamp01(tone)))
    }

    /// Between hits, bass and treble blobs rest in this tone range: the low end
    /// when their band is quiet, the high end when it's loud.
    static let hitRestTone = 0.2...0.5
    /// A full hit lifts a blob to this tone: bright with a touch of white, but
    /// not the full white flash, which was too glaring on every beat.
    static let hitPeakTone = 0.85

    /// The tone of a bass or treble blob: resting dim between hits, so a hit
    /// (`hit` 1) stands out by lifting it to `hitPeakTone`.
    static func hitTone(level: Double, hit: Double) -> Double {
        let rest = hitRestTone.lowerBound + (hitRestTone.upperBound - hitRestTone.lowerBound) * clamp01(level)
        return rest + (hitPeakTone - rest) * clamp01(hit)
    }

    /// A blob colour at a given tone (0 quiet ... 0.5 usual ... 1 loud).
    static func blobColor(_ base: RGB, tone: Double) -> RGB {
        let tone = clamp01(tone)
        let lifted = base.value < minimumBlobValue
            ? base.scaled(by: minimumBlobValue / max(base.value, 0.01))
            : base
        let brightness = dimBrightness + (fullBrightness - dimBrightness) * tone
        let toned = lifted.scaled(by: brightness)
        let whiteLift = max(0, (tone - whiteLiftStart) / (1 - whiteLiftStart)) * maxWhiteLift
        return toned.mixed(with: .white, amount: whiteLift)
    }
}
