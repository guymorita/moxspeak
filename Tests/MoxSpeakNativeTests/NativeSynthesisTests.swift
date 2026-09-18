import Testing
import Foundation
@testable import MoxSpeakNative
import MoxSpeakCore

/// Real synthesis against the real weights. Opt-in:
///
///     MOXSPEAK_NATIVE_TESTS=1 swift test
///
/// Off by default for a reason that is not squeamishness. The first synthesis in a fresh
/// process spends one to five seconds compiling Metal pipelines, and Swift Testing runs
/// suites in parallel -- which starves `rateOfZeroCannotHangPlayback`, a real-time audio
/// test in MoxSpeakCoreTests with a five-second drain timeout. Left on, this suite makes
/// that test flake on a cold shader cache. Gating is cheaper than loosening a timeout
/// that is load-bearing.
///
/// Also skipped, opt-in or not, when the ~312 MB weight file or `mlx.metallib` is absent:
/// a checkout with no models is a normal state, not a broken one.
///
///     swift build --target MoxSpeakNative && Scripts/build-metallib.sh
///     python3 Scripts/prepare-models.py --checkpoint ... --voices ... --out Models
///
/// `@MainActor` rather than `.serialized`: the engine is deliberately not `Sendable`
/// (MLX's default stream is process-global shared state), so sharing one across tests
/// means pinning them to a single isolation domain -- which is also how the app will
/// have to use it.
enum NativeTestEnvironment {
    /// Evaluated once, before any test in the suite runs, because Swift Testing decides
    /// whether to run a suite from a trait rather than letting a test skip itself
    /// mid-flight. Every precondition the synthesis tests have has to be answered here or
    /// a missing file shows up as eight failures instead of a skip.
    static let isReady: Bool = {
        guard ProcessInfo.processInfo.environment["MOXSPEAK_NATIVE_TESTS"] == "1" else { return false }
        guard NativeRuntime.isAvailable else { return false }
        for precision in NativeModelAssets.Precision.allCases {
            guard (try? NativeModelAssets.resolveDefault(precision: precision).validate()) != nil else {
                return false
            }
        }
        return NativeModelAssets.resolveDefault().availableVoices().contains("af_bella")
    }()
}

// Nested inside `NativeEngineTests` so it does not run in parallel with the other suites
// that drive the model — see the note on that type.
extension NativeEngineTests {

@MainActor
@Suite(.enabled(if: NativeTestEnvironment.isReady))
struct NativeSynthesisTests {

    /// MLX's default stream is process-global and the model is 312 MB; one engine shared
    /// across the suite is both the realistic usage and the only affordable one.
    static let shared: NativeKokoroEngine? = try? NativeKokoroEngine()

    func engine() throws -> NativeKokoroEngine {
        try #require(Self.shared, "engine failed to load; see Sources/Vendor/VENDORED.md")
    }

    @Test func synthesizesAudioOfAPlausibleLength() throws {
        let samples = try engine().synthesizeSamples(
            text: "The quick brown fox jumps over the lazy dog.", voice: "af_bella"
        )
        let seconds = Double(samples.count) / NativeKokoroEngine.outputFormat.sampleRate
        // The reference PyTorch run produces 3.58 s for this sentence. A generous window:
        // this is asserting "speech happened", not reproducing the duration predictor.
        #expect(seconds > 2.0 && seconds < 6.0)
    }

    @Test func audioIsNotSilenceAndNotClipped() throws {
        let samples = try engine().synthesizeSamples(text: "Testing, one two three.", voice: "af_bella")
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.05, "output is silence")
        #expect(peak <= 1.5, "output is wildly out of range")
    }

    @Test func pcmByteCountMatchesTheSampleCount() throws {
        let engine = try engine()
        let text = "Two channels would double this."
        let samples = try engine.synthesizeSamples(text: text, voice: "af_bella")
        let pcm = try engine.synthesize(text: text, voice: "af_bella")
        #expect(pcm.count == samples.count * 2)
    }

    @Test func slowerSpeedProducesLongerAudio() throws {
        let engine = try engine()
        let text = "Speed is a request to the duration predictor, not a resample."
        let normal = try engine.synthesizeSamples(text: text, voice: "af_bella", speed: 1.0)
        let slow = try engine.synthesizeSamples(text: text, voice: "af_bella", speed: 0.7)
        #expect(slow.count > normal.count)
    }

    @Test func emptyTextIsRejectedBeforeTouchingTheModel() throws {
        let engine = try engine()
        #expect(throws: NativeKokoroEngine.SynthesisError.self) {
            try engine.synthesizeSamples(text: "   \n  ", voice: "af_bella")
        }
    }

    @Test func aMissingVoiceNamesItselfRatherThanCrashing() throws {
        let engine = try engine()
        #expect(throws: NativeModelAssets.ResolutionError.self) {
            try engine.synthesizeSamples(text: "Hello.", voice: "no_such_voice")
        }
    }

    @Test func phonemesComeOutOfTheVendoredG2P() throws {
        let phonemes = try engine().phonemes(for: "Hello world.")
        #expect(!phonemes.isEmpty)
        // Misaki emits IPA with its own stress marks; the one thing worth pinning is that
        // it is not echoing the input back.
        #expect(phonemes.lowercased() != "hello world.")
    }

    @Test func fp16LoadsAndTracksFp32Closely() throws {
        let fp16 = try NativeKokoroEngine(assets: .resolveDefault(precision: .float16))

        let text = "Half precision should not change how long this takes to say."
        let half = try fp16.synthesizeSamples(text: text, voice: "af_bella")
        let full = try engine().synthesizeSamples(text: text, voice: "af_bella")

        // Same duration predictor, same rounding: the sample counts match exactly. The
        // acoustic comparison (mel LSD 0.86 dB between the two) lives in the report, not
        // here — this only has to catch fp16 diverging structurally.
        #expect(half.count == full.count)
    }
}

}
