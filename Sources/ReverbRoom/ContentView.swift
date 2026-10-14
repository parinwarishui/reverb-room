//
//  ContentView.swift
//  The main window.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            StatusCard(model: model)
                .padding(.top, 22)
            presets
                .padding(.top, 18)
            sliders
                .padding(.top, 18)
            nextRoom
                .padding(.top, 22)
            Text("Apple Music keeps the song's speed. Lower the pitch to get the slowed sound.")
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 16)
        .frame(width: 381)
        .foregroundStyle(.white)
        .background(Backdrop().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FOR APPLE MUSIC")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.55))
                Text("Reverb Room")
                    .font(.system(size: 32, weight: .bold))
            }
            Spacer()
            PowerButton(isOn: model.isOn) { model.toggle() }
                .offset(y: -6)
        }
    }

    private var presets: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(Preset.allCases) { preset in
                PresetButton(name: preset.name, selected: model.selectedPreset == preset) {
                    model.apply(preset)
                }
            }
        }
    }

    private var sliders: some View {
        VStack(spacing: 10) {
            SettingSlider(title: "Reverb amount",
                          value: "\(Int((model.settings.amount * 100).rounded()))%",
                          number: $model.settings.amount.rounded(to: 0.01),
                          range: ReverbSettings.amountRange)
            SettingSlider(title: "Room size",
                          value: String(format: "%.1f s", model.settings.size),
                          number: $model.settings.size.rounded(to: 0.1),
                          range: ReverbSettings.sizeRange)
            SettingSlider(title: "Pre-delay",
                          value: "\(Int(model.settings.preDelay.rounded())) ms",
                          number: $model.settings.preDelay.rounded(to: 1),
                          range: ReverbSettings.preDelayRange)
            SettingSlider(title: "Tone",
                          value: model.settings.toneName,
                          number: $model.settings.tone.rounded(to: 0.01),
                          range: ReverbSettings.toneRange)
            SettingSlider(title: "Pitch",
                          value: pitchLabel,
                          number: $model.settings.pitch.rounded(to: 0.1),
                          range: ReverbSettings.pitchRange)
        }
    }

    private var pitchLabel: String {
        let p = (model.settings.pitch * 10).rounded() / 10
        if p == 0 { return "0.0 st" }
        return (p < 0 ? "−" : "+") + String(format: "%.1f st", abs(p))
    }

    private var nextRoom: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next room")
                    .font(.system(size: 15.5, weight: .semibold))
                Text("Muffles the song as if it's playing through a wall")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Toggle("Next room", isOn: $model.settings.nextRoom)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Color(red: 0.62, green: 0.38, blue: 0.86))
        }
    }
}

// MARK: - Pieces

/// The plum-to-indigo background.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.075, blue: 0.10)
            RadialGradient(colors: [Color(red: 0.40, green: 0.15, blue: 0.33), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.17, green: 0.13, blue: 0.29).opacity(0.9), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
    }
}

struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isOn ? Color(red: 0.33, green: 0.16, blue: 0.42) : .white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(isOn ? Color.white : Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(.white.opacity(isOn ? 0 : 0.22), lineWidth: 1))
                .shadow(color: isOn ? Color(red: 0.95, green: 0.6, blue: 0.9).opacity(0.55) : .clear, radius: 14)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isOn)
        .help(isOn ? "Turn reverb off" : "Turn reverb on")
        .accessibilityLabel(isOn ? "Turn reverb off" : "Turn reverb on")
    }
}

struct StatusCard: View {
    let model: Model

    private var dotColor: Color {
        switch model.status {
        case .off: return .white.opacity(0.35)
        case .live: return Color(red: 0.42, green: 0.86, blue: 0.55)
        case .waitingForMusic, .waitingForPlay, .connecting: return Color(red: 0.98, green: 0.78, blue: 0.35)
        case .noSignal, .failed: return Color(red: 1.0, green: 0.55, blue: 0.35)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.status.message)
                    .font(.system(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if case .live = model.status {
                    LevelMeter(model: model)
                }
                if case .noSignal(permission: true) = model.status {
                    Button("Open Privacy Settings…") { AudioCapturePermission.openSettings() }
                        .controlSize(.small)
                }
                if model.status == .waitingForMusic {
                    Button("Open Music") { MusicApp.open() }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.22)))
    }
}

/// Reads only `level`, so the 20 Hz meter updates don't redraw the whole window.
struct LevelMeter: View {
    let model: Model

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.86, blue: 0.55),
                                                  Color(red: 0.95, green: 0.6, blue: 0.9)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * CGFloat(min(1, sqrt(model.level))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct PresetButton: View {
    let name: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(selected ? Color(red: 0.25, green: 0.15, blue: 0.40) : .white)
                .frame(maxWidth: .infinity, minHeight: 31)
                .background(
                    RoundedRectangle(cornerRadius: 15.5, style: .continuous)
                        .fill(selected ? Color.white : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15.5, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0 : 0.14), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 15.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingSlider: View {
    let title: String
    let value: String
    @Binding var number: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Slider(value: $number, in: range)
                .tint(.white)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }
}

extension Binding where Value == Double {
    /// Snaps values written through the binding to a step, so readouts stay tidy
    /// and presets can be matched exactly.
    func rounded(to step: Double) -> Binding<Double> {
        Binding(get: { wrappedValue },
                set: { wrappedValue = ($0 / step).rounded() * step })
    }
}
