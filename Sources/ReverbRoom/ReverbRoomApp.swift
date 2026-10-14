//
//  ReverbRoomApp.swift
//  App entry: the main window, the menu bar menu, and clean shutdown.
//

import AppKit
import SwiftUI

@main
struct ReverbRoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Reverb Room", id: "main") {
            ContentView(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarMenu(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.isOn ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarMenu: View {
    @Bindable var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.shortMessage)
        Button(model.isOn ? "Turn Off" : "Turn On") { model.toggle() }
        Divider()
        ForEach(Preset.allCases) { preset in
            Toggle(preset.name, isOn: Binding(
                get: { model.selectedPreset == preset },
                set: { if $0 { model.apply(preset) } }
            ))
        }
        Divider()
        Toggle("Muffle Through Wall", isOn: $model.settings.nextRoom)
        Divider()
        Button("Open Reverb Room") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Reverb Room") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = Model()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` or Ctrl+C: stop audio first so Music isn't left muted.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.model.shutdown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }

    /// Closing the window keeps the reverb running from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
