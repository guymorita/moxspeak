# Speakeasy — System-Wide Text-to-Speech for macOS

**Date:** 2026-09-17
**Status:** Approved design, revised after external review and measurement. Ready for
implementation planning.
**Working name:** Speakeasy (placeholder)

## Problem

macOS ships a built-in "Speak selection" accessibility feature, but its premium voices
are noticeably worse than Kokoro-82M. Kokoro-FastAPI delivers the better voices but has
no desktop interface — it is a local HTTP server with no way to point at text on screen
and hear it.

The gap is a client, not a model. Existing open-source attempts are barely built, so
building one is cheaper than adopting one.

## Goal

Select text anywhere on macOS, press one key, hear it spoken within about a second.

## Non-goals

- Reading a document aloud with in-place highlighting in the source application.
- A library, queue, or history of previously spoken text.
- Any iOS component, App Store distribution, or Apple Developer Program membership.
- Text-to-speech authoring features (SSML editing, multi-speaker dialogue).

## Constraints

- Two machines: a personal MacBook Pro (M2 Max) and a work Mac. Same app on both.
- Time to first audio must be around a second, not tens of seconds.
- Engine-agnostic: Kokoro is the default, not a hard dependency.
- No Apple Developer account. Local builds, ad-hoc signing.
- The user should never have to think about Kokoro except as a menu option. No manual
  server management, no terminal, no Python visible anywhere.

## Measured baseline

All figures measured against the Kokoro-FastAPI at `localhost:8880` on the M2 Max,
running on MPS with `PYTORCH_ENABLE_MPS_FALLBACK=1`. Cache effects were defeated by
using unique text per trial; a warm-up request preceded each run.

| chunk size | time to first audio | renders in | audio produced | throughput |
|---|---|---|---|---|
| 120 chars | ~0.6–1.0s | ~0.6s | 7.8s | ~13x realtime |
| 180 chars | ~0.6–1.4s | ~0.6s | 11.6s | ~20x realtime |

- **Speech density is ~15.4 characters per second of audio** (measured range 14.3–15.6,
  close to linear in character count). This underwrites the duration estimate used by
  the position bar.
- **There is a large fixed per-request cost**, roughly 0.6–1.0s, which dominates
  small-chunk latency. It is not explained by device misconfiguration.
- **Latency is noisy.** The 0.6–1.4s range is real variance across trials, not
  measurement error. Pinning this down is an early implementation task, and the
  constants below must be configurable rather than hardcoded.

An earlier draft of this spec claimed 200–350ms to first sound. That number was an
estimate presented as a measurement and it was wrong; it came from a cached response.
The figures above replace it.

**Inputs above roughly 180 characters are not reliable on the current backend.** See
Known Issues. The chunk cap in the Segmenter is sized to stay inside the working regime.

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

Fallback path, used only when the primary returns empty (common in some Electron apps
and PDF viewers), synthesizes ⌘C. Getting this right is more than save-and-restore:

- Capture the pasteboard's `changeCount` before sending ⌘C.
- Preserve **all** `NSPasteboardItem`s and all of their type representations, not just
  the plain-text one.
- Wait for `changeCount` to actually increment, with a timeout, rather than assuming the
  copy completed. Some applications respond slowly.
- If `changeCount` advanced more than expected, the user changed the clipboard during
  the operation. Do not restore; their change wins.
- Restore only when the observed state matches what we wrote.

**Honest limitation, to be stated in the UI rather than papered over:** file promises
and some lazily-provided representations cannot be faithfully restored. The fallback is
best-effort, and the primary AX path — which has none of these problems — is always
tried first.

A separate hotkey bypasses both paths and reads the pasteboard directly ("speak
clipboard"), touching nothing.

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

Splits prepared text into sentences with `NLTokenizer`, then packs sentences into chunks
under a **hard character cap, default 150**.

The cap is the governing constraint, not the sentence boundary. An earlier draft
specified "the first chunk is exactly one sentence," which is unsafe: a single sentence
can run to thousands of characters, blowing both the latency target and the backend's
reliable input range. Sizing rules, in priority order:

1. No chunk exceeds the character cap.
2. A sentence longer than the cap is split at clause boundaries (commas, semicolons,
   colons, dashes), then at word boundaries if a clause is still too long. Never
   mid-word.
3. Within the cap, prefer ending on a sentence boundary — it sounds better.
4. The first chunk is sized toward the low end of the cap to minimize time to first
   sound.

Sentence and chunk boundary offsets are retained, serving both sentence-level navigation
and the per-chunk duration estimate.

The cap is configurable per engine, because the reliable input size is an engine
property, not a universal constant.

### SpeechProvider (protocol)

The engine-agnostic seam. "OpenAI-compatible" guarantees a request *shape* and nothing
about streaming semantics, sample rates, content types, or error payloads, so the
contract must make those explicit rather than assume them.

Each provider declares:

- `synthesize(chunk, voice, speed) -> AsyncStream<Data>`, **cancellable**, with a
  configurable request timeout.
- `listVoices() -> [Voice]`.
- **Output audio format:** sample rate, channel layout, bit depth, and container or raw
  framing. Kokoro emits raw headerless 24kHz signed 16-bit mono PCM; another server may
  emit 44.1kHz, or wrap it in a WAV header. This is declared, and validated against the
  first response rather than trusted.
- **Whether true incremental streaming is supported**, or whether the response only
  arrives complete. A non-streaming engine is usable; it just changes chunk sizing.
- **Error payload shape**, so failures are surfaced as messages rather than as silence.

`listVoices()` is not optional polish. Kokoro exposes `/v1/audio/voices`; OpenAI has a
fixed list; others differ. Without it, "engine-agnostic" means "you edit a config file."
Implementations report their own voices with a static fallback.

PCM is the fast path and skips decoding entirely. Engines that only emit mp3 route
through an `AVAudioConverter` stage.

**`OpenAICompatibleProvider` is the only implementation in v1.** It covers
Kokoro-FastAPI, OpenAI, Groq, LM Studio, and most local servers. ElevenLabs uses a
different request shape and would be a second file implementing the same protocol —
additive, not a refactor.

### EngineSupervisor

Owns the lifecycle of the local Kokoro engine so the user never does.

- **First run:** a one-time "Setting up voices…" progress screen. Creates a private uv
  virtual environment and installs Kokoro-FastAPI and its model weights under
  `~/Library/Application Support/Speakeasy/`. Requires network, costs a few minutes and
  roughly 3–5GB of disk (PyTorch dominates this).
- **Every run after:** starts the server as a hidden child process on **its own private
  port**, health-checks it, restarts it on crash, stops it on quit.

**On reusing a server we did not start:** never automatically. Selected text is
potentially sensitive, and a port is not an identity — an unknown listener on 8880 could
be an unrelated service, or an incompatible API that silently mangles the request. The
rule is:

1. Default to our own supervised instance on a private port.
2. If a server is detected on a configured port, probe it for identity: it must respond
   correctly to `/v1/audio/voices`, return a recognizable voice set, and pass a tiny
   synthesis round-trip whose output matches the declared format.
3. Only on a positive identification, offer reuse, and require **explicit one-time user
   confirmation** naming what was found.
4. Never send user text to an unidentified endpoint.

The memory saved by reusing a running instance does not justify the leak risk;
Kokoro-82M is small enough that a second instance is an acceptable cost.

Only the built-in `Kokoro (Local)` engine is supervised. Every other configured engine
is just a URL.

### SpeechSession

The orchestrator, and the component most worth testing.

Holds the chunk list, each chunk's state (estimated / synthesizing / rendered / failed),
its decoded audio, and its real duration once known.

**Session generation tokens.** Every speak request increments a generation counter, and
every in-flight synthesis carries the generation it belongs to. On replace-while-playing
the generation advances, in-flight requests are cancelled, and any response that arrives
late carrying a stale generation is discarded rather than committed. Without this,
seeking, prioritization, and replace all race against abandoned work. The same mechanism
covers stop and quit.

**Synthesis runs continuously ahead of playback, not one chunk ahead.** At 13–20x
realtime it outruns listening comfortably — roughly a minute of playback and a typical
article is fully rendered. This is what makes scrubbing feel instant and the position
bar settle quickly.

**Output validation, per chunk.** Compare the returned audio duration against the
character-count estimate. A chunk that comes back materially short, or empty, is
retried once, then split and retried, then marked failed and skipped with a HUD
indication. This is not defensive polish — the current backend silently returns HTTP 200
with truncated or absent audio (see Known Issues), and without this check that failure
mode is invisible and presents as "it just stopped reading."

A chunk that fails outright is logged, marked failed, and skipped. One bad sentence must
never end a twenty-minute article.

**Memory accounting** is based on **decoded in-memory buffers**, not wire-format bytes,
since providers may deliver mp3 or other compressed formats that expand on decode. For
the Kokoro path this is 2.9MB per minute of audio (24kHz, 16-bit, mono), so a 30-minute
article is about 86MB. Past a configurable cap, rendered chunks spill to a temp file.

### PlaybackEngine

`AVAudioEngine` with a player node and an `AVAudioUnitTimePitch`.

The `TimePitch` unit means speed changes apply instantly and pitch-corrected, with no
re-synthesis and no request to the engine. Playback speed and synthesis speed are
deliberately decoupled.

Schedules decoded buffers, reports position, honors chunk boundaries for seeking.

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
- **⌥⇧Space — Play/pause.** Toggles. A double-press stops playback and dismisses the
  HUD.

Splitting these avoids a single key having to infer whether the user meant "pause" or
"read this new thing."

### Scrubbing

The position bar is draggable and needs a total duration, but playback starts about a
second in with one chunk synthesized. The resolution:

1. On start, estimate every chunk's duration from its character count at ~15.4 chars per
   second. The bar has a usable total immediately.
2. As each chunk renders, its estimate is replaced by its measured duration and the
   total is corrected. This is the same measurement that drives output validation.
3. Because synthesis outruns playback, the total converges to exact within seconds.

Dragging to a position inside a rendered chunk seeks instantly. Dragging to an
unrendered chunk cancels lower-priority in-flight work, prioritizes that chunk, and
plays when it lands.

Skip buttons are ±15 seconds. Because sentence boundaries are retained, ⌥-clicking a
skip button steps by sentence instead.

## Latency budget

| Stage | Cost |
|---|---|
| Selection read (AX path) | ~5ms |
| Selection read (⌘C fallback) | ~80ms, plus wait-for-changeCount |
| Text preparation | ~1ms |
| First chunk synthesis (~150 chars) | 600–1400ms, measured, variable |
| Audio start | ~10ms |
| **Total to first sound** | **~0.6–1.5s** |

The first-chunk figure dominates and is almost entirely the backend's fixed per-request
cost. Reducing it is the single highest-leverage performance task after v1 works, and
the `SpeechProvider` seam is what keeps that change contained.

## Settings

- **General** — launch at login, HUD position, text-cleanup toggle, memory cap before
  spilling to disk.
- **Voice** — engine selector, voice selector (populated by `listVoices()`), default
  speed, preview button.
- **Engines** — list of engines. Each has a display name, base URL, model id, API key,
  default voice, chunk character cap, and request timeout. `Kokoro (Local)` is built in
  and is the only supervised entry. Engines can be switched mid-session.
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
3. **A chunk returns short or empty audio.** Retried, then split and retried, then
   skipped with a HUD indication. Never silent.
4. **A chunk fails outright.** Logged, marked failed, skipped. Playback continues.
5. **Request timeout.** Cancelled and treated as a failed chunk.
6. **Nothing selected.** Brief HUD toast. No modal, no sound.

## Testing

**Unit, no hardware or server required:**

- `TextPreparer` — golden-file tests. Inputs: markdown, PDF copy-paste with hyphenation
  and hard wraps, code-heavy text, citation-heavy academic text, emoji. Expected outputs
  checked in.
- `Segmenter` — invariants: no chunk exceeds the cap; a single 5,000-character sentence
  splits at clauses and then words without breaking mid-word; abbreviations such as
  "Dr. Smith" do not split; empty and single-word inputs behave.
- Duration estimator — estimate error stays within tolerance across sample texts.

**Integration with a fake provider, no hardware or server required:**

`SpeechSession` against a `FakeProvider` emitting synthetic audio on a controllable
clock, covering:

- Prefetch ordering and continuous read-ahead.
- Seeking to an unrendered position, and the prioritization that follows.
- Pause, resume, and replace-while-playing.
- **Stale-generation responses arriving after a replace are discarded, not committed.**
- **Cancellation** — an in-flight request is actually abandoned, not merely ignored.
- **Short-audio and empty-audio responses** trigger retry, then split, then skip.
- **A non-streaming provider** that returns only complete responses.
- **An mp3-only provider**, exercising the decode path and decoded-buffer memory
  accounting.
- Request timeout handling.

**Integration with the real engine:**

- A test against the supervised local engine, skipped when unreachable. Asserts the
  response is streaming audio at the declared sample rate and channel layout, and that
  measured chars-per-second stays near the constant.
- **A wrong-service-on-the-port test**: point the identity probe at an HTTP server that
  is not Kokoro and assert it is rejected and no user text is transmitted.
- **Engine crash and restart during playback**: assert the supervisor restarts it and
  the session recovers or fails loudly, never hangs.

**Manual checklist, cannot be honestly faked:**

- AX selection capture in Chrome, Safari, Slack, Preview, VS Code, Notes, and Mail —
  recording for each whether the primary AX path or the ⌘C fallback was used.
- Pasteboard restoration with rich content: copy an image, then a styled rich-text
  selection, then run the fallback path and confirm what survives.

## Known issues

### Backend silently loses audio above ~180 characters

**Must be fixed. Does not block v1**, because the Segmenter's character cap keeps inputs
inside the reliable regime.

The Kokoro-FastAPI at `localhost:8880` returns HTTP 200 with correct headers and
truncated or entirely absent audio for inputs beyond roughly 180 characters. Measured
sweep, unique text per trial:

| input chars | audio returned | expected |
|---|---|---|
| 120 | 7.8s | 7.8s ✓ |
| 180 | 11.6s | 11.7s ✓ |
| 200 | 0.0s | 13.0s ✗ |
| 420 | 0.9s | 27.3s ✗ |
| 500 | 4.8s | 32.5s ✗ |
| 650 | 0.0s | 42.2s ✗ |

Results are **non-deterministic**, which points at a race rather than a size limit.

Ruled out by investigation:

- Device misconfiguration — correctly on MPS with `PYTORCH_ENABLE_MPS_FALLBACK=1`.
- The text chunker — `smart_split` run directly produces correct chunks with full
  character coverage.
- Output format — pcm, mp3, and wav all fail identically.
- Streaming vs non-streaming — both fail.
- Normalization — fails with it disabled.
- Model auto-unload — `model_auto_unload_timeout_seconds` defaults to 0.0 and is unset
  in the environment.

Localized to the synthesis loop at `api/src/services/tts_service.py:340` that consumes
`smart_split`. Chunks after the first are frequently dropped, sometimes the first too.

**Most likely cause is the local build, not upstream.** The checkout is on `master` at
`b4ef64b`, past the `v0.9.0` tag rather than on a release. First things to try when
returning to this: pin to the `v0.9.0` tag, rebuild the virtual environment from
scratch, and re-run the sweep. A test against the release build is underway separately.

This is the reason `SpeechSession` validates returned audio duration per chunk. Even
once fixed, that validation stays — it is the only thing standing between a silent
backend failure and a user watching a progress bar advance over silence.

## Future hooks

Noted, explicitly not in v1:

- Reducing the fixed per-request cost, which currently dominates time to first sound.
- Kokoro-FastAPI exposes word-level timestamps via its captioned-speech endpoint and a
  `return_timing` option. This is the natural foundation for karaoke-style word
  highlighting in the HUD, and would also give exact chunk durations for free.
- An ElevenLabs or other non-OpenAI-shaped provider, as a second `SpeechProvider` file.
- Replacing the bootstrapped PyTorch engine with a bundled ONNX engine, if the 3–5GB
  install, the per-request cost, or the audio-loss bug proves stubborn. The
  `SpeechProvider` seam keeps this contained.
