import Foundation
import Testing
@testable import MoxSpeakCore

/// A paragraph has to sound like a paragraph.
///
/// Reported while listening to an essay: the break between two paragraphs "almost sounded
/// like it was the same sentence". Measured in the assembled audio, it was: the paragraph
/// boundary came out at 443 ms while the ordinary sentence breaks around it measured 298,
/// 452, 418 and 396. The text changed shape and the audio did not.
@Suite struct ParagraphPauseTests {

    static func chunks(_ text: String, cap: Int = 200) -> [Chunk] {
        Segmenter(options: .init(providerCap: cap)).segment(TextPreparer().prepare(text))
    }

    /// The reported passage.
    @Test func aParagraphBreakEndsItsChunkAndIsMarked() {
        let essay = """
        When ready to return home, we simply leave the kitchen.

        I knock on the classroom door, my smile mirroring the one made of jam.
        """
        let chunks = Self.chunks(essay)
        #expect(chunks.count >= 2, "the paragraph did not force a break")
        #expect(chunks[0].text.hasSuffix("leave the kitchen."),
                Comment(rawValue: chunks[0].text))
        #expect(chunks[0].endsParagraph, "the boundary was not marked")
        #expect(!chunks[chunks.count - 1].endsParagraph,
                "the last chunk ends the document, not a paragraph")
    }

    /// A paragraph ends its chunk however much room is left. Text packed on after it
    /// would bury the boundary mid-chunk, where Kokoro decides the timing and treats it
    /// as an ordinary sentence — which is the whole defect.
    @Test func aParagraphBreaksTheChunkEvenWithRoomToSpare() {
        let chunks = Self.chunks("Short one.\n\nShort two.\n\nShort three.", cap: 200)
        #expect(chunks.count == 3, Comment(rawValue: chunks.map(\.text).description))
        #expect(chunks[0].endsParagraph && chunks[1].endsParagraph)
    }

    /// Sentences inside one paragraph still pack together; only paragraphs break.
    @Test func sentencesWithinAParagraphStillShareAChunk() {
        let chunks = Self.chunks("One. Two. Three. Four.", cap: 200)
        #expect(chunks.count == 1, Comment(rawValue: chunks.map(\.text).description))
        #expect(!chunks[0].endsParagraph)
    }

    /// The marker must never reach the phonemizer. A newline in chunk text would be sent
    /// to Kokoro as part of the utterance.
    @Test func noChunkTextContainsTheMarker() {
        let messy = """
        A heading

        Some prose that runs on for a while and then ends.

        - a list item
        - another one

        A final paragraph.
        """
        for chunk in Self.chunks(messy) {
            #expect(!chunk.text.contains("\n"),
                    Comment(rawValue: "newline survived into \(chunk.text.debugDescription)"))
        }
    }

    // MARK: - The gap itself

    /// A paragraph is a longer pause than a sentence, which is longer than a clause.
    @Test func theGapsAreOrdered() {
        let seam = AudioSeam()
        #expect(seam.gapSeconds(after: "the end.", endsParagraph: true)
                > seam.gapSeconds(after: "the end."))
        #expect(seam.gapSeconds(after: "the end.") > seam.gapSeconds(after: "a clause,"))
        #expect(seam.gapSeconds(after: "a clause,") > seam.gapSeconds(after: "mid phrase"))
        // A paragraph gap applies whatever the chunk ended on.
        #expect(seam.gapSeconds(after: "no punctuation", endsParagraph: true)
                == seam.options.paragraphGap)
    }

    /// Measured: Kokoro's own sentence pause runs 107–548 ms with a median of 392 across
    /// a corpus. A paragraph has to sit clearly above that range or it is inaudible as a
    /// paragraph, which is the bug.
    @Test func theParagraphGapClearsKokorosOwnSentencePause() {
        #expect(AudioSeam().options.paragraphGap > 0.548)
    }
}

extension ParagraphPauseTests {

    /// A paragraph long enough to fill several chunks, which is every real one.
    ///
    /// The first version of this fix marked the boundary only when the paragraph's last
    /// sentence happened to fit alongside the chunk being built. The packer has a second
    /// path — flush, then start a fresh chunk with this unit — and that is the one taken
    /// once a document is longer than one chunk. So it worked on a two-sentence sample
    /// and did nothing at all on an essay, which is exactly how it was reported.
    @Test func aLongParagraphIsStillMarked() {
        let first = """
        In every mixing bowl lies a ticket to faraway lands. Seizing this opportunity, a \
        friend and I chart a voyage around the globe. We first travel two thousand miles \
        to Mexico where he shows me how to make polvorones, a traditional cookie served \
        during weddings and holidays. Feeling inspired, I fly us across the Atlantic \
        Ocean to Israel. When ready to return home, we simply leave the kitchen.
        """
        let second = """
        I knock on the classroom door, my smile mirroring the one made of jam on the \
        lemony surprise I hold in my hands. My former track coach invites me in, grabbing \
        a couple of chairs and happily accepting his birthday gift.
        """

        // Both shapes a browser puts on the clipboard.
        for separator in ["\n\n", "\n"] {
            let chunks = Self.chunks(first + separator + second)
            let marked = chunks.filter(\.endsParagraph)
            #expect(marked.count == 1,
                    Comment(rawValue: "separator \(separator.debugDescription): "
                                      + "\(marked.count) marks across \(chunks.count) chunks"))
            #expect(marked.first?.text.hasSuffix("leave the kitchen.") == true,
                    Comment(rawValue: marked.first?.text ?? "none"))
        }
    }

    /// A single newline is what a browser usually puts between two paragraphs, so
    /// requiring a blank line meant the pause never appeared for the source people
    /// actually read from.
    @Test func aSingleNewlineAfterAFullParagraphCounts() {
        let paragraph = "This sentence is long enough to be a paragraph rather than a list item, which is the distinction that matters here."
        let chunks = Self.chunks(paragraph + "\nAnd another paragraph follows it.")
        #expect(chunks.contains { $0.endsParagraph },
                Comment(rawValue: chunks.map(\.text).description))
    }

    /// But a short line ending in a full stop is a list item, not a paragraph. After
    /// `stripMarkdown` terminates them, bullets look exactly like sentences.
    @Test func shortTerminatedLinesAreNotParagraphs() {
        let list = "Requirements:\n- Apple silicon\n- macOS 14 or later\n- About 210 MB"
        #expect(!Self.chunks(list).contains { $0.endsParagraph },
                Comment(rawValue: Self.chunks(list).map(\.text).description))

        let nav = "Pricing\nDocs\nBlog\nSign in"
        #expect(!Self.chunks(nav).contains { $0.endsParagraph })
    }

    /// And a soft wrap is never a paragraph, whatever its length.
    @Test func longSoftWrapsAreNotParagraphs() {
        let pdf = """
        Researchers have known for decades that the rate at which a glacier sheds mass \
        depends less on the air above it than on the water beneath it, and the
        instrumentation needed to observe that water has only recently become cheap.
        """
        #expect(!Self.chunks(pdf).contains { $0.endsParagraph },
                Comment(rawValue: Self.chunks(pdf).map(\.text).description))
    }
}

/// Sentences that arrive with nothing between them.
///
/// Reported as an essay that "just kept reading as if there was no period". The paragraphs
/// had been concatenated with no separator at all — "the kitchen.I knock on the door" —
/// which is what reading a web page through the Accessibility API can produce. With no
/// space there is no boundary for the segmenter to find and none for Kokoro to hear, so
/// tuning the pause between chunks cannot help: there is only one chunk.
@Suite struct MissingSentenceSpaceTests {

    static func prepared(_ t: String) -> String { TextPreparer().prepare(t) }

    @Test func aRunTogetherSentenceIsSeparated() {
        let out = Self.prepared("We simply leave the kitchen.I knock on the classroom door.")
        #expect(out.contains("kitchen. I knock"), Comment(rawValue: out))
        #expect(!out.contains("kitchen.I"), Comment(rawValue: out))
    }

    @Test func itBecomesARealChunkBoundary() {
        let run = "When ready to return home, we simply leave the kitchen."
                + "I knock on the classroom door, my smile mirroring the one made of jam."
        let chunks = Segmenter(options: .init(providerCap: 200))
            .segment(Self.prepared(run))
        #expect(chunks.count == 2, Comment(rawValue: chunks.map(\.text).description))
    }

    @Test func everyTerminatorCounts() {
        #expect(Self.prepared("Stop.Go now.").contains("Stop. Go"))
        #expect(Self.prepared("Really?Yes.").contains("Really? Yes"))
        #expect(Self.prepared("Stop!Now.").contains("Stop! Now"))
    }

    /// The rule needs a lower-case letter on the left, which is what keeps initialisms,
    /// initials and decimals intact. Getting this wrong would break far more than it fixed.
    @Test func abbreviationsAndNumbersAreUntouched() {
        #expect(Self.prepared("The U.S.A is big.") == "The U.S.A is big.")
        #expect(Self.prepared("Visit J.R.R.Tolkien today.") == "Visit J.R.R.Tolkien today.")
        #expect(Self.prepared("It costs 3.5Million.") == "It costs 3.5Million.")
        // But a genuine word running into a name is exactly the case this is for.
        #expect(Self.prepared("Dr.Smith called.") == "Dr. Smith called.")
    }

    /// The three pauses, in order, all measured against what Kokoro does itself.
    @Test func thePausesAreDistinct() {
        let o = AudioSeam().options
        #expect(o.clauseGap < o.sentenceGap)
        #expect(o.sentenceGap < o.paragraphGap)
        // Sentence matches the measured median of Kokoro's own internal pause.
        #expect(abs(o.sentenceGap - 0.392) < 0.03)
        // Paragraph clears the top of its measured range, so it reads as more than one.
        #expect(o.paragraphGap > 0.548)
    }
}
