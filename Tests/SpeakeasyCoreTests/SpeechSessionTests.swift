import Testing
import Foundation
@testable import SpeakeasyCore

private func makeSession(provider: some SpeechProvider,
                         policy: SpeechSession.ValidationPolicy = .init()) -> SpeechSession {
    SpeechSession(provider: provider,
                  preparer: TextPreparer(),
                  segmenter: Segmenter(),
                  estimator: DurationEstimator(),
                  validation: policy)
}

private let article = String(
    repeating: "This is a sentence of ordinary length that will be chunked. ", count: 12)

@Test func rendersEveryChunk() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak(article, voice: "af_bella", speed: 1.0)
    await session.waitForRenderComplete()

    let chunks = await session.chunks
    #expect(chunks.count > 1)
    for chunk in chunks {
        guard case .rendered = await session.state(of: chunk.id) else {
            Issue.record("chunk \(chunk.id) not rendered")
            return
        }
    }
}

@Test func advancesGenerationOnEachSpeak() async {
    let session = makeSession(provider: FakeProvider())
    let first = await session.speak("Hello there.", voice: "v", speed: 1.0)
    let second = await session.speak("Different text.", voice: "v", speed: 1.0)
    #expect(second > first)
}

@Test func staleResponsesAreDiscardedAfterReplace() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 2))
    let session = makeSession(provider: fake)

    _ = await session.speak(article, voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(50))

    await fake.setBehavior(.normal)
    let newGeneration = await session.speak("Completely different text.", voice: "v", speed: 1.0)
    await session.waitForRenderComplete()

    // The new generation's chunks are present and the old work committed nothing.
    #expect(await session.currentGeneration == newGeneration)
    let chunks = await session.chunks
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "Completely different text.")
}

@Test func cancelAllStopsInFlightWork() async throws {
    let fake = FakeProvider()
    await fake.setBehavior(.slow(seconds: 5))
    let session = makeSession(provider: fake)

    _ = await session.speak(article, voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(50))
    await session.cancelAllAndWait()

    #expect(await fake.cancelledCount >= 1)
}

@Test func staleWorkIsDiscardedEvenWhenItIgnoresCancellation() async throws {
    // A provider that does NOT honor cancellation: it always returns audio anyway.
    // With this, the generation guard is the only thing preventing a stale commit.
    //
    // Crucially, the FIRST call is made to resolve SLOWER than the second: if the
    // stale (first-generation) call finished before the second (current-generation)
    // call, the second call's write would land last regardless of any guard, and the
    // test would pass for the wrong reason even with the guards deleted. Making the
    // first call the slower one means the stale write, if not blocked by the guard,
    // arrives last and corrupts already-committed current-generation state.
    actor UncancellableProvider: SpeechProvider {
        nonisolated var outputFormat: AudioFormat { .kokoroPCM }
        nonisolated var supportsIncrementalStreaming: Bool { true }
        nonisolated var recommendedCharacterCap: Int { 150 }
        private let estimator = DurationEstimator()
        private var callCount = 0
        func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
            callCount += 1
            let isFirstCall = callCount == 1
            // A real delay that is NOT a Task cancellation point: `Task.sleep` throws
            // (and thus returns early) the moment its task is cancelled, even under
            // `try?` — `try?` only swallows the thrown error, it does not stop the
            // sleep from waking up early. A checked continuation resumed by a plain
            // `DispatchQueue.asyncAfter` has no idea the task was ever cancelled, so
            // it waits out the full delay regardless. That's what "ignores
            // cancellation" needs to mean here.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(isFirstCall ? 300 : 20)) {
                    continuation.resume()
                }
            }
            let seconds = estimator.estimate(characterCount: text.count)
            return Data(count: Int(seconds * Double(outputFormat.bytesPerSecond)))
        }
        func listVoices() async throws -> [Voice] { [] }
    }

    let estimator = DurationEstimator()
    let session = SpeechSession(provider: UncancellableProvider(),
                                preparer: TextPreparer(),
                                segmenter: Segmenter(),
                                estimator: estimator)

    _ = await session.speak("First selection that will be replaced.", voice: "v", speed: 1.0)
    try await Task.sleep(for: .milliseconds(20))   // let the first (slow) chunk get in flight

    let newGeneration = await session.speak("Second selection.", voice: "v", speed: 1.0)

    // Give both the fast current-generation call and the slow, abandoned
    // first-generation call more than enough time to finish and try to commit.
    // The stale one arrives last; its result must still be thrown away.
    try await Task.sleep(for: .milliseconds(400))

    #expect(await session.currentGeneration == newGeneration)
    let chunks = await session.chunks
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "Second selection.")

    guard case .rendered(_, let duration) = await session.state(of: chunks[0].id) else {
        Issue.record("expected chunk 0 to be rendered")
        return
    }
    let expected = estimator.estimate(characterCount: chunks[0].text.count)
    #expect(abs(duration - expected) < 0.05)
}

@Test func emptyInputProducesNoChunks() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak("   ", voice: "v", speed: 1.0)
    #expect(await session.chunks.isEmpty)
}

@Test func appliesTextPreparationBeforeSegmenting() async {
    let session = makeSession(provider: FakeProvider())
    _ = await session.speak("## A **heading**", voice: "v", speed: 1.0)
    let chunks = await session.chunks
    #expect(chunks.first?.text == "A heading")
}

@Test func rendersChunksSequentiallyInOrder() async {
    // Records how many syntheses are in flight at once, and in what order chunks arrive.
    actor OrderRecorder: SpeechProvider {
        nonisolated var outputFormat: AudioFormat { .kokoroPCM }
        nonisolated var supportsIncrementalStreaming: Bool { true }
        nonisolated var recommendedCharacterCap: Int { 150 }
        private let estimator = DurationEstimator()
        private var inFlight = 0
        private(set) var maxInFlight = 0
        private(set) var order: [String] = []

        func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            order.append(String(text.prefix(12)))
            try? await Task.sleep(for: .milliseconds(20))
            inFlight -= 1
            let seconds = estimator.estimate(characterCount: text.count)
            return Data(count: Int(seconds * Double(outputFormat.bytesPerSecond)))
        }
        func listVoices() async throws -> [Voice] { [] }
    }

    let recorder = OrderRecorder()
    let s = SpeechSession(provider: recorder, preparer: TextPreparer(),
                          segmenter: Segmenter(), estimator: DurationEstimator())
    let text = (1...6).map { "Sentence number \($0) has several words in it here." }.joined(separator: " ")
    _ = await s.speak(text, voice: "v", speed: 1.0)
    await s.waitForRenderComplete()

    #expect(await recorder.maxInFlight == 1, "synthesis must not run concurrently")
    let chunks = await s.chunks
    #expect(chunks.count > 1, "test needs a multi-chunk document to be meaningful")
    // Chunks must be synthesized in document order.
    let recorded = await recorder.order
    #expect(recorded == chunks.map { String($0.text.prefix(12)) })
}
