# Upgrading the speech engine

A note to whoever does this next, probably me, probably having forgotten everything.

Written 2026-09-18, when it was all still in working memory.

## What you are changing, and what you are not

Everything above `SpeechProvider` is engine-agnostic and should not need to change:
text preparation, number normalization, chunking, the retry-and-split validation ladder,
playback, hotkeys, the menu bar, settings.

A new engine is **one new type conforming to `SpeechProvider`**. That protocol exists for
exactly this. Two implementations already prove the seam works: `NativeSpeechProvider`
(MLX, in-process) and `OpenAICompatibleProvider` (HTTP). Keep the HTTP one — it is the
escape hatch and how you point at a remote engine.

Declare these honestly on any new provider; the session reads them and behaves accordingly:

- `requiresTextNormalization` — true if the engine cannot read "$1,234.56" itself
- `recommendedCharacterCap` — chunk size; ours is 100, set by memory and sentence length
- `outputFormat` — sample rate, channels, bit depth. This is **trusted, not verified** —
  get it wrong and every duration in the system is silently wrong

## The three scenarios

**New Kokoro weights, same architecture.** Replace `Models/kokoro-v1_0-fp16.safetensors`
and the voice data. Watch for a changed phoneme vocabulary or renamed tensors. Hours.

**New Kokoro architecture.** Update the vendored `KokoroSwift` inference under
`Sources/Vendor/`, possibly the phonemizer with it. Days.

**A different model entirely.** New `SpeechProvider`, plus whatever it needs to tokenize
and run. If it does not run on MLX you are also choosing a new runtime — see
`.superpowers/engine-packaging-research.md` for the ONNX evaluation, which measured
1.606s against MLX's 0.359s and is a known-working SPM fallback if MLX ever becomes
untenable. Days to weeks.

## Prove it is not worse — the harnesses are in `Tools/eval/`

Do not trust your ears, and do not trust a single run. Every number below was measured
with these scripts; a candidate engine should be held to the same bars.

| Check | Script | Current baseline |
|---|---|---|
| Acoustic fidelity | `mel_compare.py`, `spec_compare.py` | **4.85 dB** mel LSD vs PyTorch, cosine 0.957. The Python server scored 6.30 dB, so that is the bar to beat, not merely match |
| Phonemes | `compare.py`, `py_g2p.py` | **87.3%** agreement with Python misaki on identical normalized text |
| Latency | `server_latency.py`, corpora | **0.336s** median to first sound, 0.5s budget |
| Statelessness | `StatelessnessTests` in the suite | **+0.6 MB heap** over 200 utterances |
| Memory ceiling | `PerformanceEnvelopeTests` | 833 MB capped, 1663 MB uncapped |
| App coverage | `.superpowers/compatibility-matrix.md` | 92 clean of 98 combinations |

`gen_pytorch.py` regenerates the PyTorch reference audio the acoustic comparison needs.
`keystrokes/tap.swift speak|pause|stop` posts real ⌃⌥ events for driving the installed app.

## Traps that cost us real time

Read these before measuring anything. Each one produced a confident wrong answer.

**The engine caches.** Repeating the same sentence gives falsely fast numbers. This fooled
us **three separate times**, including once in a final report. Use unique text every run —
append a nonce.

**Registration success is not evidence.** `RegisterEventHotKey` returning `noErr` says
nothing about whether the handler runs. Confirm from `~/Library/Logs/MoxSpeak.log` that the
thing actually fired.

**RSS is too coarse for leak detection.** A real 17 MB-per-call cache moved resident memory
only 2.2 MB, because malloc holds unreturned slack. Assert on live malloc bytes.

**Tests can pass with the code they test deleted.** Five did, in this project. After writing
a test that matters, delete the mechanism and confirm it fails.

**Both builds are named MoxSpeak.** System Events resolves apps by name, so automation
silently drove `/Applications` instead of the test build. Target by pid.

**`swift build` needs the metallib.** After `rm -rf .build`, run `Scripts/build-metallib.sh`
or MLX aborts. It needs the mlx-swift checkout to exist first, so build once before running it.

**Synthesis is not deterministic.** Kokoro's decoder draws from MLX's global RNG, so repeat
calls differ byte-wise. Seed `MLX.seed` on both sides of any byte-equality comparison.

**MLX's CPU path is not a fallback.** `Device.withDefaultDevice(.cpu)` is ~185× slower *and
computes different audio* — 48,000 samples against 85,800 for the same sentence. Losing
Metal changes how the app sounds, not merely its speed.

## Decisions worth not relitigating

Recorded with their measurements in `docs/superpowers/plans/2026-09-18-native-engine.md`.

- **MLX over ONNX** — 0.359s vs 1.606s, and `MisakiSwift` pulls in mlx-swift regardless, so
  ONNX would have cost a second per utterance and left the same build exposure.
- **fp16 over f32** — acoustically indistinguishable from our own f32 (0.85 dB, cosine
  0.9994) and halves the model to 156 MB. The fp16 regression seen in ONNX was a conversion
  artifact and does not reproduce in MLX.
- **Bundle the model, don't download it** — the app works offline on first launch, and the
  model is frozen so it is fetched once ever. Downloadable models can be an *addition*,
  never the foundation.
- **Vendor rather than depend** — `Sources/Vendor/` holds MisakiSwift and KokoroSwift with
  their licences and upstream commits in `VENDORED.md`. The project has exactly **one**
  package dependency, `mlx-swift`, pinned to an exact version. Keep it that way.
- **Stay on Swift Package Manager.** `xcodebuild` is not required: MLX loads a prebuilt
  metallib colocated with the binary. This was the largest durability risk in the plan and
  it is closed. Do not reopen it casually.

## Known open items

- Heteronyms beyond the "have" case are unresolved. `pennTag` now returns VBN after a
  form of "have", which fixes "had read", but "I read it yesterday" still needs tense
  from elsewhere in the sentence and comes out present. See `HeteronymTests`.
- `12:00am` / `12:00pm` read literally rather than as midnight and noon.
- Safari's 400 ms pasteboard timeout is inherited from prior art and never fires, since
  Safari reaches tier 1 in every content shape tested. Dead code; remove it.
- macOS 26: tested on hardware 2026-09-20. Carbon `RegisterEventHotKey` works, and the
  app reported to Sentry from it. This is closed.
