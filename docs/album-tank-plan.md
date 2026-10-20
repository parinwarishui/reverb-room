# Plan: album-art "tank"

Status: **built** on 2026-10-15, following this plan. Agreed through a design interrogation the same day. If a later change alters a decision here, update this file and `Decisions.md` together. How it's built is described in [ARCHITECTURE.md](ARCHITECTURE.md), section 8.

## Step 0 results (run against the real app)

- **Redraw:** a `Timer`-driven view does redraw in this app: the tank counted 150 frames every 5 s (30 fps). It drew nothing while the window was covered, as intended.
- **Loudness:** with the effects on, `Meter.rms` read about 0.26–0.30 (around −11 dBFS) on a mastered track, and the tone moved (0.79, 0.70) instead of resting at 0.5.
- **Artwork:** Automation was approved and Music returned the current track's artwork (434 KB). Whether streamed catalogue songs also return artwork wasn't tested (only one track was playing), so the iTunes Search fallback was built as planned rather than dropped.
- **Tests:** Swift Testing works with the Command Line Tools once SwiftPM is pointed at their framework folder (`test.sh`), and `@testable import ReverbRoom` works on the executable target, so no library target was needed. Test files import `Darwin`, not `Foundation`: Foundation pulls in a Testing overlay the Command Line Tools don't ship.

## Goal

A small "fish tank" strip at the top of the main window: soft blobs in the two main colours of the current Apple Music track's album cover, drifting slowly. While the effects are running, the blobs get lighter in the song's loud passages and darker in its quiet ones.

## Decisions

| # | Area | Decision |
| --- | --- | --- |
| 1 | Scope | Apple Music only. Already done: other apps and the system-wide tap were removed. |
| 2 | Artwork source | Script Music with `NSAppleScript`, on the main thread. The first script runs when Music is first seen running; after that, on each `com.apple.Music.playerInfo` track-change notification. Never script Music unless it is already running, because `tell application "Music"` launches it. |
| 3 | Fallbacks | No artwork from Music: look the cover up in Apple's public iTunes Search API by artist and album, cached per album, only as a fallback. Nothing found: neutral blue-grey palette. Automation denied: a footer hint with **Open Automation Settings…**, styled like the existing permission row. A failed fetch keeps the previous palette. The effects never depend on any of this. |
| 4 | Palette | The **2 most evident colours**: shrink the cover to 32 × 32, k-means into about 5 clusters, and keep the two with the largest share weighted by vividness. Near-grey clusters are skipped unless the whole cover is monochrome. *Later changed to 3 colours, one per band (see Decisions.md).* |
| 5 | Loudness | RMS of Music's audio **before** the effects, as a new `rms` atomic next to `peak` in `SSHAtomics`. Measured **relative** to the song's own running average over about 12 s, within ±8 dB. |
| 6 | Look | 6 blobs, 3 per colour, in varied sizes. Slow drift (30–60 s loops) and staggered opacity fades. Loudness changes only the tone. Medium contrast: quiet dims to about 45% brightness, loud reaches 100% with a slight lift towards white. Rise about 0.3 s, fall about 1.5 s, 2 s cross-fade on a track change. Base ("water") is a very dark, tinted version of the darker cover colour. All numbers are named constants in one place. **Changed after the build** (user asked for a stronger response): ±5 dB instead of ±8, brightness 25%–100% with up to 30% white lift, rise 0.15 s and fall 0.8 s, and loudness now also swells the blobs (85%–120% size) and their glow. |
| 7 | Idle | Effects off: the blobs keep drifting at a steady mid-tone, in the cover's colours. Music paused: they dim and slow down. |
| 8 | Placement | **Changed after the build:** a 400 pt wide tank down the full height of the left side, with all controls in a 560 pt column on the right; fixed window 976 × 680 (later 976 × 800, when the Now Playing mini player was added above the controls). Originally a 140 pt strip across the top (window 560 × 780), enlarged at the user's request. Tank styling inside it: dark inner edge, faint glass highlight, vignette. Filter, Reverb and Equalizer stay stacked, EQ sliders 84 pt. |
| 9 | Rendering | SwiftUI `Canvas`, redrawn by a 30 fps main-thread `Timer` that updates a small `@Observable` model (time plus smoothed tone). Blob positions are pure functions of time. The timer pauses when the window is closed, minimised or fully covered. `TimelineView` is avoided because the earlier waveform visualizer built on it never moved. Fallback: Core Animation layers. |
| 10 | Tests | A `ReverbRoomTests` target using Swift Testing (`import Testing`; XCTest isn't installed on this machine). It covers the palette picker, the tone mapper and the smoothing/baseline maths, kept in their own files with no UI or Core Audio dependency. |

## Assumptions (not asked; change here if wrong)

- The tank shows no text. The menu bar panel gets no mini tank. A version that reacts to separate frequency bands was out of scope; **added later** with two filters (bass, treble) instead of an FFT, see `Decisions.md`.
- The audio thread only publishes the raw RMS. Smoothing and the 12 s baseline run in the UI timer.
- New config: `NSAppleEventsUsageDescription` in `Info.plist` and `com.apple.security.automation.apple-events` in `SSH.entitlements`. The HTTPS lookup needs no entitlement under the hardened runtime.
- Automation permission is tied to the code signature, like audio capture, so ad-hoc builds re-prompt after every rebuild. The `SSH Dev` certificate avoids that.
- `README.md`, `docs/ARCHITECTURE.md` and `Decisions.md` are updated in each step that changes behaviour.

## Build order

0. **Checkpoint, before any feature code.**
   - Publish the RMS and log it, with a frame counter, to the `[Reverb Room]` debug stream.
   - Show both in a throwaway label to confirm a `Timer`-driven view really redraws.
   - Fetch artwork for one streamed and one library track and log whether each returns data.
   - Confirm `@testable import ReverbRoom` works for a Swift Testing target (if not, move the pure files into a small library target).
   - Outcome decides whether the iTunes Search fallback is needed and whether option 9's renderer is safe.
1. RMS atomic in `SSHAtomics` and the tone mapper (relative baseline, smoothing), with tests.
2. Palette picker with tests, then the Music scripting layer (running check, notification, artwork fetch, cache).
3. The tank view and model, the window height change and the control trimming.
4. Fallbacks: iTunes Search lookup (if step 0 showed it's needed), neutral palette, the Automation hint.
5. Docs, `Decisions.md`, removing the step-0 debug label, and a final dead-code pass.

## How to check it's done

- The tank animates on its own with the effects off, in the cover's colours, and dims when Music is paused.
- With the effects on, quiet and loud passages of one song visibly darken and lighten it, without flicker.
- Changing track cross-fades the colours. A track with no cover ends up on the fallback (online cover or neutral).
- Denying Automation keeps the effects working and shows the footer hint.
- CPU stays low while the tank runs, and drops to about zero when the window is hidden (checked in Activity Monitor).
- `swift test` passes. The window fits the screen and no label wraps.

## Risks

- **Streamed tracks may return no artwork** through scripting. This is the reason for the fallback; step 0 confirms it.
- **The earlier visualizer failure was never explained.** Step 0 exists to rule it out before building on it.
- **Very light covers** may make the dark base look muddy. The tone constants are meant to be tuned by eye once it runs.
