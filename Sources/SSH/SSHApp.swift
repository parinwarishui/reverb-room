//
//  SSHApp.swift
//  App entry point: a normal window (with a Dock icon) plus a compact menu bar
//  control. Closing the window keeps reverb running from the menu bar.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SSHController()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`/`pkill`/Ctrl+C skip applicationWillTerminate, so catch those
        // signals too and un-mute the source before exiting.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller.shutdownNow()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdownNow()
    }

    /// Keep running (and keep the menu bar control) when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SSHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SSH", id: "main") {
            MainWindow(controller: appDelegate.controller)
                .frame(minWidth: 420, minHeight: 520)
        }
        .defaultSize(width: 460, height: 660)

        MenuBarExtra {
            MenuBarPanel(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}
