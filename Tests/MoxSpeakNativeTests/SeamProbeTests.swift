import Foundation
import Testing
@testable import MoxSpeakCore
@testable import MoxSpeakNative

/// What a chunk seam actually costs, in milliseconds of dead air.
@Suite(.enabled(if: NativeTestGate.isPerformanceReady), .serialized)
struct SeamProbeTests {
    static let shared = NativeSpeechProvider()

    /// First and last sample whose amplitude clears a floor, as seconds of silence.
    static func edges(_ data: Data) -> (lead: Double, tail: Double, total: Double) {
        let samples: [Int16] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        let rate = Double(AudioFormat.kokoroPCM.sampleRate)
        let floor: Int16 = 328   // ~1% of full scale
        let first = samples.firstIndex { abs(Int($0)) > Int(floor) } ?? samples.count
        let last = samples.lastIndex { abs(Int($0)) > Int(floor) } ?? 0
        return (Double(first) / rate,
                Double(samples.count - 1 - last) / rate,
                Double(samples.count) / rate)
    }

    /// Longest run of consecutive sub-floor samples that is not at either edge, i.e. the
    /// pause Kokoro renders *inside* a chunk when a sentence ends there. That is the gap a
    /// seam should reproduce; anything longer is padding, not prosody.
    static func longestInteriorGap(_ data: Data) -> Double {
        let samples: [Int16] = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let floor = 328
        guard let first = samples.firstIndex(where: { abs(Int($0)) > floor }),
              let last = samples.lastIndex(where: { abs(Int($0)) > floor }), first < last
        else { return 0 }
        var best = 0, run = 0
        for i in first...last {
            if abs(Int(samples[i])) > floor { best = max(best, run); run = 0 } else { run += 1 }
        }
        return Double(max(best, run)) / Double(AudioFormat.kokoroPCM.sampleRate)
    }

    /// End to end, through the real session and the real engine: what a listener gets.
    @Test func printsTheSeamCost() async throws {
        let provider = Self.shared
        try await provider.prepare()

        let article = """
        Researchers have known for decades that the rate at which a glacier sheds mass \
        depends less on the air above it than on the water beneath it. The instrumentation \
        needed to observe that water has only recently become cheap enough to leave behind \
        on the ice through a winter. What they found there was not what anyone expected.
        """

        let session = SpeechSession(provider: provider)
        _ = await session.speak(article, voice: "af_bella")
        await session.waitForRenderComplete()
        let chunks = await session.chunks

        print("\nSEAM COST, end to end through the real session — \(chunks.count) chunks\n")
        print("     chunk   delivered   edge silence   as synthesized   edge silence   text ends on")
        var deliveredTotal = 0.0, rawTotal = 0.0
        for chunk in chunks {
            guard case .rendered(let data, let duration) = await session.state(of: chunk.id)
            else { continue }
            let raw = try await provider.synthesize(text: chunk.text, voice: "af_bella", speed: 1.0)
            let d = Self.edges(data), r = Self.edges(raw)
            deliveredTotal += duration
            rawTotal += r.total
            let ending = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(1)
            print(String(format: "     %5d   %8.3fs   %5.0f+%4.0fms   %13.3fs   %5.0f+%4.0fms   %@",
                         chunk.id, duration, d.lead * 1000, d.tail * 1000,
                         r.total, r.lead * 1000, r.tail * 1000, String(ending) as NSString))
        }
        print(String(format: "\n     total delivered %.2fs against %.2fs as synthesized — %.2fs of dead air removed\n",
                     deliveredTotal, rawTotal, rawTotal - deliveredTotal))
    }
}
