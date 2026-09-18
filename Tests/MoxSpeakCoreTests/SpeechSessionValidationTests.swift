import Testing
import Foundation
@testable import MoxSpeakCore

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

    _ = await s.speak("A single short sentence here.", voice: "v")
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

    _ = await s.speak("A single short sentence here.", voice: "v")
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

    _ = await s.speak("A single short sentence here.", voice: "v")
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
    _ = await s.speak(text, voice: "v")
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

    _ = await s.speak("A sentence.", voice: "v")
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

    _ = await s.speak("A single short sentence here.", voice: "v")
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

    _ = await s.speak("A single short sentence here that can be split in half.", voice: "v")
    await s.waitForRenderComplete()

    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to fail after exhausting the ladder")
        return
    }
    // Bounded: it must not retry forever.
    #expect(await fake.callCount <= 40)
}

// MARK: - The split half of the recovery ladder
//
// These pin the `if depth < maxSplitDepth, let halves = splitInHalf(text)` branch of
// `synthesizeWithRecovery`. Before they existed, deleting that entire block left the whole
// suite green: nothing asserted that a split ever happened, that halves came back in
// document order, or that `maxSplitDepth` bounded the recursion.

private func session(_ provider: some SpeechProvider,
                     policy: SpeechSession.ValidationPolicy) -> SpeechSession {
    SpeechSession(provider: provider,
                  preparer: TextPreparer(),
                  segmenter: Segmenter(),
                  estimator: DurationEstimator(),
                  validation: policy)
}

@Test func splittingRecoversWhatRetriesAloneCannot() async {
    let fake = FakeProvider()
    // Three failures with a budget of maxRetries: 2 means all three attempts at the full
    // size fail. Retrying is exhausted; only halving can still succeed.
    await fake.setBehavior(.failingFirst(count: 3))
    var policy = SpeechSession.ValidationPolicy()
    policy.maxRetries = 2
    policy.maxSplitDepth = 2
    let s = session(fake, policy: policy)

    _ = await s.speak("A single short sentence here that can be split in half.", voice: "v")
    await s.waitForRenderComplete()

    guard case .rendered = await s.state(of: 0) else {
        Issue.record("expected the split to recover chunk 0; retries alone could not")
        return
    }
    // 3 exhausted attempts at full size, then one successful attempt per half.
    #expect(await fake.callCount == 5)
}

@Test func splitHalvesAreConcatenatedInDocumentOrder() async {
    // Out-of-order halves have exactly the right total duration, so the validation check
    // is blind to them. Order has to be asserted on the bytes directly.
    actor MarkingProvider: SpeechProvider {
        nonisolated var outputFormat: AudioFormat { .kokoroPCM }
        nonisolated var supportsIncrementalStreaming: Bool { true }
        nonisolated var recommendedCharacterCap: Int { 150 }
        private let estimator = DurationEstimator()
        private var nextMarker: UInt8 = 0
        /// Text of each successful call, in call order, with the byte value it was filled with.
        private(set) var marks: [(text: String, marker: UInt8)] = []

        func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
            // Anything longer than four words comes back empty, which forces the ladder
            // down to the halves. Each half then succeeds, filled with its own byte value.
            guard text.split(separator: " ").count <= 4 else { return Data() }
            nextMarker += 1
            marks.append((text, nextMarker))
            let seconds = estimator.estimate(characterCount: text.count)
            return Data(repeating: nextMarker,
                        count: Int(seconds * Double(outputFormat.bytesPerSecond)))
        }
        func listVoices() async throws -> [Voice] { [] }
    }

    let provider = MarkingProvider()
    let s = session(provider, policy: SpeechSession.ValidationPolicy())

    // Eight words, so splitInHalf produces two four-word halves the provider will serve.
    let text = "alpha bravo charlie delta echo foxtrot golf hotel."
    _ = await s.speak(text, voice: "v")
    await s.waitForRenderComplete()

    guard case .rendered(let data, _) = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to render from its halves")
        return
    }

    let marks = await provider.marks
    #expect(marks.count == 2, "expected exactly two successful half-syntheses, got \(marks.count)")
    guard marks.count == 2 else { return }

    let first = marks[0]
    let second = marks[1]
    #expect(first.text == "alpha bravo charlie delta")
    #expect(second.text == "echo foxtrot golf hotel.")

    // The whole buffer must be the first half's bytes followed by the second half's.
    // Swapping the halves flips these two byte values and fails here while leaving the
    // total length — and therefore the duration check — completely unchanged.
    let estimator = DurationEstimator()
    let bytes = { (t: String) in
        Int(estimator.estimate(characterCount: t.count) * Double(AudioFormat.kokoroPCM.bytesPerSecond))
    }
    let expected = Data(repeating: first.marker, count: bytes(first.text))
                 + Data(repeating: second.marker, count: bytes(second.text))
    #expect(data == expected, "halves were not concatenated in document order")
    #expect(data.first == first.marker)
    #expect(data.last == second.marker)
}

@Test func maxSplitDepthZeroForbidsSplittingEntirely() async {
    let fake = FakeProvider()
    await fake.setBehavior(.empty)       // never recovers
    var policy = SpeechSession.ValidationPolicy()
    policy.maxRetries = 2
    policy.maxSplitDepth = 0
    let s = session(fake, policy: policy)

    // Long enough that splitInHalf would happily split it, if splitting were permitted.
    _ = await s.speak("A single short sentence here that can be split in half.", voice: "v")
    await s.waitForRenderComplete()

    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to fail with splitting disabled")
        return
    }
    // Exactly maxRetries + 1 and not one call more: no split was attempted.
    #expect(await fake.callCount == 3)
}

@Test func piecesShorterThanFourWordsAreNotSplit() async {
    // Deliberate, documented behavior: splitInHalf returns nil below four words, so
    // `synthesizeWithRecovery` gives up after its retry budget rather than halving a
    // two- or three-word piece into fragments too small to validate meaningfully.
    let fake = FakeProvider()
    await fake.setBehavior(.empty)
    var policy = SpeechSession.ValidationPolicy()
    policy.maxRetries = 2
    policy.maxSplitDepth = 2     // splitting is ALLOWED; the word count is what stops it
    let s = session(fake, policy: policy)

    _ = await s.speak("Three words here.", voice: "v")
    await s.waitForRenderComplete()

    let chunks = await s.chunks
    #expect(chunks.count == 1)
    #expect(chunks[0].text.split(separator: " ").count == 3, "the piece must be under four words")

    guard case .failed = await s.state(of: 0) else {
        Issue.record("expected chunk 0 to fail")
        return
    }
    // maxRetries + 1 attempts and then a stop. A split would have added at least two more.
    #expect(await fake.callCount == 3)
}

// MARK: - Validation is not affected by playback speed (C1)

@Test @MainActor func truncatedAudioIsRejectedWhateverThePlaybackRate() async throws {
    // The regression this pins: when `speak` took a `speed:` and passed it to the provider,
    // a speed below 1.0 made the returned audio longer than the speed-blind estimate, so a
    // chunk the backend had truncated to 35% sailed through the ratio check and the whole
    // safety mechanism switched off. Playback rate now lives on the engine and cannot
    // reach the validator at all, so the answer must be the same at every rate.
    for rate: Float in [0.5, 1.0, 2.0] {
        let engine = try PlaybackEngine(format: .kokoroPCM)
        engine.rate = rate

        let fake = FakeProvider()
        await fake.setBehavior(.short(fraction: 0.35))   // below the 0.6 minimum ratio
        let s = session(fake)

        _ = await s.speak("A single short sentence here.", voice: "v")
        await s.waitForRenderComplete()

        guard case .failed = await s.state(of: 0) else {
            Issue.record("35% audio was accepted at playback rate \(rate)")
            return
        }
        #expect(await fake.callCount > 1, "a rejected chunk must be retried at rate \(rate)")
    }
}
