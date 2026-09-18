import Foundation
import MoxSpeakCore
import MoxSpeakNative

/// `MOXSPEAK_SELFTEST=1 MoxSpeak.app/Contents/MacOS/MoxSpeak` — proves the installed app
/// can speak using nothing but itself, then exits without ever creating a menu bar item.
///
/// This exists because "self-contained" is otherwise unfalsifiable from the outside. Even
/// now that the native engine is the default, a normal launch resolves its assets through
/// `NativeModelAssets.defaultDirectory`, which happily falls through to a developer's
/// checkout — so an app that works here proves nothing about an app that has been dragged
/// to another machine. This path loads the bundled model, the
/// bundled voice, the bundled lexicon and the bundled metallib, synthesizes real audio, and
/// reports where every one of those came from — so moving the repository's `Models/`
/// directory aside and re-running it is a test that can actually fail.
///
/// It is a diagnostic, not a feature: nothing reaches it unless the variable is set, and
/// normal launch is byte-for-byte the code path it was before.
enum NativeSelfTest {

    static let environmentKey = "MOXSPEAK_SELFTEST"

    /// The owner's voice. Named explicitly rather than taking the engine default so the
    /// self-test fails loudly if a voice-trimming decision ever drops it.
    static let defaultVoice = "am_michael"

    static let phrase = "The quick brown fox jumps over the lazy dog, twice, at 3:30 p.m."

    static func isRequested(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Runs the check and terminates the process: 0 if the bundle can speak on its own,
    /// 1 otherwise.
    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        // Line-buffer stdout. The vendored weight loader uses `try!`, so a bad path aborts
        // the process — and a block-buffered pipe would swallow every diagnostic printed
        // below, leaving only the crash. The diagnostics are the point.
        setvbuf(stdout, nil, _IOLBF, 0)

        let voice = environment["MOXSPEAK_SELFTEST_VOICE"] ?? defaultVoice
        let bundle = Bundle.main

        print("bundle              \(bundle.bundlePath)")
        print("bundle resources    \(bundle.resourceURL?.path ?? "<none>")")

        // Metal library. MLX resolves this relative to the binary, not the bundle, which is
        // why it ships in Contents/MacOS rather than Contents/Resources.
        let metallib = NativeRuntime.metalLibraryURL
        print("metallib            \(metallib?.path ?? "<MISSING>")")

        // Lexicon. MisakiSwift reads it through `Bundle`; asking the bundle for the file is
        // asking the same question the engine will ask.
        let lexicon = bundle.resourceURL?
            .appendingPathComponent("MoxSpeak_MisakiSwift.bundle/Resources/us_gold.json")
        let lexiconFound = lexicon.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        print("lexicon             \(lexiconFound ? (lexicon?.path ?? "") : "<MISSING>")")

        let assets = NativeModelAssets.resolveDefault(precision: .float16)
        let insideBundle = bundle.resourceURL.map {
            assets.directory.path.hasPrefix($0.path + "/") || assets.directory.path == $0.path
        } ?? false
        print("models              \(assets.directory.path)")
        print("models in bundle    \(insideBundle)")
        print("weights             \(assets.weightsURL.lastPathComponent)")
        print("voices              \(assets.availableVoices().count)")
        print("voice requested     \(voice) "
              + (assets.availableVoices().contains(voice) ? "(present)" : "(MISSING)"))

        guard metallib != nil else { fail("no MLX metallib beside the binary") }
        guard lexiconFound else { fail("no MisakiSwift lexicon bundle in Contents/Resources") }
        do { try assets.validate() } catch { fail("\(error)") }
        guard assets.availableVoices().contains(voice) else { fail("voice '\(voice)' is not in the bundle") }

        let outcome = synthesizeBlocking(assets: assets, voice: voice)
        switch outcome {
        case .failure(let message):
            fail(message)
        case .success(let bytes, let seconds, let peak):
            let audioSeconds = Double(bytes) / Double(AudioFormat.kokoroPCM.bytesPerSecond)
            print(String(format: "synthesized         %d bytes (%.2f s of audio) in %.2f s",
                         bytes, audioSeconds, seconds))
            print(String(format: "peak amplitude      %.3f of full scale", peak))
            guard bytes > 0 else { fail("synthesis produced no audio") }
            // A byte count alone would pass on a buffer of silence, which is exactly what a
            // half-loaded model produces. 0.05 is far below any real speech and far above
            // dither.
            guard peak > 0.05 else { fail("audio is silent (peak \(peak)) — the model loaded but produced nothing") }
            print("SELFTEST OK — this bundle speaks using nothing outside itself")
            exit(0)
        }
    }

    // MARK: - Plumbing

    private enum Outcome: Sendable {
        case success(bytes: Int, seconds: TimeInterval, peak: Double)
        case failure(String)
    }

    /// Largest absolute sample as a fraction of full scale, over raw signed 16-bit LE mono.
    private static func peakAmplitude(_ pcm: Data) -> Double {
        var peak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let magnitude = Int32(sample == Int16.min ? Int16.max : abs(sample))
                if magnitude > peak { peak = magnitude }
            }
        }
        return Double(peak) / Double(Int16.max)
    }

    /// `main.swift` has no async context and `NSApplication` has not started, so the work
    /// runs on a detached task and this thread waits for it.
    private static func synthesizeBlocking(assets: NativeModelAssets, voice: String) -> Outcome {
        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let provider = NativeSpeechProvider(assets: assets)
            let started = Date()
            do {
                let audio = try await provider.synthesize(text: phrase, voice: voice, speed: 1.0)
                box.store(.success(bytes: audio.count,
                                   seconds: Date().timeIntervalSince(started),
                                   peak: peakAmplitude(audio)))
            } catch {
                box.store(.failure("synthesis failed: \(error)"))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.take() ?? .failure("synthesis produced no result")
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Outcome?
        func store(_ outcome: Outcome) { lock.lock(); value = outcome; lock.unlock() }
        func take() -> Outcome? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func fail(_ message: String) -> Never {
        print("SELFTEST FAILED — \(message)")
        exit(1)
    }
}
