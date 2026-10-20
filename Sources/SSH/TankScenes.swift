//
//  TankScenes.swift
//  Drawing for each visualizer style. Every scene draws into one layer that the
//  tank screen-blends onto its water (and blurs, for Focus); the water, vignette
//  and glass are shared and drawn by `TankView`. Motion comes from TankMotion.swift.
//

import SwiftUI

/// How a band looks right now: the song swells with loudness, bass and treble
/// rest dim and lift and swell on each hit.
struct BandLook {
    var tone: Double
    /// Size multiplier from loudness and the latest hit.
    var scale: Double
    var hit: Double
    var color: Color

    init(_ band: TankBand, in frame: TankModel.Frame) {
        hit = frame.hits[band]
        let level = frame.tones[band]
        tone = band == .song ? level : TankTone.hitTone(level: level, hit: hit)
        scale = TankTone.radiusScale(tone: tone) * (1 + band.hitSwell * hit)
        color = TankTone.blobColor(frame.palette.color(for: band), tone: tone).color
    }
}

enum TankScenes {
    static func draw(_ mode: TankMode, _ frame: TankModel.Frame, core: Double,
                     in layer: inout GraphicsContext, size: CGSize) {
        let looks = Dictionary(uniqueKeysWithValues: TankBand.allCases.map { ($0, BandLook($0, in: frame)) })
        switch mode {
        case .bokeh: bokeh(frame, looks, core: core, in: &layer, size: size)
        case .drops: drops(frame, looks, in: &layer, size: size)
        case .rain: rain(frame, looks, in: &layer, size: size)
        }
    }

    // MARK: Bokeh

    /// Bokeh discs' size, relative to their blob's radius.
    static let bokehSize = 0.25
    /// The share of a disc that's solid colour before its edge fades, at
    /// standard focus; sharper focus widens it further (`core`).
    static let bokehSolid = 0.5

    /// Out-of-focus discs of light, like bokeh in a photo: many small ones (three
    /// per blob), each with a solid middle and a short soft edge.
    private static func bokeh(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook], core: Double,
                              in layer: inout GraphicsContext, size: CGSize) {
        for blob in TankBlobs.bokehLayout(time: frame.time, in: size) {
            let look = looks[blob.band]!
            let radius = blob.radius * bokehSize * look.scale
            let opacity = TankTone.opacity(blob.opacity, tone: look.tone)
            let solid = bokehSolid + (1 - bokehSolid) * core
            let gradient = Gradient(stops: [
                .init(color: look.color.opacity(opacity), location: 0),
                .init(color: look.color.opacity(opacity), location: solid),
                .init(color: look.color.opacity(opacity * 0.35), location: solid + (1 - solid) * 0.55),
                .init(color: look.color.opacity(0), location: 1)
            ])
            layer.fill(Path(ellipseIn: circle(blob.center, radius)),
                       with: .radialGradient(gradient, center: blob.center, startRadius: 0, endRadius: radius))
        }
    }

    // MARK: Water drops

    /// One drop per blob. Each band's drops are blurred together and cut at half
    /// opacity, so its two drops merge and split like liquid where they meet.
    private static func drops(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook],
                              in layer: inout GraphicsContext, size: CGSize) {
        let blobs = Array(TankBlobs.layout(time: frame.time, in: size).enumerated())
        let goo = TankBlobs.scale(of: size) * 0.05
        for band in TankBand.allCases {
            let look = looks[band]!
            layer.drawLayer { drops in
                drops.addFilter(.alphaThreshold(min: 0.5, color: look.color.opacity(0.85)))
                drops.addFilter(.blur(radius: goo))
                drops.drawLayer { inner in
                    for (index, blob) in blobs where blob.band == band {
                        let radius = blob.radius * 0.52 * look.scale
                        for c in DropShape.circles(center: blob.center, radius: radius, time: frame.time,
                                                   seed: Double(index) * 1.618, splash: look.hit) {
                            inner.fill(Path(ellipseIn: circle(c.center, c.radius)), with: .color(.white))
                        }
                    }
                }
            }
        }
    }

    // MARK: Rain

    /// Rings spreading on the water where drops land: the song's steady rain,
    /// a big drop on each kick, a small one on each hi-hat.
    private static func rain(_ frame: TankModel.Frame, _ looks: [TankBand: BandLook],
                             in layer: inout GraphicsContext, size: CGSize) {
        let scale = TankBlobs.scale(of: size)
        for ripple in frame.ripples {
            let look = looks[ripple.band]!
            let center = CGPoint(x: ripple.x * size.width, y: ripple.y * size.height)
            for ring in ripple.rings(at: frame.time, scale: scale) {
                layer.stroke(Path(ellipseIn: circle(center, ring.radius)),
                             with: .color(look.color.opacity(ring.opacity)), lineWidth: ring.lineWidth)
            }
            // The splash where it lands, gone in a moment.
            let age = frame.time - ripple.born
            if age >= 0, age < 0.2 {
                let radius = scale * 0.035 * CGFloat(0.6 + ripple.strength)
                layer.fill(Path(ellipseIn: circle(center, radius)), with: .color(.white.opacity(0.8 * (1 - age / 0.2))))
            }
        }
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
