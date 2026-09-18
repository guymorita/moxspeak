import Foundation
import MLX
import MoxSpeakCore

/// `MoxSpeakCore.SpeechProvider` backed by in-process Kokoro inference.
///
/// Drops into `SpeechSession` wherever `OpenAICompatibleProvider` goes. Nothing downstream
/// changes: the bytes are `AudioFormat.kokoroPCM`, the same shape the HTTP provider returns.
///
/// ## Why an actor
///
/// `NativeKokoroEngine` is deliberately not `Sendable` — MLX's default stream, the vendored
/// KokoroSwift graph and the lazily-loaded G2P lexicon are all shared mutable state. Some
/// isolation domain has to own it, and `SpeechProvider` is `Sendable`, so the provider is
/// the natural place for that ownership. One actor, one engine, one caller at a time.
///
/// The cost, stated plainly: `synthesize` blocks its executor thread for the duration of
/// inference (~0.35 s for a 150-character chunk on an M2 Max) because Kokoro inference is
/// a synchronous compute call with no suspension points inside it. That is acceptable here
/// — `SpeechSession` renders chunks strictly sequentially anyway, so there is no second
/// request to overlap with, and the app's UI runs on `@MainActor`, which has its own
/// executor and is not part of the pool being blocked.
///
/// ## Statelessness
///
/// The only state that outlives a call is the model itself and the engine's voice-vector
/// cache, both keyed by things that do not grow with usage. Nothing accumulates per
/// request: no audio cache, no history, no per-call buffer that is retained. That property
/// is what `StatelessnessTests` exists to defend — see the note there about the ~28 MB
/// per-request leak in the previous engine.
public actor NativeSpeechProvider: SpeechProvider {

    // MARK: - Declared behaviour
    //
    // `nonisolated` because `SpeechProvider`'s requirements are synchronous and are read
    // from outside the actor. They are constants, so there is nothing to protect.

    /// Exactly what `NativeKokoroEngine.pcm16` writes: 24 kHz, mono, signed 16-bit LE, raw.
    /// Not an aspiration — `nativeOutputFormatIsExactlyTheFormatPlaybackExpects` pins it to
    /// the engine's own declaration, and the engine's PCM encoding is tested byte for byte.
    public nonisolated var outputFormat: AudioFormat { NativeKokoroEngine.outputFormat }

    /// False. `generateAudio` returns one finished buffer; there is no partial audio to
    /// hand back early, and inventing a streaming interface over a call that produces all
    /// its samples at once would only move the wait.
    public nonisolated var supportsIncrementalStreaming: Bool { false }

    /// True, and this is the whole reason `TextNormalizer` was built in Phase 1.
    ///
    /// The vendored MisakiSwift is upstream's, bugs included: fed `$1,234.56` it emits
    /// "minus six hundred ten point four four…". Fed the *normalized* form of the same
    /// sentence it produces phonemes character-for-character identical to Python `misaki`.
    /// Normalizing first is not a nicety here, it is the difference between correct and
    /// nonsense — and unlike the HTTP provider there is no server doing it for us.
    public nonisolated var requiresTextNormalization: Bool { true }

    /// The largest chunk this engine should be handed. Measured, not guessed — the sweep
    /// that produced it is `PerformanceEnvelopeTests.printsTheChunkSizeSweep`, and the
    /// numbers are in `.superpowers/native-provider-report.md`.
    ///
    /// Deliberately **not** the HTTP provider's 150. That number is a workaround for the
    /// PyTorch-MPS truncation bug in Kokoro-FastAPI, which loses audio above roughly 180
    /// characters. In-process inference does not have that bug, so carrying the number
    /// over would be inheriting a workaround for someone else's problem.
    ///
    /// What the measurement actually says, and the first finding contradicts the intuition
    /// this started from:
    ///
    /// 1. **There is no meaningful fixed cost per synthesis.** Time is very nearly linear
    ///    in characters — 0.77 to 0.84 seconds per 100 characters across a 40-to-400
    ///    character sweep, within 8% across a 10x span. So a smaller chunk genuinely does
    ///    reach first sound sooner, all the way down; there is no knee below which
    ///    shrinking stops paying. The knee is in perception, not in the engine.
    /// 2. **Peak memory is not flat.** MLX's high-water allocation rises with sequence
    ///    length — 1.2 GB at 60 characters, 1.7 GB at 100, 2.1 GB at 150, 2.8 GB at 400.
    ///    Footprint on an 8 GB machine is the risk the plan named for low-end hardware, and
    ///    this is the knob that moves it. 100 sits 18% below where 150 would put it.
    /// 3. **Nothing in this range starves playback.** Synthesis runs at 7-9x realtime at
    ///    every size measured, so the sequential renderer stays far ahead of the player
    ///    whatever the cap.
    /// 4. **The token ceiling is far away.** Kokoro's context window is 510 tokens and
    ///    MisakiSwift emits 1.05-1.11 phonemes per character on ordinary English (1.30 on
    ///    very short strings), so 100 characters is ~110 tokens against a 510 limit.
    ///
    /// So the cap is set by language rather than by the engine: **100 characters is about
    /// the smallest chunk that still holds a whole typical English sentence**, and every
    /// chunk boundary is a place where Kokoro restarts its prosody contour. Below it the
    /// segmenter starts splitting sentences mid-clause for latency the user cannot
    /// perceive — 100 characters is already ~0.25 s in a release build, half the plan's
    /// half-second target and well inside the noise of pressing a hotkey.
    ///
    /// Honest caveat: the seam cost has not been measured acoustically. 100 produces about
    /// 50% more chunk boundaries across a long article than the server's 150 does, and
    /// nobody has listened for whether that is audible. If it turns out to be, this number
    /// should go up rather than the reasoning being rewritten.
    ///
    /// Two related numbers that are *not* this one:
    ///
    /// - `Segmenter.Options.firstChunkCap` (currently 100) is what actually sizes chunk 0
    ///   and therefore what governs time to first sound. This cap only lowers it, never
    ///   raises it: the segmenter takes `min(firstChunkCap, characterCap)` for chunk 0.
    /// - `NativeKokoroEngine.recommendedCharacterCap` is the engine's own cheap pre-check
    ///   against the 510-token context window. Different question, different number.
    public nonisolated var recommendedCharacterCap: Int { Self.measuredCharacterCap }

    static let measuredCharacterCap = 100

    /// Ceiling on MLX's total allocation (`MLX.Memory.memoryLimit`), applied once when the
    /// model loads.
    ///
    /// Unbounded, peak MLX allocation for a single chunk reaches **~1.7 GB at the 100-char
    /// `recommendedCharacterCap`** (Phase 3b, `.superpowers/native-provider-report.md`) —
    /// fine on this 64 GB development machine, uncomfortable on an 8 GB MacBook Air with a
    /// browser open, which the plan names as a real target, not a hypothetical one.
    ///
    /// `PerformanceEnvelopeTests` measured what a ceiling here actually costs (release
    /// build, 150-char chunk):
    ///
    ///     unconstrained          0.359 s
    ///     512 MB MLX ceiling     0.399 s   (+11%)
    ///
    /// +11% latency for a bounded footprint is a good trade — the constrained figure is
    /// still comfortably under the plan's half-second target and 2.7x faster than the HTTP
    /// server's unconstrained 1.949 s. 512 MB is not a magic number beyond "measured and
    /// acceptable"; it is exposed as `mlxMemoryLimit` below rather than hardcoded inside
    /// `synthesize` so it can be tuned (or disabled, by passing `.max`) without touching
    /// call-path code.
    public static let defaultMLXMemoryLimit = 512 << 20   // 512 MB

    // MARK: - State

    public nonisolated let assets: NativeModelAssets

    /// The MLX memory ceiling this instance applies at model load. See
    /// `defaultMLXMemoryLimit`.
    public nonisolated let mlxMemoryLimit: Int

    /// Loaded once, on first use, and kept. Not recreated per request — the whole point.
    private var engine: NativeKokoroEngine?
    /// Counts `NativeKokoroEngine` constructions. Exists so a test can prove "loads once"
    /// rather than assume it; there is no other way to observe it from outside.
    private(set) var modelLoadCount = 0

    /// - Parameters:
    ///   - assets: where the weights and voices live. Defaults to fp16, which the
    ///     Phase 3 measurement found acoustically indistinguishable from our own f32
    ///     (0.85 dB mel LSD, 0.9994 cosine) at half the size — 156 MB against 312 MB.
    ///     `NativeKokoroEngine` still defaults to f32 because the comparison harness needs
    ///     a reference; the provider is the product surface, so it takes the shipping
    ///     choice.
    ///   - mlxMemoryLimit: ceiling applied to `MLX.Memory.memoryLimit` when the model
    ///     loads. Defaults to `defaultMLXMemoryLimit` (512 MB, measured). Configurable
    ///     rather than fixed so a caller — a future low-memory mode, a test — can raise or
    ///     lower it without editing this type.
    public init(assets: NativeModelAssets = .resolveDefault(precision: .float16),
                mlxMemoryLimit: Int = NativeSpeechProvider.defaultMLXMemoryLimit) {
        self.assets = assets
        self.mlxMemoryLimit = mlxMemoryLimit
    }

    /// Loads the model and runs one throwaway synthesis.
    ///
    /// Optional — `synthesize` does this on its own if it has to. Call it at launch so the
    /// first hotkey press does not pay for it: a cold process spends ~0.9-1.0 s on its
    /// first utterance against ~0.35 s steady state, most of it Metal pipeline compilation
    /// and lazy lexicon loading.
    @discardableResult
    public func prepare(voice: String = "af_bella") throws -> TimeInterval {
        try loadedEngine().warmUp(voice: voice)
    }

    // MARK: - SpeechProvider

    public func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        try Task.checkCancellation()

        let engine = try loadedEngine()
        let audio = try engine.synthesize(text: text, voice: voice, speed: speed)

        // Kokoro inference is one synchronous call with no suspension point inside it, so
        // this is the first moment cancellation can be observed. Checking here rather than
        // returning anyway is what keeps a superseded chunk from being committed: the
        // session treats `CancellationError` as a terminal state and discards the audio.
        try Task.checkCancellation()
        return audio
    }

    /// The voices on disk, as the app's picker wants them.
    ///
    /// Reads the filesystem; does not load the model. A voices directory that is not there
    /// throws rather than returning an empty list — an empty picker and a broken install
    /// are different problems and should not look the same.
    public func listVoices() async throws -> [Voice] {
        let directory = assets.voicesDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw NativeModelAssets.ResolutionError.directoryMissing(directory)
        }
        // Kokoro's voice files carry no display name of their own — the basename
        // ("af_bella") is the identity the model, the CLI and the HTTP engine all use, so
        // inventing a prettier one here would only create a second name for one thing.
        return assets.availableVoices().map { Voice(id: $0, name: $0) }
    }

    // MARK: - Model

    private func loadedEngine() throws -> NativeKokoroEngine {
        if let engine { return engine }
        // Applied once, alongside the model load it protects — not inside `synthesize`,
        // where it would be re-set (harmlessly, but pointlessly) on every single chunk.
        // `MLX.Memory.memoryLimit` is process-global state, matching how mlx-swift exposes
        // it (see `PerformanceEnvelopeTests`, the only other place this repo sets it).
        MLX.Memory.memoryLimit = mlxMemoryLimit
        let engine = try NativeKokoroEngine(assets: assets)
        self.engine = engine
        modelLoadCount += 1
        return engine
    }
}
