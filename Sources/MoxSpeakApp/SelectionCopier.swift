import AppKit
import ApplicationServices

/// What asking the focused app to copy actually produced.
///
/// The case that earns this whole file is `nothingSelected`. Every other way of reading a
/// selection can only answer "here are some words" or "no words for you", and those two
/// answers hide the distinction that matters: *did the user select something we failed to
/// read, or did they select nothing at all?* A copy that leaves `changeCount` untouched
/// answers it outright — the app was asked to copy and had nothing to give.
enum CopyOutcome: Equatable {

    /// Tier 2 was not reached: the Accessibility read already had the text, or there is
    /// no Accessibility permission to post keystrokes with.
    case notAttempted

    /// The pasteboard changed. The payload is the text of it, or nil when what landed
    /// was not text (an image, a file, a custom flavour).
    case copied(String?)

    /// The pasteboard did not change inside the timeout — or it changed to nothing at
    /// all, which is an app copying an empty selection. Either way, nothing is selected.
    case nothingSelected

    /// Neither way of asking could be delivered. Distinct from `nothingSelected`, because
    /// it says nothing about what the user had selected.
    case failed(String)
}

/// Tier 2: ask the focused application to copy, read what landed, and put back what was
/// there before.
///
/// **Why this exists, given that the design used to forbid it.** The original reasoning
/// was that synthesizing ⌘C costs the user their clipboard and buys nothing an
/// Accessibility read does not already provide. The first half is true and the second
/// turned out to be false. Accessibility coverage is not something effort converges on:
/// Chromium and Electron build their accessibility tree lazily, `AXManualAccessibility`
/// cannot be set from outside the process at all, and the mature tools in this category
/// long ago stopped trying to coax more out of AX and simply fall through to a copy. Copy
/// works at the level of "whatever this app thinks copying means", which is the only
/// definition that generalises.
///
/// **Two ways to ask, in order of reliability.** Pressing the app's own Edit ▸ Copy menu
/// item through Accessibility is tried first: it is a direct request to the app rather
/// than an event that anything in the chain might swallow, and a *disabled* Copy item is
/// itself a hint worth not stepping on. A synthetic ⌘C follows when there is no such item,
/// it will not respond, or it produced nothing.
///
/// **Note where this sits.** Tier 2 is *inside* the Accessibility-granted tier, not an
/// alternative to it: both pressing another app's menu item and posting synthetic
/// keystrokes need exactly the permission the AX read needs. It can never be the
/// no-permission fallback.
///
/// **What cannot be restored faithfully.** The snapshot copies the concrete bytes of
/// every representation of every item. Two things do not survive that:
///
/// - *File promises* (`com.apple.pasteboard.promised-file-*`). These are a contract with
///   the originating app to produce a file on request, not data; copying the promise's
///   bytes copies a placeholder, and the app that would have honoured it is no longer
///   being asked.
/// - *Lazy representations* an owner registered without data. Asking for their bytes here
///   forces the owner to produce them now, which is usually harmless and occasionally a
///   visible delay; a representation whose owner has since gone away produces nothing and
///   is dropped.
///
/// In practice text, RTF, HTML, images and file URLs all come back exactly as they were,
/// and a drag-promise from an app like Mail does not. That is a real cost, documented
/// rather than hidden.
///
/// **Credit.** The timings, the "effectively empty" test and the three-way restore rule
/// below were learned from SelectedTextKit (MIT, © 2024 tisfeng),
/// <https://github.com/tisfeng/SelectedTextKit> — specifically `PasteboardManager.swift`
/// and `NSPasteboard+Extension.swift`. No code is copied; it is a good reference
/// implementation and these are the details that only production use teaches. It is not a
/// dependency on purpose: the 500 lines worth having would arrive with three repositories,
/// one of them a one-person fork of Apple's C API.
@MainActor
enum SelectionCopier {

    /// How long to wait for the app to answer, and how often to look while waiting.
    ///
    /// 5 ms and 200 ms are the numbers two independent production tools converged on, and
    /// they are not arbitrary: the poll has to be fine enough that the common case pays
    /// single-digit milliseconds, and the timeout short enough that a user with nothing
    /// selected does not think the hotkey is broken.
    private static let pollInterval: Duration = .milliseconds(5)
    private static let timeout: Duration = .milliseconds(200)

    /// Safari, and only Safari, needs twice that. Its copy path is measurably slower, and
    /// this is the single per-app exception in the file — deliberately, because a growing
    /// table of bundle-identifier quirks goes stale faster than the browser internals it
    /// tracks. Anything else that turns out to need special handling should earn it with
    /// an observed failure, not a guess.
    private static let slowTimeout: Duration = .milliseconds(400)
    private static let slowBundleID = "com.apple.Safari"

    /// `kVK_ANSI_C`. Spelled out rather than imported: the Carbon constant lives in a
    /// header this target does not otherwise need.
    private static let keyC: CGKeyCode = 8

    /// The nspasteboard.org convention for "this write is scaffolding, do not record it".
    /// See `restore`.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Copy whatever is selected in the focused app, then undo the damage.
    static func copySelection(pasteboard: NSPasteboard = .general) async -> CopyOutcome {
        // Snapshot first, because it is the slow part — reading every representation of
        // every item can force a lazy owner to produce data. The `changeCount` baseline
        // is then taken as late as possible, immediately before each attempt, so the
        // window in which a clipboard manager could write between baseline and copy is as
        // small as it can be made.
        let saved = snapshot(pasteboard)
        var menuFailure: String?

        if let copyItem = editCopyMenuItem() {
            let before = pasteboard.changeCount
            if AXUIElementPerformAction(copyItem, kAXPressAction as CFString) == .success {
                if let after = await waitForChange(pasteboard, from: before) {
                    return settle(pasteboard, saved: saved, before: before, after: after,
                                  how: "the app's own Edit ▸ Copy")
                }
            } else {
                menuFailure = "the app's Edit ▸ Copy item would not respond"
            }
        }

        let before = pasteboard.changeCount
        guard postCommandC() else {
            return .failed(menuFailure ?? "macOS refused to post the copy keystroke")
        }
        guard let after = await waitForChange(pasteboard, from: before) else {
            // Neither the menu item nor the keystroke moved the pasteboard. Nothing was
            // copied, so nothing was clobbered, so there is nothing to put back — and
            // restoring anyway would bump `changeCount` for no reason and make the user's
            // clipboard look newer than it is.
            return .nothingSelected
        }
        return settle(pasteboard, saved: saved, before: before, after: after,
                      how: "a synthetic ⌘C")
    }

    // MARK: - Deciding what just happened

    /// Three outcomes, not two, because "the pasteboard changed" is not one event.
    ///
    /// Restoring blindly on any change would clobber a legitimate concurrent write by
    /// something else — a screenshot tool, the user's own ⌘C. Declining to restore on any
    /// unexpected change would leave the user's clipboard *wiped* in the case where the
    /// app answered an empty selection by clearing the pasteboard, which is a worse
    /// outcome than either.
    private static func settle(_ pasteboard: NSPasteboard,
                               saved: [NSPasteboardItem],
                               before: Int,
                               after: Int,
                               how: String) -> CopyOutcome {
        if isEffectivelyEmpty(pasteboard) {
            // The app copied an empty selection and emptied the pasteboard doing it.
            // Restoring is not optional here: not restoring leaves the user with nothing.
            restore(saved, to: pasteboard)
            AppLog.write("copy: \(how) emptied the clipboard — nothing was selected, "
                         + "and the previous clipboard was put back")
            return .nothingSelected
        }

        let text = pasteboard.string(forType: .string)
        AppLog.write("copy: \(how) produced \(text?.count ?? 0) characters")

        // The test is "has anything changed *since* the copy we observed", not "did the
        // count go up by exactly one". A single copy can bump `changeCount` more than
        // once in some apps, so counting increments would refuse to restore after a
        // perfectly ordinary copy. What must not be overwritten is a write that landed
        // *after* ours — a screenshot tool, the user's own ⌘C — because that is newer
        // than the snapshot and the user meant it.
        if pasteboard.changeCount == after {
            restore(saved, to: pasteboard)
        } else {
            AppLog.write("copy: the clipboard changed again after the copy — something "
                         + "else wrote to it, so it was left alone rather than restored "
                         + "over (count \(before) → \(after) → \(pasteboard.changeCount))")
        }
        return .copied(nonBlank(text))
    }

    /// No types at all, or a single empty string and nothing else.
    ///
    /// Kept narrow on purpose. A looser test — "every representation is zero bytes" —
    /// would call an exotic but legitimate clipboard empty and report "nothing selected"
    /// when something plainly was.
    private static func isEffectivelyEmpty(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types, !types.isEmpty else { return true }
        guard types.count == 1, types.contains(.string) else { return false }
        return (pasteboard.string(forType: .string) ?? "").isEmpty
    }

    private static func waitForChange(_ pasteboard: NSPasteboard, from before: Int) async -> Int? {
        let budget = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == slowBundleID
            ? slowTimeout : timeout
        let deadline = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            let now = pasteboard.changeCount
            if now != before { return now }
        }
        return nil
    }

    // MARK: - Asking the app to copy

    /// Posts ⌘C, with the user's real modifiers held out of it.
    ///
    /// The subtlety: this runs off a global hotkey, so that hotkey's modifiers — ⌃ and
    /// ⌥ by default — are very likely still physically down when it fires. An event that
    /// inherited them would arrive as ⌃⌥⌘C, which is not "copy" in any app and is a real
    /// shortcut in some. A
    /// `.privateState` event source carries its own modifier state rather than the
    /// hardware's, so declaring `.maskCommand` on the event means ⌘ and nothing else.
    ///
    /// Not done here, deliberately: muting the system alert volume around the keystroke to
    /// swallow the beep some apps make when ⌘C finds nothing. It works, and two other
    /// tools do it — but it means writing a system-wide audio setting from a hotkey path,
    /// and a process that dies in the middle of that leaves the user's Mac silent with no
    /// clue why. An occasional beep is the smaller harm.
    private static func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// The focused app's own Copy menu item, if it has one and it is enabled.
    ///
    /// Found by shortcut rather than by title: "Edit" is "Bearbeiten" in German and
    /// "编辑" in Chinese, but a menu item whose command-key equivalent is plain ⌘C is
    /// Copy in every localisation there is. The English title is still used as a hint for
    /// which menu to look in first, because enumerating a menu makes the app build it and
    /// there is no reason to make it build all of them.
    ///
    /// A *disabled* Copy item is left alone rather than treated as proof that nothing is
    /// selected: apps are inconsistent about keeping that state current, and the
    /// keystroke below is a cheap second opinion.
    private static func editCopyMenuItem() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let bar = child(of: app, kAXMenuBarAttribute as String) else { return nil }

        let menus = children(of: bar)
        let ordered = menus.filter { title(of: $0) == "Edit" } + menus.filter { title(of: $0) != "Edit" }

        // Hard deadline: this is a hotkey path, and an app that answers slowly must cost
        // a fraction of a second, not the user's patience.
        let deadline = Date().addingTimeInterval(0.15)
        for menu in ordered {
            guard Date() < deadline else { return nil }
            guard let dropdown = children(of: menu).first else { continue }
            for item in children(of: dropdown) {
                guard let key = string(of: item, "AXMenuItemCmdChar"),
                      key.lowercased() == "c",
                      number(of: item, "AXMenuItemCmdModifiers") == 0,
                      bool(of: item, kAXEnabledAttribute as String) == true else { continue }
                return item
            }
        }
        return nil
    }

    // MARK: - Save and restore

    /// Every item, every type, as concrete bytes.
    ///
    /// `writeObjects` on the way back takes `NSPasteboardItem`s, and an item may only be
    /// written to one pasteboard once — so these are fresh items holding copied data, not
    /// the originals.
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var carried = false
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                copy.setData(data, forType: type)
                carried = true
            }
            // An item with no representations cannot be written back and would make
            // `writeObjects` fail for the whole array, taking the restorable items with
            // it. Dropping it is the lesser loss.
            return carried ? copy : nil
        }
    }

    /// Puts the snapshot back, marked as scaffolding.
    ///
    /// The `org.nspasteboard.TransientType` marker is the documented convention for "this
    /// write is not a thing the user did; do not record it". Without it, every tier 2 read
    /// leaves a *duplicate* of the user's own clipboard entry in whatever clipboard
    /// manager they run. It is a convention, not a guarantee — a manager that ignores it
    /// sees the duplicate anyway — and it cannot cover the copy itself, which is written
    /// by the focused app and is out of our hands. It is still strictly better than the
    /// prior art, which marks nothing at all.
    /// Note that an *empty* snapshot still clears: the user had an empty clipboard before
    /// tier 2 ran, and leaving the copied selection sitting on it would be exactly the
    /// clobbering this method exists to undo.
    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard let first = items.first else { return }
        first.setData(Data([1]), forType: transientType)
        pasteboard.writeObjects(items)
    }

    /// Whitespace is not speech.
    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - Small Accessibility conveniences

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success
        else { return nil }
        return out
    }

    private static func child(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let out = value(of: element, attribute),
              CFGetTypeID(out) == AXUIElementGetTypeID() else { return nil }
        return (out as! AXUIElement)  // guarded by the type check above
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(of: element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    private static func title(of element: AXUIElement) -> String {
        value(of: element, kAXTitleAttribute as String) as? String ?? ""
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        value(of: element, attribute) as? String
    }

    private static func number(of element: AXUIElement, _ attribute: String) -> Int? {
        (value(of: element, attribute) as? NSNumber)?.intValue
    }

    private static func bool(of element: AXUIElement, _ attribute: String) -> Bool? {
        (value(of: element, attribute) as? NSNumber)?.boolValue
    }
}
