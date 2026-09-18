import Testing
import Foundation
import Darwin
@testable import MoxSpeakNative

// Shared machinery for the two suites that run real inference: the statelessness soak and
// the performance envelope. Both need the same two things — a way to know whether this
// machine can run the engine at all, and a way to read this process's memory.

// MARK: - One serial home for everything that runs the model

/// Parent of every suite that performs real inference.
///
/// Swift Testing runs suites in parallel with one another, and `.serialized` on a suite
/// only orders that suite's own tests. That is a problem here and not a stylistic one:
/// these suites share a GPU, and two of them measure time and memory. A soak that takes
/// its memory baseline while a neighbouring suite is mmapping a second 312 MB model
/// attributes that model to itself and fails for no reason; a latency figure taken while
/// another suite is submitting Metal work is not a latency figure.
///
/// `.serialized` is inherited by nested suites, so declaring the model-driven suites
/// inside this one makes them run one at a time — in exchange for a slower opt-in run,
/// which is the right trade for tests whose output is a measurement.
@Suite(.serialized)
struct NativeEngineTests {}

// MARK: - Gate

/// What has to be true before a suite that runs real synthesis is allowed to run.
///
/// Swift Testing decides whether to run a suite from a trait evaluated *before* any test
/// in it, rather than letting a test skip itself mid-flight. So every precondition has to
/// be answerable here, or a missing weight file shows up as a screenful of failures
/// instead of one skip.
enum NativeTestGate {

    /// Weights, voice and Metal kernels all present. A checkout with no models is a normal
    /// state, not a broken one:
    ///
    ///     swift build --target MoxSpeakNative && Scripts/build-metallib.sh
    ///     python3 Scripts/prepare-models.py --checkpoint ... --voices ... --out Models
    static func modelsPresent(precision: NativeModelAssets.Precision) -> Bool {
        guard NativeRuntime.isAvailable else { return false }
        let assets = NativeModelAssets.resolveDefault(precision: precision)
        guard (try? assets.validate()) != nil else { return false }
        return assets.availableVoices().contains("af_bella")
    }

    static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name] == "1"
    }

    static func intSetting(_ name: String, default fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name], let value = Int(raw), value > 0
        else { return fallback }
        return value
    }

    /// The statelessness soak rides the same `MOXSPEAK_NATIVE_TESTS=1` flag as the rest of
    /// the synthesis tests. Its *long* form needs `MOXSPEAK_SOAK=1` on top — see
    /// `StatelessnessTests`.
    static let isSoakReady: Bool = flag("MOXSPEAK_NATIVE_TESTS") && modelsPresent(precision: .float16)

    /// The performance envelope has its own flag. It is a measurement harness, not a
    /// regression gate, and it takes long enough that it has no business running because
    /// somebody wanted the synthesis tests.
    static let isPerformanceReady: Bool = flag("MOXSPEAK_PERF") && modelsPresent(precision: .float16)
}

// MARK: - Memory

/// This process's memory, read from the kernel.
///
/// Two numbers, because they answer different questions and the difference matters for a
/// leak test:
///
/// - `resident` is `resident_size` from `MACH_TASK_BASIC_INFO` — every physical page
///   mapped into the task, mmapped weight file included. It is what "resident memory"
///   conventionally means, and it is the number the plan asks for.
/// - `footprint` is `phys_footprint` from `TASK_VM_INFO` — what macOS itself charges the
///   process and uses for memory pressure. It excludes clean file-backed pages, so it
///   moves when *we* allocate and stays put when the kernel merely pages in more of the
///   model file.
/// - `heap` is `size_in_use` summed across every malloc zone: bytes this process has
///   allocated and not freed. It is the only one of the three that is not a page count.
///
/// The third exists because the first two are too blunt to see a modest leak, which was
/// found out the hard way: a provider deliberately rigged to retain every synthesized
/// buffer accumulated 17 MB across a 40-utterance run and moved resident size by 2 MB.
/// malloc holds roughly 15 MB of freed-but-unreturned pages in this process, and a leak
/// smaller than that slack is invisible to an RSS measurement no matter how long you stare
/// at it. `heap` has no such slack: in the same experiment it tracked the retained bytes
/// to within 1 MB.
///
/// So the soak asserts on `heap` for sensitivity and on `resident` for coverage — `heap`
/// cannot see a leak that never goes through malloc (a Metal buffer, an mmap), and
/// `resident` cannot see a small one. Between them there is no size of leak that hides.
struct ProcessMemory: Sendable, Equatable {
    var resident: Int
    var footprint: Int
    var heap: Int

    static func sample() -> ProcessMemory {
        ProcessMemory(resident: residentBytes(), footprint: footprintBytes(), heap: heapBytes())
    }

    static func - (lhs: ProcessMemory, rhs: ProcessMemory) -> ProcessMemory {
        ProcessMemory(resident: lhs.resident - rhs.resident,
                      footprint: lhs.footprint - rhs.footprint,
                      heap: lhs.heap - rhs.heap)
    }

    /// Live malloc bytes across every zone. `nil` means "all zones".
    private static func heapBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    /// `mach_task_self_` is imported as a mutable global and so cannot be read from
    /// concurrent code under Swift 6. `task_self_trap()` asks the kernel for the same
    /// port and is a plain function, which keeps this strict-concurrency clean without
    /// an `unsafe` escape hatch.
    private static var currentTask: task_t { task_self_trap() }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(currentTask, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(currentTask, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

// MARK: - Formatting

enum Report {
    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func signedMegabytes(_ bytes: Int) -> String {
        String(format: "%+.1f MB", Double(bytes) / 1_048_576)
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3f s", value)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Ordinary English of a requested length, different for every `index`.
    ///
    /// Two properties this has to have, both learned the hard way:
    ///
    /// - **The length is actually the length asked for.** The chunk-size sweep is
    ///   meaningless if a 40-character request returns 86 characters, and an earlier
    ///   version of this did exactly that by prefixing a fixed sentence.
    /// - **No two calls return the same text.** A provider that memoized by input would
    ///   show flat memory on a repeated sentence, and flat memory is what the soak
    ///   asserts — so repeating one sentence would make the test agree with the bug.
    ///
    /// The word order is a deterministic function of `index` so a failing run can be
    /// reproduced exactly.
    static func utterance(index: Int, targetCharacters: Int = 150) -> String {
        let vocabulary = [
            "archivist", "described", "the", "flooded", "quarry", "before", "lamps",
            "came", "on", "and", "whole", "valley", "went", "quiet", "again", "leaving",
            "only", "hum", "of", "distant", "traffic", "weathered", "mariner", "recounted",
            "a", "forgotten", "timetable", "while", "rain", "kept", "tapping", "against",
            "greenhouse", "glass", "no", "one", "thought", "to", "interrupt", "him",
            "night", "courier", "catalogued", "every", "crooked", "fencepost", "as", "last",
            "commuter", "train", "rattled", "past", "level", "crossing", "windows", "lit",
            "like", "small", "aquariums", "retired", "cartographer", "explained", "an",
            "abandoned", "lighthouse", "rhythm", "tidal", "flats", "pausing", "refill",
            "chipped", "mug", "with", "lukewarm", "coffee", "gardener", "recalled", "ledger",
        ]
        // A plain linear congruential step: reproducible, dependency-free, and good enough
        // to keep two indices from colliding.
        var state = UInt64(bitPattern: Int64(index)) &* 6_364_136_223_846_793_005 &+ 1
        func nextWord() -> String {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return vocabulary[Int((state >> 33) % UInt64(vocabulary.count))]
        }

        var text = nextWord().capitalized
        // -1 leaves room for the full stop, so `text.count` lands on the target.
        while text.count < targetCharacters - 1 {
            let word = nextWord()
            if text.count + 1 + word.count > targetCharacters - 1 { break }
            text += " " + word
        }
        return text + "."
    }
}
