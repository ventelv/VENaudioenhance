# Security and privacy

VEN Audio Enhance runs entirely on your Mac. This page explains what it can reach, how it protects that, and how to check a copy before you trust it.

## What it accesses

| What | Why | When |
|---|---|---|
| Microphone | To clean up your voice live | Only while an app records from VEN Enhanced Mic (or you set it to Always) |
| Admin password, once | To install the VEN Enhanced Mic driver into `/Library/Audio/Plug-Ins/HAL` | When you click **Install VEN Enhanced Mic** |
| Files you open, drop in, or pick as a watch folder | To master them | When you add them |
| `~/Music/VEN Recordings` | Where live recordings are saved | When you press Record |
| The internet | Only to download a speech model from Hugging Face | When you click Download in Setup |

There is no analytics, no telemetry, no account, and no cloud processing. Audio and transcripts never leave the Mac.

## How it's protected

- **Hardened Runtime.** The app and `ven-cli` are signed with Apple's Hardened Runtime, so another program can't inject code into them (for example with `DYLD_INSERT_LIBRARIES`) to borrow their microphone permission. The only entitlement is microphone input, plus permission to load the self-built DeepFilterNet library when you've added it.
- **Code loading.** The app loads its optional DeepFilterNet library only from inside its own bundle, never from a folder other programs can write to.
- **Driver.** The virtual mic is a small C plug-in (`Driver/VENMic/VENMic.c`) that runs inside macOS's audio service. It checks the size of every property request and keeps all audio copies inside its own buffer. It has no network or file access. Any app can play audio into its output side, the same as BlackHole or Loopback, so only use apps you trust while recording.
- **Installer.** The install command passes the app's location through AppleScript's `quoted form of`, so no folder name can be turned into a command that runs as root. It clears macOS's download quarantine mark only on the installed copy of the driver, which you've just approved with your password.
- **Downloads.** Speech models come from a fixed revision of `huggingface.co/ggerganov/whisper.cpp` over HTTPS, and each file must match its published SHA-256 before it's kept.
- **External programs.** `whisper-cli` and `lame` are run from fixed Homebrew paths with argument lists. Nothing goes through a shell.
- **Third-party code.** RNNoise is vendored in `Sources/CRNNoise` (BSD licence, see its `COPYING`). DeepFilterNet is built from a pinned commit with `cargo --locked`, so its dependencies are exactly the ones in its `Cargo.lock`.

## Installing safely

The safest way is to build it yourself from this repository. You can read every line that runs, and the build signs it on your Mac:

```bash
git clone https://github.com/ventelv/VENaudioenhance.git
cd VENaudioenhance
scripts/build-app.sh
```

Release builds are signed ad hoc, not with a paid Apple Developer ID, and they aren't notarized. macOS will refuse to open a downloaded copy until you allow it in **System Settings → Privacy & Security → Open Anyway**. Only do that for a download from this repository's Releases page, after checking its SHA-256 against the one listed with the release:

```bash
shasum -a 256 VEN-Audio-Enhance.zip
```

To remove everything: open **Mastering & Settings → Setup** and click **Uninstall…** next to VEN Enhanced Mic (it asks for your admin password), then move the app to the Trash. Speech models, if you downloaded any, are in `~/Library/Application Support/VENWhispr`. From the source folder, `scripts/uninstall-driver.sh` does the same as the button.

## Reporting a problem

If you find a security issue, please open a private report through **Security → Report a vulnerability** on this repository, rather than a public issue.
