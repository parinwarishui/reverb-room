# Stadiums Self-Hosted (SSH)

Live reverb effects for a "stadium" effect on any app's audio on macOS. Pick an app (Music, Spotify, a browser, or all system audio), turn it on, and hear that app through a Room, Chamber, Plate, Hall or Cathedral reverb on your speakers or headphones in real time.

SSH is a small SwiftUI app with a main window and a menu bar control. It uses Core Audio process taps (macOS 14.2+), so you don't need a virtual audio driver like BlackHole or Loopback, and you don't need to change your output device.

## Features

- **Per-app or system-wide.** Apply reverb to one app, or choose **Everything** to cover all system audio except SSH itself.
- **Helper processes handled.** Chrome plays audio from "Google Chrome Helper" and Safari from a shared WebKit process. SSH maps those back to the app you picked and adds new helper processes while it's running.
- **Five presets and a wet/dry mix.** Room, Chamber, Plate, Hall and Cathedral, with a mix from 0 to 100%. The default on start is set to Hall at 35%.
- **Menu bar control.** Closing the window doesn't stop the reverb. You can turn it on and off and adjust the mix from the menu bar.
- **Remembers your settings.** The source, preset and mix are kept between launches.
- **Recovers when things change.** It follows changes of the default output device, Bluetooth sample-rate switches, a device disconnecting, and restarts of the macOS audio service. It turns off by itself if the app you picked quits.
- **Never leaves the app muted.** The original audio of the tapped app is muted while the reverb plays. It comes back when you stop, quit, or kill the process with `kill`/Ctrl+C. If the tap only delivers silence, SSH stops and explains the permission fix. If the reverb engine fails, SSH plays the original audio and then turns itself off.

## Requirements

- macOS 14.2 or later (as process taps were added in 14.2)
- Swift 5.9 or later toolchain. The Xcode Command Line Tools are enough: `xcode-select --install`

You do not need an Xcode project to get this up and running.

## Quick start

1. Check your macOS version. It must be 14.2 or later:

   ```bash
   sw_vers -productVersion
   ```

2. Install the Xcode Command Line Tools, if you don't have them yet. This gives you `git`, `swift` and `codesign`:

   ```bash
   xcode-select --install
   swift --version     # should print 5.9 or later
   ```

3. Clone the repository and go into it:

   ```bash
   git clone https://github.com/<your-username>/stadiums-self-hosted.git
   cd stadiums-self-hosted
   ```

4. Optional, but recommended: create the `SSH Dev` signing certificate, so macOS doesn't ask for permission again after every build. See [the one-time setup](#stop-the-permission-prompt-after-every-rebuild-one-time-setup) below.

5. Build and launch:

   ```bash
   ./build.sh
   ```

   If you get `permission denied`, make the script executable with `chmod +x build.sh` and run it again. The first build takes about a minute.

6. SSH opens a window and adds a waveform icon to the menu bar. Start playing music in an app such as Music or Spotify, choose that app under **Apply reverb to**, and turn on the switch.

7. The first time, macOS asks for system audio access. Click **Allow**. If no prompt appears, or the reverb stays silent, turn on SSH in **System Settings › Privacy & Security › Screen & System Audio Recording**, under **System Audio Recording Only**. See [Permission](#permission).

To get updates later, run `git pull`, then `./build.sh` again. The script quits the running copy first.

## Build and run

```bash
./build.sh          # compile (release), wrap into build/SSH.app, sign, launch
./build.sh debug    # same, then stream the app's log lines into the terminal
swift build         # compile only, to check for errors
```

`build.sh` stops any running copy first, puts the binary and `Info.plist` into `build/SSH.app`, code-signs it and starts it with `open`.

In VS Code, **Cmd+Shift+B** runs the default _build & run_ task. The _build, run & show logs_ and _compile only_ tasks are in [.vscode/tasks.json](.vscode/tasks.json). With the Swift extension installed, [Package.swift](Package.swift) gives you autocomplete and jump-to-definition.

> **Always launch the `.app` (which `build.sh` does).** If you run the binary directly from a terminal or debugger, macOS gives the audio-capture permission to the terminal, not to SSH.

### Stop the permission prompt after every rebuild (one-time setup)

macOS ties the System Audio Recording permission to the app's code signature. Ad-hoc signing gives each build a new identity, so macOS asks again after every build. To fix this, create a self-signed certificate once:

1. Open **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `SSH Dev`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**

`build.sh` finds the certificate by name and signs with it (by its SHA-1 hash, so two certificates with the same name give a clear error instead of an "ambiguous" one). After that, the permission survives rebuilds.

The first time, macOS asks whether `codesign` may use the certificate's key. **Allow** asks again on each build. **Always Allow** is more convenient, but it lets any program running as you sign its own app as SSH and so inherit SSH's audio permission. On a machine you share or install untrusted software on, choose **Allow**.

`build.sh` also turns on the hardened runtime (`--options runtime`, entitlements in [SSH.entitlements](SSH.entitlements)). Without it, other code could be injected into SSH with `DYLD_INSERT_LIBRARIES` and use its permission to record system audio.

## Usage

1. Start playing something in the app you want to change. An app only appears in the list after it has made some sound.
2. In SSH, choose it under **Apply reverb to**, or choose **Everything**.
3. Turn on the switch. The first time, macOS asks for system audio access.
4. Pick a **Space** preset and adjust the **Mix**.

### Permission

Grant access in **System Settings › Privacy & Security › Screen & System Audio Recording**, and turn on SSH under **System Audio Recording Only**. The main window shows the current status and has an **Open Privacy Settings…** button.

SSH never records your microphone. Some headsets, such as AirPods, have a mic on the same audio device, so macOS may still show a microphone prompt. SSH keeps the device's input streams turned off.

## Troubleshooting

| Symptom                                     | Cause and fix                                                                                                                                                                                                              |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Press play in _App_, then turn reverb on." | The app hasn't made any sound yet, so there's nothing to tap. Start playback first.                                                                                                                                        |
| "…the tap only delivered silence…"          | The app is playing but the capture is empty. Usually this build doesn't have permission. Allow it in Privacy Settings (see above) and set up the signing certificate so you don't have to allow it again after each build. |
| Asked for permission after every build      | You're using ad-hoc signing. Create the `SSH Dev` certificate.                                                                                                                                                             |
| The level meter stays flat                  | No audio is reaching SSH. Run `./build.sh debug` and check the `[SSH]` log lines.                                                                                                                                          |
| "Open _App_ first."                         | The app you picked last time isn't running.                                                                                                                                                                                |

To read the logs from a copy that's already running:

```bash
log stream --style compact --predicate 'eventMessage CONTAINS "[SSH]"'
```

App names, device names and device UIDs appear as `<private>`. Any process can read the unified log, and these reveal what you listen to and on which device.

## Project layout

```
Package.swift            SwiftPM manifest (the app target plus a small C target, macOS 14.2+)
Info.plist               Bundle metadata and the permission prompt strings
SSH.entitlements         Hardened-runtime entitlements
build.sh                 Build, wrap into .app, sign (hardened runtime), launch
Sources/SSHAtomics/      C11 atomics for the level meter shared with the audio thread
Sources/SSH/
  SSHApp.swift    App entry point, window + menu bar, signal handling
  SSHController.swift  UI state, start/stop lifecycle, watchdog, observers
  AudioPipeline.swift    Process tap → aggregate device → reverb → output
  AudioSources.swift     Finds apps that are playing audio, maps helpers to apps
  CoreAudio.swift        Core Audio helpers and the permission check
  Views.swift            Main window and menu bar panel (SwiftUI)
```

For the details of how it works, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Limitations

- **Private APIs.** It uses private macOS functions for the permission check (TCC) and to match helper processes to apps. That's fine for a personal or open-source tool, but the App Store would reject it.
- **Browsers are tapped as a whole.** Every tab gets the reverb, not just one.
- **No tests yet.**
- **Placeholder bundle ID.** The ID is `com.yourname.stadiums-self-hosted`. If you change it, change it in both `Info.plist` and `build.sh`.

## Credits

The tap and aggregate-device approach, the mapping of helper processes to apps, and the Bluetooth drift-compensation handling follow FineTune, Mimir and AudioCap.
