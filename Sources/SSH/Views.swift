//
//  Views.swift
//  Main window (the album-art tank fills it; a floating, collapsible panel on
//  the right holds the player, effects rack and visualizer settings, and hiding
//  it shows a full-window now-playing view) and the compact menu bar panel.
//

import SwiftUI

// MARK: - Typography

/// Helvetica Neue for headers and titles, so the app reads as designed rather
/// than default-System everywhere. Body text (sliders' readouts, source rows,
/// error copy) stays on the system font for legibility at small sizes.
extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Helvetica Neue", size: size).weight(weight)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.display(11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }
}

// MARK: - Main window

struct MainWindow: View {
    @Bindable var controller: SSHController
    let nowPlaying: MusicNowPlaying
    @Bindable var tank: TankModel

    @AppStorage("sidebarShown") private var sidebarShown = true
    /// Follows `!sidebarShown`, but a beat behind it: the panel leaves before the
    /// player rises, and the player sinks before the panel comes back.
    @State private var heroShown = false

    /// Fixed, so labels (effect names, slider readouts) never reflow; the tank
    /// takes whatever room is left.
    static let panelWidth: CGFloat = 540
    static let panelCornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            TankView(model: tank)
                .ignoresSafeArea()
            // With the panel hidden, the window turns into a full-screen player.
            if heroShown {
                NowPlayingHero(nowPlaying: nowPlaying)
                    .padding(48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.offset(y: 40).combined(with: .opacity))
                    // Without this, a ZStack drops a leaving view behind the tank,
                    // so its fade-out is never seen.
                    .zIndex(1)
            }
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 10) {
                panelToggle
                if sidebarShown {
                    panel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(16)
        }
        .onAppear {
            heroShown = !sidebarShown
            controller.refreshPermission()
        }
    }

    /// One after the other, so the two never overlap: hiding slides the panel
    /// out, then fades the player up into place; showing fades the player down
    /// and out, then slides the panel back in.
    private func togglePanel() {
        let panel = Animation.spring(response: 0.35, dampingFraction: 0.9)
        let hero = Animation.easeOut(duration: 0.35)
        if sidebarShown {
            withAnimation(panel) { sidebarShown = false }
            withAnimation(hero.delay(0.25)) { heroShown = true }
        } else {
            withAnimation(.easeIn(duration: 0.2)) { heroShown = false }
            withAnimation(panel.delay(0.15)) { sidebarShown = true }
        }
    }

    /// A small glass tab with a chevron: points right to tuck the panel away,
    /// left to bring it back.
    private var panelToggle: some View {
        let label = sidebarShown ? "Hide controls" : "Show controls"
        return Button(action: togglePanel) {
            Image(systemName: sidebarShown ? "chevron.right" : "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help("\(label) (⌃⌘S)")
        .accessibilityLabel(label)
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    NowPlayingView(nowPlaying: nowPlaying)
                    Divider()
                    transportBar

                    effectsRack
                        .padding(16)

                    footer
                }
            }
            Divider()
            tankControls
                .padding(16)
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity)
        .background { AmbientBackground(model: tank) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator))
        // Cast by a plain shape, not the panel's content, so the shadow isn't
        // redrawn each time the playhead or tint changes.
        .background { shape.fill(.black).shadow(color: .black.opacity(0.35), radius: 20, y: 8) }
    }

    // MARK: Tank controls

    private var tankControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Visualizer")
            HStack(spacing: 10) {
                Text("Style")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Picker("Visualizer style", selection: $tank.mode) {
                    ForEach(TankMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .controlSize(.small)
            // Left blurs every style into a haze; right sharpens it, crisp only at the end.
            TankSlider(title: "Focus", value: $tank.focus, range: TankFocus.range,
                       lowIcon: "circle.dotted", highIcon: "circle.fill",
                       reset: TankFocus.standard)
            TankSlider(title: "Speed", value: $tank.speed, range: TankModel.speedRange,
                       lowIcon: "tortoise", highIcon: "hare",
                       reset: 1)
        }
    }

    // MARK: Transport bar

    private var transportBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.display(18, weight: .semibold))
                Text(statusSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Reverb", isOn: powerBinding(controller))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
                .disabled(controller.phase == .stopping)   // stays usable while starting, so a start can be cancelled
        }
        .padding(16)
        .background(.quaternary.opacity(0.25))
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle: return "Effects off"
        case .starting: return "Starting…"
        case .running: return "Effects on \(SSHController.sourceName)"
        case .stopping: return "Stopping…"
        }
    }

    private var statusSubtitle: String {
        switch controller.phase {
        case .running:
            return controller.outputName.isEmpty ? "Live" : "Playing through \(controller.outputName)"
        default:
            return "Applies to \(SSHController.sourceName)"
        }
    }

    // MARK: Effects rack

    private var effectsRack: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Effects")

            VStack(alignment: .leading, spacing: 12) {
                EffectModuleBox(name: "Filter", isEnabled: $controller.filterEnabled) {
                    LabeledContent("Low cut") {
                        ValueSlider(value: $controller.highPassCutoff, range: 20...2000, unit: "Hz")
                    }
                    LabeledContent("High cut") {
                        ValueSlider(value: $controller.lowPassCutoff, range: 200...20000, unit: "Hz")
                    }
                }

                EffectModuleBox(name: "Reverb", isEnabled: $controller.reverbEnabled) {
                    Picker("Space", selection: $controller.preset) {
                        ForEach(ReverbPresets.all, id: \.value) { item in
                            Text(item.name).tag(item.value)
                        }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Mix") {
                        ValueSlider(value: $controller.wetDryMix, range: 0...100, unit: "%")
                    }
                }

                EffectModuleBox(name: "Equalizer", isEnabled: $controller.eqEnabled) {
                    LabeledContent("Preset") {
                        Picker("Preset", selection: eqPresetBinding) {
                            // Only listed while the sliders don't match a preset, so
                            // the menu always has an item for the current selection.
                            if controller.eqPresetName == SSHController.customEQPresetName {
                                Text(SSHController.customEQPresetName).tag(SSHController.customEQPresetName)
                                Divider()
                            }
                            ForEach(EqualizerPresets.all, id: \.name) { preset in
                                Text(preset.name).tag(preset.name)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(EqualizerBands.frequencies.indices, id: \.self) { i in
                            EQBandSlider(
                                gain: controller.eqGainBinding(band: i),
                                label: Self.frequencyLabel(EqualizerBands.frequencies[i])
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var eqPresetBinding: Binding<String> {
        Binding(
            get: { controller.eqPresetName },
            set: { controller.applyEQPreset(named: $0) }
        )
    }

    private static func frequencyLabel(_ hz: Float) -> String {
        hz >= 1000 ? String(format: "%.0fk", hz / 1000) : String(format: "%.0f", hz)
    }

    // MARK: Footer

    /// Collapses to nothing once audio access is granted and there's no error,
    /// so the common case doesn't reserve space for it.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = controller.errorMessage {
                ErrorBox(message: error, showPermissionHelp: controller.showPermissionHelp)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else if controller.permission != .authorized {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                    Text("System audio access: \(permissionText(controller.permission))")
                        .font(.callout)
                    Spacer()
                    Button("Open Privacy Settings…") {
                        AudioCapturePermission.openSettings()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            } else if nowPlaying.access == .denied {
                HStack(spacing: 10) {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(.secondary)
                    Text("Album art and the player need permission to use Music.")
                        .font(.callout)
                    Spacer()
                    Button("Open Automation Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .padding(.bottom, footerIsEmpty ? 0 : 14)
    }

    private var footerIsEmpty: Bool {
        controller.errorMessage == nil && controller.permission == .authorized && nowPlaying.access != .denied
    }
}

// MARK: - Menu bar

struct MenuBarIcon: View {
    let controller: SSHController

    var body: some View {
        Image(systemName: controller.phase == .running ? "waveform.circle.fill" : "waveform.circle")
    }
}

struct MenuBarPanel: View {
    @Bindable var controller: SSHController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(controller.phase == .running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.phase == .running ? "Reverb on" : "Reverb off")
                        .font(.display(13, weight: .semibold))
                    Text(SSHController.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Reverb", isOn: powerBinding(controller))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(controller.phase == .stopping)   // stays usable while starting, so a start can be cancelled
            }

            if controller.phase == .running {
                LevelMeter(meter: controller.meter)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Mix").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.wetDryMix, in: 0...100)
            }

            Divider()

            HStack {
                Button("Open Reverb Room") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 270)
    }
}

// MARK: - Shared pieces

private func powerBinding(_ controller: SSHController) -> Binding<Bool> {
    Binding(
        get: { controller.phase == .running || controller.phase == .starting },
        set: { isOn in
            if isOn { controller.start() } else { controller.stop() }
        }
    )
}

private func permissionText(_ status: AudioCapturePermission.Status) -> String {
    switch status {
    case .authorized: return "Allowed"
    case .denied: return "Denied"
    case .unknown: return "Not asked yet"
    }
}

/// An effect block's DisclosureGroup label: its name plus its own enable toggle,
/// independent of the main power switch.
struct EffectBlockLabel: View {
    let name: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack {
            Text(name)
                .font(.display(13, weight: .medium))
            Spacer()
            Toggle(name, isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Apple Music mini player: cover, what's playing, the playhead and the controls.
struct NowPlayingView: View {
    let nowPlaying: MusicNowPlaying
    /// Set while the user drags the playhead, so the timer doesn't fight the drag.
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    Text("Now Playing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.display(14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            scrubber
            controls
        }
        .padding(16)
    }

    private var title: String {
        if !nowPlaying.isRunning { return "Music isn't open" }
        if !nowPlaying.hasTrack { return "Nothing playing" }
        if nowPlaying.artist.isEmpty { return nowPlaying.trackName }
        if nowPlaying.trackName.isEmpty { return nowPlaying.artist }
        return "\(nowPlaying.artist) – \(nowPlaying.trackName)"
    }

    private var cover: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var scrubber: some View {
        let duration = nowPlaying.clock.duration
        let position = scrubPosition ?? nowPlaying.clock.position(at: nowPlaying.now)
        return HStack(spacing: 8) {
            Text(PlaybackClock.format(position))
                .frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { position }, set: { scrubPosition = $0 }),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubPosition else { return }
                    nowPlaying.seek(to: target)
                    scrubPosition = nil
                }
            )
            .controlSize(.small)
            .disabled(!nowPlaying.canControl || duration <= 0)
            Text(duration > 0 ? "-" + PlaybackClock.format(duration - position) : "")
                .frame(width: 44, alignment: .leading)
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            PlayerButton(symbol: "shuffle", help: "Shuffle", isOn: nowPlaying.shuffle) {
                nowPlaying.toggleShuffle()
            }
            PlayerButton(symbol: "backward.fill", help: "Previous") { nowPlaying.previous() }
            PlayerButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                         help: nowPlaying.isPlaying ? "Pause" : "Play", size: 24) {
                nowPlaying.playPause()
            }
            PlayerButton(symbol: "forward.fill", help: "Next") { nowPlaying.next() }
            PlayerButton(symbol: nowPlaying.repeatMode == .one ? "repeat.1" : "repeat",
                         help: "Repeat", isOn: nowPlaying.repeatMode != .off) {
                nowPlaying.cycleRepeat()
            }
        }
        .disabled(!nowPlaying.canControl)
    }
}

/// The full-window player shown while the panel is hidden, as in Music's full
/// screen view: the cover with the song's name large and the artist small
/// beside it, in the bottom-left corner.
struct NowPlayingHero: View {
    let nowPlaying: MusicNowPlaying

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.height * 0.4, geo.size.width * 0.3, 300)
            HStack(alignment: .bottom, spacing: 24) {
                cover
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.03, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.display(34, weight: .bold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.display(20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private var title: String {
        if !nowPlaying.isRunning { return "Music isn't open" }
        if !nowPlaying.hasTrack { return "Nothing playing" }
        return nowPlaying.trackName.isEmpty ? nowPlaying.artist : nowPlaying.trackName
    }

    private var subtitle: String {
        guard nowPlaying.isRunning, nowPlaying.hasTrack, !nowPlaying.trackName.isEmpty else { return "" }
        return nowPlaying.artist
    }

    private var cover: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }
}

/// A borderless player-control icon. Toggles (shuffle, repeat) show their "on"
/// state in the accent colour, as in Music.
private struct PlayerButton: View {
    let symbol: String
    let help: String
    var isOn: Bool?
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isOn == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One module in the effects rack: a fixed, always-expanded box with the
/// block's name/toggle header and its controls below — the DAW insert-chain
/// look, no collapsing.
struct EffectModuleBox<Content: View>: View {
    let name: String
    @Binding var isEnabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EffectBlockLabel(name: name, isEnabled: $isEnabled)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// A slider paired with its live numeric readout, used for every effect parameter.
struct ValueSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range)
            Text(Self.readout(value, unit: unit))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

extension ValueSlider {
    /// "20 kHz" rather than "20000 Hz", which doesn't fit the readout column.
    static func readout(_ value: Float, unit: String) -> String {
        if unit == "Hz", value >= 1000 {
            return String(format: "%.1f kHz", value / 1000)
        }
        return String(format: "%.0f %@", value, unit)
    }
}

/// A small visualizer slider, with icons for each end. Right-click to reset.
private struct TankSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let lowIcon: String
    let highIcon: String
    let reset: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Image(systemName: lowIcon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: $value, in: range)
                .accessibilityLabel("Visualizer \(title.lowercased())")
            Image(systemName: highIcon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .controlSize(.small)
        .contextMenu {
            Button("Reset \(title)") { value = reset }
        }
    }
}

/// The panel background: the window colour, slightly see-through, with a light
/// wash of the cover's colours drifting slowly from one to the next. Not a
/// blurring material: that re-blurs the moving tank behind it on every frame,
/// which nearly doubled the GPU load. Its own view, so a tint change redraws
/// only this.
private struct AmbientBackground: View {
    let model: TankModel

    var body: some View {
        let tint = model.tint.color
        LinearGradient(colors: [tint.opacity(AmbientTint.opacity), tint.opacity(AmbientTint.opacity * 0.4)],
                       startPoint: .top, endPoint: .bottom)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
    }
}

/// One vertical fader in the 10-band EQ: gain readout, a rotated Slider (SwiftUI
/// has no native vertical slider), and its frequency label below.
struct EQBandSlider: View {
    @Binding var gain: Float
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%+.0f", gain))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Slider(value: $gain, in: -12...12)
                .frame(width: 84)
                .rotationEffect(.degrees(-90))
                .frame(width: 28, height: 84)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ErrorBox: View {
    let message: String
    let showPermissionHelp: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)

            if showPermissionHelp {
                Text("System Settings › Privacy & Security › Screen & System Audio Recording › turn on Reverb Room under “System Audio Recording Only”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") {
                    AudioCapturePermission.openSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Input level from the tap. If this stays flat while the source is playing,
/// audio isn't reaching the app — the first thing to check when debugging.
struct LevelMeter: View {
    let meter: Meter

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.green)
                        .frame(width: geo.size.width * CGFloat(min(max(meter.peak, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }
}
