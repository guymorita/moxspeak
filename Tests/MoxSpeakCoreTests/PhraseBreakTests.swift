import Testing
@testable import MoxSpeakCore

/// Where a sentence too long for one chunk gets broken.
///
/// Reported from an essay: MoxSpeak paused after "the well" in "potential to become the
/// well balanced contributor", which is heard as a pause in the middle of a noun phrase
/// and, worse, as the noun "well". The packer had filled to the cap and broken wherever
/// that landed.
@Suite struct PhraseBreakTests {

    static func chunks(_ text: String, cap: Int) -> [String] {
        Segmenter(options: .init(providerCap: cap)).segment(TextPreparer().prepare(text))
            .map(\.text)
    }

    static let sentence = """
    Only by acknowledging such vulnerabilities and working within a community of friends \
    and mentors can I improve upon them and grow from a sapling filled with hope and \
    potential to become the well balanced contributor to my communities that the seedling \
    who stared at the maple leaves looming above longed to be.
    """

    /// The reported break, gone.
    @Test func itNoLongerBreaksInsideANounPhrase() {
        for cap in [150, 200, 250, 300] {
            let texts = Self.chunks(Self.sentence, cap: cap)
            for text in texts {
                #expect(!text.hasSuffix("the well"),
                        Comment(rawValue: "cap \(cap) broke after 'the well'"))
                // Nor after any bare article, which is the same mistake.
                for article in [" the", " a", " an"] {
                    #expect(!text.hasSuffix(article),
                            Comment(rawValue: "cap \(cap) broke after '\(article)': \(text)"))
                }
            }
        }
    }

    /// When a break is unavoidable it lands in front of a word that opens a phrase, which
    /// is where a person would take a breath.
    @Test func breaksLandBeforeAPhraseOpener() {
        let texts = Self.chunks(Self.sentence, cap: 200)
        #expect(texts.count > 1, "the sentence should not fit in one chunk at 200")
        for next in texts.dropFirst() {
            let first = next.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            #expect(Segmenter.phraseOpeners.contains(first),
                    Comment(rawValue: "chunk starts on '\(first)', not a phrase opener"))
        }
    }

    /// The whole essay sentence fits in one chunk at the shipped cap, so none of this
    /// applies to it any more. That is the real fix; the phrase logic is the fallback.
    @Test func theShippedCapHoldsALongSentenceWhole() {
        #expect(Self.chunks(Self.sentence, cap: 400).count == 1)
    }

    // MARK: - The chooser itself

    @Test func itPrefersTheLatestGoodBreak() {
        let words = ["Only", "by", "acknowledging", "such", "vulnerabilities", "and",
                     "working", "within", "a", "community"]
            .enumerated().map { (text: $1, start: $0 * 10) }
        let index = Segmenter.phraseBreak(in: words, notBefore: 10)
        // "within" is the last opener; breaking before it beats breaking before "and".
        #expect(index.map { words[$0].text } == "within",
                Comment(rawValue: index.map { words[$0].text } ?? "none"))
    }

    /// A break too early leaves a chunk barely worth having, so the cap wins instead.
    @Test func itRefusesToGiveUpTooMuchOfTheChunk() {
        let words = ["and", "then", "a", "very", "long", "run", "of", "words"]
            .enumerated().map { (text: $1, start: $0 * 10) }
        #expect(Segmenter.phraseBreak(in: words, notBefore: 1_000) == nil)
    }

    /// A run with no phrase opener in it has no better answer than the cap.
    @Test func aRunWithNoOpenerHasNoBetterBreak() {
        let words = ["alpha", "bravo", "charlie", "delta", "echo"]
            .enumerated().map { (text: $1, start: $0 * 10) }
        #expect(Segmenter.phraseBreak(in: words, notBefore: 5) == nil)
    }

    /// Never the first word: that would emit an empty chunk.
    @Test func itNeverBreaksBeforeTheFirstWord() {
        let words = ["and", "and", "and"].enumerated().map { (text: $1, start: $0 * 10) }
        #expect(Segmenter.phraseBreak(in: words, notBefore: 0) != 0)
    }
}
