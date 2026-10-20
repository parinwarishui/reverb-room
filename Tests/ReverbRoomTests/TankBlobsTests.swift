import CoreGraphics
import Testing
@testable import ReverbRoom

@Suite struct TankBlobsTests {
    private let size = CGSize(width: 400, height: 648)

    @Test func blobsKeepTheirShareOfTheTankAtAnyShape() {
        // Same area, different shape: same blob sizes.
        let tall = TankBlobs.layout(time: 0, in: CGSize(width: 200, height: 800)).map(\.radius)
        let wide = TankBlobs.layout(time: 0, in: CGSize(width: 800, height: 200)).map(\.radius)
        #expect(tall == wide)
    }

    @Test func sixBlobsTwoPerBand() {
        let blobs = TankBlobs.layout(time: 0, in: size)
        #expect(blobs.count == 6)
        for band in TankBand.allCases {
            #expect(blobs.filter { $0.band == band }.count == 2)
        }
    }

    @Test func bokehHasThreeDiscsPerBlobAllInsideTheTank() {
        for step in 0..<200 {
            let discs = TankBlobs.bokehLayout(time: Double(step) * 1.7, in: size)
            #expect(discs.count == 18)
            #expect(discs.allSatisfy { (0...size.width).contains($0.center.x) && (0...size.height).contains($0.center.y) })
        }
    }

    @Test func bokehCopiesDontSitOnTopOfEachOther() {
        let discs = TankBlobs.bokehLayout(time: 10, in: size)
        let blobs = TankBlobs.layout(time: 10, in: size).count
        for i in 0..<blobs {
            let a = discs[i].center, b = discs[i + blobs].center, c = discs[i + 2 * blobs].center
            #expect(hypot(a.x - b.x, a.y - b.y) > 1 && hypot(a.x - c.x, a.y - c.y) > 1)
        }
    }

    @Test func eachBandHasItsOwnColour() {
        let palette = TankPalette(first: .white, second: .black, third: RGB(r: 1, g: 0, b: 0))
        let colours = TankBand.allCases.map { palette.color(for: $0) }
        #expect(Set(colours.map { "\($0)" }).count == 3)
    }

    @Test func bassBlobsAreTheBiggestAndTrebleTheSmallest() {
        let blobs = TankBlobs.layout(time: 0, in: size)
        let smallestBass = blobs.filter { $0.band == .bass }.map(\.radius).min()!
        let largestTreble = blobs.filter { $0.band == .treble }.map(\.radius).max()!
        #expect(smallestBass > largestTreble)
    }

    @Test func blobsDriftOverTime() {
        let now = TankBlobs.layout(time: 100, in: size)
        let later = TankBlobs.layout(time: 105, in: size)
        let moved = zip(now, later).filter { abs($0.center.x - $1.center.x) + abs($0.center.y - $1.center.y) > 1 }
        #expect(moved.count == now.count)
    }

    @Test func centresStayInsideTheTankAndOpacityInRange() {
        for second in stride(from: 0.0, through: 600, by: 0.5) {
            for blob in TankBlobs.layout(time: second, in: size) {
                #expect(blob.radius > 0)
                #expect((0...size.width).contains(blob.center.x))
                #expect((0...size.height).contains(blob.center.y))
                #expect(TankBlobs.opacityRange.contains(blob.opacity))
            }
        }
    }
}

@Suite struct TankFocusTests {
    @Test func everyStepOfTheSliderChangesTheBlur() {
        let steps = stride(from: 0.0, through: 1.0, by: 0.1).map { TankFocus.blurRadius(focus: $0, scale: 300) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 })   // strictly less blur each step
        #expect(TankFocus.blurRadius(focus: 0.9, scale: 300) > 2)        // still visibly soft near the end
        #expect(TankFocus.blurRadius(focus: 1, scale: 300) == 0)         // sharp only at the very end
    }

    @Test func blobsTightenInTheSharpHalf() {
        #expect(TankFocus.core(focus: 0) == 0)
        #expect(TankFocus.core(focus: TankFocus.standard) == 0)
        let partly = TankFocus.core(focus: 0.75), fully = TankFocus.core(focus: 1)
        #expect(partly > 0 && partly < fully)
        #expect(fully < 1)   // a thin soft rim stays, so edges don't alias
    }
}
