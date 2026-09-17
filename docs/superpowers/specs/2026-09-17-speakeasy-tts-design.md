# Speakeasy — System-Wide Text-to-Speech for macOS

**Date:** 2026-09-17
**Status:** Approved design, ready for implementation planning
**Working name:** Speakeasy (placeholder)

## Problem

macOS ships a built-in "Speak selection" accessibility feature, but its premium voices
are noticeably worse than Kokoro-82M. Kokoro-FastAPI delivers the better voices but has
no desktop interface — it is a local HTTP server with no way to point at text on screen
and hear it.

The gap is a client, not a model. Existing open-source attempts are barely built, so
building one is cheaper than adopting one.

## Goal

Select text anywhere on macOS, press one key, hear it spoken in under half a second.

## Non-goals

- Reading a document aloud with in-place highlighting in the source application.
- A library, queue, or history of previously spoken text.
- Any iOS component, App Store distribution, or Apple Developer Program membership.
- Text-to-speech authoring features (SSML editing, multi-speaker dialogue).

## Constraints

- Two machines: a personal MacBook Pro (M2 Max) and a work Mac. Same app on both.
- Time to first audio must be a fraction of a second, not tens of seconds.
- Engine-agnostic: Kokoro is the default, not a hard dependency.
- No Apple Developer account. Local builds, ad-hoc signing.
- The user should never have to think about Kokoro except as a menu option. No manual
  server management, no terminal, no Python visible anywhere.

## Measured baseline

On the M2 Max, against the already-running Kokoro-FastAPI at `localhost:8880`:

- 118 characters of input produced 367,362 bytes of 24kHz 16-bit mono PCM
  (7.65 seconds of audio) in 1.40 seconds wall clock.
- **Synthesis runs at roughly 5.5x realtime.**
- **Output length is ~15.4 characters per second of speech**, and close to linear in
  character count. This is the basis of the duration estimate (see Scrubbing).

These two numbers are what make both the latency target and the draggable position bar
achievable. They should be re-measured on the work Mac and the constants made
configurable rather than hardcoded.

## Architecture

A single Swift menu-bar application. Ten components, each with one responsibility and a
narrow interface, so most of the system is testable without audio hardware or a server.

```
hotkey → SelectionReader → TextPreparer → Segmenter → SpeechSession
                                                         ↓      ↑
                                           SpeechProvider → PlaybackEngine → HUD
                                                 ↑
                                          EngineSupervisor
```

### HotkeyManager

Registers global hotkeys via `RegisterEventHotKey`. Emits events. Nothing else.

Registration failure is meaningful: it means another application already owns that
combination. This is surfaced to the settings UI as conflict detection.

### SelectionReader

Returns the currently selected text, or nil.

Primary path reads `AXSelectedText` from the focused UI element via the Accessibility
API. This is instant and never touches the pasteboard.

Fallback path, used when the primary returns empty (common in some Electron apps and PDF
viewers): synthesize ⌘C, read `NSPasteboard`, then restore the pasteboard's previous
contents. Costs roughly 80ms.

A separate hotkey bypasses both and reads the pasteboard directly ("speak clipboard").

Missing Accessibility permission is detected explicitly and reported as such — never as
"no text selected."

### TextPreparer

Pure function: raw string in, speakable string out. Roughly 100 lines of rules.

It covers only what Kokoro-FastAPI's normalizer does not. That normalizer
(`api/src/services/text_processing/normalization/english.py`) already handles numbers,
money, times, phone numbers, units, email addresses, URLs, abbreviations, all-caps runs,
and version strings. Duplicating any of that is a bug, not a feature.

The gap is document formatting:

- Markdown syntax: emphasis markers, heading hashes, list bullets, link syntax reduced
  to its label text, table pipes.
- Fenced and indented code blocks: skipped, or announced as "code block" (configurable).
- Citation brackets such as `[12]`. Necessary because Kokoro's `allow_voice_tags`
  defaults to false, so bracketed text is spoken literally as written.
- PDF copy-paste artifacts: hyphenation across line breaks, and hard-wrapped lines
  rejoined into paragraphs.
- Emoji and decorative symbol runs.
- Whitespace and quote-character normalization.

Toggleable in settings. Must remain sub-millisecond; it sits directly in the latency
path.

On the request side, `normalization_options.unit_normalization` should be sent as
`true`. It defaults to `false` in Kokoro-FastAPI, which leaves "10KB" spoken as the
letters rather than as "10 kilobytes".

### Segmenter

Splits prepared text into sentences with `NLTokenizer`, then groups sentences into
chunks.

**The first chunk is always exactly one sentence.** This is the single most important
decision for perceived latency: a short first chunk finishes synthesis fast and starts
audio immediately. Subsequent chunks grow to 2–3 sentences for throughput.

Retains sentence boundary offsets, which serve both sentence-level navigation and the
per-chunk duration estimate.

### SpeechProvider (protocol)

The engine-agnostic seam. Three requirements:

- `synthesize(chunk, voice, speed) -> AsyncStream<Data>`
- `listVoices() -> [Voice]`
- A declaration of which audio formats the engine can emit.

`listVoices()` is not optional polish. Kokoro exposes `/v1/audio/voices`; OpenAI has a
fixed list; others differ. Without it, "engine-agnostic" means "you edit a config file."
Implementations report their own voices with a static fallback.

Format negotiation matters for the same reason. PCM is the fast path and skips decoding
entirely. Engines that only stream mp3 route through an `AVAudioConverter` stage.

**`OpenAICompatibleProvider` is the only implementation in v1.** Because OpenAI's
`/v1/audio/speech` shape is the de facto standard, it covers Kokoro-FastAPI, OpenAI,
Groq, LM Studio, and most local servers. ElevenLabs uses a different request shape and
would be a second file implementing the same protocol — additive, not a refactor.

### EngineSupervisor

Owns the lifecycle of the local Kokoro engine so the user never does.

- **First run:** a one-time "Setting up voices…" progress screen. Creates a private uv
  virtual environment and installs Kokoro-FastAPI and its model weights under
  `~/Library/Application Support/Speakeasy/`. Requires network, costs a few minutes and
  roughly 3–5GB of disk (PyTorch dominates this).
- **Every run after:** starts the server as a hidden child process, health-checks it,
  restarts it on crash, stops it on quit.
- **Port handling:** if something is already serving on 8880, reuse it rather than
  starting a second copy. Otherwise bind the next free port.

Only the built-in `Kokoro (Local)` engine is supervised. Every other configured engine
is just a URL.

### SpeechSession

The orchestrator, and the component most worth testing.

Holds the chunk list, each chunk's state (estimated / synthesizing / rendered / failed),
its PCM data, and its real duration once known.

**Synthesis runs continuously ahead of playback, not one chunk ahead.** At 5.5x realtime
it outruns listening badly — roughly a minute of playback and a typical article is fully
rendered in memory. This is what makes scrubbing feel instant and the position bar
settle to exact quickly.

Memory cost is 2.9MB per minute of audio (24kHz, 16-bit, mono), so a 30-minute article
is about 86MB. Past a configurable cap, rendered chunks spill to a temp file.

A chunk that fails to synthesize is logged, marked failed, and skipped. One bad sentence
must never end a twenty-minute article.

### PlaybackEngine

`AVAudioEngine` with a player node and an `AVAudioUnitTimePitch`.

The `TimePitch` unit means speed changes apply instantly and pitch-corrected, with no
re-synthesis and no request to the engine. Playback speed and synthesis speed are
deliberately decoupled.

Schedules PCM buffers, reports position, honors chunk boundaries for seeking.

### HUDController

A small non-activating translucent `NSPanel`, top-center. Fades in on play, fades out a
few seconds after audio ends. Never takes focus.

```
┌──────────────────────────────────────────────┐
│  ⏪15   ⏸   15⏩      af_bella ▾     1.0× ▾   │
│  ━━━━━━━━━━●─────────────────────  3:41/12:08│
└──────────────────────────────────────────────┘
```

### MenuBarController and SettingsView

Menu bar icon reflects state: idle, speaking, engine starting, error. SwiftUI settings
window.

## Interaction model

Two hotkeys, both rebindable:

- **⌥⇧S — Speak selection.** Always speaks the current selection, replacing whatever is
  playing. One key, same behavior every time.
- **⌥⇧Space — Play/pause.** Toggles. A double-press stops playback and dismisses
  the HUD.

Splitting these avoids a single key having to infer whether the user meant "pause" or
"read this new thing."

### Scrubbing

The position bar is draggable and needs a total duration, but playback starts about
250ms in with one sentence synthesized. The resolution:

1. On start, estimate every chunk's duration from its character count at ~15.4 chars per
   second. The bar has a usable total immediately.
2. As each chunk renders, its estimate is replaced by its true duration and the total
   is corrected.
3. Because synthesis outruns playback, the total converges to exact within seconds.

Dragging to a position inside a rendered chunk seeks instantly. Dragging to an
unrendered chunk triggers on-demand synthesis of that chunk, roughly 200ms, and
prioritizes it ahead of the sequential queue.

Skip buttons are ±15 seconds. Because sentence boundaries are retained, ⌥-clicking a
skip button steps by sentence instead.

## Latency budget

| Stage | Cost |
|---|---|
| Selection read (AX path) | ~5ms |
| Selection read (⌘C fallback) | ~80ms |
| Text preparation | ~1ms |
| First-sentence synthesis | 150–250ms |
| Audio start | ~10ms |
| **Total to first sound** | **~200–350ms** |

## Settings

- **General** — launch at login, HUD position, text-cleanup toggle, memory cap before
  spilling to disk.
- **Voice** — engine selector, voice selector (populated by `listVoices()`), default
  speed, preview button.
- **Engines** — list of engines. Each has a display name, base URL, model id, API key,
  and default voice. `Kokoro (Local)` is built in and is the only supervised entry.
  Engines can be switched mid-session.
- **Shortcuts** — recorder controls with conflict detection.
- **Advanced** — engine status, re-run setup, log file access.

API keys live in the Keychain. They are never written to the settings file and never
included in an export.

### Hotkey conflict detection

Three tiers, in increasing order of difficulty and decreasing order of certainty:

1. **Against the app's own other binding** — checked directly, hard block.
2. **Against system shortcuts** — read from
   `~/Library/Preferences/com.apple.symbolichotkeys.plist`, shown as a warning.
3. **Against other applications** — `RegisterEventHotKey` fails when another process
   owns the combination. The field reports "already in use by another app."

Tier 3 is the practical mechanism and is reliable, which is what makes conflict
detection cheap rather than a research project.

## Two-machine story

- Settings export and import as a JSON file. Keychain items are excluded.
- The app is ad-hoc signed (`codesign -s -`). No Apple Developer account is required to
  build and run it locally and indefinitely.
- Copy the `.app` between machines with `rsync` or `scp` rather than AirDrop; this
  avoids the Gatekeeper quarantine attribute entirely. If quarantined, clear it with
  `xattr -dr com.apple.quarantine`.
- Each machine grants Accessibility permission once. Because the permission is bound to
  the binary's signature, re-granting will occasionally be needed during development.
- The work Mac can either run its own bootstrapped engine or point its engine entry at
  the personal Mac over Tailscale, or at a hosted API. It is a URL change, not a
  different build.

## Error handling

Ordered by expected frequency:

1. **Accessibility permission not granted.** Detected explicitly, with a deep link to
   the correct System Settings pane. This is the most likely first-run confusion on the
   second machine.
2. **Engine not yet reachable.** HUD shows "Starting voice engine…", auto-retry with
   backoff, menu bar icon reflects state. A failed bootstrap produces an actionable
   message and a link to the log, not an indefinite spinner.
3. **A chunk fails to synthesize.** Logged, marked failed, skipped. Playback continues.
4. **Nothing selected.** Brief HUD toast. No modal, no sound.

## Testing

**Unit, no hardware or server required:**

- `TextPreparer` — golden-file tests. Inputs: markdown, PDF copy-paste with hyphenation
  and hard wraps, code-heavy text, citation-heavy academic text, emoji. Expected outputs
  checked in.
- `Segmenter` — invariants: the first chunk is always exactly one sentence; known
  abbreviations such as "Dr. Smith" do not split; empty and single-word inputs behave.
- Duration estimator — estimate error stays within tolerance across sample texts.

**Integration with a fake, no hardware or server required:**

- `SpeechSession` against a `FakeProvider` that emits synthetic PCM on a controllable
  clock. Covers prefetch ordering, seeking to an unrendered position, on-demand
  prioritization, pause and resume, replace-while-playing, and failed-chunk recovery.

**Integration with the real engine:**

- One test against `localhost:8880`, skipped when unreachable. Asserts the response is
  streaming PCM at the expected sample rate and that measured chars-per-second stays
  near the constant.

**Manual checklist, cannot be honestly faked:**

- AX selection capture in Chrome, Safari, Slack, Preview, VS Code, Notes, and Mail —
  recording for each whether the primary AX path or the ⌘C fallback was used.

## Future hooks

Noted, explicitly not in v1:

- Kokoro-FastAPI exposes word-level timestamps via its captioned-speech endpoint and a
  `return_timing` option. This is the natural foundation for karaoke-style word
  highlighting in the HUD.
- An ElevenLabs or other non-OpenAI-shaped provider, as a second `SpeechProvider` file.
- Replacing the bootstrapped PyTorch engine with a bundled ONNX engine, if the 3–5GB
  install or startup time becomes annoying. The `SpeechProvider` seam keeps this
  contained.
