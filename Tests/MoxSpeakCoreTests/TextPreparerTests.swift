import Testing
import Foundation
@testable import MoxSpeakCore

@Test func stripsMarkdownEmphasisAndHeadings() {
    let p = TextPreparer()
    #expect(p.prepare("## The **bold** truth") == "The bold truth")
    #expect(p.prepare("It was *very* cold.") == "It was very cold.")
    #expect(p.prepare("Use `swift test` now.") == "Use swift test now.")
}

@Test func reducesMarkdownLinksToLabel() {
    let p = TextPreparer()
    #expect(p.prepare("See [the docs](https://example.com/a/b) today.")
            == "See the docs today.")
}

/// The bullet goes; the fact that these were two separate items does not.
///
/// This used to expect "first second", which is the defect rather than the behaviour: two
/// list items spoken as one phrase, with no pause between them. The marker is the only
/// evidence a line was a standalone item, so an unterminated item is terminated while the
/// marker is still there to prove it was one.
@Test func stripsListBulletsButKeepsThemApart() {
    let p = TextPreparer()
    #expect(p.prepare("- first\n- second") == "first. second.")
    #expect(p.prepare("1. first\n2. second") == "first. second.")
    // An item that punctuates itself is left exactly as it is.
    #expect(p.prepare("- first.\n- second?") == "first. second?")
    #expect(p.prepare("- ends in a colon:\n- next") == "ends in a colon: next.")
}

@Test func stripsCitationBrackets() {
    let p = TextPreparer()
    #expect(p.prepare("This is established [12] and known [3].")
            == "This is established and known.")
}

@Test func rejoinsPdfHyphenationAndHardWraps() {
    let p = TextPreparer()
    let pdf = "The quick brown fox jum-\nped over the lazy\ndog."
    #expect(p.prepare(pdf) == "The quick brown fox jumped over the lazy dog.")
}

/// A paragraph break survives as a newline, and it is the only newline left in prepared
/// text. It used to become a plain space, which made a new paragraph acoustically
/// identical to the next sentence — `Segmenter` breaks a chunk here and `AudioSeam` gives
/// it a longer pause, and neither can happen if the boundary is thrown away.
@Test func paragraphBreaksSurviveAsNewlines() {
    let p = TextPreparer()
    #expect(p.prepare("First para.\n\nSecond para.") == "First para.\nSecond para.")
    // A run of blank lines is still one break.
    #expect(p.prepare("First para.\n\n\n\nSecond para.") == "First para.\nSecond para.")
    // A soft wrap is not a paragraph break and gains nothing.
    #expect(p.prepare("one long line that\nwrapped here") == "one long line that wrapped here")
}

@Test func announcesFencedCodeBlocksByDefault() {
    let p = TextPreparer()
    let input = "Before.\n```swift\nlet x = 1\n```\nAfter."
    #expect(p.prepare(input) == "Before. Code block. After.")
}

@Test func skipsCodeBlocksWhenConfigured() {
    var opts = TextPreparer.Options()
    opts.codeBlocks = .skip
    let p = TextPreparer(options: opts)
    let input = "Before.\n```swift\nlet x = 1\n```\nAfter."
    // Removing the block leaves a block-level gap, which is a paragraph break.
    #expect(p.prepare(input) == "Before.\nAfter.")
}

@Test func stripsEmoji() {
    let p = TextPreparer()
    #expect(p.prepare("Shipped it 🚀🎉 today.") == "Shipped it today.")
}

@Test func normalizesSmartQuotesAndEllipses() {
    let p = TextPreparer()
    #expect(p.prepare("\u{201C}Wait\u{2026}\u{201D} he said.") == "\"Wait...\" he said.")
}

@Test func leavesPlainProseUntouched() {
    let p = TextPreparer()
    let prose = "It was a bright cold day in April, and the clocks were striking thirteen."
    #expect(p.prepare(prose) == prose)
}

@Test func doesNotTouchNumbersOrUrlsOrAbbreviations() {
    // The backend normalizer owns these. Double-handling them is a bug.
    let p = TextPreparer()
    let input = "Dr. Smith paid $1,200 on 3/4/2026 via https://pay.example.com"
    #expect(p.prepare(input) == input)
}

@Test func handlesEmptyAndWhitespaceOnlyInput() {
    let p = TextPreparer()
    #expect(p.prepare("") == "")
    #expect(p.prepare("   \n\n  ") == "")
}

// MARK: - Object placeholders

@Test func objectPlaceholdersAreRemoved() {
    // A browser puts U+FFFC in a selection wherever it crossed something that is not
    // text. Selecting the GitHub heading "Read Aloud TTS with Kokoro" picks up the
    // invisible anchor link that follows it and hands over exactly this.
    let preparer = TextPreparer()
    #expect(preparer.prepare("Read Aloud TTS with Kokoro\u{FFFC}") == "Read Aloud TTS with Kokoro")
}

@Test func aSelectionOfNothingButPlaceholdersPreparesToNothing() {
    let preparer = TextPreparer()
    #expect(preparer.prepare("\u{FFFC}\u{FFFC}") == "")
}

@Test func placeholdersInsideProseDoNotEatTheSpacesAroundThem() {
    let preparer = TextPreparer()
    #expect(preparer.prepare("before \u{FFFC} after") == "before after")
}
