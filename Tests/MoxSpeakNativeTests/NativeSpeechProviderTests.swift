import Testing
import Foundation
import MLX
@testable import MoxSpeakNative
import MoxSpeakCore

// MARK: - What the provider declares
//
// These need nothing on disk. They are cheap, and they are the half of the contract that
// is *trusted rather than verified* by everything downstream: `SpeechSession` divides byte
// counts by `outputFormat.bytesPerSecond` to get durations and never checks the answer, so
// a wrong declaration here is silently wrong everywhere.

@Test func providerDeclaresTheFormatTheEngineActuallyEmits() {
    let provider = NativeSpeechProvider(assets: NativeModelAssets(directory: URL(fileURLWithPath: "/nope")))
    #expect(provider.outputFormat == NativeKokoroEngine.outputFormat)
    #expect(provider.outputFormat == AudioFormat.kokoroPCM)
}

@Test func providerDoesNotClaimStreamingItCannotDo() {
    let provider = NativeSpeechProvider(assets: NativeModelAssets(directory: URL(fileURLWithPath: "/nope")))
    #expect(provider.supportsIncrementalStreaming == false)
}

@Test func theTwoProvidersDisagreeAboutNormalizationOnPurpose() {
    // The one flag whose value is different for the two engines, and the one that is
    // silently destructive in both directions. Pinning them together is the point: a
    // future edit that "harmonizes" them breaks one engine or the other.
    let native = NativeSpeechProvider(assets: NativeModelAssets(directory: URL(fileURLWithPath: "/nope")))
    let http = OpenAICompatibleProvider(config: .kokoroLocal(port: 8880))
    #expect(native.requiresTextNormalization == true, "MisakiSwift reads '$1,234.56' as digits unless we expand it first")
    #expect(http.requiresTextNormalization == false, "Kokoro-FastAPI normalizes server-side; doing it twice corrupts text")
}

@Test func characterCapIsItsOwnNumberNotTheServersWorkaround() {
    let provider = NativeSpeechProvider(assets: NativeModelAssets(directory: URL(fileURLWithPath: "/nope")))
    // 150 is the HTTP provider's number, and it exists only to dodge the PyTorch-MPS
    // truncation bug in Kokoro-FastAPI. In-process inference does not have that bug, so
    // inheriting the number would be inheriting a workaround for someone else's problem.
    #expect(provider.recommendedCharacterCap != OpenAICompatibleProvider(config: .kokoroLocal(port: 8880)).recommendedCharacterCap)
    // Bounds, not a restatement of the constant. The floor is linguistic: a chunk much
    // under ~60 characters cannot hold a typical English sentence, so the segmenter starts
    // splitting mid-clause and Kokoro restarts its prosody contour inside a phrase. The
    // ceiling is the model's: Kokoro's context window is 510 tokens and MisakiSwift emits
    // 1.05-1.11 phonemes per character on ordinary English, so 400 characters is already
    // within reach of `tooManyTokens` on phoneme-dense text.
    #expect(provider.recommendedCharacterCap >= 60)
    #expect(provider.recommendedCharacterCap <= 350)
}

@Test func itFitsTheSpeechProviderSeamWithoutAdaptation() {
    // The seam is the deliverable: the app plumbing takes `any SpeechProvider` and must
    // not need to know which engine it got.
    let provider: any SpeechProvider =
        NativeSpeechProvider(assets: NativeModelAssets(directory: URL(fileURLWithPath: "/nope")))
    #expect(provider.outputFormat.bytesPerSecond == 48000)
}

// MARK: - Voices
//
// Voice listing reads the filesystem and nothing else, so it works — and is tested — with
// no 156 MB weight file anywhere near it.

private func temporaryVoicesDirectory(_ names: [String]) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let voices = directory.appendingPathComponent("voices", isDirectory: true)
    try FileManager.default.createDirectory(at: voices, withIntermediateDirectories: true)
    for name in names {
        try Data().write(to: voices.appendingPathComponent(name))
    }
    return directory
}

@Test func listVoicesComesFromTheBundledVoiceFiles() async throws {
    let directory = try temporaryVoicesDirectory(
        ["bm_george.safetensors", "af_bella.safetensors", "readme.txt"])
    defer { try? FileManager.default.removeItem(at: directory) }

    let provider = NativeSpeechProvider(assets: NativeModelAssets(directory: directory))
    let voices = try await provider.listVoices()

    #expect(voices == [Voice(id: "af_bella", name: "af_bella"),
                       Voice(id: "bm_george", name: "bm_george")])
}

@Test func listVoicesDoesNotNeedTheModelLoaded() async throws {
    // No weight file exists in this directory at all. If listing voices ever starts
    // loading the model, this test starts throwing `weightsMissing` and says so.
    let directory = try temporaryVoicesDirectory(["af_bella.safetensors"])
    defer { try? FileManager.default.removeItem(at: directory) }

    let provider = NativeSpeechProvider(assets: NativeModelAssets(directory: directory))
    #expect(try await provider.listVoices().count == 1)
}

@Test func listVoicesThrowsRatherThanQuietlyReturningNothing() async throws {
    let directory = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let provider = NativeSpeechProvider(assets: NativeModelAssets(directory: directory))
    // An empty picker and a broken install must not look the same to the app.
    await #expect(throws: NativeModelAssets.ResolutionError.self) {
        _ = try await provider.listVoices()
    }
}

// MARK: - Against the real model

extension NativeEngineTests {

/// Opt-in exactly like `NativeSynthesisTests`, and for the same reason: the first
/// synthesis in a fresh process spends seconds compiling Metal pipelines, which starves a
/// real-time audio test elsewhere in the package when suites run in parallel.
///
///     MOXSPEAK_NATIVE_TESTS=1 swift test
@Suite(.enabled(if: NativeTestGate.isSoakReady), .serialized)
struct NativeSpeechProviderSynthesisTests {

    /// One provider for the suite: loading the model is the expensive part and a warm
    /// provider is the realistic subject. `theModelLoadsOnceNoMatterHowManyCallsArrive`
    /// deliberately uses its own, since it is counting loads.
    static let shared = NativeSpeechProvider()

    @Test func synthesizedBytesAreTheEnginesOwnPCM() async throws {
        let text = "The provider is a wrapper, not a second implementation."

        // Kokoro's decoder excites its source module with Gaussian noise drawn from MLX's
        // global RNG, so two syntheses of the same text are *not* bit-identical by
        // default — the sample count matches, the samples do not. Seeding either side
        // identically is what turns "same wrapper" into something a byte comparison can
        // actually prove. (That this seeding works is itself evidence the only
        // nondeterminism is the RNG.)
        MLX.seed(20260918)
        let viaProvider = try await Self.shared.synthesize(text: text, voice: "af_bella", speed: 1.0)

        let engine = try NativeKokoroEngine(assets: .resolveDefault(precision: .float16))
        MLX.seed(20260918)
        let viaEngine = try engine.synthesize(text: text, voice: "af_bella", speed: 1.0)

        #expect(viaProvider == viaEngine)
        #expect(viaProvider.count % 2 == 0)
        let seconds = Double(viaProvider.count) / Double(AudioFormat.kokoroPCM.bytesPerSecond)
        #expect(seconds > 1.0 && seconds < 10.0)
    }

    @Test func theModelLoadsOnceNoMatterHowManyCallsArrive() async throws {
        let provider = NativeSpeechProvider()
        for index in 0..<4 {
            _ = try await provider.synthesize(
                text: "Call number \(index), and the model had better already be here.",
                voice: "af_bella", speed: 1.0)
        }
        // Not "it felt fast" — the construction count itself. Property 3 of the plan stands
        // or falls on the model being loaded once and kept.
        #expect(await provider.modelLoadCount == 1)
    }

    /// Phase 4: bounding MLX's memory. Unbounded, peak MLX allocation for a single
    /// ~100-character chunk reaches ~1.7 GB (`printsTheChunkSizeSweep` reproduces this
    /// figure directly). `NativeSpeechProvider()`'s default constructor now applies a
    /// 512 MB ceiling (`defaultMLXMemoryLimit`) at model load — this proves that ceiling
    /// is actually reaching `MLX.Memory.memoryLimit`, not just being stored and ignored.
    ///
    /// `Self.shared` (this suite's default-constructed, already-warm provider) stands in
    /// for the shipping ceiling; a second, freshly-loaded provider constructed with
    /// `mlxMemoryLimit: .max` stands in for "no ceiling at all". Comparing MLX's own peak
    /// allocation across the two for an identical chunk is a direct, not inferred, check
    /// that the ceiling binds.
    @Test func defaultConstructionActuallyAppliesTheMeasuredMLXMemoryCeiling() async throws {
        let capped = Self.shared
        try await capped.prepare()
        #expect(capped.mlxMemoryLimit == NativeSpeechProvider.defaultMLXMemoryLimit)

        let text = Report.utterance(index: 0, targetCharacters: 100)

        MLX.GPU.resetPeakMemory()
        _ = try await capped.synthesize(text: text, voice: "af_bella", speed: 1.0)
        let cappedPeak = MLX.Memory.peakMemory

        let uncapped = NativeSpeechProvider(mlxMemoryLimit: .max)
        try await uncapped.prepare()
        MLX.GPU.resetPeakMemory()
        _ = try await uncapped.synthesize(text: text, voice: "af_bella", speed: 1.0)
        let uncappedPeak = MLX.Memory.peakMemory

        print("MLX MEMORY CEILING — capped (512 MB) peak \(Report.megabytes(cappedPeak))"
            + " vs uncapped peak \(Report.megabytes(uncappedPeak))")

        let comparisonMessage = "512 MB ceiling should measurably lower MLX's own peak allocation; "
            + "capped=\(cappedPeak) bytes, uncapped=\(uncappedPeak) bytes"
        #expect(cappedPeak < uncappedPeak, "\(comparisonMessage)")
        // Generous headroom above the 512 MB target itself -- memoryLimit is backpressure
        // (mlx-swift: "calls to malloc will wait on scheduled tasks if exceeded"), not a
        // hard cap, so some overshoot is expected and already measured elsewhere
        // (PerformanceEnvelopeTests' own "512 MB MLX ceiling" row peaks around 900-950 MB
        // across a whole run). This just rules out the ceiling doing nothing at all.
        let boundMessage = "capped peak \(Report.megabytes(cappedPeak)) is nowhere near the ~1.7 GB "
            + "unconstrained figure for a 100-char chunk; the ceiling appears not to be binding"
        #expect(cappedPeak < 1_200 << 20, "\(boundMessage)")
    }

    @Test func aCancelledTaskDoesNotHandBackAudio() async throws {
        let provider = Self.shared
        try await provider.prepare()

        let task = Task {
            try await provider.synthesize(
                text: "This request is abandoned before its audio could ever be played.",
                voice: "af_bella", speed: 1.0)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func theExistingSessionDrivesItUnchanged() async throws {
        // The whole point of conforming to the protocol: no new plumbing. This is the real
        // `SpeechSession`, with the real segmenter, normalizer and validation ladder.
        let provider = Self.shared
        try await provider.prepare()

        let session = SpeechSession(provider: provider)
        await session.speak("The bill came to $12.50 on March 3rd. We paid it and left.", voice: "af_bella")
        await session.waitForRenderComplete()

        let chunks = await session.chunks
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            let state = await session.state(of: chunk.id)
            guard case .rendered(let data, let duration) = state else {
                Issue.record("chunk \(chunk.id) did not render: \(state)")
                continue
            }
            #expect(!data.isEmpty)
            #expect(duration > 0)
        }
    }

    @Test func normalizationHappensBecauseTheProviderAsksForIt() async throws {
        // `SpeechSession` runs `TextNormalizer` only when the provider says to. This is the
        // observable consequence: the engine is handed words, not "$12.50".
        let provider = NativeSpeechProvider()
        try await provider.prepare()

        let engine = try NativeKokoroEngine(assets: .resolveDefault(precision: .float16))
        let raw = try engine.phonemes(for: "It cost $12.50.")
        let normalized = try engine.phonemes(for: TextNormalizer().normalize("It cost $12.50."))
        #expect(raw != normalized, "if these ever agree, requiresTextNormalization has stopped earning its keep")
    }
}

}
