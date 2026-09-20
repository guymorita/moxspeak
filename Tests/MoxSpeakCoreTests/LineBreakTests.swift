import Testing
@testable import MoxSpeakCore

/// What a line break turns into, which is the difference between a page that is read and
/// a page that is gabbled.
@Suite struct LineBreakTests {

    static func prepared(_ text: String) -> String { TextPreparer().prepare(text) }

    /// The report that started this: marketing copy from a web page, read as one
    /// breathless run-on because no line ended in a full stop.
    @Test func headingsAndShortLinesBecomeTheirOwnSentences() {
        let page = """
        For Developers

        Start with code.
        Scale without limits.
        Smallest is built for rapid prototyping and seamless integration.
        """
        let out = Self.prepared(page)
        #expect(out.hasPrefix("For Developers."),
                Comment(rawValue: "the heading ran into the next line: \(out)"))
        #expect(!out.contains("For Developers Start"))
        // Lines that already end in a full stop are left exactly as they were.
        #expect(out.contains("Start with code. Scale without limits."))
        #expect(!out.contains(".."))
    }

    /// The case that must not regress. A PDF or an email wraps mid-sentence, and putting
    /// a full stop there would be worse than the bug being fixed.
    @Test func softWrapsAreStillJoinedWithoutAPause() {
        let wrapped = """
        The quick brown fox jumps over
        the lazy dog and keeps on
        running until it is tired.
        """
        let out = Self.prepared(wrapped)
        #expect(out == "The quick brown fox jumps over the lazy dog and keeps on running "
                     + "until it is tired.",
                Comment(rawValue: out))
    }

    /// A list is a stack of separate things and should be read as one.
    @Test func listItemsAreSeparatedEvenWithoutPunctuation() {
        let list = """
        Requirements:
        - Apple silicon
        - macOS 14 or later
        - About 210 MB
        """
        let out = Self.prepared(list)
        #expect(out.contains("Apple silicon."), Comment(rawValue: out))
        #expect(out.contains("macOS 14 or later."), Comment(rawValue: out))
        // A colon already earns a pause; a full stop after it would be a stutter.
        #expect(!out.contains("Requirements:."), Comment(rawValue: out))
    }

    /// Nothing may gain a doubled terminator, in any combination.
    @Test func punctuationIsNeverDoubled() {
        for ending in [".", "!", "?", ":", ";", "…", "\u{2014}"] {
            let out = Self.prepared("A line that ends\(ending)\n\nAnother line.")
            #expect(!out.contains("\(ending)."),
                    Comment(rawValue: "doubled after \(ending): \(out)"))
        }
        // A closing quote sits outside the full stop it closes.
        let quoted = Self.prepared("He said \"stop.\"\n\nThen he left.")
        #expect(!quoted.contains("\".") && !quoted.contains(".."),
                Comment(rawValue: quoted))
    }

    /// Blank lines are a real break whatever precedes them, including a lower-case start
    /// on the next line, because nothing wraps across a blank line.
    @Test func aBlankLineAlwaysBreaks() {
        let out = Self.prepared("the end of something\n\nand the start of another")
        #expect(out == "the end of something. and the start of another",
                Comment(rawValue: out))
    }

    @Test func ordinaryProseIsUntouched() {
        let prose = "One sentence. Then another one, with a clause. And a third?"
        #expect(Self.prepared(prose) == prose)
    }
}
