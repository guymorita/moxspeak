# Vendored sources

Everything under `Sources/Vendor/` is third-party code copied into this repo rather than
pulled in as a package dependency. Each directory below is a target in the root
`Package.swift`, is built from these files and nothing else, and keeps its upstream
LICENSE alongside the code it covers.

## Why vendored rather than depended on

These are small, low-adoption projects doing something central to the product. A
pronunciation dictionary and a G2P front end are exactly the kind of thing that must not
break because an unmaintained upstream moved, and exactly the kind of thing we will want
to fix ourselves. (The prior spike found MisakiSwift disagreeing with Python `misaki` on
half a varied corpus — currency, percent, version numbers, hyphenated compounds. Fixing
that is downstream work, and vendoring is what makes it possible without a fork-and-wait
cycle.)

Vendoring also fixes a concrete build problem: all three upstream manifests declare
`swift-tools-version: 6.2` and `macOS 15`. As package dependencies they cannot be built
by the Swift 6.0 toolchain on this machine, and they would drag the deployment target off
macOS 14. As vendored targets we own the manifest, so the floor is ours to set. See
**Platform floor** below for why macOS 14 is honest and not a papered-over number.

`mlx-swift` stays a normal package dependency (pinned exactly to `0.30.2`). It is Apple's,
it is actively maintained, it is 100 MB of C++ and Metal we have no business carrying, and
we need MLX for inference regardless.

---

## MisakiSwift — grapheme-to-phoneme

| | |
|---|---|
| upstream | https://github.com/mlalma/MisakiSwift |
| commit | `b7477b15fc46cf8e20b32c008126611b38ec6b79` (2026-06-30) |
| license | Apache-2.0 — `MisakiSwift/LICENSE` |
| vendored from | `Sources/MisakiSwift/` |

### Changes from upstream

1. **`` `_` `` backticked at 34 call sites** in `English/EnglishG2P.swift`. `MToken` has a
   property literally named `_`; Swift 6.2's parser rejects the bare form. Two
   `tokens.first?._.x` expressions became `tokens.first.map { $0.` + "`_`" + `.x }` because
   optional chaining into a backticked member does not parse.
2. **`nonisolated` dropped from five `final class` declarations** in
   `English/FallbackNetwork/` (`BARTModel`, `BARTEncoderLayer`, `BARTDecoderLayer`,
   `FeedForward`, `MultiHeadAttention`). `nonisolated` on a type is Swift 6.2 syntax; the
   targets build in Swift 5 language mode where it is neither valid nor needed.
3. **British English resources omitted.** `Resources/` carries `us_gold.json`,
   `us_silver.json`, `us_bart.safetensors` and `us_bart_config.json` only — the `gb_*`
   files are another 9 MB for a voice set we do not ship. The code paths are untouched:
   `EnglishG2P(british: true)` still compiles, and would fail at resource load. If British
   voices are ever wanted, copy the four `gb_*` files from upstream's `Resources/`.
4. **Resource lookups go through `MoxSpeakResourceLocator`** (new file, ours) instead of
   `Bundle.module` directly — four call sites in `English/Lexicon/DataResourcesUtil.swift`
   and `English/FallbackNetwork/EnglishFallbackNetwork.swift`. See
   "Resources inside a signed `.app`" below for why; `Bundle.module` remains the fallback,
   so nothing changes for `swift test`.

Nothing else was changed. The G2P behaviour is upstream's, bugs included.

---

## MLXUtilsLibrary — MToken, logging, timing

| | |
|---|---|
| upstream | https://github.com/mlalma/MLXUtilsLibrary |
| commit | `41f6cfd5d68b65aa3c65a34efe3b71c371ed915b` (2025-11-22) |
| license | Apache-2.0 — `MLXUtilsLibrary/LICENSE` |
| vendored from | `Sources/MLXUtilsLibrary/` |

### Changes from upstream

1. **`NpyzReader/` omitted** — six files implementing a NumPy `.npy`/`.npz` reader that
   nothing in MisakiSwift or KokoroSwift calls. Dropping it also drops upstream's only
   non-MLX dependency, ZIPFoundation.

What remains is `MToken` (the token type the whole G2P pipeline is built on),
`BenchmarkTimer`, `Log`, and an `MLXArray` debug-print extension. No source edits.

---

## KokoroSwift — the acoustic model

| | |
|---|---|
| upstream | https://github.com/mlalma/kokoro-ios |
| commit | `4d6d1d8ff8cd012014180c9cd4cf0151e7682354` (2026-01-10) |
| license | MIT — `KokoroSwift/LICENSE` |
| vendored from | `Sources/KokoroSwift/` plus the package-root `Resources/config.json` |

This is the Kokoro graph — ALBERT text encoder, duration and prosody predictors,
iSTFTNet decoder — implemented in MLX Swift. It is vendored for the same manifest reasons
as the other two, and because it depends on MisakiSwift: leaving it as a remote package
would pull in a *second*, unvendored copy of the G2P we just took control of.

### Changes from upstream

1. **`resources/config.json` relocated.** Upstream declares `.copy("../../Resources/")`,
   reaching outside the target directory. Here the file lives at
   `KokoroSwift/Resources/config.json`; the `Bundle.module` lookup is unchanged.
2. **`KokoroConfig`'s resource lookup goes through `MoxSpeakResourceLocator`** (new file,
   ours) instead of `Bundle.module` directly — one call site. Same reason as MisakiSwift;
   see "Resources inside a signed `.app`" below.
3. **`KokoroTTS.phonemize(text:language:)` added** (`TTSEngine/KokoroTTS.swift`). Upstream
   keeps `phonemizeText` private, so there is no way to read the phoneme string without
   running synthesis. G2P is the part of this pipeline most likely to be wrong and a wrong
   pronunciation is invisible in every acoustic metric, so it needs to be inspectable.

`TextProcessing/eSpeakNGG2PProcessor.swift` is retained verbatim; it is entirely inside
`#if canImport(eSpeakNGLib)` and compiles to nothing, since we do not ship eSpeak.

---

## Platform floor

**macOS 14.0, verified — not assumed.**

Upstream's manifests say macOS 15 / iOS 18. That number is not backed by anything in the
code:

- `grep -rn '@available\|#available' Sources/Vendor/` returns nothing. No API in the
  vendored tree is version-gated, so there is nothing to guard or replace.
- The whole tree compiles at `.macOS(.v14)` with **zero warnings and zero errors**.
  Availability violations are compile *errors* in Swift, so a clean build at a macOS 14
  deployment target is the compiler proving that no macOS 15+ API is referenced.
- The binary runs and produces correct audio on macOS 14.6.1 (Swift 6.0.2 toolchain).

What upstream's 15 actually buys them is the *language* features noted above —
`nonisolated` on a type, and the `_` property name — which need a Swift 6.2 **toolchain**,
not a newer OS. Removing those two things (changes 1 and 2 under MisakiSwift) is what
lets the Swift 6.0 toolchain build it; the OS floor was never the constraint.

`mlx-swift` 0.30.2 declares `.macOS("14.0")` itself, so MLX imposes no floor above ours.
Where MLX needs to know the running OS it asks at runtime: `get_metal_version()` in
`Cmlx/mlx/mlx/backend/metal/device.cpp` uses `__builtin_available` to select Metal 3.1 /
3.2 / 4.0 on macOS 14 / 15 / 26 for the kernels it JIT-compiles. That is a runtime branch,
so one binary built against macOS 14 adapts upward on its own.

**One behavioural caveat, not a build one:** `MisakiSwift/English/Lexicon/PennTagUtil.swift`
uses Apple's `NaturalLanguage` POS tagger to resolve heteronyms ("he *read* the book" vs
"we've *read* it"). That tagger is OS-supplied and its output may differ across macOS
versions. It cannot break the build and cannot crash; it can change a pronunciation. If
heteronyms are ever golden-tested, expect those tests to be OS-sensitive.

---

## Model assets — not in git

The Kokoro weights and voice vectors are ~490 MB and are gitignored (`Models/`,
`*.safetensors`). `Scripts/prepare-models.py` regenerates all of them.

| file | source | size |
|---|---|---|
| `Models/kokoro-v1_0.safetensors` | `kokoro-v1_0.pth`, cast to f32 | 312 MB |
| `Models/kokoro-v1_0-fp16.safetensors` | same, cast to f16 | 156 MB |
| `Models/voices/*.safetensors` | one `.pt` per voice, f32, key `"voice"` | 15 MB (29 English voices) |

Upstream of all three is the `hexgrad/Kokoro-82M` v1.0 release. On this machine they are
already on disk inside the Kokoro-FastAPI checkout, which is where the re-fetch reads
from:

```
/Users/guymorita/Dev/Kokoro-FastAPI/api/src/models/v1_0/kokoro-v1_0.pth
/Users/guymorita/Dev/Kokoro-FastAPI/api/src/voices/v1_0/*.pt
```

If that checkout is gone, the same files are on Hugging Face at
`hexgrad/Kokoro-82M` (`kokoro-v1_0.pth` and `voices/*.pt`).

```bash
# needs torch + safetensors; the Kokoro-FastAPI venv has both
/Users/guymorita/Dev/Kokoro-FastAPI/.venv/bin/python Scripts/prepare-models.py \
  --checkpoint /Users/guymorita/Dev/Kokoro-FastAPI/api/src/models/v1_0/kokoro-v1_0.pth \
  --voices     /Users/guymorita/Dev/Kokoro-FastAPI/api/src/voices/v1_0 \
  --out        Models
```

The Kokoro-FastAPI voice directory holds more than hexgrad released. `prepare-models.py`
skips two families of it, which is why 29 voices come out of a directory with 46 English
`.pt` files in it:

- `*_v0*` — superseded earlier generations of voices already in the set (`af_v0bella` is
  the previous `af_bella`). Two picker rows for one voice, the older one looking like a
  peer of the newer.
- `*_inno` — outputs of Kokoro-FastAPI's own voice-tuning/cloning feature. Not in
  `VOICES.md`, not characterised anywhere, not something the model's authors shipped.

`--all-variants` converts them anyway. `VoiceCatalogTests.noSupersededOrClonedVariantsShip`
fails if they ever end up back in `Models/voices`.

The one non-obvious thing the script does is strip the `module.` segment every key
carries from the DataParallel wrapper Kokoro was trained under. `bert.module.embeddings…`
loads into MLX perfectly happily and then crashes KokoroSwift on the first weight lookup,
which is a confusing way to spend an afternoon.

`MOXSPEAK_MODEL_DIR` overrides where the engine looks. Otherwise it tries
`~/Library/Application Support/MoxSpeak/models`, then `<repo>/Models`.

---

## The Metal library — why `swift build` is enough

`swift build` has no Metal compilation rule; Xcode's build system does. That is the entire
reason MLX is commonly said to require `xcodebuild`. It does not.

MLX looks for its kernels in this order (`load_default_library`,
`Cmlx/mlx/mlx/backend/metal/device.cpp`):

1. `mlx.metallib` **colocated with the binary**
2. `Resources/mlx.metallib` colocated with the binary
3. `default.metallib` inside an `mlx-swift_Cmlx.bundle`
4. `Resources/default.metallib`
5. the literal relative path `default.metallib`

Xcode produces (3). We produce (1), which is checked first and needs no bundle at all.
`Scripts/build-metallib.sh` compiles the nine non-JIT-able `.metal` sources out of the
resolved `mlx-swift` checkout and drops `mlx.metallib` next to the `swift build` output.
It is compiled `-std=metal3.1 -mmacosx-version-min=14.0`: Metal 3.1 is what macOS 14
ships, and Metal libraries are forward compatible, so the floor is deliberate. Everything
MLX cannot pre-compile it JIT-compiles at runtime from strings embedded in the C++,
independently of this file and at whatever Metal version the running OS supports.

The result is byte-comparable to Xcode's: both export the same 382 functions and both
stamp `Platform MACOS 14.0` (`xcrun metal-vtool -show`). Ours is smaller (3.0 MB vs
3.8 MB) because Xcode's carries extra debug metadata.

Run it after any `swift build` into a fresh `.build`:

```bash
swift build -c release --target MoxSpeakNative
Scripts/build-metallib.sh            # writes .build/debug/ and .build/release/
```

An app bundle needs the same file next to its executable, in `Contents/MacOS/`.
`build-app.sh` puts it there, and signs it *before* the bundle around it: a `.metallib` is
a Mach-O-ish `MetalLib executable`, so `codesign` treats it as nested code and otherwise
refuses with "code object is not signed at all".

---

## Resources inside a signed `.app`

SwiftPM generates each resourced target's `Bundle.module` as, in effect:

```swift
Bundle(path: Bundle.main.bundleURL.appendingPathComponent("MoxSpeak_MisakiSwift.bundle"))
    ?? Bundle(path: "<absolute path into this machine's .build>")
```

For an app, `Bundle.main.bundleURL` is `MoxSpeak.app` **itself**, so that first path asks
for a directory at the root of the bundle, a sibling of `Contents/`. `codesign` will not
sign that:

```
MoxSpeak.app: unsealed contents present in the bundle root
```

and the second path is an absolute `.build` directory baked in at compile time, which
exists on exactly one machine. Neither can ship.

So `MoxSpeakResourceLocator` (one small file in each of the two resourced vendored
targets) looks in `Bundle.main.resourceURL` first — `Contents/Resources/` in an app, and
for a bare `swift build` executable the directory the binary sits in, which is where
SwiftPM already leaves the bundle. When neither has it (`swift test`, where `Bundle.main`
is the `.xctest` harness) it falls back to `Bundle.module`, which is what has always
worked there. `Bundle.module` is only *touched* on that fallback path, deliberately: its
generated accessor calls `fatalError` when it cannot find the bundle, so reaching for it
first and recovering afterwards is not an option.

### `Bundle.resourceURL` is base-relative, and MLX cares

`Bundle.resourceURL` returns a URL with a `baseURL` — `Contents/Resources/` *relative to*
the `.app`. `URL.path` flattens that and looks fine; `URL.path()`, the newer accessor,
returns only the relative half — and `URL.path()` is what `MLX.loadArrays(url:)` calls.
The symptom is the process aborting inside a vendored `try!` with

```
Failed to open file Contents/Resources/Models/kokoro-v1_0-fp16.safetensors
```

against a bundle where the file is plainly present. Both `MoxSpeakResourceLocator` and
`NativeModelAssets.bundleModelsDirectory` collapse the base with `.absoluteURL` for that
reason, and `theBundledModelDirectoryIsAnAbsoluteURLWithNoBaseLeftOnIt` pins it.
