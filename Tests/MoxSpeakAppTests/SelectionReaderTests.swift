import Testing
import AppKit
import Foundation
@testable import MoxSpeakApp

// The rule that picks between the three tiers, tested with the world passed in.
//
// This exists because the cases that matter most cannot be staged: "permission granted,
// focused app hands back nothing" is routine in Electron windows and PDF views, and
// "permission granted, the app was asked to copy and copied nothing" is the signal the
// whole fix turns on — both unreachable on a machine where Accessibility has never been
// granted. Keeping the rule pure means it is checkable regardless, and it is the rule,
// not the readers around it, that decides whether the user hears the right words, the
// wrong ones, or an honest silence.

// MARK: - Tier 3: without permission (the zero-permission default)

@Test func withoutPermissionTheClipboardIsRead() {
    let reading = SelectionReader.decide(isTrusted: false, selection: nil, clipboard: "copied")
    #expect(reading.text == "copied")
    #expect(reading.source == .clipboard)
    #expect(reading.source.tier == 3)
    #expect(reading.isTrusted == false)
}

@Test func withoutPermissionASelectionIsNotUsedEvenIfOneIsSomehowOffered() {
    // `read` never fetches a selection untrusted, so this can only happen if someone
    // rewires it later. The rule refuses anyway: no permission, no selection, ever.
    let reading = SelectionReader.decide(isTrusted: false,
                                         selection: "highlighted",
                                         clipboard: "copied")
    #expect(reading.text == "copied")
    #expect(reading.source == .clipboard)
}

@Test func withoutPermissionACopyIsNotUsedEitherEvenIfOneIsSomehowOffered() {
    // Tier 2 needs the same permission tier 1 does, so an untrusted process can never
    // have posted a ⌘C. If it somehow did, the answer is still the clipboard as-is.
    let reading = SelectionReader.decide(isTrusted: false,
                                         selection: nil,
                                         copied: .nothingSelected,
                                         clipboard: "copied")
    #expect(reading.text == "copied")
    #expect(reading.source == .clipboard)
}

@Test func withoutPermissionAndAnEmptyClipboardThereIsNothingToSay() {
    let reading = SelectionReader.decide(isTrusted: false, selection: nil, clipboard: nil)
    #expect(reading.text == nil)
    #expect(reading.source == .clipboard)
    // The wording must not mention a selection the user cannot have.
    #expect(!reading.note.contains("selected"))
    #expect(reading.flash == "Clipboard is empty")
}

// MARK: - Tier 1: Accessibility read the words

@Test func withPermissionTheSelectionWins() {
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: "highlighted",
                                         clipboard: "copied")
    #expect(reading.text == "highlighted")
    #expect(reading.source == .selection)
    #expect(reading.source.tier == 1)
    #expect(reading.isTrusted == true)
}

@Test func tierOneSaysItLeftTheClipboardAlone() {
    // The user's clipboard being untouched is a promise, not an implementation detail,
    // and the log is where the promise is kept.
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: "highlighted",
                                         clipboard: "copied")
    #expect(reading.reason.contains("not touched"))
}

// MARK: - Tier 2: the app was asked to copy

@Test func withPermissionAndNoSelectionTheCopyIsSpoken() {
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .copied("from the editor"),
                                         clipboard: "from the editor")
    #expect(reading.text == "from the editor")
    #expect(reading.source == .copy)
    #expect(reading.source.tier == 2)
}

@Test func aCopyThatChangedNothingMeansNothingWasSelected() {
    // The bug this branch exists to kill. The clipboard holds something — something the
    // user copied ages ago — and the app has just told us, by copying nothing, that there
    // is no selection. Speaking that clipboard is how the user ends up hearing unrelated
    // text with total confidence and no explanation.
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .nothingSelected,
                                         clipboard: "something from twenty minutes ago")
    #expect(reading.text == nil)
    #expect(reading.flash == "Nothing selected")
    #expect(reading.note.contains("nothing is selected"))
    // And it must be possible to find out from the log that a clipboard was declined,
    // not merely that nothing happened.
    #expect(reading.reason.contains("clipboard"))
}

@Test func aCopyThatProducedSomethingUnreadableSaysSoRatherThanGuessing() {
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .copied(nil),
                                         clipboard: "stale text")
    #expect(reading.text == nil)
    #expect(reading.flash == "Selection isn't text")
    #expect(reading.note.contains("not text"))
}

@Test func aCopyThatCouldNotBeSentIsNotMistakenForAnEmptySelection() {
    // "We could not ask" and "we asked and there was nothing" are different facts, and
    // conflating them would put a macOS problem on the user as "nothing is selected".
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .failed("macOS refused"),
                                         clipboard: "stale text")
    #expect(reading.text == nil)
    #expect(reading.flash == "Couldn't read the selection")
    #expect(reading.reason.contains("macOS refused"))
}

@Test func whatAccessibilitySawIsCarriedIntoTheTierTwoExplanation() {
    // A selection the app reported but would not spell out is a different story from no
    // selection at all, and the log should tell them apart even when both end in a copy.
    let sawIt = SelectionReader.decide(isTrusted: true,
                                       selection: nil,
                                       evidence: .unreadable,
                                       copied: .copied("words"),
                                       clipboard: "words")
    let sawNothing = SelectionReader.decide(isTrusted: true,
                                            selection: nil,
                                            evidence: .none,
                                            copied: .copied("words"),
                                            clipboard: "words")
    #expect(sawIt.reason.contains("would not spell out"))
    #expect(sawNothing.reason.contains("no selected text"))
    #expect(sawIt.reason != sawNothing.reason)
}

// MARK: - Nothing anywhere

@Test func withPermissionAndNothingAnywhereTheWordingNamesTheSelection() {
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .nothingSelected,
                                         clipboard: nil)
    #expect(reading.text == nil)
    #expect(reading.note.contains("selected"))
}

// MARK: - What gets logged

@Test func everyOutcomeNamesItsSourceAndSaysWhy() {
    // The log line is built from these two. A path that cannot explain itself is exactly
    // the silent failure this project refuses to ship, so neither may ever be blank.
    let outcomes = [
        SelectionReader.decide(isTrusted: false, selection: nil, clipboard: "c"),
        SelectionReader.decide(isTrusted: true, selection: "s", clipboard: nil),
        SelectionReader.decide(isTrusted: true, selection: nil,
                               copied: .copied("c"), clipboard: "c"),
        SelectionReader.decide(isTrusted: true, selection: nil,
                               copied: .nothingSelected, clipboard: "c"),
        SelectionReader.decide(isTrusted: true, selection: nil,
                               copied: .nothingSelected, clipboard: nil),
    ]
    for outcome in outcomes {
        #expect(!outcome.reason.isEmpty)
        #expect(!outcome.flash.isEmpty)
        #expect(!outcome.note.isEmpty)
        #expect(["selection", "copy", "clipboard"].contains(outcome.source.rawValue))
    }
    #expect(outcomes[0].source == .clipboard)
    #expect(outcomes[1].source == .selection)
    #expect(outcomes[2].source == .copy)
    // Three tiers, three numbers, and the number is the only way a user finds out which
    // one ran.
    #expect(outcomes[0].source.tier == 3)
    #expect(outcomes[1].source.tier == 1)
    #expect(outcomes[2].source.tier == 2)
    // A copy that spoke and a copy that declined must not be indistinguishable in the
    // log: one is the app working, the other is the app protecting the user from it.
    #expect(outcomes[2].reason != outcomes[3].reason)
}

// MARK: - Saving and restoring the clipboard

@MainActor
@Test func aSnapshotCarriesEveryTypeOfEveryItem() {
    // Tier 2 clobbers the user's clipboard on purpose and has to put it back exactly.
    // "Exactly" means every representation, not just the plain string: an item copied
    // from a rich editor carries RTF and HTML beside the text, and restoring only the
    // text would silently downgrade what the user had.
    let pasteboard = NSPasteboard(name: .init("moxspeak.tests.snapshot"))
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString("plain", forType: .string)
    item.setData(Data("<b>rich</b>".utf8), forType: .html)
    pasteboard.writeObjects([item])

    let saved = SelectionCopier.snapshot(pasteboard)

    // Something else happens to the pasteboard, as a copy would do.
    pasteboard.clearContents()
    pasteboard.setString("the selection", forType: .string)
    #expect(pasteboard.string(forType: .string) == "the selection")

    SelectionCopier.restore(saved, to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "plain")
    #expect(pasteboard.data(forType: .html) == Data("<b>rich</b>".utf8))
}

@MainActor
@Test func theRestoredClipboardIsMarkedAsScaffolding() {
    // nspasteboard.org's convention for "do not record this". Without it, every tier 2
    // read leaves a duplicate of the user's own entry in their clipboard manager.
    let pasteboard = NSPasteboard(name: .init("moxspeak.tests.transient"))
    pasteboard.clearContents()
    pasteboard.setString("theirs", forType: .string)

    let saved = SelectionCopier.snapshot(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("the selection", forType: .string)
    SelectionCopier.restore(saved, to: pasteboard)

    let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    #expect(pasteboard.types?.contains(transient) == true)
    #expect(pasteboard.string(forType: .string) == "theirs")
}

@MainActor
@Test func aSnapshotOfNonTextSurvivesTheRoundTrip() {
    // The user may have an image on the clipboard when they press ⌥⇧S. Losing it would
    // be a worse bug than the one being fixed.
    let pasteboard = NSPasteboard(name: .init("moxspeak.tests.image"))
    pasteboard.clearContents()
    let pixels = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let item = NSPasteboardItem()
    item.setData(pixels, forType: .png)
    pasteboard.writeObjects([item])

    let saved = SelectionCopier.snapshot(pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("the selection", forType: .string)
    SelectionCopier.restore(saved, to: pasteboard)

    #expect(pasteboard.data(forType: .png) == pixels)
    #expect(pasteboard.string(forType: .string) == nil)
}

@MainActor
@Test func restoringAnEmptySnapshotLeavesAnEmptyClipboard() {
    // An empty clipboard is a state the user can legitimately be in, and coming back
    // from tier 2 with someone else's text in it would be inventing content.
    let pasteboard = NSPasteboard(name: .init("moxspeak.tests.empty"))
    pasteboard.clearContents()
    let saved = SelectionCopier.snapshot(pasteboard)
    pasteboard.setString("the selection", forType: .string)

    SelectionCopier.restore(saved, to: pasteboard)
    #expect(pasteboard.string(forType: .string) == nil)
}
