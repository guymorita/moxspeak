import Testing
import Foundation
@testable import MoxSpeakApp

// The rule that decides selection-versus-clipboard, tested with the world passed in.
//
// This exists because the case that matters most cannot be staged: "permission granted,
// focused app hands back nothing" is routine in Electron windows and PDF views, and is
// unreachable on a machine where Accessibility has never been granted. Keeping the rule
// pure means it is checkable regardless — and it is the rule, not the two readers around
// it, that decides whether the user hears the right words or the wrong ones.

// MARK: - Without permission (the default, and today's behavior)

@Test func withoutPermissionTheClipboardIsRead() {
    let reading = SelectionReader.decide(isTrusted: false, selection: nil, clipboard: "copied")
    #expect(reading.text == "copied")
    #expect(reading.source == .clipboard)
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

@Test func withoutPermissionAndAnEmptyClipboardThereIsNothingToSay() {
    let reading = SelectionReader.decide(isTrusted: false, selection: nil, clipboard: nil)
    #expect(reading.text == nil)
    #expect(reading.source == .clipboard)
    // The wording must not mention a selection the user cannot have.
    #expect(!reading.emptyNote.contains("selected"))
    #expect(reading.emptyFlash == "Clipboard is empty")
}

// MARK: - With permission

@Test func withPermissionTheSelectionWins() {
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: "highlighted",
                                         clipboard: "copied")
    #expect(reading.text == "highlighted")
    #expect(reading.source == .selection)
    #expect(reading.isTrusted == true)
}

@Test func withPermissionButNoSelectionTheClipboardIsTheFallback() {
    // Electron, PDF views, anything that does not implement AXSelectedText. Doing
    // nothing here would make granting the permission a downgrade.
    let reading = SelectionReader.decide(isTrusted: true, selection: nil, clipboard: "copied")
    #expect(reading.text == "copied")
    #expect(reading.source == .clipboard)
    #expect(reading.reason.contains("fell back to the clipboard"))
}

@Test func withPermissionAndNothingAnywhereTheWordingCoversBoth() {
    let reading = SelectionReader.decide(isTrusted: true, selection: nil, clipboard: nil)
    #expect(reading.text == nil)
    #expect(reading.emptyNote.contains("selected"))
    #expect(reading.emptyNote.contains("clipboard"))
}

// MARK: - What gets logged

@Test func everyOutcomeNamesItsSourceAndSaysWhy() {
    // The log line is built from these two. A path that cannot explain itself is exactly
    // the silent failure this project refuses to ship, so neither may ever be blank.
    let outcomes = [
        SelectionReader.decide(isTrusted: false, selection: nil, clipboard: "c"),
        SelectionReader.decide(isTrusted: true, selection: "s", clipboard: "c"),
        SelectionReader.decide(isTrusted: true, selection: nil, clipboard: "c"),
        SelectionReader.decide(isTrusted: true, selection: nil, clipboard: nil),
    ]
    for outcome in outcomes {
        #expect(!outcome.reason.isEmpty)
        #expect(["selection", "clipboard"].contains(outcome.source.rawValue))
    }
    #expect(outcomes[0].source == .clipboard)
    #expect(outcomes[1].source == .selection)
    #expect(outcomes[2].source == .clipboard)
    // The two clipboard readings must not be indistinguishable in the log: one is the
    // app working as designed, the other is a granted permission not paying off.
    #expect(outcomes[0].reason != outcomes[2].reason)
}
