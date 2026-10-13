//
//  Views.swift
//  Main window (System Settings-style grouped form) and the compact menu bar panel.
//

import SwiftUI
import AVFoundation

// MARK: - Main window

struct MainWindow: View {
    @Bindable var controller: SSHController

    var body: some View {
        Form {
            statusSection
            sourceSection
            reverbSection
            accessSection
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshPermission() }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.title3.weight(.semibold))
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
            .padding(.vertical, 4)

            if controller.phase == .running {
                LevelMeter(meter: controller.meter)
                    .padding(.vertical, 2)
            }

            if let error = controller.errorMessage {
                ErrorBox(message: error, showPermissionHelp: controller.showPermissionHelp)
            }
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .idle: return "Reverb off"
        case .starting: return "Starting…"
        case .running: return "Reverb on \(controller.selectedSourceName)"
        case .stopping: return "Stopping…"
        }
    }

    private var statusSubtitle: String {
        switch controller.phase {
        case .running:
            return controller.outputName.isEmpty ? "Live" : "Playing through \(controller.outputName)"
        default:
            return "Applies to \(controller.selectedSourceName)"
        }
    }

    // MARK: Source picker

    private var sourceSection: some View {
        Section {
            SourceRow(
                name: "Everything",
                detail: "All system audio",
                icon: nil,
                systemImage: "speaker.wave.3.fill",
                isPlaying: false,
                isSelected: controller.isEverythingSelected
            ) {
                controller.selectedSourceID = SSHController.everythingID
            }

            ForEach(controller.sources) { source in
                SourceRow(
                    name: source.name,
                    detail: nil,
                    icon: source.icon,
                    systemImage: nil,
                    isPlaying: source.isPlaying,
                    isSelected: controller.selectedSourceID == source.id
                ) {
                    controller.selectedSourceID = source.id
                }
            }

            // Keep the remembered choice visible even when that app isn't open or
            // hasn't played anything yet.
            if !controller.isEverythingSelected,
               !controller.sources.contains(where: { $0.id == controller.selectedSourceID }) {
                SourceRow(
                    name: controller.selectedSourceName,
                    detail: "Not producing audio yet",
                    icon: AudioSources.icon(forBundleID: controller.selectedSourceID),
                    systemImage: nil,
                    isPlaying: false,
                    isSelected: true
                ) {}
                .opacity(0.6)
            }
        } header: {
            Text("Apply reverb to")
        } footer: {
            Text("Apps show up here once they've played some sound. Browsers are tapped as a whole, so every tab gets reverb.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Reverb controls

    private var reverbSection: some View {
        Section("Reverb") {
            Picker("Space", selection: $controller.preset) {
                ForEach(ReverbPresets.all, id: \.value) { item in
                    Text(item.name).tag(item.value)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Mix") {
                HStack(spacing: 10) {
                    Slider(value: $controller.wetDryMix, in: 0...100)
                    Text("\(Int(controller.wetDryMix.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Permission

    private var accessSection: some View {
        Section {
            LabeledContent("System audio access") {
                Text(permissionText(controller.permission))
                    .foregroundStyle(controller.permission == .authorized ? Color.secondary : Color.orange)
            }
            if controller.permission != .authorized {
                Button("Open Privacy Settings…") {
                    AudioCapturePermission.openSettings()
                }
            }
        }
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
                        .font(.headline)
                    Text(controller.selectedSourceName)
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
                Button("Open SSH") {
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

struct SourceRow: View {
    let name: String
    let detail: String?
    let icon: NSImage?
    let systemImage: String?
    let isPlaying: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: systemImage ?? "app")
                            .resizable()
                            .scaledToFit()
                            .padding(3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isPlaying {
                    Text("Playing")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(Color.green)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Text("System Settings › Privacy & Security › Screen & System Audio Recording › turn on SSH under “System Audio Recording Only”.")
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
