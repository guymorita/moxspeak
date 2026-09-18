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
4. **Durable.** Still builds and runs in three years. Minimize and pin what can move
   underneath us.
5. **Works across macOS versions.** Deployment target stays `.macOS(.v14)`. The owner runs
   14.6 on one machine and **macOS 26** on another, and both must work. Prefer
   version-agnostic APIs; where something recent is needed, guard with `if #available` and
   provide a fallback rather than raising the floor for everyone.

   **The open risk here is Carbon.** `RegisterEventHotKey` is the only global-hotkey API
   that needs no Accessibility permission — the reason this app installs without prompts —
   and it has been deprecated for over a decade. If it has been removed in macOS 26, global
   hotkeys break there and the design needs rethinking. Testing the current build on the
   macOS 26 machine settles it cheaply and should happen before more is built on the
   assumption. The migration path, if needed, is `CGEventTap` plus an Accessibility prompt —
   which costs the no-permission property.

   Also unverified across versions: SF Symbol availability for the menu bar gem, and whether
   a prebuilt `.metallib` is portable across OS versions and GPU generations.

## Standing constraints

- swift-tools-version 6.0, `.macOS(.v14)`, Swift 6 strict concurrency, zero warnings.
- Plain `swift test` stays the test command for `MoxSpeakCore` regardless of what the app build needs.
- Every phase ends green. No phase leaves the tree broken for the next one.
- `rm -rf .build` before final verification in every phase — this repo's incremental cache has produced wrong results repeatedly.
- The `SpeechProvider` seam is load-bearing and stays. The HTTP provider is never deleted.

---

## Phase 1 — TextNormalizer ✅ *(done 2026-09-18)*

Own the number-to-words layer so no engine has to do it for us.

`TextNormalizer` in `MoxSpeakCore`, separate from `TextPreparer` (formatting vs language — different jobs, different timing). `SpeechProvider` gains `requiresTextNormalization`; the HTTP provider returns `false` (Kokoro-FastAPI normalizes server-side and doubling it corrupts text), a native provider returns `true`.

**Result:** feeding MisakiSwift and Python misaki the *same normalized text* took agreement
from **40.7% to 87.3%** across a 150-input corpus, with **zero regressions**. Every remaining
gap is pronunciation, not normalization — which was the blocker on going native. 215 tests.

Worth recording: on roughly a third of the corpus the Python reference is itself wrong
("3:30" read with the colon aloud, "12mm" as "twelve m", "Mt." as "em tee"), so raw match
rate against it understates the result.

**Known gap, needs an owner before native ships:** URLs and emails are not normalized at
all, and are the worst remaining MisakiSwift failure. Relevant because web articles are a
primary use case.

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

### DECIDED: MLX *(2026-09-18)*

| Backend | Median TTFA | Notes |
|---|---|---|
| **MLX** | **0.359 s** | chosen |
| ONNX f32 | 1.606 s | +1.247 s — twelve times the 100 ms tolerance |
| ONNX fp16 | 1.376 s | quality regression: mel LSD 9.49 dB |
| ONNX int8 | 4.443 s | slower *and* worse — 10.71 dB |

The rule said take ONNX within 100 ms. It missed by more than a second, reproduced
independently in Python, so the rule chose MLX without needing interpretation.

**The fact that collapsed the argument:** ONNX would not have escaped MLX anyway.
`MisakiSwift` depends on `mlx-swift` for phonemization, so the project carries MLX
regardless of inference backend. Taking ONNX would have cost 1.2 s per utterance and left
the same build-system exposure. The durability case for ONNX was real but moot.

Also established, and worth keeping:

- ONNX **does** build under plain `swift build` — Microsoft ships an official SPM package
  with a remote binary target. Noted in case MLX ever becomes untenable and this decision
  is revisited; the fallback path is known to work.
- Quantization is a dead end here. No "faster and still sounds right" option exists.
- ONNX f32 was the most acoustically faithful thing measured (1.44 dB LSD vs PyTorch).
  MLX at 4.85 dB is still better than the Python server we run today at 6.30 dB, so this
  is an improvement over the status quo, not a compromise against it.
- Peak RSS 595 MB (ONNX f32); comfortable on an 8 GB machine.

**Unresolved and carried forward:** whether MLX's lead holds on a base Air. MLX would need
a 4.5x regression merely to tie ONNX's M2 Max figure, so inversion is unlikely — but it is
unproven, and `mlx-swift` exposes no GPU limiter to test it with. The Phase 3 performance
envelope suite is where this gets watched.

**Done when:** a number exists and the decision is recorded with its reasoning.

---

## Phase 3a — MLX integration ✅ *(done 2026-09-18)*

Two open risks in this plan closed, both favourably.

**`xcodebuild` is NOT required — the project stays on Swift Package Manager.** The spike
was right that `swift build` cannot *compile* MLX's Metal kernels, and wrong that they must
be compiled at app-build time: MLX checks for an `mlx.metallib` colocated with the binary
before it checks the SwiftPM bundle. `Scripts/build-metallib.sh` produces one in ~6s with
the same 382 exported functions. This removes the single largest durability risk here.

**fp16 is acoustically clean in MLX** — the Phase 2 regression was an ONNX conversion
artifact and does not reproduce:

| | mel LSD vs PyTorch | TTFA |
|---|---|---|
| f32 | 4.86 dB | 0.345 s |
| **fp16 (ship this)** | **4.85 dB** | 0.355 s |
| HTTP server (control) | 6.30 dB | 1.949 s |

fp16 against our own f32: 0.85 dB, cosine 0.9994 — six times tighter than either is to
PyTorch. Model halves 312 → 156 MB, peak RSS 519 → 377 MB. Buys size, not speed.

**Verified rather than assumed:** `MoxSpeakCore.build` contains zero MLX objects and no
Core source imports MLX; `mlx-swift` pinned `exact: "0.30.2"`; macOS 14 floor proven by the
compiler (availability violations are compile errors) — upstream's "macOS 15" was buying
Swift 6.2 *language* features, not OS APIs; models gitignored, repo stays 6.8 MB; licences
and upstream commits recorded in `Sources/Vendor/VENDORED.md`. 237 tests.

**Carried forward:** nobody has run this on macOS 26 — only forward-compatibility
properties were proven. And MisakiSwift's POS tagger is OS-supplied `NaturalLanguage`, so
heteronyms may *sound* slightly different between the two machines.

---

## Phase 3b — NativeSpeechProvider

- **Vendor MisakiSwift into the repo** rather than depending on it. It is a small, low-adoption package doing something core; an unmaintained dependency for pronunciation is exactly the fragility this plan exists to remove. Vendoring also lets us carry our own fixes. Record its licence (Apache-2.0) and upstream commit.
- Implement `NativeSpeechProvider: SpeechProvider` around the Phase 2 backend: `requiresTextNormalization = true`, its own `recommendedCharacterCap`, and an honest `outputFormat`.
- Model loads **once**; synthesis is a pure function of (phonemes, voice). No audio cache, no per-call accumulation.

**The statelessness test is the deliverable here, not a nice-to-have.** Run many syntheses in one process and assert resident memory does not grow beyond a threshold. Property 3 is otherwise just a hope, and the exact failure it guards against already cost us a day.

**Done when:** the provider passes the existing `SpeechProvider` conformance expectations, and the memory test fails if a cache is deliberately introduced.

### The performance envelope suite

Alongside the statelessness test, build a small **opt-in performance suite** that runs the
native provider under deliberately constrained settings, as a standing proxy for an average
Mac rather than the development machine.

**Shape it so it survives.** A wall-clock assertion inside the normal `swift test` run will
fail whenever the machine is busy, get marked flaky, and then get disabled — at which point
it protects nothing. So:

- It lives behind an environment flag or a separate target, and is **not** part of the
  default `swift test` run.
- Its primary output is a **printed table of numbers**, not a pass/fail. Regressions are
  visible even when nothing trips.
- It carries exactly one assertion, against a **generous** budget with real headroom, to
  catch order-of-magnitude regressions rather than noise.

**Configurations to cover**, each a proxy for a weaker machine:

| Configuration | Stands in for |
|---|---|
| Unconstrained | this M2 Max |
| CPU only, GPU/Metal disabled | machines where the GPU path is unavailable or weak |
| CPU only, 4 threads | a base M-series chip |
| CPU only, 2 threads | the pessimistic floor |

Report, for each: time to first audio, full synthesis time, and peak resident memory.

**Be honest about what it is.** Fewer threads and no GPU is *directionally* like weaker
hardware; it is not a MacBook Air. It cannot model memory bandwidth, thermal throttling on
a fanless body, or a different chip generation. Name that limitation where the suite is
documented so nobody later mistakes a green run for hardware coverage we do not have.

Calibrate the budget from the constrained measurements taken in Phase 2, so it reflects
something observed rather than a guess.


---

## Phase 3b — NativeSpeechProvider ✅ *(done 2026-09-18)*

253 tests. Core still builds with zero MLX objects; native suites **skip** rather than fail
when `Models/` is absent.

**Statelessness proven — after the test itself was caught lying.** The first version
asserted on resident memory and **passed with a real 17 MB-per-call cache in place**: malloc
holds ~15 MB of unreturned slack, so RSS moved only 2.2 MB. Rewritten to assert on live
malloc bytes (sensitive) *and* resident (catches leaks that skip malloc).

- Red with cache in: heap +17.1 MB against a 4 MB limit.
- Green with cache out: heap +0.1 MB.
- **200-utterance soak: 92.9 MB of audio through, heap +0.6 MB, run 200 at 1.01× run 5.**

That is the fifth test in this project caught passing with the thing it tested removed.

**`recommendedCharacterCap = 100`, and the reasoning inverted.** There is no fixed cost per
synthesis to amortize — release timing is linear, 0.229–0.251 s per 100 chars from 40 to 400.
So latency does not set the cap. Memory does (1.2 GB @60, 1.7 GB @100, 2.1 GB @150, 2.8 GB
@400) together with language: ~100 chars is the smallest chunk that still holds a whole
English sentence.

**Two findings that change how we think about the engine:**

- **MLX's CPU path is not a fallback.** `Device.withDefaultDevice(.cpu)` is ~185× slower
  *and computes different audio* — 48,000 samples against 85,800 for the same sentence.
  Losing Metal would change how the app sounds, not merely its speed.
- **"Synthesis is a pure function of (phonemes, voice)" is false.** Kokoro's decoder draws
  Gaussian noise from MLX's global RNG, so repeat calls differ byte-wise. Nothing
  accumulates, so statelessness holds, but output is not deterministic without seeding.

**Could not be constrained, and was not faked:** thread count — mlx-swift 0.30.2 exposes no
such control, and `VECLIB_MAXIMUM_THREADS` at 1/2/4/8 changed nothing (62.6 s across the
board). The plan's "4 threads" and "2 threads" rows are therefore not implemented. What was
measurable instead:

| configuration | TTFA |
|---|---|
| unconstrained | 0.359 s |
| no buffer cache | 0.482 s |
| 512 MB MLX ceiling | 0.399 s |
| 256 MB + no cache | 0.734 s |

Even the pessimistic floor beats today's HTTP server by 2.7×.

---

## Phase 4 — Let the provider set the chunk size, and bound MLX's memory

The 150-character cap exists *only* as a workaround for the PyTorch-MPS truncation bug. Native has no such limit, and a smaller first chunk means faster first sound.

`SpeechProvider.recommendedCharacterCap` is already declared and currently unused — a known dead-code finding from the final review. Wire `SpeechSession` to consult it when building the `Segmenter`, so each engine brings its own correct number.

Re-tune the native first-chunk size against measured time-to-first-sound rather than guessing.

**Also in this phase, from Phase 3b's findings:** set an **MLX memory ceiling**. Peak
memory is currently unbounded and reaches 1.7 GB at a 100-character chunk — fine on a 64 GB
machine, uncomfortable on an 8 GB Air with a browser open. The envelope suite measured a
512 MB ceiling costing only +11% latency (0.399 s vs 0.359 s), which is a good trade for
bounding memory on exactly the machines we said we cared about.

Note also that `Segmenter.Options.firstChunkCap` (already 100) is what actually governs
time-to-first-sound; `recommendedCharacterCap` can only lower it.

**Done when:** the HTTP provider still gets 150, the native provider gets its own measured
value, a test pins that the session honours the provider, and peak memory is bounded.

---

### DECIDED: distribution *(2026-09-18)*

**Bundle one model in the app; downloadable models are an addition, never the foundation.**

The app ships with weights inside it so first launch works offline with no network, no
setup step and no failure mode. If a better model appears later, support downloading
*additional* ones — flexibility layered on top of a working out-of-box experience rather
than in place of it. Nobody is ever left with an app that does nothing until a download
succeeds.

Two facts make the download cost smaller than it appears: the model is frozen (13 months
without a commit), so it is fetched once ever; and because the weights never change, delta
updates keep later app updates near 20 MB rather than 360 MB.

Open: whether **MLX fp16** is acoustically clean. The fp16 regression measured in Phase 2
came through ONNX and may be a conversion artifact. If MLX fp16 holds up, the model halves
to ~160 MB and bundle size stops being a question. Measure it in Phase 3.

## Phase 5 — Bundle everything, and keep the build honest

- Model weights, lexicon and voice data ship **inside the `.app`**. No Application Support directory, no download on first run, works offline.
- `build-app.sh` assembles and signs with the Developer ID identity (already done — grants survive rebuilds).
- Record the resulting bundle size. The spike estimated ~362 MB.
- Phase 2 chose MLX, so the app target may need `xcodebuild` — `swift build` reportedly
  cannot compile MLX's Metal kernels. **Investigate shipping a prebuilt `.metallib`
  instead**; the spike produced one (~3.8 MB), which suggests the kernels need not be
  compiled from source at app-build time. If that works, the project stays on SPM and the
  single largest durability risk in this plan disappears. `MoxSpeakCore` stays
  SPM-testable either way.

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
- **Carbon hotkeys** are long-deprecated but are the only no-permission global hotkey API.
  Accepted, with the migration path being `CGEventTap` plus an Accessibility prompt if Apple
  ever removes it — at the cost of the no-permission property. **Unverified on macOS 26;
  test before relying on it further.**
- **Notarization.** Developer ID signing alone is not enough to run on another Mac:
  `spctl` reports `rejected — source=Unnotarized Developer ID`, so a copied build needs
  right-click-Open or the quarantine attribute cleared. Notarization becomes necessary if
  this is ever shared publicly.

---

## Boxed for later

Deferred deliberately, not forgotten.

**Notarization.** Developer ID signing alone does not clear Gatekeeper on another Mac.
macOS 15+ removed the right-click-Open bypass, so an unnotarized build gets a dead-end
"could not verify … Move to Trash" dialog — confirmed on the macOS 26 machine.

Required before sharing publicly; every downloader hits the same wall. One-time setup, and
the credential step needs the owner because it uses his Apple ID:

```bash
xcrun notarytool store-credentials "moxspeak-notary" \
  --apple-id "<apple-id>" --team-id 9F9SXNU23N
```

(app-specific password from appleid.apple.com → Sign-In and Security). After that,
`build-app.sh` gains a submit-and-staple step and the problem is gone permanently.

Immediate workaround meanwhile: `xattr -dr com.apple.quarantine <path>`, or System Settings
→ Privacy & Security → Open Anyway.

**Verifying macOS 26.** Unresolved and still the sharpest open risk: whether Carbon
`RegisterEventHotKey` still works there. It is the only global-hotkey API needing no
Accessibility permission, and it has been deprecated for a decade. Blocked behind
notarization, since the app would not launch on that machine.

Also unverified there: SF Symbol availability for the gem, media keys, and AX selection
reading.

**Note:** the work Mac gets much easier once the native engine lands — the awkwardness today
is that it would need Kokoro-FastAPI installed. Native removes that entirely; the machine
needs nothing but the app.

**URL and email normalization.** Phase 1's known gap, still unowned. The worst remaining
MisakiSwift failure, and relevant because web articles are a primary use case.
