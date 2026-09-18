import Testing
import Foundation
@testable import SpeakeasyCore

private func session(_ provider: some SpeechProvider) -> SpeechSession {
    SpeechSession(provider: provider,
                  preparer: TextPreparer(),
                  segmenter: Segmenter(),
                  estimator: DurationEstimator())
}

@Test func emptyAudioIsRetriedThenMarkedFailed() async {
    let fake = FakeProvider()
    await fake.setBehavior(.empty)
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to be failed")
        return
    }
    // One initial attempt plus retries at this level, plus the split attempts.
    #expect(await fake.callCount >= 2)
}

@Test func shortAudioIsRetried() async {
    let fake = FakeProvider()
    await fake.setBehavior(.short(fraction: 0.2))
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    #expect(await fake.callCount >= 2)
    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to be failed after retries")
        return
    }
}

@Test func audioWithinToleranceIsAccepted() async {
    let fake = FakeProvider()
    // 80% of estimate is above the 0.6 default ratio.
    await fake.setBehavior(.short(fraction: 0.8))
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .rendered = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to be accepted")
        return
    }
    #expect(await fake.callCount == 1)
}

@Test func oneFailedChunkDoesNotStopTheOthers() async {
    // A provider that fails only the second chunk it is asked for.
    actor SelectiveProvider: SpeechProvider {
        nonisolated var outputFormat: AudioFormat { .kokoroPCM }
        nonisolated var supportsIncrementalStreaming: Bool { true }
        nonisolated var recommendedCharacterCap: Int { 150 }
        private var seen = 0
        private let estimator = DurationEstimator()

        func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
            seen += 1
            if text.contains("POISON") { return Data() }
            let seconds = estimator.estimate(characterCount: text.count)
            return Data(count: Int(seconds * 48000))
        }
        func listVoices() async throws -> [Voice] { [] }
    }

    let s = session(SelectiveProvider())
    // The first sentence is padded to fill the 100-char first-chunk cap on its own, so
    // the segmenter is guaranteed to put it in a separate chunk from the poisoned one —
    // otherwise all three (short) sentences pack into a single chunk and the test can
    // never observe both a rendered chunk and a failed one.
    let text = "First sentence is fine, and rather longer than the others so it fills up the chunk boundary nicely. POISON sentence fails here. Third sentence is fine too."
    _ = await s.speak(text, voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    let chunks = await s.chunks
    var rendered = 0
    var failed = 0
    for chunk in chunks {
        switch await s.state(of: chunk.id) {
        case .rendered: rendered += 1
        case .failed: failed += 1
        default: break
        }
    }
    #expect(rendered >= 1, "other chunks must still render")
    #expect(failed >= 1, "the poisoned chunk must be marked failed")
}

@Test func providerErrorsAreRecordedAsFailed() async {
    let fake = FakeProvider()
    await fake.setBehavior(.failing(.httpStatus(code: 500, body: "boom")))
    let s = session(fake)

    _ = await s.speak("A sentence.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .failed(let reason) = await s.state(of: 0) else {
        Issue.record("expected failed state")
        return
    }
    #expect(reason.contains("500"))
}

// MARK: - Task 8 (revised): recursive retry-then-split ladder for intermittent failures

@Test func intermittentFailureIsRecoveredByRetry() async {
    let fake = FakeProvider()
    await fake.setBehavior(.failingFirst(count: 2))   // fails twice, then works
    let s = session(fake)

    _ = await s.speak("A single short sentence here.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    // With maxRetries = 2 the third attempt succeeds, so no split is needed.
    guard case .rendered = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to recover on retry")
        return
    }
    #expect(await fake.callCount == 3)
}

@Test func persistentFailureSplitsThenGivesUp() async {
    let fake = FakeProvider()
    await fake.setBehavior(.empty)     // never recovers
    let s = session(fake)

    _ = await s.speak("A single short sentence here that can be split in half.", voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to fail after exhausting the ladder")
        return
    }
    // Bounded: it must not retry forever.
    #expect(await fake.callCount <= 40)
}
