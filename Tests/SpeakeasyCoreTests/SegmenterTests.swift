import Testing
import Foundation
@testable import SpeakeasyCore

private func makeSegmenter(cap: Int = 150, firstCap: Int = 100) -> Segmenter {
    var o = Segmenter.Options()
    o.characterCap = cap
    o.firstChunkCap = firstCap
    return Segmenter(options: o)
}

@Test func noChunkExceedsTheCap() {
    let s = makeSegmenter()
    let text = String(repeating: "This is a sentence of moderate length. ", count: 40)
    let chunks = s.segment(text)
    #expect(!chunks.isEmpty)
    for c in chunks {
        #expect(c.characterCount <= 150, "chunk \(c.id) was \(c.characterCount) chars")
    }
}

@Test func firstChunkRespectsTheSmallerFirstCap() {
    let s = makeSegmenter()
    let text = String(repeating: "Another ordinary sentence here. ", count: 30)
    let chunks = s.segment(text)
    #expect(chunks[0].characterCount <= 100)
}

@Test func splitsAGiantSingleSentenceWithoutBreakingWords() {
    let s = makeSegmenter()
    // One sentence, no internal punctuation, far over the cap.
    let giant = Array(repeating: "wordy", count: 400).joined(separator: " ") + "."
    let chunks = s.segment(giant)
    #expect(chunks.count > 1)
    for c in chunks {
        #expect(c.characterCount <= 150)
        // No chunk may start or end mid-word.
        #expect(!c.text.hasPrefix("ordy"))
        #expect(c.text.split(separator: " ").allSatisfy { $0 == "wordy" || $0 == "wordy." })
    }
}

@Test func prefersClauseBoundariesInsideLongSentences() {
    let s = makeSegmenter(cap: 60, firstCap: 60)
    let text = "This clause is here, and this clause follows it, and a third one closes."
    let chunks = s.segment(text)
    #expect(chunks.count >= 2)
    // A clause split should leave the comma attached to the earlier chunk.
    #expect(chunks[0].text.hasSuffix(",") || chunks[0].text.hasSuffix("it,")
            || chunks[0].text.hasSuffix("here,"))
}

@Test func doesNotSplitOnAbbreviationPeriods() {
    let s = makeSegmenter()
    let chunks = s.segment("Dr. Smith went home. Mr. Jones stayed.")
    #expect(chunks.count == 1)
    #expect(chunks[0].text.contains("Dr. Smith"))
}

@Test func packsShortSentencesTogether() {
    let s = makeSegmenter()
    let chunks = s.segment("One. Two. Three. Four.")
    #expect(chunks.count == 1)
}

@Test func assignsSequentialIdsAndEstimates() {
    let s = makeSegmenter()
    let text = String(repeating: "A sentence that is reasonably long goes here. ", count: 20)
    let chunks = s.segment(text)
    for (i, c) in chunks.enumerated() {
        #expect(c.id == i)
        #expect(c.estimatedDuration > 0)
    }
}

@Test func emptyAndWhitespaceInputProduceNoChunks() {
    let s = makeSegmenter()
    #expect(s.segment("").isEmpty)
    #expect(s.segment("    ").isEmpty)
}

@Test func singleWordProducesOneChunk() {
    let s = makeSegmenter()
    let chunks = s.segment("Hello")
    #expect(chunks.count == 1)
    #expect(chunks[0].text == "Hello")
}

@Test func coversEveryWordOfTheInput() {
    let s = makeSegmenter()
    let text = String(repeating: "Coverage matters a great deal here. ", count: 25)
    let chunks = s.segment(text)
    let rejoined = chunks.map(\.text).joined(separator: " ")
    let originalWords = text.split(separator: " ").map(String.init)
    let rejoinedWords = rejoined.split(separator: " ").map(String.init)
    #expect(originalWords == rejoinedWords)
}
