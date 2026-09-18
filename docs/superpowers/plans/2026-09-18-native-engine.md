# MoxSpeak Native Engine Implementation Plan

**Goal:** MoxSpeak installs and works with nothing else on the machine. No Python, no server to start, no first-run download. Sub-half-second to first sound, and run 200 is as fast as run 1.

**Date:** 2026-09-18
**Predecessor:** Plan 1 (speech core) and the menu bar app, both shipped. 154 tests.

## The four properties this plan is accountable to

Everything below serves one of these. If a task serves none, it does not belong.

1. **Self-contained.** Install MoxSpeak, nothing else. Uninstall it, nothing left behind.
2. **Fast.** Sub-half-second to first sound. The spike measured 0.359s native against
   1.949s for the current server, on an M2 Max.
3. **Stateless.** Run 200 is as fast as run 1. The old engine leaked ~28 MB per request; this must be structurally impossible to regress into, and proven by a test.
4. **Durable.** Still builds and runs in three years. Minimize and pin what can move underneath us.

## Standing constraints

- swift-tools-version 6.0, `.macOS(.v14)`, Swift 6 strict concurrency, zero warnings.
- Plain `swift test` stays the test command for `MoxSpeakCore` regardless of what the app build needs.
- Every phase ends green. No phase leaves the tree broken for the next one.
- `rm -rf .build` before final verification in every phase — this repo's incremental cache has produced wrong results repeatedly.
- The `SpeechProvider` seam is load-bearing and stays. The HTTP provider is never deleted.

---

## Phase 1 — TextNormalizer *(in progress)*

Own the number-to-words layer so no engine has to do it for us.

`TextNormalizer` in `MoxSpeakCore`, separate from `TextPreparer` (formatting vs language — different jobs, different timing). `SpeechProvider` gains `requiresTextNormalization`; the HTTP provider returns `false` (Kokoro-FastAPI normalizes server-side and doubling it corrupts text), a native provider returns `true`.

**Done when:** phoneme match rate against Python misaki is measured and materially above the 50% baseline, with remaining failures named.

---

## Phase 2 — Choose the inference backend, by measurement

The one genuinely open decision, and the biggest durability risk in the plan.

**MLX** was measured by the spike at 0.359s TTFA, but forces `xcodebuild` — `swift build` cannot compile its Metal kernels. Xcode projects rot across OS and toolchain versions in a way SPM manifests do not.

**ONNX Runtime** stays on SPM and is far more widely adopted, but was never measured natively here. Research suggests roughly comparable speed (~280ms CPU), close enough that it may cost nothing.

**Task:** run ONNX Runtime against the identical corpus and method the spike used for MLX — same sentences, unique text per run, median of 6, time to first audio.

**Decision rule, set before seeing the number so it can't be rationalized:** if ONNX
lands within 100ms of MLX, take ONNX for the build-system longevity. If it is more than
100ms slower, take MLX and accept `xcodebuild`.

**Quantization judged on its own merits.** int8 (88 MB) and fp16 (169 MB) weights mean a
smaller bundle and lower memory for everyone. If one is spectrally indistinguishable from
f32, take it. Do not accept a quality regression to buy headroom.

### Lower-end Macs — a nice-to-have, deliberately not a requirement

Most Mac users are on a base M1/M2/M3, not a Max, and this may be shared publicly — so a
tool that only feels good on a $4,000 laptop makes a poor first impression on the majority
who try it. Worth knowing the answer; **not** worth distorting the design for.

Measure it, don't optimize for it: report thread-scaling under constraint as a proxy, and
peak resident memory per configuration. These are nearly free once the harness exists.

Calibration: Kokoro-82M is small, and published figures put it near 280ms on CPU alone. A
base M1 CPU is perhaps 30-40% slower than this machine for such work — around 400ms, still
inside the sub-500ms target with no GPU involved. The expected finding is that low-end
hardware is simply fine. The realistic risks there are **memory footprint on an 8 GB
machine** and **thermal throttling on a fanless body during a long article**, not
single-utterance latency.

Low-end viability overrides the decision rule only if an option looks genuinely unusable —
degrading catastrophically rather than gracefully, or a footprint that breaks 8 GB.

**Done when:** a number exists and the decision is recorded with its reasoning.

---

## Phase 3 — NativeSpeechProvider

- **Vendor MisakiSwift into the repo** rather than depending on it. It is a small, low-adoption package doing something core; an unmaintained dependency for pronunciation is exactly the fragility this plan exists to remove. Vendoring also lets us carry our own fixes. Record its licence (Apache-2.0) and upstream commit.
- Implement `NativeSpeechProvider: SpeechProvider` around the Phase 2 backend: `requiresTextNormalization = true`, its own `recommendedCharacterCap`, and an honest `outputFormat`.
- Model loads **once**; synthesis is a pure function of (phonemes, voice). No audio cache, no per-call accumulation.

**The statelessness test is the deliverable here, not a nice-to-have.** Run many syntheses in one process and assert resident memory does not grow beyond a threshold. Property 3 is otherwise just a hope, and the exact failure it guards against already cost us a day.

**Done when:** the provider passes the existing `SpeechProvider` conformance expectations, and the memory test fails if a cache is deliberately introduced.

---

## Phase 4 — Let the provider set the chunk size

The 150-character cap exists *only* as a workaround for the PyTorch-MPS truncation bug. Native has no such limit, and a smaller first chunk means faster first sound.

`SpeechProvider.recommendedCharacterCap` is already declared and currently unused — a known dead-code finding from the final review. Wire `SpeechSession` to consult it when building the `Segmenter`, so each engine brings its own correct number.

Re-tune the native first-chunk size against measured time-to-first-sound rather than guessing.

**Done when:** the HTTP provider still gets 150, the native provider gets its own measured value, and a test pins that the session honours the provider.

---

## Phase 5 — Bundle everything, and keep the build honest

- Model weights, lexicon and voice data ship **inside the `.app`**. No Application Support directory, no download on first run, works offline.
- `build-app.sh` assembles and signs with the Developer ID identity (already done — grants survive rebuilds).
- Record the resulting bundle size. The spike estimated ~362 MB.
- If Phase 2 chose MLX, the app target moves to `xcodebuild`; `MoxSpeakCore` stays SPM-testable either way.

**Done when:** the assembled `.app` runs on a machine with no Python and no Kokoro server.

---

## Phase 6 — Native becomes the default, server stays selectable

- Engine choice in the menu, persisted alongside voice and speed.
- Native is the default; the HTTP provider remains for pointing at a remote or a beefier engine.
- Engine switching takes effect without a restart.

**Done when:** a fresh launch with no server running speaks correctly, and switching to the HTTP engine still works when one is available.

---

## Phase 7 — Clean uninstall

Preferences and the log are the only things outside the bundle. Add a menu item that clears both, so removing MoxSpeak leaves nothing behind. Document what it touches.

**Done when:** the item empties the defaults domain and the log, and the app returns to first-launch behaviour.

---

## Phase 8 — End-to-end verification

Against the four properties, with numbers:

1. **Self-contained:** stop Kokoro entirely, confirm the app still speaks.
2. **Fast:** time to first sound, unique text per run, median of at least 6. Target under 0.5s.
3. **Stateless:** 200 consecutive syntheses; report time-to-first-sound for the first and last ten, and resident memory across the run. Both should be flat.
4. **Durable:** a written record of every pinned version and vendored component.

Plus a quality spot-check: the normalizer's corpus through the full native path, confirming numbers, currency and dates sound right.

---

## Explicitly not in this plan

The HUD with its scrub bar, sentence-level navigation, memory spill-to-disk, and the long-selection guard. All are real, none are needed for the four properties above. They come after.

## Known risks

- **MLX / `xcodebuild`** — the main durability threat. Phase 2 is designed to avoid it if the measurement allows.
- **Heteronyms** — "read" past vs present comes from POS tagging, which normalization cannot fix. Two of 28 in the spike. Accepted; revisit if it grates in use.
- **Carbon hotkeys** are long-deprecated but are the only no-permission global hotkey API. Accepted, with the migration path being `CGEventTap` plus an Accessibility prompt if Apple ever removes it.
