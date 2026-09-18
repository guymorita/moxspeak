import Testing
import Foundation
import MLX
@testable import MoxSpeakNative
import MoxSpeakCore

extension NativeEngineTests {

/// Property 3 of the native-engine plan: **run 200 is as fast as run 1**.
///
/// This is not a nice-to-have and it is not paranoia. The engine MoxSpeak shipped before
/// this one leaked roughly 28 MB per request and got measurably slower over an afternoon
/// of use; the failure cost a day to find because nothing was watching for it. The design
/// that replaces it is supposed to make that structurally impossible — the model loads
/// once, and nothing is retained per call — but "supposed to" is what the previous engine
/// had too.
///
/// So: run many syntheses in one process and watch the number.
///
/// ## Running it
///
/// Short form, inline with the rest of the synthesis tests (40 utterances, under a minute):
///
///     MOXSPEAK_NATIVE_TESTS=1 swift test
///
/// Long soak, the one that would have caught the old leak in its first minute:
///
///     MOXSPEAK_NATIVE_TESTS=1 MOXSPEAK_SOAK=1 swift test --filter Statelessness
///
/// `MOXSPEAK_SOAK_ITERATIONS=<n>` overrides either count.
///
/// ## Proving the test can fail
///
/// A memory test that cannot go red is worse than no test, because it buys confidence
/// without earning it. This one was checked by deliberately breaking the property it
/// guards — a dictionary added to `NativeSpeechProvider` that retained every synthesized
/// buffer — and confirming it went red, then confirming it went green again when the cache
/// came out. Both runs are recorded in `.superpowers/native-provider-report.md`.
///
/// The threshold is set from that experiment rather than from taste: several times the
/// measured run-to-run noise, and well under what one retained utterance per call reaches
/// within the *short* run. If the iteration count is ever lowered, check that second half
/// again.
///
/// ## Two measurement decisions, both load-bearing
///
/// **MLX's buffer cache is pinned for the duration.** Left at its default, MLX's allocator
/// keeps freed Metal buffers in a pool whose ceiling is derived from the machine's
/// recommended working set — on this 64 GB host that is tens of gigabytes, and the pool
/// genuinely does grow into it: an unpinned 30-utterance run reported 45.9 GB of MLX cache
/// and a resident size wandering between 2.2 and 2.8 GB. That is allocator policy, not
/// retention, and it swamps the ~430 KB per utterance a real leak would show. Pinning the
/// cache low makes the measurement about what this code keeps. The unpinned behaviour is
/// interesting in its own right and is what the "no buffer cache" and "512 MB ceiling"
/// rows of `PerformanceEnvelopeTests` exist to explore.
///
/// **The assertion is on resident size, not `phys_footprint`.** Both are printed, because
/// both are informative, but `phys_footprint` charges this process for Metal's buffer
/// accounting and reported 78 GB in that same unpinned run against 2.3 GB actually
/// resident. A number that can exceed the machine's RAM by 14 GB is not a number to fail a
/// build on.
@Suite(.enabled(if: NativeTestGate.isSoakReady), .serialized)
struct StatelessnessTests {

    /// One provider for the suite. Two would load the model twice for no reason, and a
    /// provider that has already run is the realistic subject anyway.
    static let provider = NativeSpeechProvider()

    /// Growth in live malloc bytes allowed between the post-warm-up baseline and the end
    /// of the run. This is the sensitive assertion — see `ProcessMemory` for why resident
    /// size alone is not enough.
    ///
    /// Sized from both sides of the deliberate-failure experiment rather than from taste.
    /// A clean 40-utterance run moves the heap by well under a megabyte. A provider that
    /// retained each call's audio keeps about 0.49 MB per utterance — 17 MB across the 35
    /// utterances that count toward growth — so it trips this around utterance 15 rather
    /// than only at the very end. Both margins matter: lower it and the test flakes on
    /// ordinary allocator noise, raise it past ~15 MB and the short form stops catching
    /// the bug it exists for.
    static let allowedHeapGrowthBytes = 4 * 1_048_576

    /// Growth in resident size allowed over the same span. The coarse assertion, and the
    /// one the plan actually asked for by name. It is set well above malloc's ~15 MB of
    /// unreturned slack because anything below that is noise at this scale; what it is
    /// here to catch is a leak that never passes through malloc at all — a Metal buffer, a
    /// mapping — which `heap` would never see, and the previous engine's 28 MB *per
    /// request*, which would blow through this inside two utterances.
    static let allowedResidentGrowthBytes = 40 * 1_048_576

    /// What MLX's buffer pool is allowed to hold while this runs. See the note above.
    static let pinnedCacheLimitBytes = 64 * 1_048_576

    /// Ignored when computing growth. The mmapped weight file pages in over the first few
    /// utterances and MLX's pool reaches its working size in about as long; neither is a
    /// leak, and starting the clock at t=0 would measure both.
    static let baselineIterations = 5

    static func iterationCount() -> Int {
        NativeTestGate.intSetting(
            "MOXSPEAK_SOAK_ITERATIONS", default: NativeTestGate.flag("MOXSPEAK_SOAK") ? 200 : 40)
    }

    /// One loop, two properties. They are measured together because they are two readings
    /// of the same run — reporting a latency curve from a different population than the
    /// memory curve would make neither of them evidence about the other, and it would cost
    /// a second minute of wall clock to say less.
    @Test func nothingAccumulatesAcrossManySyntheses() async throws {
        let iterations = Self.iterationCount()
        try #require(iterations > Self.baselineIterations * 2)

        let restoreCacheLimit = MLX.Memory.cacheLimit
        MLX.Memory.cacheLimit = Self.pinnedCacheLimitBytes
        defer { MLX.Memory.cacheLimit = restoreCacheLimit }

        let provider = Self.provider
        try await provider.prepare()

        var latencies: [TimeInterval] = []
        var memory: [ProcessMemory] = []
        var audioBytes = 0

        for index in 0..<iterations {
            // Unique text every time. A provider that memoized by input would show flat
            // memory on a repeated sentence, and flat memory is exactly what this asserts,
            // so repeating one sentence would make the test agree with the bug.
            let text = Report.utterance(index: index)
            let start = Date()
            let audio = try await provider.synthesize(text: text, voice: "af_bella", speed: 1.0)
            latencies.append(Date().timeIntervalSince(start))
            memory.append(.sample())
            audioBytes += audio.count
            #expect(!audio.isEmpty)
        }

        let baseline = memory[Self.baselineIterations - 1]
        let final = memory[memory.count - 1]
        let growth = final - baseline

        let window = max(3, iterations / 8)
        let firstLatencies = Report.median(Array(latencies.prefix(window + 1).dropFirst()))
        let lastLatencies = Report.median(Array(latencies.suffix(window)))

        Self.printTable(
            iterations: iterations, latencies: latencies, memory: memory,
            audioBytes: audioBytes, baseline: baseline, final: final, growth: growth,
            window: window, firstLatencies: firstLatencies, lastLatencies: lastLatencies)

        #expect(growth.heap <= Self.allowedHeapGrowthBytes,
                "live malloc bytes grew \(Report.megabytes(growth.heap)) over \(iterations - Self.baselineIterations) utterances that produced and discarded \(Report.megabytes(audioBytes)) of audio. Something is being retained per call — that is the failure this suite exists to catch.")
        #expect(growth.resident <= Self.allowedResidentGrowthBytes,
                "resident size grew \(Report.megabytes(growth.resident)) over \(iterations - Self.baselineIterations) utterances. Whatever is accumulating is not coming through malloc — look at Metal buffers and mappings, not at Swift objects.")

        // The half a memory check cannot see: a structure that is rescanned or rebuilt
        // every call can stay flat in memory while getting steadily slower. Generous on
        // purpose — this is a laptop that is also compiling things, not a bench. It is
        // looking for a curve that keeps climbing, not for a third of scheduler noise.
        #expect(lastLatencies < firstLatencies * 1.6,
                "the last \(window) utterances ran \(String(format: "%.2fx", lastLatencies / firstLatencies)) as long as the first \(window); the engine is getting slower as it runs")
    }

    private static func printTable(
        iterations: Int, latencies: [TimeInterval], memory: [ProcessMemory],
        audioBytes: Int, baseline: ProcessMemory, final: ProcessMemory, growth: ProcessMemory,
        window: Int, firstLatencies: TimeInterval, lastLatencies: TimeInterval
    ) {
        let window = min(5, iterations / 3)
        var lines = [
            "",
            "STATELESSNESS — \(iterations) consecutive syntheses in one process"
                + (NativeTestGate.flag("MOXSPEAK_SOAK") ? " (soak)" : " (short form; MOXSPEAK_SOAK=1 for 200)"),
            "  build: \(buildDescription)   MLX cache pinned to \(Report.megabytes(pinnedCacheLimitBytes))",
            "",
            "     #    latency    resident   footprint        heap",
            "  ----  ---------  ----------  ----------  ----------",
        ]
        func row(_ index: Int) -> String {
            String(format: "  %4d  %8.3fs  %9.1f  %9.1f  %10.2f", index + 1, latencies[index],
                   Double(memory[index].resident) / 1_048_576,
                   Double(memory[index].footprint) / 1_048_576,
                   Double(memory[index].heap) / 1_048_576)
        }
        lines += (0..<window).map(row)
        lines.append("   ...")
        lines += ((iterations - window)..<iterations).map(row)
        lines += [
            "",
            "  baseline (after \(baselineIterations)) : resident \(Report.megabytes(baseline.resident)), footprint \(Report.megabytes(baseline.footprint)), heap \(Report.megabytes(baseline.heap))",
            "  final                : resident \(Report.megabytes(final.resident)), footprint \(Report.megabytes(final.footprint)), heap \(Report.megabytes(final.heap))",
            "  growth               : resident \(Report.signedMegabytes(growth.resident)) (limit \(Report.megabytes(allowedResidentGrowthBytes)))",
            "                         heap     \(Report.signedMegabytes(growth.heap)) (limit \(Report.megabytes(allowedHeapGrowthBytes)))",
            "                         footprint \(Report.signedMegabytes(growth.footprint)) (reported, not asserted)",
            "",
            "  audio produced and discarded : \(Report.megabytes(audioBytes))   <- what a per-call cache would have retained",
            "  MLX active / cache           : \(Report.megabytes(MLX.Memory.activeMemory)) / \(Report.megabytes(MLX.Memory.cacheMemory))",
            "  latency median / min / max   : \(Report.seconds(Report.median(latencies))) / \(Report.seconds(latencies.min() ?? 0)) / \(Report.seconds(latencies.max() ?? 0))",
            "  latency first \(window) / last \(window)      : \(Report.seconds(firstLatencies)) / \(Report.seconds(lastLatencies))"
                + "   (\(String(format: "%.2fx", lastLatencies / firstLatencies)), limit 1.60x)",
            "",
        ]
        print(lines.joined(separator: "\n"))
    }

    static var buildDescription: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }
}

}
