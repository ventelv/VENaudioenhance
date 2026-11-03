# VEN Audio Enhance

A free, native macOS app that does what Auphonic does, locally:

- **Live:** cleans up whatever microphone you choose in real time and hands it to every app through a virtual input called **VEN Enhanced Mic**.
- **File mastering:** drop in recordings for an Auphonic-style pass: noise and hum removal, AutoEQ, adaptive leveler, breath reduction, and loudness normalization with a true-peak limiter.
- **Smart cutting and transcripts:** removes "um"/"uh", coughs and long pauses (you can review each cut first), and writes SRT/VTT/TXT/JSON transcripts. Speech recognition runs locally with whisper.cpp.

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

**File Mastering:** drag files into the window or onto the app icon. Choose the loudness target (−16 LUFS for podcasts, −14 for YouTube/Spotify, −23 for EBU broadcast and so on), the format (WAV/AIFF/FLAC/ALAC/AAC, plus MP3 after `brew install lame`), and optionally a watch folder that processes new recordings automatically.

**Cutting and transcripts** (in the Cutting and Transcript sections of the File Mastering settings):

- **Filler words:** whisper.cpp finds "um", "uh", "er", "hmm" and similar words with word-level timing. Each cut is then placed on the audio itself: it runs from the gap before the filler to the gap after it, and leaves one natural pause.
- **Coughs:** short, loud, explosive bursts that contain no words. They are found in the audio before noise reduction.
- **Long pauses:** shortened to the length you choose.
- **Review:** with "Let me review cuts" on, a list opens with every cut. You can hear each one with and without the edit, switch cuts off, or export them as an Audacity label track.
- **Transcripts:** SRT, VTT, TXT and JSON files are saved next to the output. Their timings match the edited audio, and the words that were cut are left out.

Speech recognition needs whisper.cpp (`brew install whisper-cpp`) and a model. Download one in **Setup → Speech recognition**: Large v3 Turbo (compact) is 547 MB and handles 99 languages. Models already on this Mac from other whisper.cpp apps are found automatically.

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
.build/release/ven-cli process talk.wav --cut-fillers --cut-coughs --transcript srt,txt --labels
.build/release/ven-cli transcribe talk.wav --formats srt,vtt   # transcript only
.build/release/ven-cli models                       # installed and downloadable speech models
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
| `Sources/VENCore/` | Swift: devices, live engine and controller, mastering pipeline, cutting, whisper.cpp transcripts, audio file I/O, self-test. |
| `Sources/VENApp/` | SwiftUI menu bar app. |
| `Sources/ven-cli/` | Command-line tool. |

## Roadmap

- "Studio" noise engine using DeepFilterNet. It handles keyboard clicks and other changing noises better.
- Multitrack with crossgating and ducking, intro/outro with music ducking, video remux, and chapter markers.
