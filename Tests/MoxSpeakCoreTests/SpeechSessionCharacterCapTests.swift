import Testing
import Foundation
@testable import MoxSpeakCore

/// Phase 4: `SpeechProvider.recommendedCharacterCap` has been declared since the original
/// speech core shipped and was, until now, never read anywhere -- `SpeechSession` always
/// built its `Segmenter` with default options (150/100) regardless of which provider it
/// was driving. These tests exercise `SpeechSession`'s own default construction (no
/// `segmenter:` argument), which is exactly the path that was silently ignoring the
/// provider. If the wiring in `SpeechSession.init` regresses back to a hardcoded
/// `Segmenter()`, `sessionHonoursANativeStyleCapOf100` fails: a 150-char chunk would show
/// up where only 100-char chunks are allowed.
private actor CapProvider: SpeechProvider {
    nonisolated let recommendedCharacterCap: Int
    nonisolated var outputFormat: AudioFormat { .kokoroPCM }
    nonisolated var supportsIncrementalStreaming: Bool { true }
    nonisolated var requiresTextNormalization: Bool { false }
    private let estimator = DurationEstimator()

    init(recommendedCharacterCap: Int) {
        self.recommendedCharacterCap = recommendedCharacterCap
    }

    func synthesize(text: String, voice: String, speed: Double) async throws -> Data {
        let seconds = estimator.estimate(characterCount: text.count)
        return Data(count: Int(seconds * Double(outputFormat.bytesPerSecond)))
    }

    func listVoices() async throws -> [Voice] { [] }
}

private let longArticle = String(
    repeating: "This is a sentence of ordinary length that will be chunked into pieces. ",
    count: 15)

@Test func sessionHonoursANativeStyleCapOf100() async {
    // Native's measured cap (see NativeSpeechProvider.recommendedCharacterCap). A session
    // that still hardcoded Segmenter()'s 150/100 defaults would let later chunks run up
    // to 150 chars -- this is the assertion that catches that regression.
    let session = SpeechSession(provider: CapProvider(recommendedCharacterCap: 100))
    _ = await session.speak(longArticle, voice: "v")

    let chunks = await session.chunks
    #expect(chunks.count > 1, "test needs multiple chunks to be meaningful")
    for chunk in chunks {
        let message = "chunk \(chunk.id) was \(chunk.characterCount) chars; "
            + "session did not honour the provider's declared cap of 100"
        #expect(chunk.characterCount <= 100, "\(message)")
    }
}

@Test func sessionHonoursAnHTTPStyleCapOf150() async {
    let session = SpeechSession(provider: CapProvider(recommendedCharacterCap: 150))
    _ = await session.speak(longArticle, voice: "v")

    let chunks = await session.chunks
    #expect(chunks.count > 1, "test needs multiple chunks to be meaningful")
    for chunk in chunks {
        #expect(chunk.characterCount <= 150)
    }
    // Chunk 0 is exempt -- firstChunkCap (100) governs it regardless of characterCap, by
    // design (see Segmenter.Options). A later chunk landing above 100 is what actually
    // proves the session picked up 150 rather than silently falling back to the
    // 100/150-agnostic default, which would coincidentally also cap everything at 150.
    let message = "no chunk exceeded 100 chars; session does not appear to be using the "
        + "provider's 150 cap for anything beyond what the old hardcoded default gave"
    #expect(chunks.dropFirst().contains { $0.characterCount > 100 }, "\(message)")
}

@Test func relationshipBetweenTheTwoCapsHoldsWhenAProviderDeclaresSomethingSmaller() async {
    // A cap below the segmenter's own latency-tuned firstChunkCap default (100) must pull
    // every chunk -- including chunk 0 -- down with it. firstChunkCap can only ever lower
    // characterCap, never exceed it.
    let session = SpeechSession(provider: CapProvider(recommendedCharacterCap: 40))
    _ = await session.speak(longArticle, voice: "v")

    let chunks = await session.chunks
    #expect(!chunks.isEmpty)
    for chunk in chunks {
        #expect(chunk.characterCount <= 40,
                "chunk \(chunk.id) was \(chunk.characterCount) chars against a declared cap of 40")
    }
}
