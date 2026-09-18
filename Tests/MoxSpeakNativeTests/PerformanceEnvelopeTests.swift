import Testing
import Foundation
import MLX
@testable import MoxSpeakNative
import MoxSpeakCore

extension NativeEngineTests {

/// A standing proxy for a slower Mac than the one this was written on.
///
/// The development machine is an M2 Max. Most people who would run MoxSpeak are on a base
/// M1, M2 or M3, often fanless, often with 8 GB. This suite exists so the gap between
/// those two situations is a printed number somebody can look at, rather than an
/// assumption nobody has ever tested.
///
/// ## Run it
///
///     MOXSPEAK_PERF=1 swift test --filter PerformanceEnvelope
///     MOXSPEAK_PERF=1 MOXSPEAK_PERF_CPU=1 swift test --filter PerformanceEnvelope   # adds the CPU row, slow
///
/// It is **not** part of `swift test`. A wall-clock assertion that runs by default fails
/// whenever the machine is busy, gets called flaky, gets disabled, and then protects
/// nothing. The primary output here is the table; there is exactly one assertion in the
/// whole suite and it is sized to catch an order-of-magnitude regression, not noise.
///
/// ## What can actually be constrained, and what cannot
///
/// This is the honest part, and it is shorter than the plan hoped.
///
/// **GPU off — available, but not a usable proxy.** `MLX.Device.withDefaultDevice(.cpu)`
/// does move the whole graph to the CPU backend. Two things make the resulting number
/// useless as a stand-in for a weak GPU: it is roughly **180x slower** (62-70 s for a
/// 150-character utterance against 0.36 s), and it does not compute the same answer — the
/// duration predictor comes out systematically shorter, so "The quick brown fox jumps over
/// the lazy dog." yields 48,000 samples on the CPU backend against 85,800 on the GPU. That
/// divergence reproduces with MLX's global default device set as well as with the scoped
/// one, so it is the CPU backend itself, not a half-applied setting. The row is kept
/// behind `MOXSPEAK_PERF_CPU=1` so the number stays reproducible, and it is labelled as
/// what it is.
///
/// **Thread count — no such control exists.** MLX's CPU backend runs one worker thread per
/// stream (`mlx/scheduler.h`, `StreamThread`) and gets its parallelism from Accelerate.
/// There is no thread-count API in `mlx-swift` 0.30.2, and `VECLIB_MAXIMUM_THREADS`, the
/// usual lever on Accelerate, was measured to do nothing here: 1 / 2 / 4 / 8 threads gave
/// 62.60 / 62.51 / 62.58 / 65.68 s on the CPU backend and 1 / 2 / 4 gave 0.358 / 0.354 /
/// 0.356 s on the GPU path, against 0.360 s with the variable unset. Thread pinning is not available on Apple silicon either
/// (`thread_policy_set` affinity tags are a no-op on arm64), and QoS made no difference
/// because MLX creates its own stream thread at its own QoS. So the "4 threads" and
/// "2 threads" configurations the plan asked for are **not implemented, because they
/// cannot be**. Inventing rows for them would have been worse than saying so.
///
/// **Memory — this is the lever that works, and it is the one that matters.** The plan's
/// own reading of the risk was that low-end Macs would be limited by footprint on 8 GB
/// rather than by single-utterance latency. MLX's allocator takes both a memory ceiling
/// and a buffer-cache ceiling, and squeezing them moves the number in the right direction
/// and by a believable amount. Those are the constrained rows below.
///
/// ## What no configuration here can model
///
/// Say this out loud so a green run is never mistaken for hardware coverage:
///
/// - **Memory bandwidth.** An M2 Max has 400 GB/s; a base M3 has 100 GB/s. Nothing here
///   slows the bus down. A four-fold bandwidth cut is invisible to this suite.
/// - **Thermal throttling.** A fanless MacBook Air reading a long article will clock down
///   after a few minutes. Every number here is taken cold-ish on a machine with fans.
/// - **A different chip generation.** Fewer GPU cores, an older Metal feature set, a
///   different scheduler. Constraining an M2 Max does not turn it into an M1.
/// - **An 8 GB machine under real pressure**, where the OS is also compressing and
///   swapping other applications' memory.
///
/// The only thing that settles those is running the binary on such a machine. This suite
/// narrows what is worth checking there; it does not replace it.
@Suite(.enabled(if: NativeTestGate.isPerformanceReady), .serialized)
struct PerformanceEnvelopeTests {

    /// One provider for the suite. Both tests want a warm engine, and loading the model
    /// twice would only add a wait.
    ///
    /// Explicitly unconstrained (`mlxMemoryLimit: .max`) rather than
    /// `NativeSpeechProvider()`'s shipping default (`defaultMLXMemoryLimit`, 512 MB, see
    /// Phase 4). This suite exists to measure what a ceiling costs by applying one itself,
    /// per row, in `configurations()` below — if the provider's own load already clamped
    /// the global limit to 512 MB, `configurations()`'s "unconstrained" row would capture
    /// that 512 MB as its baseline and silently measure "512 MB vs 512 MB" instead of
    /// "512 MB vs actually unconstrained", which is the whole comparison this table exists
    /// to report.
    static let shared = NativeSpeechProvider(mlxMemoryLimit: .max)

    /// The one assertion in the suite, and it is deliberately loose.
    ///
    /// Unconstrained time to first audio for a `recommendedCharacterCap`-sized chunk
    /// measures ~0.25 s in a release build and ~0.9 s in the debug build `swift test`
    /// actually runs. Five seconds is five to twenty times that, depending on which build
    /// you are in: far enough away that a busy laptop, a cold shader cache or a parallel
    /// build cannot reach it, close enough that the regressions worth catching trip it
    /// immediately. For scale, the two that would: falling back to MLX's CPU backend takes
    /// this to ~60 s, and reloading the model per call adds a second or more every time.
    static let timeToFirstAudioBudget: TimeInterval = 5.0

    struct Configuration {
        var name: String
        var standsInFor: String
        /// Applied before the run and undone after. Returns nothing; the undo is the
        /// caller's job via `restore`.
        var apply: () -> Void
        var restore: () -> Void
        var onCPU: Bool = false
    }

    struct Measurement {
        var timeToFirstAudio: TimeInterval
        var fullSynthesis: TimeInterval
        var peakResident: Int
        var peakMLX: Int
        var audioSeconds: Double
    }

    // MARK: - The table

    @Test func printsThePerformanceEnvelope() async throws {
        let provider = Self.shared
        try await provider.prepare()

        let cap = provider.recommendedCharacterCap
        let firstChunk = Report.utterance(index: 0, targetCharacters: cap)
        let passage = (1...6).map { Report.utterance(index: $0, targetCharacters: cap) }

        var rows: [(Configuration, Measurement)] = []
        for configuration in Self.configurations() {
            let measurement = try await Self.measure(
                configuration: configuration, provider: provider,
                firstChunk: firstChunk, passage: passage)
            rows.append((configuration, measurement))
        }

        Self.printTable(rows: rows, cap: cap, passage: passage)

        let unconstrained = try #require(rows.first { $0.0.name == "unconstrained" }?.1)
        #expect(unconstrained.timeToFirstAudio < Self.timeToFirstAudioBudget,
                "time to first audio was \(Report.seconds(unconstrained.timeToFirstAudio)) against a budget of \(Report.seconds(Self.timeToFirstAudioBudget)); that budget carries at least five times the measured value in headroom, so tripping it means something structural changed, not that the machine was busy")
    }

    /// How `NativeSpeechProvider.recommendedCharacterCap` was chosen, kept runnable so the
    /// choice can be re-derived instead of trusted. No assertion: it is a measurement.
    @Test func printsTheChunkSizeSweep() async throws {
        let provider = Self.shared
        try await provider.prepare()

        var lines = [
            "",
            "CHUNK SIZE SWEEP — what chunk size costs, in time and in memory",
            "  build: \(Self.buildDescription)",
            "",
            "  chars   synthesis     audio   realtime   per-100-chars   peak RSS   MLX peak",
            "  -----  ----------  --------  ---------  --------------  ---------  ---------",
        ]
        for characters in [40, 60, 80, 100, 150, 200, 250, 300, 400] {
            var timings: [TimeInterval] = []
            var audioSeconds = 0.0
            var peakResident = 0
            MLX.GPU.resetPeakMemory()
            for repetition in 0..<4 {
                let text = Report.utterance(index: repetition * 7 + characters, targetCharacters: characters)
                let start = Date()
                let audio = try await provider.synthesize(text: text, voice: "af_bella", speed: 1.0)
                let elapsed = Date().timeIntervalSince(start)
                if repetition > 0 { timings.append(elapsed) }
                audioSeconds = Double(audio.count) / Double(AudioFormat.kokoroPCM.bytesPerSecond)
                peakResident = max(peakResident, ProcessMemory.sample().resident)
            }
            let median = Report.median(timings)
            lines.append(String(
                format: "  %5d  %9.3fs  %7.2fs  %8.1fx  %13.3fs  %8.0fM  %8.0fM",
                characters, median, audioSeconds, audioSeconds / median,
                median / Double(characters) * 100,
                Double(peakResident) / 1_048_576, Double(MLX.Memory.peakMemory) / 1_048_576))
        }
        lines += [
            "",
            "  Two readings, and they point in opposite directions.",
            "",
            "  Time is very nearly linear in characters with almost no fixed floor, so a",
            "  smaller chunk really does reach first sound sooner — and a larger one wastes",
            "  nothing per character. Realtime factor stays far above 1x at every size, so",
            "  the sequential renderer never risks starving playback whatever the cap.",
            "",
            "  Memory is not flat. MLX's peak grows with sequence length, and that is the",
            "  number that matters on an 8 GB machine — the constraint the plan predicted",
            "  would bind on low-end hardware.",
            "",
            "  `recommendedCharacterCap` is currently \(provider.recommendedCharacterCap);",
            "  `Segmenter.Options.firstChunkCap` (100) is the separate knob that sizes chunk 0,",
            "  and it is what actually governs time to first sound.",
            "",
        ]
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Configurations

    static func configurations() -> [Configuration] {
        // Captured once, up front: MLX's defaults are derived from the device's recommended
        // working set, so they are machine-specific and must be read rather than assumed.
        let defaultCacheLimit = MLX.Memory.cacheLimit
        let defaultMemoryLimit = MLX.Memory.memoryLimit

        func restoreDefaults() {
            MLX.Memory.memoryLimit = defaultMemoryLimit
            MLX.Memory.cacheLimit = defaultCacheLimit
        }

        var configurations: [Configuration] = [
            Configuration(
                name: "unconstrained",
                standsInFor: "this M2 Max, as shipped",
                apply: restoreDefaults,
                restore: restoreDefaults),
            Configuration(
                name: "no buffer cache",
                standsInFor: "a machine with no spare RAM to pool buffers in",
                apply: { restoreDefaults(); MLX.Memory.cacheLimit = 0 },
                restore: restoreDefaults),
            Configuration(
                name: "512 MB MLX ceiling",
                standsInFor: "an 8 GB machine with other apps open",
                apply: { restoreDefaults(); MLX.Memory.memoryLimit = 512 << 20 },
                restore: restoreDefaults),
            Configuration(
                name: "256 MB, no cache",
                standsInFor: "the pessimistic floor",
                apply: {
                    restoreDefaults()
                    MLX.Memory.memoryLimit = 256 << 20
                    MLX.Memory.cacheLimit = 0
                },
                restore: restoreDefaults),
        ]

        if NativeTestGate.flag("MOXSPEAK_PERF_CPU") {
            configurations.append(Configuration(
                name: "CPU backend *",
                standsInFor: "nothing — see the note; ~180x slower AND different audio",
                apply: restoreDefaults,
                restore: restoreDefaults,
                onCPU: true))
        }
        return configurations
    }

    // MARK: - Measurement

    static func measure(
        configuration: Configuration, provider: NativeSpeechProvider,
        firstChunk: String, passage: [String]
    ) async throws -> Measurement {
        configuration.apply()
        defer { configuration.restore() }

        let run: (String) async throws -> Data = { text in
            if configuration.onCPU {
                return try await MLX.Device.withDefaultDevice(.cpu) {
                    try await provider.synthesize(text: text, voice: "af_bella", speed: 1.0)
                }
            }
            return try await provider.synthesize(text: text, voice: "af_bella", speed: 1.0)
        }

        // One throwaway so the measurement sees the configuration's steady state rather
        // than the cost of switching into it. Skipped on the CPU backend, where a single
        // utterance costs over a minute.
        if !configuration.onCPU { _ = try await run(firstChunk) }

        MLX.GPU.resetPeakMemory()
        var peakResident = ProcessMemory.sample().resident

        var firstAudioTimings: [TimeInterval] = []
        for _ in 0..<(configuration.onCPU ? 1 : 3) {
            let start = Date()
            _ = try await run(firstChunk)
            firstAudioTimings.append(Date().timeIntervalSince(start))
            peakResident = max(peakResident, ProcessMemory.sample().resident)
        }

        // "Full synthesis" is the whole passage rendered chunk by chunk, the way
        // `SpeechSession` renders it — sequentially, in order, one request at a time.
        let passageStart = Date()
        var audioBytes = 0
        for text in (configuration.onCPU ? Array(passage.prefix(1)) : passage) {
            audioBytes += try await run(text).count
            peakResident = max(peakResident, ProcessMemory.sample().resident)
        }
        let fullSynthesis = Date().timeIntervalSince(passageStart)

        return Measurement(
            timeToFirstAudio: Report.median(firstAudioTimings),
            fullSynthesis: fullSynthesis,
            peakResident: peakResident,
            peakMLX: MLX.Memory.peakMemory,
            audioSeconds: Double(audioBytes) / Double(AudioFormat.kokoroPCM.bytesPerSecond))
    }

    // MARK: - Output

    static func printTable(rows: [(Configuration, Measurement)], cap: Int, passage: [String]) {
        var lines = [
            "",
            "PERFORMANCE ENVELOPE",
            "  host        : \(hostDescription())",
            "  build       : \(buildDescription)",
            "  first chunk : \(cap) characters   passage: \(passage.count) chunks, "
                + "\(passage.reduce(0) { $0 + $1.count }) characters",
            "",
            "  configuration        first audio    full passage   peak RSS   MLX peak   stands in for",
            "  -------------------  -----------  -------------  ---------  ---------  -------------",
        ]
        for (configuration, measurement) in rows {
            lines.append("  " + Report.padded(configuration.name, 21)
                + String(format: "%10.3fs   %11.3fs  %8.0fM  %8.0fM   ",
                         measurement.timeToFirstAudio, measurement.fullSynthesis,
                         Double(measurement.peakResident) / 1_048_576,
                         Double(measurement.peakMLX) / 1_048_576)
                + configuration.standsInFor)
        }
        if rows.contains(where: { $0.0.onCPU }) {
            lines += [
                "",
                "  * CPU backend is one utterance only, and it is not a comparable number: it runs",
                "    ~180x slower and its duration predictor produces materially shorter audio than",
                "    the GPU path for the same text. It is reported because it is reproducible, not",
                "    because it stands in for anything.",
            ]
        }
        lines += [
            "",
            "  Not modelled by any row above: memory bandwidth, thermal throttling on a fanless",
            "  body, a different chip generation, or an 8 GB machine under real pressure. A green",
            "  run here is not hardware coverage — see the note on this suite.",
            "",
        ]
        print(lines.joined(separator: "\n"))
    }

    static func hostDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let cores = ProcessInfo.processInfo.processorCount
        let ram = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let model = String(decoding: brand.prefix(while: { $0 != 0 }), as: UTF8.self)
        return "\(model), \(cores) cores, \(ram) GB, \(version)"
    }

    static var buildDescription: String {
        #if DEBUG
        return "debug (swift test default — a release build is roughly 30% faster here)"
        #else
        return "release"
        #endif
    }
}

}
