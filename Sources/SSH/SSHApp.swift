//
//  SSHApp.swift
//  App entry point: a normal window (with a Dock icon) plus a compact menu bar
//  control. Closing the window keeps reverb running from the menu bar.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SSHController()
    let nowPlaying = MusicNowPlaying()
    lazy var tank = TankModel(controller: controller, nowPlaying: nowPlaying)
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
        Window("Reverb Room", id: "main") {
            // Resizable down to a minimum: the sidebar keeps a fixed width so
            // its labels never wrap, and the tank fills the rest (including
            // full screen).
            MainWindow(controller: appDelegate.controller,
                       nowPlaying: appDelegate.nowPlaying,
                       tank: appDelegate.tank)
                .frame(minWidth: 976, minHeight: 800)
        }
        .defaultSize(width: 976, height: 800)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPanel(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}
