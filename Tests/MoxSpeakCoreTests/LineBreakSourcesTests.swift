import Testing
@testable import MoxSpeakCore

/// Line breaks as they actually arrive, from the places people copy text from.
///
/// The shape of a line break is entirely a property of the source, and the sources
/// disagree completely: a PDF wraps mid-sentence at a fixed width, a web page uses them
/// as layout, Obsidian means them structurally, and Word often has none at all. A rule
/// tuned on one of those breaks the others, so each one gets a case here.
@Suite struct LineBreakSourcesTests {

    static func prepared(_ text: String) -> String { TextPreparer().prepare(text) }

    /// Windows and a lot of web forms send CRLF. `.whitespaces` does not include a
    /// carriage return, so a "blank" line arriving as "\r" is not empty, and every
    /// paragraph break silently stops being one.
    @Test func windowsLineEndingsBehaveLikeUnixOnes() {
        let crlf = "For Developers\r\n\r\nStart with code.\r\nScale without limits."
        let lf = "For Developers\n\nStart with code.\nScale without limits."
        #expect(Self.prepared(crlf) == Self.prepared(lf),
                Comment(rawValue: "CRLF: \(Self.prepared(crlf))"))
        #expect(Self.prepared(crlf).hasPrefix("For Developers.\nStart with code."))
        #expect(!Self.prepared(crlf).contains("\r"))
    }

    /// An Obsidian note: headings, bullets, a nested list, and prose underneath.
    @Test func obsidianNote() {
        let note = """
        ## Weekly review

        Things that went well:
        - shipped the update check
        - fixed the seam padding

        The bigger question is whether the chunk cap is still right. It was measured
        against a different engine, so the number may no longer mean anything.
        """
        let out = Self.prepared(note)
        #expect(out.hasPrefix("Weekly review."), Comment(rawValue: out))
        #expect(out.contains("shipped the update check."), Comment(rawValue: out))
        #expect(out.contains("fixed the seam padding."), Comment(rawValue: out))
        // The prose under it wrapped mid-sentence and must stay one sentence.
        #expect(out.contains("It was measured against a different engine"),
                Comment(rawValue: out))
        #expect(!out.contains("measured. against"))
    }

    /// Word and Google Docs usually paste a paragraph as one long line with no internal
    /// breaks at all, and paragraphs separated by a single newline.
    @Test func wordStyleParagraphs() {
        let doc = "The first paragraph runs on for a while and ends properly.\n"
                + "The second paragraph also ends properly.\n"
                + "A third one, for luck."
        let out = Self.prepared(doc)
        #expect(out == "The first paragraph runs on for a while and ends properly. "
                     + "The second paragraph also ends properly. A third one, for luck.",
                Comment(rawValue: out))
        #expect(!out.contains(".."))
    }

    /// A PDF hard-wraps at a fixed width, mid-sentence, with no punctuation at the break.
    /// Adding a full stop to any of these would be far worse than the bug being fixed.
    @Test func pdfHardWrapping() {
        let pdf = """
        Researchers have known for decades that the rate at which a glacier sheds
        mass depends less on the air above it than on the water beneath it, and the
        instrumentation needed to observe that water has only recently become cheap
        enough to leave behind on the ice through a winter.
        """
        let out = Self.prepared(pdf)
        #expect(!out.contains("sheds. mass"), Comment(rawValue: out))
        #expect(!out.contains("the. instrumentation"), Comment(rawValue: out))
        #expect(out.hasSuffix("through a winter."))
        // One sentence in, one sentence out.
        #expect(out.filter { $0 == "." }.count == 1, Comment(rawValue: out))
    }

    /// A web page's navigation and headings: a stack of short lines, none punctuated.
    /// Every one of them is its own utterance.
    @Test func webPageHeadingStack() {
        let page = """
        Pricing
        Docs
        Blog
        Sign in
        """
        let out = Self.prepared(page)
        // The last line gets no terminator: nothing follows it, and inventing a full
        // stop for the end of a document would put one on every single-line reading too.
        #expect(out == "Pricing. Docs. Blog. Sign in", Comment(rawValue: out))
    }

    /// A quoted email reply. Blockquote markers go; the lines under them are prose.
    @Test func quotedEmail() {
        let email = """
        > I think the chunk size is wrong, and it has been
        > wrong since the engine changed.

        Agreed. I will measure it today.
        """
        let out = Self.prepared(email)
        #expect(out.contains("wrong, and it has been wrong since the engine changed."),
                Comment(rawValue: out))
        #expect(!out.contains("been. wrong"))
    }

    /// A markdown table: rows are separate, cells within a row are not sentences.
    @Test func markdownTable() {
        let table = """
        | Key | What it does |
        |---|---|
        | Control O S | Speak the selection |
        | Control O X | Stop |
        """
        let out = Self.prepared(table)
        #expect(!out.contains("selection Control"), Comment(rawValue: out))
        #expect(!out.contains("|"), Comment(rawValue: out))
    }

    /// Whatever the source, a trailing newline must not put a full stop on the end of
    /// something that had none, and nothing may ever gain a doubled terminator.
    @Test func trailingAndRepeatedBlankLinesAddNothing() {
        #expect(Self.prepared("Just one line\n") == "Just one line")
        #expect(Self.prepared("Just one line\n\n\n") == "Just one line")
        #expect(Self.prepared("One.\n\n\n\nTwo.") == "One.\nTwo.")
        #expect(!Self.prepared("A heading\n\n\nBody text here.").contains(".."))
    }
}
