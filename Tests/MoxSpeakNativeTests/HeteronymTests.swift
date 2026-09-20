import Testing
@testable import MoxSpeakNative

/// Words spelled one way and said two, resolved by the words around them.
///
/// Reported against the website's own audio sample: "She had read the letter" came out
/// /ɹid/, present tense, in a sentence that is plainly past. It reads as the app not
/// understanding the sentence, which is the one thing a reader must not sound like.
///
/// Two separate defects were behind it. The lexicon keys these words by Penn tag — "read"
/// carries VBD, VBN and VBP entries — but the lookup only ever computed a coarse parent
/// tag (VERB, NOUN, ADJ), so those entries were unreachable and everything fell through
/// to DEFAULT. And even reachable, the tag would have been wrong: "read" spells every
/// form the same way, so morphology cannot tell a participle from an infinitive. It takes
/// the preceding word, which the G2P was not passing down at all.
extension NativeEngineTests {

@MainActor
@Suite(.enabled(if: NativeTestEnvironment.isReady))
struct HeteronymTests {

    static let engine: NativeKokoroEngine? = try? NativeKokoroEngine(
        assets: .resolveDefault(precision: .float16))

    static func phonemes(_ text: String) throws -> String {
        guard let engine else { return "" }
        return try engine.phonemes(for: text)
    }

    /// The reported sentence.
    @Test func readAfterAnAuxiliaryIsThePastTense() throws {
        let past = try Self.phonemes("She had read the letter.")
        #expect(past.contains("ɹˈɛd"), Comment(rawValue: past))
        #expect(!past.contains("ɹˈid"), Comment(rawValue: "still present tense: \(past)"))
    }

    @Test func everyHaveFormCounts() throws {
        for sentence in ["I have read it.", "She has read it.", "They had read it."] {
            let out = try Self.phonemes(sentence)
            #expect(out.contains("ɹˈɛd"), Comment(rawValue: "\(sentence) -> \(out)"))
        }
    }

    /// The other side of the same coin, and the reason this is a rule about "have" rather
    /// than about the word "read": without a preceding auxiliary it must stay /ɹid/.
    @Test func readWithoutAnAuxiliaryStaysPresentTense() throws {
        for sentence in ["Please read the header.", "I will read it later.",
                         "You can read this offline."] {
            let out = try Self.phonemes(sentence)
            #expect(out.contains("ɹˈid"), Comment(rawValue: "\(sentence) -> \(out)"))
            #expect(!out.contains("ɹˈɛd"), Comment(rawValue: "\(sentence) -> \(out)"))
        }
    }

    /// The same fix reaches the other three words the lexicon keys this way.
    @Test func theOtherAffectedWords() throws {
        // The verb, as in winding a clock.
        let verb = try Self.phonemes("She had wound the clock.")
        #expect(verb.contains("wˈWnd"), Comment(rawValue: verb))

        // And the noun, which must not move. This is the check that would catch a fix
        // applied too broadly: making every "wound" a participle would be a new bug
        // wearing the old one's clothes.
        let noun = try Self.phonemes("The wound was deep.")
        #expect(noun.contains("wˈund"), Comment(rawValue: noun))
        #expect(!noun.contains("wˈWnd"), Comment(rawValue: noun))
    }
}

}
