import Testing
@testable import ReverbRoom

private let red = RGB(r: 0.85, g: 0.10, b: 0.12)
private let blue = RGB(r: 0.10, g: 0.25, b: 0.80)
private let grey = RGB(r: 0.50, g: 0.50, b: 0.50)
private let orange = RGB(r: 0.95, g: 0.55, b: 0.10)
private let green = RGB(r: 0.10, g: 0.70, b: 0.20)

/// A 32 × 32 "cover" made of solid blocks: `parts` gives each colour's pixel count.
private func cover(_ parts: [(RGB, Int)]) -> [RGB] {
    parts.flatMap { Array(repeating: $0.0, count: $0.1) }
}

private func close(_ a: RGB, _ b: RGB, within tolerance: Double = 0.05) -> Bool {
    a.distance(to: b) <= tolerance
}

@Suite struct PalettePickerTests {
    @Test func emptyImageHasNoColours() {
        #expect(PalettePicker.evidentColors(in: []) == nil)
    }

    @Test func picksTheThreeMainColoursLargestFirst() throws {
        let (first, second, third) = try #require(PalettePicker.evidentColors(in: cover([(red, 500), (blue, 324), (green, 200)])))
        #expect(close(first, red))
        #expect(close(second, blue))
        #expect(close(third, green))
    }

    @Test func twoColourCoverAddsADistinctShade() throws {
        let (first, second, third) = try #require(PalettePicker.evidentColors(in: cover([(red, 700), (blue, 324)])))
        #expect(close(first, red))
        #expect(close(second, blue))
        #expect(third.distance(to: first) >= PalettePicker.minimumSeparation)
        #expect(third.distance(to: second) >= PalettePicker.minimumSeparation)
    }

    @Test func vividPatchBeatsALargeGreyArea() throws {
        let (first, _, _) = try #require(PalettePicker.evidentColors(in: cover([(grey, 820), (orange, 204)])))
        #expect(close(first, orange))
    }

    @Test func blackAndWhiteCoverStillGivesTwoDistinctColours() throws {
        let pixels = cover([(.black, 500), (.white, 300), (grey, 224)])
        let (first, second, third) = try #require(PalettePicker.evidentColors(in: pixels))
        #expect(first.distance(to: second) >= PalettePicker.minimumSeparation)
        #expect(third.distance(to: first) >= PalettePicker.minimumSeparation)
        #expect(third.distance(to: second) >= PalettePicker.minimumSeparation)
    }

    @Test func singleColourCoverGetsADarkerAndALighterShade() throws {
        let (first, second, third) = try #require(PalettePicker.evidentColors(in: cover([(red, 1024)])))
        #expect(close(first, red))
        let shades = [second, third]
        #expect(shades.contains { $0.value < first.value })              // darker
        #expect(shades.contains { min($0.r, $0.g, $0.b) > min(red.r, red.g, red.b) })   // paler
    }

    @Test func sameCoverAlwaysGivesTheSameColours() {
        let pixels = (0..<1024).map { i in
            RGB(r: Double(i % 7) / 6, g: Double(i % 11) / 10, b: Double(i % 13) / 12)
        }
        let a = PalettePicker.evidentColors(in: pixels)
        let b = PalettePicker.evidentColors(in: pixels)
        #expect(a?.0 == b?.0 && a?.1 == b?.1 && a?.2 == b?.2)
    }

    @Test func tinySpecksAreIgnored() throws {
        // 1% green noise must not become one of the three colours.
        let (first, second, third) = try #require(PalettePicker.evidentColors(in: cover([(red, 600), (blue, 414), (green, 10)])))
        #expect(!close(first, green) && !close(second, green) && !close(third, green))
    }
}

@Suite struct TankPaletteTests {
    @Test func waterIsADarkVersionOfTheDarkestColour() {
        let palette = TankPalette(first: orange, second: blue, third: .white)
        #expect(palette.water.value < 0.2)
        // Tinted, not plain black: it keeps blue's hue.
        #expect(palette.water.b > palette.water.r)
    }

    @Test func blendGoesFromOnePaletteToTheOther() {
        let a = TankPalette(first: red, second: blue, third: green)
        let b = TankPalette.neutral
        #expect(TankPalette.blend(a, b, 0) == a)
        #expect(TankPalette.blend(a, b, 1) == b)
        let middle = TankPalette.blend(a, b, 0.5).first
        #expect(close(middle, a.first.mixed(with: b.first, amount: 0.5), within: 1e-9))
        #expect(close(TankPalette.blend(a, b, 0.5).third, a.third.mixed(with: b.third, amount: 0.5), within: 1e-9))
    }

    @Test func reorderingKeepsTheColoursAndTheWater() {
        let palette = TankPalette(first: red, second: blue, third: green)
        let shuffled = palette.reordered([2, 0, 1])
        #expect(shuffled.first == green && shuffled.second == red && shuffled.third == blue)
        #expect(shuffled.water == palette.water)
    }
}

@Suite struct AmbientTintTests {
    private let palette = TankPalette(first: red, second: blue, third: green)

    @Test func visitsEachColourInTurn() {
        let third = AmbientTint.cycleSeconds / 3
        #expect(close(AmbientTint.color(palette, time: 0), AmbientTint.brightened(red), within: 1e-9))
        #expect(close(AmbientTint.color(palette, time: third), AmbientTint.brightened(blue), within: 1e-9))
        #expect(close(AmbientTint.color(palette, time: 2 * third), AmbientTint.brightened(green), within: 1e-9))
        // …and loops back to the first.
        #expect(close(AmbientTint.color(palette, time: AmbientTint.cycleSeconds), AmbientTint.brightened(red), within: 1e-9))
    }

    @Test func changesSlowly() {
        // A fifth of a second (one tint update) never moves the colour visibly.
        for step in 0..<300 {
            let t = Double(step) * 0.2
            #expect(AmbientTint.color(palette, time: t).distance(to: AmbientTint.color(palette, time: t + 0.2)) < 0.05)
        }
    }

    @Test func darkColoursAreLiftedSoTheWashTints() {
        let nearlyBlack = RGB(r: 0.10, g: 0.02, b: 0.05)
        #expect(AmbientTint.brightened(nearlyBlack).value >= AmbientTint.minimumValue - 1e-9)
    }
}

@Suite struct TankToneTests {
    @Test func louderIsBrighter() {
        let quiet = TankTone.blobColor(blue, tone: 0)
        let usual = TankTone.blobColor(blue, tone: 0.5)
        let loud = TankTone.blobColor(blue, tone: 1)
        #expect(quiet.value < usual.value)
        #expect(usual.value < loud.value)
    }

    @Test func louderSwellsAndGlows() {
        #expect(TankTone.radiusScale(tone: 0) < TankTone.radiusScale(tone: 0.5))
        #expect(TankTone.radiusScale(tone: 0.5) < TankTone.radiusScale(tone: 1))
        #expect(TankTone.opacity(0.6, tone: 0) < TankTone.opacity(0.6, tone: 1))
        #expect(TankTone.opacity(0.85, tone: 1) <= 1)   // never past fully opaque
    }

    @Test func quietIsDimmedToTheDimBrightness() {
        let bright = RGB(r: 1, g: 0.2, b: 0.2)
        #expect(abs(TankTone.blobColor(bright, tone: 0).value - TankTone.dimBrightness) < 1e-9)
    }

    @Test func loudPeaksLiftTowardsWhite() {
        let loud = TankTone.blobColor(blue, tone: 1)
        // The darkest channel rises: the colour gets paler, not just brighter.
        #expect(min(loud.r, loud.g, loud.b) > min(blue.r, blue.g, blue.b))
    }

    @Test func veryDarkCoverColoursStayVisible() {
        let nearlyBlack = RGB(r: 0.05, g: 0.02, b: 0.03)
        #expect(TankTone.blobColor(nearlyBlack, tone: 0.5).value > 0.25)
    }
}
