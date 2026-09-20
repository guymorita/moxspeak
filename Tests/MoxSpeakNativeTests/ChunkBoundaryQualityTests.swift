import Testing
@testable import MoxSpeakCore
@testable import MoxSpeakNative

/// Where the native engine's chunk cap is allowed to break a sentence.
///
/// This is the test that was missing when the cap moved. `SpeechSession` started honouring
/// `NativeSpeechProvider.recommendedCharacterCap` in 9d498aa, which dropped the effective
/// cap from the segmenter's own default of 150 to the engine's declared 100 — and nothing
/// anywhere asserted what that did to where sentences got cut. The number had a comment
/// saying the acoustic cost was unmeasured and that the number should go up if it turned
/// out to be audible. It was audible: read back a paragraph and the engine stopped between
/// "lots of" and "awkward".
///
/// Every chunk boundary is a place where Kokoro restarts its prosody contour, so a chunk
/// that ends mid-clause is *heard* as a full stop in the wrong place. The segmenter's
/// ladder goes sentence, then clause, then word, then hard split; the first two produce
/// boundaries a listener accepts, and the last two do not. So the property is: on ordinary
/// English prose, the cap must be large enough that the ladder never reaches the word rung.
///
/// This does not synthesize anything, so it runs without the model or the perf flag.
@Suite struct ChunkBoundaryQualityTests {

    /// Prose with the shape the app actually meets: article sentences, a couple of long
    /// ones, and the message that reported the bug. Not the eval corpus — that is mostly
    /// short normalizer probes, and short sentences cannot exercise a cap.
    static let prose = """
    Did something happen? Like I feel like it's pausing at weird places now. It seems to \
    just be pausing it like not where it should be in the sentences. Are we still chunking \
    it? Is that why? yeah, pl see if you can maybe think about root causing that. it just \
    seems to be stopping at lots of awkward places in the sentences.

    The restriction exists because Shift and Option are how you type alternate characters, \
    so a process that could observe them globally would be able to read passwords as they \
    were entered. Apple's rule, stated plainly, is that a hotkey must include at least one \
    modifier that is neither Shift nor Option. The failure mode is the worst possible \
    shape: registration returns no error, the handler installs cleanly, and the callback \
    is simply never invoked.

    Researchers have known for decades that the rate at which a glacier sheds mass depends \
    less on the air above it than on the water beneath it, and the instrumentation needed \
    to observe that water has only recently become cheap enough to leave behind on the ice \
    through a winter.
    """

    /// A chunk a listener accepts ends where a speaker would pause: a sentence terminator,
    /// or a clause delimiter. Anything else means the ladder fell through to splitting
    /// between two words that belong to the same breath.
    static func endsAtASpeakableBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last
        else { return true }
        return ".!?…".contains(last) || ",;:—".contains(last)
    }

    static func midClauseBreaks(cap: Int) -> [String] {
        let prepared = TextPreparer().prepare(prose)
        return Segmenter(options: Segmenter.Options(providerCap: cap))
            .segment(prepared)
            .map(\.text)
            .filter { !endsAtASpeakableBoundary($0) }
    }

    /// The property, asserted against whatever the engine currently declares.
    @Test func theNativeCapNeverSplitsBetweenWords() {
        let breaks = Self.midClauseBreaks(cap: NativeSpeechProvider.measuredCharacterCap)
        #expect(breaks.isEmpty, Comment(rawValue:
            "at a \(NativeSpeechProvider.measuredCharacterCap)-character cap the segmenter "
            + "cut \(breaks.count) chunk(s) between words, which Kokoro renders as a full "
            + "stop in the middle of a clause:\n"
            + breaks.map { "  …\($0.suffix(60))" }.joined(separator: "\n")))
    }

    /// The same measurement across the range, so the choice can be re-derived rather than
    /// trusted — and so it is on the record that this is a cliff, not a gradient.
    @Test func theCapIsAboveTheCliff() {
        #expect(!Self.midClauseBreaks(cap: 100).isEmpty)
        #expect(Self.midClauseBreaks(cap: 200).isEmpty)
    }
}
