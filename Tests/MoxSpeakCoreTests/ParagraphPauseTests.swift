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
