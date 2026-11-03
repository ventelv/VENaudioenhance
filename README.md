# VEN Audio Enhance

A free, native macOS app that does what Auphonic does, locally:

- **Live:** cleans up whatever microphone you choose in real time and hands it to every app through a virtual input called **VEN Enhanced Mic**.
- **File mastering:** drop in recordings for an Auphonic-style pass: noise and hum removal, AutoEQ, adaptive leveler, breath reduction, pause cutting, and loudness normalization with a true-peak limiter.

## Using it

1. Open **VEN Audio Enhance** from Applications. A waveform icon appears in the menu bar.
2. The first time, click **Install VEN Enhanced Mic** and enter your password. This adds the virtual mic.
3. In Zoom, QuickTime, OBS, GarageBand or any other app, choose **VEN Enhanced Mic** as the microphone.

In the default "When an app uses it" mode, VEN only opens your real mic while something is recording from VEN Enhanced Mic.

| Control | What it does |
|---|---|
| Mic picker | Which physical mic to clean up. Automatic prefers a dedicated USB mic. |
| Presets | Podcast, Meeting, Streaming, Voice-over, Gentle. Fine-tune them in **Mastering & Settings → Live Mic**. |
| Enhance switch | A/B comparison with the raw mic. |
| Cough key | Hold the on-screen button, or hold **⌃⌥C** in any app, to mute. |
| Record | Saves a *raw* and an *enhanced* WAV to `~/Music/VEN Recordings`. Drop the raw one into File Mastering for the best final result. |
| Headphones | Lets you listen to yourself through the enhanced chain. |

**File Mastering:** drag files into the window. Choose the loudness target (−16 LUFS for podcasts, −14 for YouTube/Spotify, −23 for EBU broadcast and so on), the format (WAV/AIFF/FLAC/ALAC/AAC, plus MP3 after `brew install lame`), and optionally a watch folder that processes new recordings automatically.

## Live signal chain

The chain runs at 48 kHz in 10 ms blocks with about 21 ms of processing delay:

high-pass → hum notches (50/60 Hz auto-detected, up to 16 harmonics) → RNNoise neural noise reduction (strength mix) → voice EQ → de-esser → speech-gated leveler → compressor → pause gate → look-ahead true-peak limiter

## Building (Command Line Tools only, no Xcode needed)

```bash
scripts/build-app.sh          # builds, signs ad-hoc, installs to /Applications
scripts/install-driver.sh     # (re)install just the virtual mic driver
scripts/uninstall-driver.sh   # remove the virtual mic
```

**Signing:** set `VEN_SIGN_IDENTITY` to a self-signed code-signing certificate from Keychain Access. That gives a stable signature, so macOS doesn't ask for microphone permission again after each rebuild.

### Command-line tool

```bash
.build/release/ven-cli selftest                     # DSP checks (loudness meter, limiter, hum, NR, leveler…)
.build/release/ven-cli devices                      # list devices, show which are in use
.build/release/ven-cli process talk.wav --target -16 --format flac --cut-silence
.build/release/ven-cli loudness file.wav            # EBU R128 loudness and true peak
.build/release/ven-cli live --input "RØDE" --seconds 30   # run the live chain with stats
.build/release/ven-cli record --device "VEN Enhanced Mic" --seconds 10 out.wav
```

## Layout

| Path | What's there |
|---|---|
| `Driver/VENMic/` | CoreAudio AudioServerPlugIn: a loopback device. The `vcnt` property counts the apps recording from it. |
| `Sources/VENDSP/` | Real-time C DSP: the chain, limiter, loudness meter, resampler, and the live I/O core with lock-free rings. |
| `Sources/CRNNoise/` | Vendored [RNNoise](https://github.com/xiph/rnnoise) 0.2 (BSD). |
| `Sources/VENCore/` | Swift: devices, live engine and controller, mastering pipeline, audio file I/O, self-test. |
| `Sources/VENApp/` | SwiftUI menu bar app. |
| `Sources/ven-cli/` | Command-line tool. |

## Roadmap

- Transcripts (SRT/VTT/TXT) and automatic cutting of filler words and coughs, using local whisper.cpp, with a cut-review view.
- "Studio" noise engine using DeepFilterNet. It handles keyboard clicks and other changing noises better.
- Multitrack with crossgating and ducking, intro/outro with music ducking, video remux, and chapter markers.
