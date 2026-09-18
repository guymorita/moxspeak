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
    //
    // "Ages ago" is the operative word, and it is what the change count says: the mark
    // and the current count agree, so nothing has been written since we last looked.
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .nothingSelected,
                                         clipboard: "something from twenty minutes ago",
                                         clipboardChangeCount: 91,
                                         lastActedClipboardChangeCount: 91)
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

// MARK: - Freshness: telling a clipboard just filled from one left over

// The second confidently-wrong outcome this area has produced, and the reason these tests
// replay *sequences* rather than checking single calls. "Never speak a stale clipboard"
// was right about the failure it was written for and wrong about the workflow it broke:
// in a full-screen TUI that swallows mouse selection, copy-then-press is the only way to
// use this app, and the rule refused it for the same reason it refused a clipboard from
// twenty minutes ago — because it could not tell them apart.
//
// `NSPasteboard.changeCount` is what tells them apart, and the rule that uses it is a
// state machine with exactly one piece of memory: the count last acted on. A test that
// only ever calls `decide` once cannot see that memory work, so these thread it.

/// One ⌥⇧S press with nothing selected, with the memory threaded through exactly as
/// `SelectionReader.read` threads it: `decide` answers, and whatever it reports having
/// acted on becomes the mark the next press is judged against.
private func press(clipboard: String?,
                   changeCount: Int,
                   mark: inout Int?) -> TextReading {
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .nothingSelected,
                                         clipboard: clipboard,
                                         clipboardChangeCount: changeCount,
                                         lastActedClipboardChangeCount: mark)
    if let acted = reading.clipboardChangeCountActedOn { mark = acted }
    return reading
}

@Test func nothingSelectedButAFreshlyCopiedClipboardIsSpoken() {
    // The owner's report, exactly: he copies in iTerm2 running a TUI, the TUI owns the
    // mouse so no selection exists anywhere, and the words he wants are sitting on the
    // clipboard where he put them two seconds ago.
    var mark: Int? = 500
    let reading = press(clipboard: "the paragraph he just copied", changeCount: 501,
                        mark: &mark)

    #expect(reading.text == "the paragraph he just copied")
    // It came off the clipboard, so that is what the log says it is. Calling it a copy
    // would credit the ⌘C that produced nothing.
    #expect(reading.source == .clipboard)
    #expect(reading.source.tier == 3)
    #expect(reading.isTrusted == true)
}

@Test func nothingSelectedAndAnUnchangedClipboardStaysSilent() {
    // The original bug. Same branch, same clipboard holding text, and the only difference
    // is that nothing has written to it since MoxSpeak last looked.
    var mark: Int? = 500
    let reading = press(clipboard: "something from twenty minutes ago", changeCount: 500,
                        mark: &mark)

    #expect(reading.text == nil)
    #expect(reading.source == .copy)
    #expect(reading.flash == "Nothing selected")
}

@Test func theSameCopyPressedTwiceSpeaksOnceAndThenGoesQuiet() {
    // Each distinct copy gets exactly one chance. The second press is judged against a
    // mark the first press moved, so the very same clipboard is no longer fresh — which
    // is what stops "speak the clipboard when nothing is selected" from collapsing back
    // into the old always-speak-it behaviour.
    var mark: Int? = 12
    let first = press(clipboard: "copied once", changeCount: 13, mark: &mark)
    let second = press(clipboard: "copied once", changeCount: 13, mark: &mark)

    #expect(first.text == "copied once")
    #expect(second.text == nil)
    #expect(mark == 13)
}

@Test func aFreshCopyAfterADeclineIsSpoken() {
    // A decline must also move the mark, not just a successful speak — otherwise the
    // clipboard that was declined stays "unchanged" forever relative to an older mark and
    // the *next* copy's freshness is measured from the wrong place. Press, decline, copy,
    // press: the second press speaks.
    var mark: Int? = 7
    let declined = press(clipboard: "old text", changeCount: 7, mark: &mark)
    let spoken = press(clipboard: "newly copied", changeCount: 8, mark: &mark)

    #expect(declined.text == nil)
    #expect(spoken.text == "newly copied")
    #expect(mark == 8)
}

@Test func threeDistinctCopiesInARowAreEachSpokenOnce() {
    // The workflow as it is actually used: copy, press, copy, press, copy, press — with a
    // duplicate press in the middle that must stay silent.
    var mark: Int? = 0
    let spoken = [
        press(clipboard: "one", changeCount: 1, mark: &mark).text,
        press(clipboard: "one", changeCount: 1, mark: &mark).text,
        press(clipboard: "two", changeCount: 2, mark: &mark).text,
        press(clipboard: "three", changeCount: 3, mark: &mark).text,
        press(clipboard: "three", changeCount: 3, mark: &mark).text,
    ]
    #expect(spoken == ["one", nil, "two", "three", nil])
}

@Test func atLaunchAnOldClipboardIsNotTreatedAsFresh() {
    // The baseline recorded at launch is the current change count, so a clipboard filled
    // before MoxSpeak started looks exactly as unchanged as it is. Without it the first
    // press of every session would speak whatever happened to be lying around, which is
    // the original bug wearing a new hat.
    var mark: Int? = 1_234   // as `recordClipboardBaseline` would have set it
    let firstPress = press(clipboard: "yesterday's clipboard", changeCount: 1_234,
                           mark: &mark)
    #expect(firstPress.text == nil)

    // And a copy made after launch is fresh, which is the half the baseline must not
    // break: recording it cannot be allowed to silence the very next real copy.
    let afterCopying = press(clipboard: "copied after launch", changeCount: 1_235,
                             mark: &mark)
    #expect(afterCopying.text == "copied after launch")
}

@Test func withNoBaselineAtAllNothingIsTreatedAsFresh() {
    // Unreachable in the app — launch records a baseline before a press is possible — but
    // the answer has to be the one that cannot be confidently wrong. Inventing freshness
    // from the absence of a record is precisely how the original bug worked.
    var mark: Int? = nil
    let reading = press(clipboard: "who knows how old", changeCount: 9_999, mark: &mark)
    #expect(reading.text == nil)
    #expect(ClipboardFreshness.isFresh(changeCount: 9_999, lastActedOn: nil) == false)
}

@Test func freshnessIsAnyChangeNotAnIncrementCount() {
    // A single copy can bump `changeCount` more than once, and `NSPasteboard` makes no
    // promise the number only ever rises. "Different from what we last acted on" is the
    // question; "exactly one more" would be a guess that a multi-bump copy falsifies.
    #expect(ClipboardFreshness.isFresh(changeCount: 11, lastActedOn: 10) == true)
    #expect(ClipboardFreshness.isFresh(changeCount: 14, lastActedOn: 10) == true)
    #expect(ClipboardFreshness.isFresh(changeCount: 3, lastActedOn: 10) == true)
    #expect(ClipboardFreshness.isFresh(changeCount: 10, lastActedOn: 10) == false)
}

@Test func aFreshlyWrittenClipboardWithNoTextIsNotBlamedOnStaleness() {
    // The user copied an image. Nothing was selected and the clipboard *did* change, so
    // "it hasn't changed" would be untrue — the reason it went unspoken is that there are
    // no words on it. It still spends its one chance, so the next press is silent too.
    var mark: Int? = 40
    let reading = press(clipboard: nil, changeCount: 41, mark: &mark)

    #expect(reading.text == nil)
    #expect(reading.reason.contains("no text"))
    #expect(!reading.reason.contains("has not changed"))
    #expect(mark == 41)
}

@Test func tierOneNeverConsultsFreshness() {
    // A press that read the selection has no business touching the mark that says when
    // the clipboard was last looked at — and must speak the selection no matter how
    // freshly something else was copied.
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: "highlighted",
                                         clipboard: "copied one second ago",
                                         clipboardChangeCount: 77,
                                         lastActedClipboardChangeCount: 1)
    #expect(reading.text == "highlighted")
    #expect(reading.source == .selection)
    #expect(reading.clipboardChangeCountActedOn == nil)
}

@Test func tierTwoSuccessNeverConsultsFreshness() {
    // The copy produced the words, so the clipboard was never the source and its
    // freshness is irrelevant. Recording a mark here would spend a copy's one chance on a
    // press that did not need it, silencing a later press that did.
    let reading = SelectionReader.decide(isTrusted: true,
                                         selection: nil,
                                         copied: .copied("from the editor"),
                                         clipboard: "something else entirely",
                                         clipboardChangeCount: 77,
                                         lastActedClipboardChangeCount: 1)
    #expect(reading.text == "from the editor")
    #expect(reading.source == .copy)
    #expect(reading.clipboardChangeCountActedOn == nil)
}

@Test func theOtherTierTwoFailuresDoNotSpendACopysOneChanceEither() {
    // A copy that produced a non-text payload, and a copy that could not be sent. Neither
    // looked at the clipboard, so neither may move the mark.
    let notText = SelectionReader.decide(isTrusted: true, selection: nil,
                                         copied: .copied(nil), clipboard: "fresh text",
                                         clipboardChangeCount: 5,
                                         lastActedClipboardChangeCount: 4)
    let couldNotAsk = SelectionReader.decide(isTrusted: true, selection: nil,
                                             copied: .failed("macOS refused"),
                                             clipboard: "fresh text",
                                             clipboardChangeCount: 5,
                                             lastActedClipboardChangeCount: 4)
    #expect(notText.clipboardChangeCountActedOn == nil)
    #expect(couldNotAsk.clipboardChangeCountActedOn == nil)
    // And neither may quietly speak the fresh clipboard behind the user's back: they are
    // answers about the selection, not about the clipboard.
    #expect(notText.text == nil)
    #expect(couldNotAsk.text == nil)
}

@Test func withoutPermissionFreshnessIsIgnoredEntirely() {
    // Tier 3 with no Accessibility is not a fallback, it is the whole feature: ⌥⇧S has
    // always meant "speak what I copied". Applying freshness here would make the second
    // press on the same text silent — a new bug, not a fix.
    var readings: [TextReading] = []
    for _ in 0..<2 {
        readings.append(SelectionReader.decide(isTrusted: false,
                                               selection: nil,
                                               clipboard: "copied",
                                               clipboardChangeCount: 500,
                                               lastActedClipboardChangeCount: 500))
    }
    #expect(readings.allSatisfy { $0.text == "copied" })
    #expect(readings.allSatisfy { $0.clipboardChangeCountActedOn == nil })
}

@MainActor
@Test func theLaunchBaselineIsTheClipboardsCurrentChangeCount() {
    // `main.swift` calls this before the first press is possible. It has to record the
    // count the clipboard *already* has, because that is what makes a clipboard filled
    // before launch read as unchanged — the guarantee the previous test assumes.
    let pasteboard = NSPasteboard(name: .init("moxspeak.tests.baseline"))
    pasteboard.clearContents()
    pasteboard.setString("here before MoxSpeak was", forType: .string)

    let recorded = SelectionReader.recordClipboardBaseline(pasteboard)
    #expect(recorded == pasteboard.changeCount)
    #expect(SelectionReader.lastActedClipboardChangeCount == pasteboard.changeCount)
    #expect(ClipboardFreshness.isFresh(changeCount: pasteboard.changeCount,
                                       lastActedOn: SelectionReader.lastActedClipboardChangeCount)
            == false)

    // And a write after the baseline is fresh, on the real API rather than an invented
    // integer — `changeCount` genuinely moving is the assumption the whole rule rests on.
    pasteboard.clearContents()
    pasteboard.setString("copied just now", forType: .string)
    #expect(ClipboardFreshness.isFresh(changeCount: pasteboard.changeCount,
                                       lastActedOn: SelectionReader.lastActedClipboardChangeCount)
            == true)
}

// MARK: - What the freshness branches say out loud

@Test func theDeclineNeverClaimsTheClipboardHoldsSomethingElse() {
    // The exact sentence that made the bug report confusing: "Did not speak the clipboard,
    // which holds something else." It was an assertion about content nothing had compared,
    // and in the owner's case it was flatly untrue — the clipboard held precisely what he
    // wanted spoken. What is actually known is that the clipboard has not moved, and that
    // is all the line may say.
    var mark: Int? = 500
    let reading = press(clipboard: "the very thing he wanted", changeCount: 500, mark: &mark)
    #expect(!reading.reason.contains("holds something else"))
    #expect(reading.reason.contains("has not changed"))
}

@Test func theTwoFreshnessOutcomesAreToldApartInTheLog() {
    // A press that spoke a fresh clipboard and a press that declined a stale one both
    // start from "nothing is selected". If the log stopped there, the one case that has
    // now been wrong twice would be invisible in the file that exists to explain it.
    var spokeMark: Int? = 500
    var declinedMark: Int? = 500
    let spoke = press(clipboard: "fresh", changeCount: 501, mark: &spokeMark)
    let declined = press(clipboard: "stale", changeCount: 500, mark: &declinedMark)

    #expect(spoke.reason != declined.reason)
    #expect(spoke.reason.contains("has been written since"))
    #expect(declined.reason.contains("has not changed since"))
    // Both still name the fact they share, so neither reads as a different failure.
    #expect(spoke.reason.contains("nothing is selected"))
    #expect(declined.reason.contains("nothing is selected"))
}

@Test func theDeclinedWordingTellsTheUserBothHalvesOfWhyNothingHappened() {
    // "Nothing is selected" was the whole message when the clipboard was refused outright.
    // Now that a freshly copied clipboard *is* spoken, reaching this line means two things
    // are true at once — nothing selected, and nothing newly copied — and the user can act
    // on either one.
    var mark: Int? = 500
    let reading = press(clipboard: "stale", changeCount: 500, mark: &mark)
    #expect(reading.note.contains("nothing is selected"))
    #expect(reading.note.contains("nothing new has been copied"))
    #expect(reading.flash == "Nothing selected")
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

// MARK: - Naming the frontmost app in the log

// The bug report that started this: "source=copy (tier 2) — nothing selected" is true of
// every app on the machine at once. Without the frontmost app's name and bundle
// identifier on the line, an ambiguous report cannot be turned into a reproduction —
// which is exactly what happened with the iTerm2 report this exists to make unnecessary.

@Test func theFrontmostAppIsNamedByNameAndBundleID() {
    let label = AppController.describeFrontmost(name: "iTerm2",
                                                 bundleID: "com.googlecode.iterm2")
    #expect(label == "iTerm2 (com.googlecode.iterm2)")
}

@Test func aMissingNameOrBundleIDStillProducesAWordedLabelRatherThanACrashOrBlank() {
    // `NSRunningApplication.localizedName` and `.bundleIdentifier` are both optional —
    // seen in the wild for some system processes — and the log line must stay readable
    // rather than embedding a blank or a literal "nil".
    let noName = AppController.describeFrontmost(name: nil, bundleID: "com.example.app")
    let noBundleID = AppController.describeFrontmost(name: "Some App", bundleID: nil)
    let neither = AppController.describeFrontmost(name: nil, bundleID: nil)
    #expect(!noName.isEmpty && !noName.contains("nil"))
    #expect(!noBundleID.isEmpty && !noBundleID.contains("nil"))
    #expect(!neither.isEmpty && !neither.contains("nil"))
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
