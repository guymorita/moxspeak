# Third-party notices

MoxSpeak is built on other people's work. Every component below is redistributed
inside the application under the licence named, and each licence's full text
ships alongside this file.

Nothing here is restricted by MoxSpeak's own licence. If you want any of these
components, take them from their upstream project under their own terms.

---

## Kokoro-82M — the voice model

| | |
|---|---|
| what | The neural network weights and the 29 voice vectors that produce the speech |
| upstream | https://huggingface.co/hexgrad/Kokoro-82M (v1.0) |
| author | hexgrad |
| licence | Apache License 2.0 |

The weights are converted to `.safetensors` and cast to float16 before bundling;
the conversion is `Scripts/prepare-models.py` and changes no values beyond the
precision cast and the removal of a `module.` key prefix left by the training
harness. No retraining, no fine-tuning.

---

## KokoroSwift — inference

| | |
|---|---|
| what | The Kokoro graph — ALBERT text encoder, duration and prosody predictors, iSTFTNet decoder — implemented in MLX Swift |
| upstream | https://github.com/mlalma/kokoro-ios |
| commit | `4d6d1d8ff8cd012014180c9cd4cf0151e7682354` |
| author | Lassi Maksimainen |
| licence | MIT |

Vendored into `Sources/Vendor/KokoroSwift/` with four changes, each listed in
`Sources/Vendor/VENDORED.md`.

---

## MisakiSwift — grapheme-to-phoneme

| | |
|---|---|
| what | Turns English text into the phonemes Kokoro speaks, including the pronunciation dictionary and a fallback network |
| upstream | https://github.com/mlalma/MisakiSwift |
| commit | `b7477b15fc46cf8e20b32c008126611b38ec6b79` |
| author | Lassi Maksimainen |
| licence | Apache License 2.0 |

Vendored into `Sources/Vendor/MisakiSwift/` with four changes, each listed in
`Sources/Vendor/VENDORED.md`. British English resources are omitted.

---

## MLXUtilsLibrary — token types and utilities

| | |
|---|---|
| what | `MToken`, the token type the G2P pipeline is built on, plus logging and timing helpers |
| upstream | https://github.com/mlalma/MLXUtilsLibrary |
| commit | `41f6cfd5d68b65aa3c65a34efe3b71c371ed915b` |
| author | Lassi Maksimainen |
| licence | Apache License 2.0 |

Vendored into `Sources/Vendor/MLXUtilsLibrary/`. The NumPy reader is omitted;
no source edits.

---

## MLX Swift — the array and Metal runtime

| | |
|---|---|
| what | Apple's array framework for Apple silicon. Runs every tensor operation in the model |
| upstream | https://github.com/ml-explore/mlx-swift |
| version | 0.30.2, pinned exactly |
| author | Apple Inc. / ml-explore |
| licence | MIT |

A package dependency rather than vendored. `mlx.metallib`, the precompiled Metal
kernel library shipped in `Contents/MacOS/`, is built from MLX's own `.metal`
sources by `Scripts/build-metallib.sh`.

---

## Sentry Cocoa — crash reporting

| | |
|---|---|
| what | Captures crashes so they can be fixed without anyone having to report them |
| upstream | https://github.com/getsentry/sentry-cocoa |
| author | Functional Software, Inc. (Sentry) |
| licence | MIT |

What it sends, and what it is prevented from sending, is described in the
privacy section of the README and enforced in `Sources/MoxSpeakApp/Telemetry/`.

---

## Full licence texts

These accompany this file, both in the repository under `licenses/` and inside
the application at `MoxSpeak.app/Contents/Resources/licenses/`.

| file | covers |
|---|---|
| `Apache-2.0.txt` | Kokoro-82M, MisakiSwift, MLXUtilsLibrary |
| `KokoroSwift-MIT.txt` | KokoroSwift — carries its own copyright line |
| `mlx-swift-MIT.txt` | MLX Swift — carries its own copyright line |
| `sentry-cocoa-MIT.txt` | Sentry Cocoa — carries its own copyright line |

One shared copy of the Apache text covers three components because all three
ship the identical licence, differing only in indentation, and none of them
ships a `NOTICE` file. The copyright holder of each is named in its section
above, which is the attribution the licence actually asks for.

The Apache License 2.0 requires that its notice travel with redistribution; that
is what this file is. It also permits its components to be redistributed inside a
work under different terms, which is what MoxSpeak does — every component listed
here remains under its own licence regardless of MoxSpeak's, and nothing in
MoxSpeak's licence takes away a right these grant you.
