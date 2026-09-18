import AppKit
import ApplicationServices

/// What the Accessibility read learned about the user's selection, beyond the words.
///
/// Kept even though tier 2 now settles the question outright, because it is what decides
/// whether tier 2 runs at all — and because "the app reported a selection it would not
/// spell out" is worth saying in the log when the copy that follows comes back empty.
enum SelectionEvidence: String, Sendable {

    /// Nothing anywhere said the user had text selected.
    case none

    /// The focused app reported a selection but handed back no readable words: an empty
    /// string where characters were expected, or characters that are all placeholders for
    /// non-text content.
    case unreadable
}

/// Where the text about to be spoken came from, and why.
///
/// Carried as a value rather than reported as a side effect because the caller needs all
/// of it at once: the text to speak, the sentence to log, and the wording to put on
/// screen when there was nothing to speak at all.
struct TextReading {

    /// Named for the user's mental model, not the API, and numbered for the log.
    ///
    /// One shortcut, three tiers, and the user is never asked which one they want:
    ///
    /// 1. `selection` — Accessibility read the words straight out of the focused app.
    ///    Instant, and the clipboard is never touched.
    /// 2. `copy` — Accessibility found nothing, so the app was asked to copy and the
    ///    pasteboard was put back afterwards. Slower by a few tens of milliseconds, and
    ///    it reaches apps no amount of attribute-walking ever will.
    /// 3. `clipboard` — read what was copied, exactly as MoxSpeak has always done with no
    ///    permissions. Reached two ways: with no Accessibility permission at all, where it
    ///    is the only thing there is to read; and *with* the permission, when tiers 1 and 2
    ///    agree nothing is selected but the user has just filled the clipboard — see
    ///    `ClipboardFreshness`. Both are "the text came off the clipboard", which is what
    ///    this case is for saying.
    enum Source: String {
        case selection
        case copy
        case clipboard

        /// The tier number, for the log. The user cannot choose a tier, so the only way
        /// to find out which one ran is to write it down.
        var tier: Int {
            switch self {
            case .selection: 1
            case .copy: 2
            case .clipboard: 3
            }
        }
    }

    /// The text. Nil when there was nothing to speak.
    let text: String?
    let source: Source

    /// Why this source and not another, in a sentence, for the log.
    let reason: String

    /// Whether Accessibility was granted at the moment of this read. Re-read every time;
    /// never cached.
    let isTrusted: Bool

    /// What to flash beside the menu bar icon when `text` is nil.
    let flash: String

    /// The same thing at slightly greater length, for the menu's status line and the log.
    let note: String

    /// The pasteboard `changeCount` this press *acted on* — spoke aloud, or looked at and
    /// declined — or nil when the clipboard was never consulted at all.
    ///
    /// This is the half of the freshness rule that cannot be a pure function of the
    /// inputs: deciding is one thing, remembering what was decided is another, and the
    /// caller is the only part of this that outlives a single press. Carrying it here
    /// rather than reporting it as a side effect keeps the whole rule inside `decide`,
    /// where it can be replayed press-by-press in a test.
    ///
    /// Nil on tiers 1 and 2's successes by construction: a press that read the selection
    /// never looked at the clipboard, so it has no business moving the mark that says
    /// when the clipboard was last looked at.
    let clipboardChangeCountActedOn: Int?

    init(text: String?,
         source: Source,
         reason: String,
         isTrusted: Bool,
         flash: String,
         note: String,
         clipboardChangeCountActedOn: Int? = nil) {
        self.text = text
        self.source = source
        self.reason = reason
        self.isTrusted = isTrusted
        self.flash = flash
        self.note = note
        self.clipboardChangeCountActedOn = clipboardChangeCountActedOn
    }
}

/// Whether the clipboard holds something the user has *just put there*.
///
/// The distinction this draws is the one the original "never speak a stale clipboard" rule
/// was missing. That rule was written against a real failure — text copied twenty minutes
/// ago, spoken with total confidence when nothing was selected — and it fixed it by
/// refusing the clipboard outright whenever the selection read came back empty. But
/// "nothing is selected" and "the user just copied something" are not mutually exclusive:
/// in a full-screen TUI that swallows mouse selection, copy-then-press is the *only*
/// workflow there is, and it is how MoxSpeak worked before Accessibility existed. Refusing
/// both cases with one rule broke the second to fix the first.
///
/// `NSPasteboard.changeCount` is the signal that tells them apart. It increments on every
/// write by anyone, so remembering the count MoxSpeak last acted on turns "is this stale?"
/// into a question with an answer rather than a guess:
///
/// - Copied two seconds ago: the count has moved since we last acted → fresh → speak it.
/// - Untouched since the last press: the count is exactly where we left it → not fresh →
///   stay silent, which is the original bug staying fixed.
///
/// Acting on a clipboard — speaking it *or* declining it — updates the mark, so each
/// distinct copy gets exactly one chance to be spoken and a second press on the same copy
/// is silent. And the mark is set at launch (`SelectionReader.recordClipboardBaseline`),
/// so the first press of a session does not mistake a long-dead clipboard for a fresh one.
enum ClipboardFreshness {

    /// Whether `changeCount` represents a write that landed after we last acted.
    ///
    /// A nil mark means MoxSpeak has never acted on the clipboard *and* never recorded a
    /// launch baseline. That should not happen — the baseline is recorded at launch — and
    /// the conservative answer is the one that cannot be confidently wrong: not fresh.
    /// Inventing freshness from the absence of a record is how the original bug worked.
    static func isFresh(changeCount: Int, lastActedOn mark: Int?) -> Bool {
        guard let mark else { return false }
        return changeCount != mark
    }
}

/// Reads what the user wants spoken.
///
/// The shape of this file is set by two rules.
///
/// **Accessibility is optional and must stay optional.** MoxSpeak's whole pitch is that
/// it asks for nothing, so:
///
/// - `read` calls `AXIsProcessTrusted()`, which never prompts, and touches no other
///   Accessibility API unless that returns true. An untrusted launch makes no AX calls at
///   all beyond that one query, and posts no keystrokes: tier 2 needs exactly the
///   permission tier 1 needs, so it lives inside the granted branch and can never be the
///   no-permission fallback.
/// - `requestPermission()` — the only call here that can raise a system dialog — is
///   reachable solely from a menu item the user clicked. Nothing on the launch path or
///   the hotkey path goes near it.
/// - With the permission absent the clipboard is read and spoken exactly as it always
///   was. That is tier 3, it is the zero-permission default, and none of the caution
///   below applies to it.
///
/// **A granted permission must not make the app confidently wrong.** With Accessibility
/// on, the speak shortcut means "read what I selected". The old code fell back to the
/// clipboard whenever
/// the selection read came back empty, which produced the worst failure this project has:
/// text the user copied twenty minutes ago, spoken with complete confidence, with nothing
/// on screen to say why. The fix is not a better guess, it is a real answer — tier 2 asks
/// the app to copy, and a pasteboard that does not change is the app saying *nothing was
/// selected*. That case says so out loud and speaks nothing.
///
/// **…but "stale" and "just copied" are different things.** The first version of that rule
/// refused the clipboard in *both* cases, which broke copy-then-press — the way this app
/// worked before Accessibility existed, and the only way it can work in a full-screen TUI
/// that eats mouse selection. `ClipboardFreshness` is the missing distinction: when
/// nothing is selected, a clipboard written since MoxSpeak last acted on it is spoken, and
/// one sitting untouched since the last press is not. Each copy gets one chance.
enum SelectionReader {

    /// Whether macOS currently trusts this process for Accessibility.
    ///
    /// `AXIsProcessTrusted()` asks; it does not prompt. That distinction is the whole
    /// reason this app can display the permission's state without ever demanding it.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The option key for `AXIsProcessTrustedWithOptions`, spelled out.
    ///
    /// The SDK exposes `kAXTrustedCheckOptionPrompt` as a mutable global, which Swift 6
    /// strict concurrency rejects outright — a `var` anyone could write to is shared
    /// mutable state whatever Apple's intentions were. The constant's value is this
    /// string and has been since 10.9; naming it here is not a workaround so much as
    /// declining to launder a compile error through `nonisolated(unsafe)`.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    /// Raises the system Accessibility dialog. User-initiated only.
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([promptOptionKey: true] as CFDictionary)
    }

    /// The pasteboard `changeCount` MoxSpeak last spoke or last declined.
    ///
    /// The only mutable state in this file, and it is one integer. Main-actor isolated
    /// because the only things that touch it are the hotkey path and launch, both of
    /// which are already there — no locking, and Swift 6 has nothing to complain about.
    ///
    /// Nil means "never recorded", which `ClipboardFreshness` reads as *not* fresh. That
    /// is unreachable in the real app (launch records a baseline before the first press
    /// is possible) and is the safe answer if it ever became reachable.
    @MainActor private(set) static var lastActedClipboardChangeCount: Int?

    /// Take the launch baseline, so the first press of a session does not mistake a
    /// clipboard filled yesterday for one filled just now.
    ///
    /// Called from `applicationDidFinishLaunching`. It costs one cheap property read and
    /// touches no Accessibility API, so it is safe on the untrusted path too — a user who
    /// never grants the permission simply never consults the value.
    ///
    /// Returns the count it recorded, and writes nothing to the log itself. The log line
    /// belongs at the launch site: this function is also what a test calls, and a test
    /// that appends to `~/Library/Logs/MoxSpeak.log` is putting invented events into the
    /// one file the owner reads to find out what really happened.
    @MainActor
    @discardableResult
    static func recordClipboardBaseline(_ pasteboard: NSPasteboard = .general) -> Int {
        let count = pasteboard.changeCount
        lastActedClipboardChangeCount = count
        return count
    }

    /// The three tiers, in order, with the first one that answers winning.
    ///
    /// `async` because tier 2 has to wait for another process to service a keystroke.
    /// The wait is bounded and usually a few milliseconds; see `SelectionCopier`.
    @MainActor
    static func read(pasteboard: NSPasteboard = .general) async -> TextReading {
        let trusted = isTrusted
        guard trusted else {
            return decide(isTrusted: false,
                          selection: nil,
                          evidence: .none,
                          copied: .notAttempted,
                          clipboard: clipboardText(pasteboard))
        }

        let selection = readSelection()
        if selection.text != nil {
            return decide(isTrusted: true,
                          selection: selection.text,
                          evidence: selection.evidence,
                          copied: .notAttempted,
                          clipboard: nil)
        }

        // Both of these are read *before* tier 2 runs, and that ordering is load-bearing.
        // A copy moves `changeCount` by definition, and the restore that follows an
        // emptied pasteboard moves it again — so a count read afterwards would look
        // freshly written on every single press and the rule below would degenerate into
        // "always speak the clipboard", which is the bug it exists to prevent. What
        // freshness is a question about is the clipboard the user had in hand when they
        // pressed the key, so that is the one measured.
        let clipboard = clipboardText(pasteboard)
        let changeCount = pasteboard.changeCount

        let copied = await SelectionCopier.copySelection(pasteboard: pasteboard)
        let reading = decide(isTrusted: true,
                             selection: nil,
                             evidence: selection.evidence,
                             copied: copied,
                             clipboard: clipboard,
                             clipboardChangeCount: changeCount,
                             lastActedClipboardChangeCount: lastActedClipboardChangeCount)

        // Spoken or declined, this copy has had its turn.
        if let acted = reading.clipboardChangeCountActedOn {
            lastActedClipboardChangeCount = acted
        }
        return reading
    }

    /// The decision itself, with the world passed in.
    ///
    /// Split out because every case worth arguing about — permission granted and the app
    /// refuses to say what is selected, permission granted and *nothing* is selected —
    /// is unreachable on a machine where the permission has never been granted. Keeping
    /// the rule pure means it is verifiable anywhere; only the readers around it need a
    /// real Mac to exercise.
    ///
    /// `clipboardChangeCount` and `lastActedClipboardChangeCount` are the freshness
    /// question, and they are consulted in exactly one branch — tier 2 answering
    /// "nothing is selected". Their defaults mean "no freshness information", which
    /// `ClipboardFreshness` reads as not fresh: a caller that does not know cannot be
    /// talked into speaking a clipboard.
    static func decide(isTrusted: Bool,
                       selection: String?,
                       evidence: SelectionEvidence = .none,
                       copied: CopyOutcome = .notAttempted,
                       clipboard: String?,
                       clipboardChangeCount: Int = 0,
                       lastActedClipboardChangeCount: Int? = nil) -> TextReading {

        // MARK: Tier 3 — no permission.
        guard isTrusted else {
            // `selection` and `copied` are ignored here by construction — `read` fetches
            // neither without permission, because both need it — and the assertion is
            // worth keeping honest in tests.
            //
            // Freshness is ignored too, and deliberately. With no permission the
            // clipboard is not a fallback, it is the entire feature: the shortcut means "speak
            // what I copied" and always has. Applying the freshness rule here would make
            // the second press on the same text silent, which would be a new bug rather
            // than a fix. Nothing is recorded either, for the same reason — there is no
            // mark to keep when nothing is ever declined.
            return TextReading(text: clipboard,
                               source: .clipboard,
                               reason: "select-to-speak is off "
                                     + "(no Accessibility permission, none requested) — "
                                     + "read the clipboard",
                               isTrusted: false,
                               flash: "Clipboard is empty",
                               note: "the clipboard holds no text")
        }

        // MARK: Tier 1 — Accessibility had the words.
        if let selection {
            return TextReading(text: selection,
                               source: .selection,
                               reason: "read the selection from the focused element "
                                     + "(the clipboard was not touched)",
                               isTrusted: true,
                               flash: "Nothing selected",
                               note: "nothing is selected")
        }

        // MARK: Tier 2 — Accessibility had nothing, so the app was asked to copy.
        let sawSelection = evidence == .unreadable
        let axNote = sawSelection
            ? "the focused element reported a selection it would not spell out"
            : "the focused element reported no selected text"

        switch copied {
        case .copied(let text?):
            return TextReading(text: text,
                               source: .copy,
                               reason: "\(axNote) — copied the selection instead "
                                     + "and put the clipboard back",
                               isTrusted: true,
                               flash: "Nothing selected",
                               note: "nothing is selected")

        case .copied(nil):
            return TextReading(text: nil,
                               source: .copy,
                               reason: "\(axNote) — the copy produced something that is "
                                     + "not text, so there was nothing to say",
                               isTrusted: true,
                               flash: "Selection isn't text",
                               note: "what is selected is not text — an image or a file, "
                                   + "not something that can be read aloud")

        case .nothingSelected:
            // The whole point of tier 2. An app asked to copy that copies nothing has
            // told us, definitively, that there is no selection.
            //
            // What that does *not* tell us is whether the clipboard is stale. Only
            // `changeCount` knows, so this is the one branch that asks — and whichever
            // way it answers, this copy has now had its turn and the mark moves.
            let settled = "\(axNote), and asking the app to copy changed nothing — "
                        + "so nothing is selected"
            let fresh = ClipboardFreshness.isFresh(changeCount: clipboardChangeCount,
                                                   lastActedOn: lastActedClipboardChangeCount)

            if fresh, let clipboard {
                // The owner's workflow: copy in a terminal that forwards its own
                // selection, then press. Nothing is selected because the TUI owns the
                // mouse, and the thing he wants spoken is sitting on the clipboard where
                // he put it two seconds ago.
                return TextReading(text: clipboard,
                                   source: .clipboard,
                                   reason: "\(settled). The clipboard has been written "
                                         + "since MoxSpeak last acted on it (change count "
                                         + "\(clipboardChangeCount)), so it holds something "
                                         + "freshly copied — spoke that",
                                   isTrusted: true,
                                   flash: "Nothing selected",
                                   note: "nothing is selected",
                                   clipboardChangeCountActedOn: clipboardChangeCount)
            }

            if fresh {
                // Written since we last looked, but there are no words on it — an image,
                // a file, a cleared clipboard. Worth distinguishing from "unchanged",
                // because the reason it went unspoken is a different reason.
                return TextReading(text: nil,
                                   source: .copy,
                                   reason: "\(settled), and the clipboard has been "
                                         + "written since MoxSpeak last acted on it but "
                                         + "holds no text to speak",
                                   isTrusted: true,
                                   flash: "Nothing selected",
                                   note: "nothing selected, and the clipboard is empty",
                                   clipboardChangeCountActedOn: clipboardChangeCount)
            }

            // Nothing selected, and nothing copied since the last time we looked. This is
            // the original bug's case and it stays silent. Note what this line does *not*
            // claim: the previous wording said the clipboard "holds something else",
            // which was an assertion about content we had never compared — and in the
            // owner's case it was flatly untrue. All we know, and all we say, is that the
            // clipboard has not moved.
            return TextReading(text: nil,
                               source: .copy,
                               reason: "\(settled), and the clipboard has not changed "
                                     + "since MoxSpeak last looked at it (change count "
                                     + "\(clipboardChangeCount)) — so there was nothing "
                                     + "freshly copied to speak either",
                               isTrusted: true,
                               flash: "Nothing selected",
                               note: "nothing selected or copied",
                               clipboardChangeCountActedOn: clipboardChangeCount)

        case .failed(let why):
            return TextReading(text: nil,
                               source: .copy,
                               reason: "\(axNote), and the copy could not be sent — \(why)",
                               isTrusted: true,
                               flash: "Couldn't read the selection",
                               note: "macOS would not let MoxSpeak ask the focused app "
                                   + "to copy — \(why)")

        case .notAttempted:
            // Only reachable from `decide` called directly, never from `read`: with the
            // permission granted and no selection, tier 2 always runs.
            return TextReading(text: nil,
                               source: .selection,
                               reason: "\(axNote), and no copy was attempted",
                               isTrusted: true,
                               flash: "Nothing selected",
                               note: "nothing is selected")
        }
    }

    // MARK: - The selection

    /// How long the whole Accessibility read may take, end to end.
    ///
    /// This runs on the hotkey press, on the main actor, with the user waiting. An app
    /// that is wedged or swapped out can take seconds to answer an AX query, and several
    /// of those in a row would be indistinguishable from MoxSpeak having crashed. Every
    /// loop below checks the deadline; whatever has been found by then is the answer.
    private static let budget: TimeInterval = 0.4

    /// Per-message timeout handed to each element we talk to, so one slow reply cannot
    /// eat the entire budget by itself.
    private static let messagingTimeout: Float = 0.25

    /// How far up the ancestor chain to look. Eight is comfortably past the deepest
    /// case measured — Chrome answers at the third ancestor of a markdown heading — and
    /// short enough that the walk costs a handful of IPC round trips, not hundreds.
    private static let ancestorLimit = 8

    /// The attribute WebKit and Chromium actually expose web selections through.
    ///
    /// Not in the SDK headers: these are AppKit's private-ish text-marker API, which is
    /// nonetheless the documented-by-practice way every screen reader reads a web page.
    /// `AXSelectedText` is simply absent on most web nodes — in Safari it fails on
    /// *every* node, body text included — so a reader that only asks for `AXSelectedText`
    /// cannot read a browser at all.
    private static let selectedMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange"

    /// The focused element's selected text, and what we learned trying to get it.
    ///
    /// Three things had to change from "ask the system-wide element for `AXSelectedText`":
    ///
    /// 1. **More than one way to find the focused element.** The system-wide element's
    ///    `AXFocusedUIElement` is the usual answer but not the only one — it comes back
    ///    `cannotComplete` in some processes — so the focused *application*'s own focused
    ///    element, and the frontmost application's, are tried in turn.
    /// 2. **More than one way to ask for the text.** `AXSelectedText` is unimplemented on
    ///    most web nodes. The marker-range path is how browsers really answer.
    /// 3. **More than one element to ask.** In Chrome, a selected markdown heading focuses
    ///    the `AXHeading` node, which reports no selected text while its third ancestor
    ///    reports it fine. So the walk goes *up*: a bounded climb of the ancestor chain,
    ///    which is a handful of queries, rather than down through a web page's thousands
    ///    of descendants.
    static func readSelection() -> (text: String?, evidence: SelectionEvidence) {
        guard isTrusted else { return (nil, .none) }

        let deadline = Date().addingTimeInterval(budget)
        var evidence = SelectionEvidence.none

        for start in focusedElements() {
            var node: AXUIElement? = start
            var hops = 0
            while let current = node, hops <= ancestorLimit, Date() < deadline {
                AXUIElementSetMessagingTimeout(current, messagingTimeout)
                switch selectedText(of: current) {
                case .text(let text):
                    return (text, .none)
                case .placeholder:
                    // Keep climbing — an ancestor may express the same selection as real
                    // words — but remember that a selection demonstrably exists.
                    evidence = .unreadable
                case .nothing:
                    break
                }
                node = parent(of: current)
                hops += 1
            }
        }

        return (nil, evidence)
    }

    /// The candidate starting points, in order of how often they are right.
    ///
    /// All three are tried because they genuinely differ: an app can have a focused
    /// element the system-wide query will not report, and the system-wide query itself
    /// can fail outright while the same question asked of the application succeeds.
    private static func focusedElements() -> [AXUIElement] {
        var found: [AXUIElement] = []
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        if let focused = element(of: systemWide, kAXFocusedUIElementAttribute as String) {
            found.append(focused)
        }
        if let app = element(of: systemWide, kAXFocusedApplicationAttribute as String),
           let focused = element(of: app, kAXFocusedUIElementAttribute as String) {
            found.append(focused)
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            if let focused = element(of: app, kAXFocusedUIElementAttribute as String) {
                found.append(focused)
            }
        }
        return found
    }

    /// What one element had to say about the selection.
    private enum NodeReading {
        /// Real words. Returned verbatim — cleaning is `TextPreparer`'s job, not this
        /// file's, and doing it in both places is how the two drift apart.
        case text(String)
        /// Characters came back, none of them speakable. Something is selected.
        case placeholder
        /// The element does not answer the question.
        case nothing
    }

    private static func selectedText(of element: AXUIElement) -> NodeReading {
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element,
                                         kAXSelectedTextAttribute as CFString,
                                         &selectedValue) == .success,
           let text = selectedValue as? String {
            if let speakable = speakable(text) { return .text(speakable) }
            if !text.isEmpty { return .placeholder }
        }

        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element,
                                         selectedMarkerRangeAttribute as CFString,
                                         &rangeValue) == .success,
           let rangeValue {
            var stringValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element,
                                                          stringForMarkerRangeAttribute as CFString,
                                                          rangeValue,
                                                          &stringValue) == .success,
               let text = stringValue as? String {
                if let speakable = speakable(text) { return .text(speakable) }
                if !text.isEmpty { return .placeholder }
            }
        }

        // An element that answered "" is not evidence of a selection: browsers hand an
        // empty string back for "no selection here" all day long. Only characters that
        // turned out not to be words count as evidence, so this is `.nothing`.
        return .nothing
    }

    private static func element(of parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)  // guarded by the type check above
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        self.element(of: element, kAXParentAttribute as String)
    }

    // MARK: - The clipboard

    /// The clipboard, if it holds anything worth speaking.
    ///
    /// Internal rather than private because the menu's "Speak Clipboard" item reads it
    /// directly, bypassing the tiers — see `AppController.speakClipboard`.
    static func clipboardText(_ pasteboard: NSPasteboard = .general) -> String? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return speakable(text)
    }

    /// U+FFFC OBJECT REPLACEMENT CHARACTER.
    ///
    /// Web engines put one of these in a selection wherever the selected range covered
    /// something that is not text: an image, a button, or — the case that started this —
    /// the invisible anchor link GitHub wraps every markdown heading in. A string of
    /// nothing but these is a selection we could see and could not read.
    private static let objectReplacement: Character = "\u{FFFC}"

    /// The text if there is anything in it worth speaking, nil otherwise.
    ///
    /// Whitespace is not speech, and neither is a placeholder for an image. Note that the
    /// *original* string is returned, placeholders and all: deciding there is something
    /// here and tidying it up are different jobs, and `TextPreparer` owns the second one.
    private static func speakable(_ text: String) -> String? {
        let words = text.filter { $0 != objectReplacement }
        return words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
