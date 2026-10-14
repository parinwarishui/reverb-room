# Reverb Room

Live reverb for any app on macOS: Apple Music, Spotify, YouTube in your browser,
or anything else that plays sound. Pick one or several apps, turn it on, and they
come through a room: Slowed + Reverb, Concert Hall, Cathedral, Studio Room, Next
Room or Vaporwave, or your own settings for amount, room size, pre-delay, tone and
pitch.

It taps the apps directly with a Core Audio process tap (macOS 14.2+), so there's
no virtual audio driver to install and no output device to switch.

## Choosing apps

Under **Add reverb to**, tap an app to select or deselect it; every selected app
gets the same room. Apple Music and any running media apps (Spotify, Safari,
Chrome, Arc, Firefox, Edge, Brave, TV, Podcasts and more) are listed straight
away; other apps appear once they play sound. For YouTube, pick the browser it's
playing in (every tab in that browser gets the reverb). The same list is under
**Apps** in the menu bar menu, and your choice is remembered between launches.

## Build and install

You need macOS 14.2 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install    # build, sign, copy to /Applications, open
./build.sh            # build into build/ and open from there
./build.sh check      # verify the DSP and measure CPU use
./build.sh logs       # stream the running app's log lines
```

The first time you turn it on, macOS asks for **System Audio Recording** access.
Allow it, or turn on Reverb Room in **System Settings › Privacy & Security ›
Screen & System Audio Recording › System Audio Recording Only**.

To keep that permission across rebuilds, create a code-signing certificate named
`Reverb Room Dev` once (Keychain Access › Certificate Assistant › Create a
Certificate…, Self Signed Root, Code Signing). `build.sh` signs with it when it's
there and falls back to ad-hoc signing when it isn't.

## How it sounds the way it does

```
apps ─► process tap ─► pitch shifter ─┬─────────────────── dry ─┐
                                       └─ convolution reverb ─ wet ┴─► wall filter ─► limiter ─► speakers
```

- **Convolution reverb.** Each room is a stereo impulse response generated from
  room size, pre-delay and tone: two dozen early reflections softened by the walls,
  then a dense, decorrelated tail with an RT60 decay and high frequencies that die
  away sooner than lows (air and wall absorption). It's convolved with a
  uniformly partitioned FFT convolver (Accelerate/vDSP). A 10-second cathedral
  uses about 2% of one core.
- **Reverb return EQ.** The response is highpassed at 120 Hz with gentle cuts at
  300 Hz (mud) and 3.2 kHz (harshness), the way an engineer EQs a reverb return,
  so the song's bass and vocals stay clear under a long tail.
- **True stereo.** Each side's reverb also hears 40% of the other side, so a
  hard-panned instrument still fills the whole room.
- **Equal-power mix.** The amount slider crossfades dry and wet at constant power,
  so loudness stays even as you add reverb.
- **Next room.** A 24 dB/octave lowpass at 380 Hz with a small low-end resonance
  and make-up gain: the bass thumps through the wall and the rest is gone.
- **Reverb ducking.** The reverb dips by up to 5 dB under loud passages and
  blooms back in the gaps, so it never piles on top of an already-full master.
- **Lookahead limiter.** Peaks are held at -1 dBFS (the streaming true-peak
  target). The gain is the minimum the next 5 ms needs, averaged over the same
  5 ms, so it's a smooth ramp that's guaranteed to catch every peak without
  distorting it. Release is program-dependent: 60 ms after a lone peak, 600 ms
  when a whole loud section is being limited, so loud songs don't pump.
- **Pitch.** [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch),
  a polyphonic pitch shifter built for music, replaces Apple's phase vocoder,
  which made vocals sound watery and smeared drums. The app keeps the song's
  speed; lower the pitch for the slowed sound. At 0 the shifter is bypassed
  bit-for-bit with no added delay; moving in or out of 0 crossfades over 60 ms.
- **Smooth changes.** Slider moves ramp over one block and room changes crossfade,
  so nothing clicks.

Added latency at 48 kHz is about 26 ms with the pitch at 0 (one 1024-sample
convolution block plus limiter lookahead), and about 175 ms when the pitch is
shifted (the shifter's 150 ms analysis window). That only matters while watching
video, so keep the pitch at 0 for YouTube.

## Troubleshooting

| You see | What to do |
| --- | --- |
| "… is playing but no sound is reaching Reverb Room. Allow it…" | Allow System Audio Recording (see above). |
| "This song isn't reaching Reverb Room…" | The song is playing in Dolby Atmos. In Music, open Settings › Playback and set Dolby Atmos to Off. |
| "Waiting for Spotify. Press play to start." | The app hasn't opened audio yet. Press play. |
| An app isn't in the list | It appears once it has played some sound. |

Closing the window keeps the reverb running; use the waveform icon in the menu
bar to change rooms or apps, turn it off or quit. Quitting, or `kill`, always
un-mutes the apps first.

## Project layout

```
Sources/RRAtomics/     C11 atomics shared with the audio thread
Sources/RRStretch/     C wrapper around Signalsmith Stretch (vendored, MIT, in vendor/)
Sources/ReverbDSP/     Impulse-response generator, FFT convolver, pitch shifter, processor, limiter, filters
Sources/ReverbRoom/    The app: app discovery, tap and pipeline, model, SwiftUI window, menu bar
Sources/dsp-check/     Self-check: convolution accuracy, latency, limiter, pitch, stereo, CPU
```

It uses two private, read-only calls: `TCCAccessPreflight`, to tell a missing
permission apart from a Dolby Atmos song, and
`responsibility_get_pid_responsible_for_pid`, to trace Safari's WebKit audio
process back to Safari. That's fine for a personal app, but the App Store wouldn't
accept it.

## Third-party code

`Sources/RRStretch/vendor/` contains [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)
and [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear), both MIT-licensed
by Signalsmith Audio and included unmodified with their licenses.
