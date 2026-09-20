# MoxSpeak

Select text anywhere on your Mac, press one key, hear it read aloud in a good voice.

No server to start, no account, no network. The voice model runs on your machine and is
bundled with the app, so it works on a plane.

**[Download for macOS](https://github.com/guymorita/moxspeak/releases/latest)** ·
[moxspeak website](https://guymorita.github.io/moxspeak/)

---

## Requirements

- **Apple silicon** (M1 or later). Intel Macs cannot run it: inference uses MLX, which is
  Apple silicon only.
- **macOS 14 Sonoma or later.**
- About 210 MB on disk. Most of that is the voice model, which is why there is nothing to
  download or configure on first launch.

## Install

Download the DMG from
[Releases](https://github.com/guymorita/moxspeak/releases/latest), open it, and drag
MoxSpeak to Applications.

Or, if you would rather:

```bash
brew install --cask guymorita/tap/moxspeak
```

The app is signed with a Developer ID and notarized by Apple, so it opens without a
Gatekeeper warning.

## Using it

MoxSpeak lives in the menu bar. It has no window and no Dock icon.

| | |
|---|---|
| **⌃⌥S** | Speak the selected text |
| **⌃⌥D** | Pause or resume |
| **⌃⌥X** | Stop |

All three are rebindable under **Keyboard Shortcuts…** in the menu.

**Select-to-Speak** needs Accessibility permission, which macOS asks for on first launch.
Without it MoxSpeak still works, but it reads whatever you last copied rather than what
you have selected.

If your menu bar icon does not appear, check whether a menu bar manager such as Ice,
Bartender or Hidden Bar has put it in a hidden section. New icons often land there.

## Privacy

The text you select or copy never leaves your Mac. Speech is synthesized locally; there
is no speech API and no server.

MoxSpeak sends anonymous crash reports and a short list of usage events, so that bugs get
fixed without anyone having to report them. What may be sent is a fixed allowlist, and it
is enforced in code rather than by convention:
[`TelemetryPayload.swift`](Sources/MoxSpeakApp/TelemetryPayload.swift), with the tests
that hold it to that in
[`TelemetryPayloadTests.swift`](Tests/MoxSpeakAppTests/TelemetryPayloadTests.swift).

Switch it off under **Advanced → Send anonymous usage stats**. With it off, the reporting
SDK is never started at all, so nothing is collected or queued for later.

Identity is a random UUID generated on your machine, not derived from any hardware
identifier. **Reset MoxSpeak…** clears it.

## The voices

29 English voices from [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), an
82-million-parameter model released under Apache-2.0. It is small enough to run in real
time on a MacBook Air and, to most ears, better than the premium voices macOS ships.

Time to first sound is about 0.3 seconds on an M2 Max.

## Building it

```bash
git clone https://github.com/guymorita/moxspeak
cd moxspeak
swift build -c release --target MoxSpeakNative
Scripts/build-metallib.sh      # MLX's Metal kernels; needed once after a clean checkout
./build-app.sh
```

The model weights are not in git (they are ~470 MB). `Sources/Vendor/VENDORED.md` has the
provenance and the script that regenerates them.

There is one thing worth knowing if you are poking at the engine: `SpeechProvider` is the
seam, and `docs/UPGRADING-THE-ENGINE.md` is the runbook for replacing what is behind it,
including the measurement harnesses and the traps that cost real time.

## Licence

Source-available, not open source. You can read, build, modify and audit it; you cannot
redistribute it. See [LICENSE](LICENSE).

It is public because MoxSpeak asks for Accessibility access so it can read your selection,
and you should not have to take anyone's word for what it does with that.

Third-party components (the Kokoro model, KokoroSwift, MisakiSwift, MLX and Sentry)
keep their own licences, which are more permissive. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
