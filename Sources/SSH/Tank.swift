//
//  Tank.swift
//  The album-art "fish tank": a visualizer over dark water in the current
//  cover's three colours, one per band (bass, the whole song, treble). It has
//  several styles (TankMode: bokeh, water drops, rain), drawn in
//  TankScenes.swift. It also drives the window's slowly shifting background tint.
//
//  A main-thread Timer advances `TankModel.frame` 30 times a second and the view
//  redraws from it. Blob positions are pure functions of time (`TankBlobs`), so
//  there's no animation state to drift out of sync. The timer does nothing while
//  the window is hidden, minimised or covered.
//

import AppKit
import Observation
import QuartzCore
import SwiftUI

/// What a blob follows: the song's overall loudness, or one frequency band.
enum TankBand: CaseIterable {
    case song, bass, treble

    /// How much a full hit swells this band's blobs, on top of their loudness size.
    var hitSwell: Double {
        switch self {
        case .song: return 0
        case .bass: return 0.15
        case .treble: return 0.10
        }
    }
}

/// One tone per band (0 quiet ... 0.5 usual ... 1 loud).
struct BandTones: Equatable {
    var song = LoudnessTone.restingTone
    var bass = LoudnessTone.restingTone
    var treble = LoudnessTone.restingTone

    subscript(band: TankBand) -> Double {
        switch band {
        case .song: return song
        case .bass: return bass
        case .treble: return treble
        }
    }
}

/// The drum pulse per band (see `HitDetector`): 1 just after a hit, dying to 0.
/// The song as a whole has no hits.
struct BandHits: Equatable {
    var bass = 0.0
    var treble = 0.0

    subscript(band: TankBand) -> Double {
        switch band {
        case .song: return 0
        case .bass: return bass
        case .treble: return treble
        }
    }
}

@Observable
final class TankModel {
    struct Frame: Equatable {
        var time = 0.0
        var tones = BandTones()
        var hits = BandHits()
        var palette = TankPalette.neutral
        /// Rain style only: the ripples on the water.
        var ripples: [Ripple] = []
    }

    static let framesPerSecond = 30.0
    static let crossFadeSeconds = 2.0
    /// Drift speed while Music is paused, relative to normal.
    static let pausedSpeed = 0.35
    /// RMS above this counts as Music playing even if no notification said so
    /// (e.g. Automation was denied and the app launched mid-song).
    static let audibleRMS: Float = 1e-4

    /// Everything the view draws. Assigned once per tick, so each tick is one redraw.
    private(set) var frame = Frame()

    /// The window's background wash (see `AmbientTint`). Updated a few times a
    /// second, not every frame: it changes too slowly to need more, and each
    /// change redraws the window background.
    private(set) var tint = AmbientTint.color(.neutral, time: 0)

    /// The visualizer style. Set by the menu under the tank.
    var mode: TankMode = TankMode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .bokeh {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    /// How sharp the blobs are (see `TankFocus`). Set by the slider under the tank.
    var focus: Double = TankModel.saved(Keys.focus, default: TankFocus.standard, in: TankFocus.range) {
        didSet { UserDefaults.standard.set(focus, forKey: Keys.focus) }
    }

    /// How fast the blobs drift, relative to normal. Set by the slider under the tank.
    var speed: Double = TankModel.saved(Keys.speed, default: 1, in: TankModel.speedRange) {
        didSet { UserDefaults.standard.set(speed, forKey: Keys.speed) }
    }

    static let speedRange = 0.2...3.0
    /// Ticks between tint updates (5 a second at 30 fps).
    static let tintInterval = 6

    private enum Keys {
        static let focus = "tankFocus"
        static let speed = "tankSpeed"
        static let mode = "tankMode"
    }

    private static func saved(_ key: String, default value: Double, in range: ClosedRange<Double>) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Double, stored.isFinite else { return value }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    @ObservationIgnored private let controller: SSHController
    @ObservationIgnored private let nowPlaying: MusicNowPlaying
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: CFTimeInterval?
    @ObservationIgnored private var songTone = LoudnessTone(.song)
    @ObservationIgnored private var bassTone = LoudnessTone(.hits)
    @ObservationIgnored private var trebleTone = LoudnessTone(.hits)
    @ObservationIgnored private var bassHits = HitDetector(.drums)
    @ObservationIgnored private var trebleHits = HitDetector(.hats)
    @ObservationIgnored private var rain = RainField()
    @ObservationIgnored private var fadeFrom = TankPalette.neutral
    @ObservationIgnored private var fadeTo = TankPalette.neutral
    @ObservationIgnored private var fadeProgress = 1.0
    /// The last palette Music reported, before shuffling, to notice the next change.
    @ObservationIgnored private var reportedPalette = TankPalette.neutral
    @ObservationIgnored private var tintTime = 0.0
    @ObservationIgnored private var ticks = 0

    init(controller: SSHController, nowPlaying: MusicNowPlaying) {
        self.controller = controller
        self.nowPlaying = nowPlaying
    }

    func attach(to window: NSWindow?) { self.window = window }

    func start() {
        guard timer == nil else { return }
        lastTick = nil
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - (lastTick ?? now), 0), 0.1)   // a long gap (e.g. sleep) isn't a jump
        lastTick = now
        guard isOnScreen else { return }

        let reported = nowPlaying.palette
        if reported != reportedPalette {
            reportedPalette = reported
            fadeFrom = TankPalette.blend(fadeFrom, fadeTo, fadeProgress)
            // Which colour goes to which band is left to chance, so it varies
            // from song to song.
            fadeTo = reported.reordered([0, 1, 2].shuffled())
            fadeProgress = 0
        }
        fadeProgress = min(1, fadeProgress + dt / Self.crossFadeSeconds)

        let running = controller.phase == .running
        let meter = controller.meter
        let rms = running ? meter.rms : 0
        let playing = nowPlaying.isPlaying || rms > Self.audibleRMS
        func input(_ level: Float) -> LoudnessTone.Input {
            !playing ? .paused : running ? .active(rms: level) : .idle
        }
        let tones = BandTones(song: songTone.update(input(rms), dt: dt),
                              bass: bassTone.update(input(running ? meter.bassRMS : 0), dt: dt),
                              treble: trebleTone.update(input(running ? meter.trebleRMS : 0), dt: dt))
        let listening = running && playing
        let kicks = bassHits.count, hats = trebleHits.count
        let hits = BandHits(bass: bassHits.update(rms: listening ? meter.bassRMS : nil, dt: dt),
                            treble: trebleHits.update(rms: listening ? meter.trebleRMS : nil, dt: dt))

        let palette = TankPalette.blend(fadeFrom, fadeTo, fadeProgress)
        let sceneDT = dt * speed * (playing ? 1 : Self.pausedSpeed)
        let time = frame.time + sceneDT
        if mode == .rain {
            rain.update(time: time, dt: sceneDT, songTone: tones.song,
                        kick: bassHits.count > kicks, hat: trebleHits.count > hats)
        }
        frame = Frame(time: time,
                      tones: tones,
                      hits: hits,
                      palette: palette,
                      ripples: mode == .rain ? rain.ripples : [])

        tintTime += dt
        ticks += 1
        if ticks % Self.tintInterval == 0 {
            tint = AmbientTint.color(palette, time: tintTime)
        }
    }
}

// MARK: - Blob layout

/// Where each blob is at a given time. Pure, so it's easy to test and has no state.
enum TankBlobs {
    struct Blob {
        var center: CGPoint
        var radius: CGFloat
        var opacity: Double
        var band: TankBand
    }

    /// One looping path per blob. Periods are 30–60 s and differ per axis and per
    /// blob, so the blobs never line up and the pattern doesn't visibly repeat.
    private struct Path {
        let band: TankBand
        let radius: Double        // × tank scale (see `layout`)
        let periodX: Double, phaseX: Double
        let periodY: Double, phaseY: Double
        let fadePeriod: Double, fadePhase: Double
    }

    /// Two blobs per band, both in that band's cover colour: the large ones follow
    /// the bass (kick drums), the medium ones the song, the small ones the treble
    /// (hi-hats, cymbals).
    private static let paths: [Path] = [
        Path(band: .bass, radius: 1.25, periodX: 53, phaseX: 0.0, periodY: 37, phaseY: 1.1, fadePeriod: 19, fadePhase: 0.0),
        Path(band: .bass, radius: 1.05, periodX: 41, phaseX: 2.1, periodY: 47, phaseY: 0.4, fadePeriod: 23, fadePhase: 1.7),
        Path(band: .song, radius: 0.85, periodX: 59, phaseX: 4.0, periodY: 31, phaseY: 2.6, fadePeriod: 17, fadePhase: 3.1),
        Path(band: .song, radius: 0.95, periodX: 34, phaseX: 1.3, periodY: 56, phaseY: 3.9, fadePeriod: 29, fadePhase: 0.9),
        Path(band: .treble, radius: 0.70, periodX: 47, phaseX: 5.2, periodY: 43, phaseY: 5.0, fadePeriod: 21, fadePhase: 4.4),
        Path(band: .treble, radius: 0.75, periodX: 38, phaseX: 3.3, periodY: 51, phaseY: 1.8, fadePeriod: 26, fadePhase: 2.5)
    ]

    static let opacityRange = 0.40...0.85

    /// Half the geometric mean of the sides: blobs keep the same share of the
    /// tank whether it's a wide strip or a tall pane.
    static func scale(of size: CGSize) -> Double {
        0.5 * (size.width * size.height).squareRoot()
    }

    static func layout(time: Double, in size: CGSize) -> [Blob] {
        let scale = scale(of: size)
        return paths.map { p in
            let x = 0.5 + 0.40 * sin(2 * .pi * time / p.periodX + p.phaseX)
            let y = 0.5 + 0.40 * sin(2 * .pi * time / p.periodY + p.phaseY)
            let fade = 0.5 + 0.5 * sin(2 * .pi * time / p.fadePeriod + p.fadePhase)
            return Blob(center: CGPoint(x: x * size.width, y: y * size.height),
                        radius: p.radius * scale,
                        opacity: opacityRange.lowerBound + (opacityRange.upperBound - opacityRange.lowerBound) * fade,
                        band: p.band)
        }
    }
}

extension TankBlobs {
    /// How many discs the bokeh draws per blob.
    static let bokehCopies = 3

    /// The bokeh's discs: three per blob. Each copy follows the same paths, but
    /// shifted in time and mirrored (left–right, then top–bottom), so the copies
    /// never trail one another or line up symmetrically.
    static func bokehLayout(time: Double, in size: CGSize) -> [Blob] {
        let shifts: [(time: Double, mirrorX: Bool, mirrorY: Bool)] = [(0, false, false), (23.7, true, false), (47.3, false, true)]
        return shifts.prefix(bokehCopies).flatMap { shift in
            layout(time: time + shift.time, in: size).map { blob in
                var blob = blob
                if shift.mirrorX { blob.center.x = size.width - blob.center.x }
                if shift.mirrorY { blob.center.y = size.height - blob.center.y }
                return blob
            }
        }
    }
}

// MARK: - Focus

/// How sharp the visualizer is: 0 is a dreamy haze, 1 is crisp. The blur
/// shrinks steadily across the whole slider, for every style, and is gone only
/// at 1. In the sharp half, blobs also get a solid core, so their soft edges
/// tighten too.
enum TankFocus {
    static let range = 0.0...1.0
    /// The middle of the slider: softly blurred.
    static let standard = 0.5
    /// Blur radius at focus 0, relative to the tank scale.
    static let maxBlur = 0.12
    /// At focus 1, this share of each blob's radius is solid before the edge fades.
    static let maxCore = 0.9

    static func blurRadius(focus: Double, scale: Double) -> Double {
        let haze = 1 - min(max(focus, 0), 1)
        return haze * maxBlur * scale
    }

    /// Where each blob's solid core ends, as a share of its radius.
    static func core(focus: Double) -> Double {
        max(0, (focus - standard) / (1 - standard)) * maxCore
    }
}

// MARK: - View

struct TankView: View {
    let model: TankModel
    @Environment(\.displayScale) private var displayScale

    /// Pixels per point to draw the tank at. Everything in it is soft, and a
    /// blur hides pixels smaller than itself, so a blurred tank is drawn at a
    /// lower resolution and scaled up: a full-screen Retina tank has 4× the
    /// pixels of a 1× one, and its blur passes cost in proportion. Only a
    /// nearly sharp tank gets the screen's full resolution.
    static func renderScale(mode: TankMode, focus: Double, size: CGSize, screen: CGFloat) -> CGFloat {
        let blur = TankFocus.blurRadius(focus: focus, scale: TankBlobs.scale(of: size)) * mode.blurAmount
        if blur >= 12 { return min(screen, 0.5) }
        if blur >= 3 { return min(screen, 1) }
        return screen
    }

    var body: some View {
        // Read here, not inside the Canvas closure, so every new frame is a tracked
        // change that redraws the view.
        let frame = model.frame
        let focus = model.focus
        let mode = model.mode
        // Edge to edge: the tank fills the window, so it has no rim of its own.
        GeometryReader { geo in
            // Drawn into a smaller canvas (in the tank's own coordinates, scaled
            // down) and scaled back up to fill the view.
            let k = Self.renderScale(mode: mode, focus: focus, size: geo.size, screen: displayScale) / displayScale
            Canvas { context, size in
                context.scaleBy(x: k, y: k)
                Self.draw(frame, mode: mode, focus: focus, in: &context, size: geo.size)
            }
            .frame(width: geo.size.width * k, height: geo.size.height * k)
            .drawingGroup()
            .scaleEffect(1 / k, anchor: .topLeading)
        }
        .background(WindowReader { model.attach(to: $0) })
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .accessibilityHidden(true)
    }

    private static func draw(_ frame: TankModel.Frame, mode: TankMode, focus: Double,
                             in context: inout GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let blur = TankFocus.blurRadius(focus: focus, scale: TankBlobs.scale(of: size)) * mode.blurAmount

        context.fill(Path(bounds), with: .color(frame.palette.water.color))

        // Screen blending makes overlaps glow instead of muddying: within the
        // layer, and the layer onto the water.
        context.blendMode = .screen
        context.drawLayer { layer in
            if blur > 0 { layer.addFilter(.blur(radius: blur)) }
            layer.blendMode = .screen
            TankScenes.draw(mode, frame, core: TankFocus.core(focus: focus), in: &layer, size: size)
        }
        context.blendMode = .normal

        // Vignette: the edges of the water fall off into shadow.
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        context.fill(Path(bounds), with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.5)]),
            center: center, startRadius: size.height * 0.4,
            endRadius: (size.width * size.width + size.height * size.height).squareRoot() / 2))

        // Glass highlight across the top.
        let highlight = CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.42)
        context.fill(Path(highlight), with: .linearGradient(
            Gradient(colors: [.white.opacity(0.10), .white.opacity(0)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: highlight.height)))
    }
}

extension TankPalette {
    /// Bass blobs take the first colour, the song's the second, treble's the third.
    func color(for band: TankBand) -> RGB {
        switch band {
        case .bass: return first
        case .song: return second
        case .treble: return third
        }
    }
}

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

/// Reports the window the tank is in, so the model can pause while it's hidden.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {}

    final class WindowTrackingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
