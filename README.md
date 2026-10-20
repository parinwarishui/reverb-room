# Reverb Room

Live effects for Apple Music on macOS. Turn it on and hear Music through a 10-band equalizer, a low-cut/high-cut filter and a reverb on your speakers or headphones in real time, with an album-art "fish tank" that glows in the current song's colours and a mini player for Music. Music is the only supported app for now.

Reverb Room is a small SwiftUI app with a main window and a menu bar control. It uses Core Audio process taps (macOS 14.2+), so you don't need a virtual audio driver like BlackHole or Loopback, and you don't need to change your output device.

> The project started as "Stadiums Self-Hosted" (SSH). That's why the source folder, the Swift types (`SSHController`, `SSHAtomics`), the entitlements file and the signing certificate name still use the `SSH` prefix.

## Features

- **Apple Music only.** Reverb Room taps Music's audio and nothing else. It follows Music if it starts a new audio process while running.
- **Three effects, each with its own on/off switch:**
  - **Equalizer.** 10 bands (31 Hz to 16 kHz), ±12 dB each, with all 22 of Apple Music's EQ presets (Flat, Acoustic, Bass Booster, … Vocal Booster). Moving a slider switches the preset menu to **Custom**.
  - **Filter.** A low cut (high-pass, 20 Hz–2 kHz) and a high cut (low-pass, 200 Hz–20 kHz). Pull the high cut down for a muffled, "music in the next room" sound.
  - **Reverb.** Room, Chamber, Plate, Hall and Cathedral, with a wet/dry mix from 0 to 100%.
- **Album-art tank.** A tall pane on the left of the window with soft blobs in the three most evident colours of the current song's cover, drifting over dark water. Each part of the music has its own colour, assigned at random for each song. While the effects are on, the blobs react to the music: the two large ones flash and swell on each **kick drum**, the two small ones flick on each **hi-hat or cymbal**, and the two medium ones swell with the song's overall loudness. Hits are sudden jumps in their band, not just loud passages, so a steady bass line doesn't keep the bass blobs lit. Everything is judged against the song's own recent level, so it works the same for loud pop and quiet classical. With the effects off it rests at a steady tone, and it dims when Music is paused. Colours cross-fade when the song changes, and the window background slowly drifts through the same three colours.
- **Mini player.** The current song's cover, "Now Playing" and "Artist – Track", a playhead you can drag to seek, and shuffle, previous, play/pause, next and repeat buttons, laid out like Music's MiniPlayer. Changes made in Music itself (skips, seeks, shuffle) show up within a few seconds.
- **Sensible defaults.** On first launch, Reverb is on (Hall at 35%), and the Equalizer and Filter are off, so the effects only change what you turn on.
- **Menu bar control.** Closing the window doesn't stop the audio. You can turn it on and off, watch the input level and adjust the reverb mix from the menu bar.
- **Remembers your settings.** Every effect setting is kept between launches.
- **Recovers when things change.** It follows changes of the default output device, Bluetooth sample-rate switches, a device disconnecting, and restarts of the macOS audio service. It turns off by itself if Music quits.
- **Never leaves the app muted.** Music's own output is muted while Reverb Room plays it. It comes back when you stop, quit, or kill the process with `kill`/Ctrl+C. If the tap only delivers silence, Reverb Room stops and explains the permission fix. If the effects engine fails, it plays the original audio and then turns itself off.

## Requirements

- macOS 14.2 or later (process taps were added in 14.2)
- Swift 5.9 or later toolchain. The Xcode Command Line Tools are enough: `xcode-select --install`

You don't need an Xcode project.

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
   git clone https://github.com/parinwarishui/reverb-room.git
   cd reverb-room
   ```

4. Optional, but recommended: create the `SSH Dev` signing certificate, so macOS doesn't ask for permission again after every build. See [the one-time setup](#stop-the-permission-prompt-after-every-rebuild-one-time-setup) below.

5. Build and launch:

   ```bash
   ./build.sh
   ```

   If you get `permission denied`, make the script executable with `chmod +x build.sh` and run it again. The first build takes about a minute.

6. Reverb Room opens a window and adds a waveform icon to the menu bar. Start playing something in Music and turn on the switch at the top of the window.

7. The first time, macOS asks two things: whether Reverb Room may **control Music** (to read the current song's artwork) and, when you turn the switch on, for **system audio access**. Click **Allow** for both. Click **Allow**. If no prompt appears, or you hear nothing, turn on Reverb Room in **System Settings › Privacy & Security › Screen & System Audio Recording**, under **System Audio Recording Only**. See [Permission](#permission).

To get updates later, run `git pull`, then `./build.sh` again. The script quits the running copy first.

## Build and run

```bash
./build.sh          # compile (release), wrap into "build/Reverb Room.app", sign, launch
./build.sh debug    # same, then stream the app's log lines into the terminal
swift build         # compile only, to check for errors
./test.sh           # run the unit tests
```

`test.sh` wraps `swift test`. The Command Line Tools include Swift Testing, but SwiftPM doesn't look in their framework folder on its own, so the script passes that path.

`build.sh` stops any running copy first, puts the `ReverbRoom` binary and `Info.plist` into `build/Reverb Room.app`, code-signs it and starts it with `open`.

In VS Code, **Cmd+Shift+B** runs the default _build & run_ task. The _build, run & show logs_, _compile only_ and _run tests_ tasks are in [.vscode/tasks.json](.vscode/tasks.json). With the Swift extension installed, [Package.swift](Package.swift) gives you autocomplete and jump-to-definition.

> **Always launch the `.app` (which `build.sh` does).** If you run the binary directly from a terminal or debugger, macOS gives the audio-capture permission to the terminal, not to Reverb Room.

### Stop the permission prompt after every rebuild (one-time setup)

macOS ties the System Audio Recording permission to the app's code signature. Ad-hoc signing gives each build a new identity, so macOS asks again after every build. To fix this, create a self-signed certificate once:

1. Open **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name: `SSH Dev`, Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**

`build.sh` finds the certificate by name and signs with it (by its SHA-1 hash, so two certificates with the same name give a clear error instead of an "ambiguous" one). After that, the permission survives rebuilds.

The first time, macOS asks whether `codesign` may use the certificate's key. **Allow** asks again on each build. **Always Allow** is more convenient, but it lets any program running as you sign its own app as Reverb Room and so inherit its audio permission. On a machine you share or install untrusted software on, choose **Allow**.

`build.sh` also turns on the hardened runtime (`--options runtime`, entitlements in [SSH.entitlements](SSH.entitlements)). Without it, other code could be injected into Reverb Room with `DYLD_INSERT_LIBRARIES` and use its permission to record system audio.

## Usage

The **tank** fills the whole window (resize it or go full screen and it grows with it); it needs no setup and only animates while the window is on screen. The controls sit in a floating panel on the right. The arrow tab beside it (or ⌃⌘S) tucks it away, and the window becomes a full-screen player like Music's: the big cover, the song's name and the artist over the tank. The panel, from top to bottom:

- **Now Playing.** Cover, song, playhead and player buttons. The buttons need the Automation permission below; without it the panel still shows the song's name, but not the cover or playhead.

- **Transport bar.** Shows what's happening ("Effects on Music", "Playing through AirPods") and has the main on/off switch. The switch starts and stops the whole capture; the effect switches below decide what's applied while it runs.
- **Effects.** The **Filter**, **Reverb** and **Equalizer** modules, each with its own switch. Changes apply instantly while audio is playing.
- **Visualizer** (pinned at the bottom). **Style** picks the visualizer: **Bokeh** (soft out-of-focus discs of light), **Water drops** (merging, wobbling liquid) or **Rain** (ripples on water, with a big drop on each kick). **Focus** goes from a dreamy blur (left) to sharp (right) and **Speed** sets how fast things move; right-click either to reset it.

To use it:

1. Open Music and start playing something. Music can only be tapped after it has made some sound.
2. Turn on the main switch. The first time, macOS asks for system audio access.
3. Turn on the effects you want and adjust them. In the Equalizer, pick a **Preset** or drag the band sliders.

### Permission

Reverb Room asks for two permissions.

**Control Music (Automation).** Used to read the current song, its artwork and the playhead, and for the player buttons. If you say no, the effects still work, the tank uses neutral blue-grey colours and the player buttons are disabled; the bottom of the window then offers **Open Automation Settings…**. To change it later: **System Settings › Privacy & Security › Automation › Reverb Room › Music**.

**System audio access.** Grant access in **System Settings › Privacy & Security › Screen & System Audio Recording**, and turn on Reverb Room under **System Audio Recording Only**. Until access is granted, the bottom of the main window shows the status and an **Open Privacy Settings…** button.

When Music has no artwork for a song (common for songs streamed from the Apple Music catalog rather than your library), Reverb Room looks the cover up in Apple's public iTunes Search API, in your Mac's region's store first and then the US store. That request sends the artist, album and song name to Apple, once per album or single per session, and nothing else.

Reverb Room never records your microphone. Some headsets, such as AirPods, have a mic on the same audio device, so macOS may still show a microphone prompt. Reverb Room keeps the device's input streams turned off.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "Press play in _App_, then turn reverb on." | The app hasn't made any sound yet, so there's nothing to tap. Start playback first. |
| "…the tap only delivered silence…" | The app is playing but the capture is empty. Usually this build doesn't have permission. Allow it in Privacy Settings (see above) and set up the signing certificate so you don't have to allow it again after each build. |
| Asked for permission after every build | You're using ad-hoc signing. Create the `SSH Dev` certificate. |
| The level meter in the menu bar stays flat | No audio is reaching Reverb Room. Run `./build.sh debug` and check the `[Reverb Room]` log lines. |
| Sounds dull or muffled | Check the effect switches. A lowered **High cut** in the Filter, a bass-heavy EQ preset, or a high reverb **Mix** all take the edge off. Turn all three effects off to hear the untouched signal. |
| "Open Music first." | Music isn't running. |
| The tank stays blue-grey | It has no cover colours: Automation is denied (the window's footer says so), the song has no artwork anywhere, or Music isn't playing. Check `./build.sh debug` for `Artwork:` lines. |
| The tank doesn't follow the music | Loudness only drives it while the effects switch is on. With the effects off it rests at a steady tone by design. |

To read the logs from a copy that's already running:

```bash
log stream --style compact --predicate 'eventMessage CONTAINS "[Reverb Room]"'
```

App names, device names and device UIDs appear as `<private>`. Any process can read the unified log, and these reveal what you listen to and on which device.

## Project layout

```
Package.swift            SwiftPM manifest (the ReverbRoom app target plus a small C target, macOS 14.2+)
Info.plist               Bundle metadata and the permission prompt strings
SSH.entitlements         Hardened-runtime entitlements
build.sh                 Build, wrap into .app, sign (hardened runtime), launch
test.sh                  Run the unit tests (Swift Testing)
Sources/SSHAtomics/      C11 atomics for the level meter (peak, RMS) shared with the audio thread
Sources/SSH/
  SSHApp.swift           App entry point, fixed-size window + menu bar, signal handling
  SSHController.swift    UI state, effect settings, presets, start/stop lifecycle, watchdog, observers
  AudioPipeline.swift    Process tap → aggregate device → EQ → filter → reverb → output
  AudioSources.swift     Finds Music's Core Audio processes
  CoreAudio.swift        Core Audio helpers, logging and the permission check
  MusicNowPlaying.swift  Follows Music's current track and playhead, player commands, online cover fallback
  MusicEvents.swift      Raw Apple Events to Music (reads and commands), safe off the main thread
  PlaybackClock.swift    The playhead between readings, time formatting, repeat modes
  CoverSearch.swift      Online cover fallback: which searches to run, which result to trust
  BandSplitter.swift     Bass and treble filters for the drum- and hi-hat-reactive blobs
  HitDetector.swift      Finds kick and hi-hat hits in a band: sudden jumps, not loud stretches
  TankPalette.swift      Cover colours: picking the three most evident, water, cross-fade, window tint, tone
  LoudnessTone.swift     RMS → the tank's tone, relative to the song's recent average
  Tank.swift             The tank: model (30 fps timer), blob layout, the view
  TankMotion.swift       Visualizer styles' motion: water drops, rain ripples
  TankScenes.swift       Drawing for each visualizer style
  Views.swift            Main window and menu bar panel (SwiftUI)
Tests/ReverbRoomTests/   Unit tests for the palette, tone, blob layout, playhead clock, cover search and band filters
```

For the details of how it works, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Limitations

- **Private APIs.** It uses private macOS functions for the permission check (TCC) and to match audio processes to their app. That's fine for a personal or open-source tool, but the App Store would reject it.
- **Music only.** Spotify, browsers and system-wide audio are not supported. They were removed on purpose, to be added back later if wanted.
- **EQ presets are recreated.** Apple doesn't expose Music's EQ presets to other apps. The values are the published iTunes/Music ones, applied with a different EQ engine, so they're close to Music's EQ but not guaranteed to sound identical.
- **Few tests.** Only pure logic is unit-tested (tank, playhead clock). The audio pipeline and the Music scripting are checked by running the app.
- **The tank's loudness needs the effects on.** It reads loudness from the same capture the effects use, so with the main switch off the tank can't follow the music.
- **Placeholder bundle ID.** The ID is `com.yourname.reverb-room`. If you change it, change it in both `Info.plist` and `build.sh`.

## Credits

The tap and aggregate-device approach, the mapping of audio processes to apps, and the Bluetooth drift-compensation handling follow FineTune, Mimir and AudioCap.
