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

## Adapt to the song

With **Adapt to the song** on (the default), Reverb Room listens to whatever is
playing and fine-tunes the sliders around the room you picked. Sliders the song
is moving show their value in pink with a ✦; your own setting stays underneath,
and dragging a slider sets a new centre for it.

Every 10 ms the audio thread sums the energy below 200 Hz, 200 Hz–4 kHz and above
4 kHz, plus the peak, and queues it lock-free. Twice a second, off the audio
thread, the last 8 seconds are analysed:

| It hears | How | It changes |
| --- | --- | --- |
| Tempo | Autocorrelation of band-wise spectral flux, 60–180 BPM, weighted toward 120 BPM to avoid octave errors | Pre-delay snaps to the nearest 1/128, 1/64, 1/32 or 1/16 note; slower songs get longer rooms |
| Density | Onsets per second (peaks of the onset strength above a median-based threshold) | Busy songs get less reverb and a shorter room, so it doesn't turn to mush |
| Dynamics | Crest factor (peak over RMS), median per second | Squashed, loud masters get less reverb |
| Brightness | Share of energy above 4 kHz (and below 200 Hz) | Bright, harsh mixes get a darker tail; dull ones a brighter tail |

The changes are bounded (amount −18 % to +12 %, room size ×0.6 to ×1.5, tone
±0.25) and eased in over a few seconds. Pitch and Next room are never changed.

## How it sounds the way it does

```
apps ─► tap ─► pitch shifter ─┬────────────────────────────────────────── dry ─┐
                               └─ de-ess + soften ─ convolution reverb ─ wet ─┴─► loudness match ─► wall ─► true-peak limiter ─► speakers
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
- **Clean reverb send.** What feeds the reverb is treated like a mix engineer's
  reverb send: a de-esser turns the band above 5 kHz down by up to 8 dB when "s"
  sounds and hi-hats dominate, so tails don't fill with hiss, and a transient
  softener dips sharp drum hits by up to 6 dB, so drums stay punchy instead of
  smearing. Sustained notes feed the reverb untouched, and the dry song is never
  processed by either.
- **Loudness matching (ITU-R BS.1770 / EBU R128).** K-weighted loudness is
  measured going in and after the mix over R128's 3-second short-term window,
  and the mix is gently corrected (±6 dB at most) to match. More reverb never
  makes a song louder or quieter, and the limiter isn't pushed harder. The
  next-room wall comes after the match, so it still sounds next door.
- **Reverb ducking.** The reverb dips by up to 5 dB under loud passages and
  blooms back in the gaps, so it never piles on top of an already-full master.
- **Lookahead true-peak limiter.** Peaks are held at -1 dBTP, the streaming
  target. Peak detection is 4× oversampled as in BS.1770, so it also catches the
  inter-sample peaks your DAC reconstructs between samples, which a plain sample
  limiter misses and which clip in headphones on loud masters. The gain is the minimum the next 5 ms needs, averaged over the same
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
Sources/ReverbDSP/     Impulse-response generator, FFT convolver, pitch shifter, processor, limiter, filters, song analyzer
Sources/ReverbRoom/    The app: app discovery, tap and pipeline, model, SwiftUI window, menu bar
Sources/dsp-check/     Self-check: convolution, latency, limiter, BS.1770 conformance, pitch, send, song analysis, CPU
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
