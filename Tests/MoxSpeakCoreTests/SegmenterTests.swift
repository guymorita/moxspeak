import Testing
import Foundation
@testable import MoxSpeakCore

private func makeSegmenter(cap: Int = 150, firstCap: Int = 100) -> Segmenter {
    var o = Segmenter.Options()
    o.characterCap = cap
    o.firstChunkCap = firstCap
    return Segmenter(options: o)
}

// MARK: - Segmenter.Options.init(providerCap:)
//
// The constructor `SpeechSession` uses to build a provider's segmenter (Phase 4:
// `recommendedCharacterCap` was declared since the speech core shipped and, until now,
// never read). Pinned directly, independent of `SpeechSession`, so a regression in the
// relationship between `characterCap` and `firstChunkCap` shows up at the smallest unit
// that can express it.

@Test func providerCapOf150MatchesTheHTTPProvidersLongstandingDefault() {
    // The HTTP provider's 150 exists only as a workaround for the PyTorch-MPS truncation
    // bug, and this is the exact pair `Segmenter()`'s own defaults already produced --
    // adopting the provider's number must not change behavior for the HTTP path.
    let o = Segmenter.Options(providerCap: 150)
    #expect(o.characterCap == 150)
    #expect(o.firstChunkCap == 100)
}

@Test func providerCapOf100MatchesTheNativeProvidersMeasuredValue() {
    let o = Segmenter.Options(providerCap: 100)
    #expect(o.characterCap == 100)
    #expect(o.firstChunkCap == 100)
}

@Test func firstChunkCapIsClampedWhenAProviderDeclaresACapBelowTheLatencyDefault() {
    // firstChunkCap governs time-to-first-sound and can only ever lower, never raise,
    // relative to characterCap -- so a provider declaring something smaller than the
    // segmenter's own latency-tuned default (100) must pull firstChunkCap down with it,
    // rather than leaving an inconsistent pair where firstChunkCap > characterCap.
    let o = Segmenter.Options(providerCap: 40)
    #expect(o.characterCap == 40)
    #expect(o.firstChunkCap == 40, "firstChunkCap must never exceed characterCap")
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

// MARK: - Source offsets (C3)

@Test func sourceOffsetsIndexBackIntoThePreparedString() {
    let s = makeSegmenter(cap: 50, firstCap: 50)
    let sentences = [
        "Sentence number one is right here.",
        "Sentence number two follows next.",
        "Sentence number three comes after.",
        "Sentence number four is the last one.",
    ]
    let text = sentences.joined(separator: " ")
    let chunks = s.segment(text)

    #expect(chunks.count > 1, "the input must actually span multiple chunks for this test to mean anything")
    for chunk in chunks {
        let start = text.index(text.startIndex, offsetBy: chunk.sourceStart)
        let end = text.index(text.startIndex, offsetBy: chunk.sourceEnd)
        #expect(String(text[start..<end]) == chunk.text,
                "chunk \(chunk.id) offsets [\(chunk.sourceStart), \(chunk.sourceEnd)) don't match its text \"\(chunk.text)\"")
    }
}

@Test func sourceOffsetsAreMonotonicAcrossChunks() {
    let s = makeSegmenter(cap: 50, firstCap: 50)
    let text = String(repeating: "This is an ordinary sentence for offset testing. ", count: 10)
    let chunks = s.segment(text)

    #expect(chunks.count > 1, "the input must actually span multiple chunks for this test to mean anything")
    for i in 1..<chunks.count {
        #expect(chunks[i].sourceStart >= chunks[i - 1].sourceStart,
                "chunk \(i) start regressed relative to chunk \(i - 1)")
        #expect(chunks[i].sourceStart >= chunks[i - 1].sourceEnd,
                "chunk \(i) starts at \(chunks[i].sourceStart), before chunk \(i - 1) ends at \(chunks[i - 1].sourceEnd)")
    }
}

@Test func sentenceOffsetsLocateSentenceStartsWithinChunkText() {
    let s = makeSegmenter()   // default cap 150 / firstCap 100 — everything below fits in chunk 0
    let sentenceTexts = ["One sentence here.", "Another one follows.", "And a third one too."]
    let chunks = s.segment(sentenceTexts.joined(separator: " "))

    #expect(chunks.count == 1, "expected everything to pack into a single chunk for this test to mean anything")
    let chunk = chunks[0]
    #expect(chunk.sentenceOffsets.count == sentenceTexts.count)

    for (offset, expected) in zip(chunk.sentenceOffsets, sentenceTexts) {
        let start = chunk.text.index(chunk.text.startIndex, offsetBy: offset)
        let prefix = String(chunk.text[start...].prefix(expected.count))
        #expect(prefix == expected, "sentenceOffset \(offset) does not point at \"\(expected)\", got \"\(prefix)\"")
    }
}

@Test func duplicateChunkTextGetsDistinctCorrectSourceOffsets() {
    // Sized so the sentence exactly fills a chunk on its own: this is precisely the
    // "both sides sit exactly at the cap" case where the packer drops the boundary
    // space (see Segmenter.pack) rather than fabricating one, so the second occurrence's
    // chunk.text is byte-identical to the first occurrence's chunk.text. A
    // reimplementation that recovered offsets by searching the source for chunk.text
    // (instead of tracking them through packing) would find only the FIRST occurrence
    // and report it for both chunks — this test fails exactly that implementation.
    let sentence = "The quick fox jumps."
    let cap = sentence.count
    let s = makeSegmenter(cap: cap, firstCap: cap)
    let text = "\(sentence) \(sentence)"
    let chunks = s.segment(text)

    #expect(chunks.count == 2, "expected the identical sentence to land in two separate chunks")
    #expect(chunks[0].text == sentence)
    #expect(chunks[1].text == sentence, "identical text in both chunks is the point of this test")

    #expect(chunks[0].sourceStart == 0)
    #expect(chunks[0].sourceEnd == sentence.count)
    #expect(chunks[1].sourceStart == sentence.count + 1,
            "must point at the SECOND occurrence, not be a copy of the first chunk's offset")
    #expect(chunks[1].sourceEnd == sentence.count + 1 + sentence.count)

    // Ground truth: indexing `text` with each chunk's own offsets recovers the right
    // occurrence for both chunks, not just the first.
    for chunk in chunks {
        let start = text.index(text.startIndex, offsetBy: chunk.sourceStart)
        let end = text.index(text.startIndex, offsetBy: chunk.sourceEnd)
        #expect(String(text[start..<end]) == chunk.text)
    }
}
