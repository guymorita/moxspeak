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

**Inputs above roughly 150-300 characters are not reliable on the current backend.** See
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
| Engine identity probe | ~15ms, once per session |
| First chunk synthesis | **the backend's floor — see below** |
| Audio start | ~10ms |

**Everything the client controls is negligible.** Measured end to end through the CLI
against the live engine, time-to-first-sound tracks raw HTTP to the same endpoint within
noise: ~2050ms via the full pipeline versus 1681–2107ms for a bare HTTP request of
comparable size. The client adds no measurable overhead.

**The backend's floor is large and variable.** The same engine measured ~600ms early in
a session and ~2000ms later the same day, for the same input size, with no configuration
change. That variability is consistent with the state-dependent behavior documented under
Known Issues — the engine degrades as a process accumulates work. Treat any single
latency number from this engine as a sample, not a constant.

**Synthesis must be sequential, not concurrent.** This is the one latency decision the
client owns, and it is worth stating plainly because the intuitive design is wrong.

An earlier implementation dispatched one synthesis request per chunk immediately, on the
theory that parallelism would keep playback fed. Measured, it did the opposite:

| | first chunk ready | all four done |
|---|---|---|
| 4 requests concurrently | 8.05s | 8.05s |
| 4 requests sequentially | **1.97s** | 7.62s |

The engine runs a single model and serializes internally, so concurrent requests all
complete together — the first chunk finishes no sooner than the last. Through the full
pipeline this made time-to-first-sound scale with *document length*: 1898ms for a
one-chunk input, 3846ms for three chunks, 5954ms for eight. Exactly backwards.

Rendering chunks strictly in document order fixes it, costs nothing in total throughput,
and still outruns playback comfortably, since synthesis runs many times faster than
realtime. The same three-chunk input dropped from 3846ms to 2050ms, and the scaling with
document length disappeared.

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

### Backend silently loses audio when a chunk exceeds ~13s of speech

**Must be fixed. Does not block v1** — and measurement now shows the Segmenter's
character cap does not merely avoid the bug, it fully mitigates it.

The Kokoro-FastAPI at `localhost:8880` returns HTTP 200 with correct headers
(`audio/pcm`, `transfer-encoding: chunked`) and truncated or entirely absent audio.
`/health` reports healthy throughout, including on requests that return zero bytes.

**The loss is proportional and deterministic.** The same prose passage repeated:

| input | chars | expected | got | ratio |
|---|---|---|---|---|
| prose x1 | 801 | 52.0s | 11.16s | 21% |
| prose x2 | 1602 | 104.0s | 22.32s | 21% |
| prose x4 | 3204 | 208.1s | 44.63s | 21% |

Exactly 1x / 2x / 4x. Roughly one chunk's worth of audio survives per ~800 characters
of input. An earlier revision of this spec called the behavior non-deterministic; that
was an artifact of a sweep that varied input length and request-sequence position
together. It is deterministic.

The practical threshold sits between 150 and 300 characters: 150 characters returns
complete audio, 300 returns zero bytes.

**Chunking is a complete mitigation, not just an avoidance.** A 580-character passage
sent whole loses ~79% of its audio. Split into four chunks of at most 150 characters and
sent back-to-back with no delay:

```
chunk 1: 147ch  expect  9.5s  got 9.34s  OK
chunk 2: 145ch  expect  9.4s  got 8.68s  OK
chunk 3: 144ch  expect  9.4s  got 9.56s  OK
chunk 4: 149ch  expect  9.7s  got 9.52s  OK
4/4 OK — 37.1s of audio rendered in 5.3s wall clock = 7.1x realtime
```

Nothing is lost, and throughput still outruns playback by 7x. This is why the cap is a
correctness mechanism and not a performance tuning knob, and why no chunk may ever
exceed it — including a single whitespace-free token, which is hard-split to stay under.

Ruled out by investigation:

- **Output format** — pcm, mp3 and wav fail identically on byte-identical input (mp3
  duration measured with ffprobe, not inferred from byte count).
- **Request rate and concurrency** — eight back-to-back identical 300-character requests
  all returned zero; a 3-second gap between them changed nothing.
- **Version** — v0.9.0 and master are functionally identical here (confirmed
  independently in a parallel session).
- **Device misconfiguration** — `DEVICE_TYPE=mps`, `PYTORCH_ENABLE_MPS_FALLBACK=1`,
  `USE_GPU=true` are all set on the running process.
- **The text chunker** — `smart_split` run directly yields correct chunks with full
  character coverage (458 of 459 characters on a two-chunk passage).
- **Streaming vs non-streaming** — both fail.
- **Normalization** — fails with it disabled.
- **Model auto-unload** — `model_auto_unload_timeout_seconds` defaults to 0.0 and is
  unset in the environment.

Localized to the synthesis loop at `api/src/services/tts_service.py:340` that consumes
`smart_split`.

**ROOT CAUSE (found 2026-09-17, jointly with a parallel debugging session).**

PyTorch's MPS backend on Apple Silicon has a hard limit of 65,536 output channels.
Kokoro's vocoder produces a tensor whose channel dimension scales with the duration of
audio being generated, so a single `generate()` call that would produce more than
roughly 13-19 seconds of speech crosses that limit and MPS refuses to run it:

```
Generation failed: Output channels > 65536 not supported at the MPS device.
```

`PYTORCH_ENABLE_MPS_FALLBACK=1` does not catch it. The fallback only covers missing
operations; this is a hard validation error, so there is nothing to fall back to. The
same limit is documented against OpenVoice, RVC and Parler-TTS on Mac
(pytorch/pytorch#144445).

The failure is invisible because `tts_service.py` has two layers of broad
`except Exception: log and continue` — one inside `_process_chunk()` (~line 172) and one
in `generate_audio_stream()`'s per-chunk loop (~line 340). A chunk that hits the MPS
error has its audio dropped and the loop moves on. The response still ends cleanly with
200, which is indistinguishable from success to any client.

At ~15.4 characters per second of speech, the 13-19 second ceiling corresponds to the
200-300 character boundary measured above. Everything follows from this: proportional
loss (only chunks under the ceiling survive), zero-byte responses, a healthy `/health`,
and independence from format, request rate, and text content.

The earlier hypothesis that repetitive text triggered it was tested and disproved —
varied prose fails identically at matched lengths. So was a hypothesis that the trigger
was the number of internal chunks; punctuation density makes no difference.

**The cap reduces incidence; it cannot guarantee safety.** The parallel session found
chunks of ~245 tokens that succeeded in one run and failed in another — identical size,
different outcome. So there is a state-dependent component on top of the size-dependent
one, and no chunk-size cap can be a guarantee, because the thing being predicted is the
same duration predictor that overflows. This is what makes per-chunk duration validation
in `SpeechSession` load-bearing rather than belt-and-braces: it is the only mechanism
that catches a failure the cap did not prevent.

**Why the 150-character cap is the right mitigation.** 150 characters is about 10 seconds
of speech, roughly 30% under the ceiling. Every request the client makes is a single
chunk well inside the working range, which is why chunked delivery renders complete audio
where a single large request loses most of it.

Fixes belong upstream and are being handled in the parallel session: abort the stream
rather than ending it cleanly on chunk failure (a clean end cannot be detected by any
client), retry the affected chunk on CPU with a narrowly-matched exception, and cap
`smart_split` chunks by predicted audio duration rather than token count alone.


**The one contradicting data point, now explained.** A parallel session sent a 21,800-character
block shaped like the built-in web player's request and got back an essentially complete
22-minute render. Under the root cause above, that run simply happened to be
split into internal chunks that all stayed under the duration ceiling. It is consistent
with the diagnosis rather than contradicting it.

This is the reason `SpeechSession` validates returned audio duration per chunk. Even once
fixed, that validation stays — it is the only thing standing between a silent backend
failure and a user watching a progress bar advance over silence.

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
