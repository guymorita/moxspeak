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

@Test func hardSplitsASingleTokenLongerThanTheCap() {
    let s = makeSegmenter()
    // A bare URL with no spaces, far longer than the 150-char cap.
    let url = "https://example.com/" + String(repeating: "segment/", count: 40)
    let chunks = s.segment(url)
    #expect(chunks.count > 1)
    for c in chunks {
        #expect(c.characterCount <= 150, "chunk \(c.id) was \(c.characterCount) chars")
    }
    // No character is lost or duplicated.
    #expect(chunks.map(\.text).joined() == url)
}

@Test func neverSplitsMultiByteCharacters() {
    // Every one of these is a single Character built from several Unicode scalars, which
    // is the whole point: a hardSplit that counted scalars instead of Characters would
    // tear one of them in half. "categoría" would NOT catch that — its "í" is a single
    // scalar, so a scalar-based splitter passes it.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"  // ZWJ sequence, 7 scalars
    let flag = "\u{1F1FA}\u{1F1F8}"                                              // regional pair, 2 scalars
    let combining = "e\u{0301}"                                                  // e + combining acute, 2 scalars
    let unit = family + flag + combining
    #expect(unit.count == 3, "each piece must be exactly one grapheme cluster")

    // One spaceless 180-Character "word", forced through hardSplit by a 100-char cap.
    let word = String(repeating: unit, count: 60)
    #expect(word.count == 180)
    #expect(word.unicodeScalars.count == 660, "scalar count must differ from Character count")

    let s = makeSegmenter(cap: 100, firstCap: 100)
    let chunks = s.segment(word)

    #expect(chunks.count > 1, "the input must actually be split for this test to mean anything")
    #expect(chunks.map(\.text).joined() == word, "no character may be lost or duplicated")

    // The load-bearing assertion: every chunk must consist ENTIRELY of whole clusters.
    // A scalar-based split leaves a chunk ending in a bare "\u{1F468}" or starting with a
    // lone ZWJ or half a flag, none of which are in this set.
    let whole: Set<Character> = Set(unit)
    for c in chunks {
        #expect(c.characterCount <= 100, "chunk \(c.id) was \(c.characterCount) chars")
        for character in c.text {
            #expect(whole.contains(character),
                    "chunk \(c.id) contains a torn cluster: \(character.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }
}

@Test func preservesEveryCharacterAcrossChunkBoundaries() {
    let s = makeSegmenter()
    let input = String(repeating: "a", count: 400) + " " + String(repeating: "b", count: 400)
    let chunks = s.segment(input)
    let total = chunks.reduce(0) { $0 + $1.characterCount }
    #expect(total == input.count, "expected \(input.count) chars, chunks hold \(total)")
    for c in chunks { #expect(c.characterCount <= 150) }
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
    // The abbreviation has to land ON a chunk boundary for this to test anything. A short
    // input is packed back into one chunk no matter how the sentences were cut, so a naive
    // "split after every period" tokenizer would pass it without being detected.
    //
    // Sized so the leading sentence (52 chars) fills most of the 60-char cap:
    //   NLTokenizer  -> ["Padding ... indeed.", "Dr. Smith went home."]
    //                   the second unit (21 with its space) does not fit, so it is flushed
    //                   whole and "Dr. Smith" stays together.
    //   naive period -> ["Padding ... indeed.", "Dr.", "Smith went home."]
    //                   "Dr." (4 with its space) DOES fit, so the chunk ends "... indeed. Dr."
    //                   and "Smith went home." is torn off into the next chunk.
    let s = makeSegmenter(cap: 60, firstCap: 60)
    let chunks = s.segment("Padding sentence one is here and fairly long indeed. Dr. Smith went home.")

    #expect(chunks.count == 2, "the input must straddle a chunk boundary")
    #expect(!chunks.contains { $0.text.hasSuffix("Dr.") },
            "a chunk ended on an abbreviation period: \(chunks.map(\.text))")
    #expect(chunks.contains { $0.text.contains("Dr. Smith") },
            "\"Dr. Smith\" was torn across chunks: \(chunks.map(\.text))")
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
