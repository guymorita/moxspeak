import AppKit
import ApplicationServices

/// Where the text about to be spoken came from, and why.
///
/// Carried as a value rather than reported as a side effect because the caller needs all
/// of it at once: the text to speak, the sentence to log, and the wording to put on
/// screen when there was nothing to speak at all.
struct TextReading {

    /// Named for the user's mental model, not the API. `selection` is "what I had
    /// highlighted"; `clipboard` is "what I last copied".
    enum Source: String {
        case selection
        case clipboard
    }

    /// The text, already trimmed and known non-blank. Nil when there was nothing.
    let text: String?
    let source: Source

    /// Why this source and not the other, in a sentence, for the log.
    let reason: String

    /// Whether Accessibility was granted at the moment of this read. Re-read every time;
    /// never cached.
    let isTrusted: Bool

    /// What to flash beside the menu bar icon when `text` is nil.
    var emptyFlash: String {
        isTrusted ? "Nothing selected or copied" : "Clipboard is empty"
    }

    /// The same thing at slightly greater length, for the menu's status line and the log.
    var emptyNote: String {
        isTrusted
            ? "nothing is selected and the clipboard holds no text"
            : "the clipboard holds no text"
    }
}

/// Reads what the user wants spoken — the on-screen selection when macOS permits it, the
/// clipboard otherwise.
///
/// The shape of this file is set by one rule: **Accessibility is optional and must stay
/// optional.** MoxSpeak's whole pitch is that it asks for nothing, so:
///
/// - `read()` calls `AXIsProcessTrusted()`, which never prompts, and touches no other
///   Accessibility API unless that returns true. An untrusted launch makes no AX calls
///   at all beyond that one query.
/// - `requestPermission()` — the only call here that can raise a system dialog — is
///   reachable solely from a menu item the user clicked. Nothing on the launch path or
///   the hotkey path goes near it.
/// - Every failure inside the trusted path falls through to the clipboard. An Electron
///   window or a PDF view that exposes no `AXSelectedText` must degrade to exactly
///   today's behavior, not to silence.
///
/// What is deliberately *not* here: synthesizing ⌘C to force a selection into the
/// clipboard. It buys nothing — it needs the same Accessibility permission this path
/// already has — and it costs the user whatever they had on their clipboard. Trading
/// someone's saved clipboard for a fallback that plain `NSPasteboard` already provides
/// is a bad deal in both directions.
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

    /// The selection if it can be had, the clipboard if it cannot.
    ///
    /// Note the `isTrusted` short-circuit: when the permission is absent, `selectedText()`
    /// is never even called, so the untrusted path touches no Accessibility API beyond
    /// the one query that cannot prompt.
    static func read(pasteboard: NSPasteboard = .general) -> TextReading {
        let trusted = isTrusted
        return decide(isTrusted: trusted,
                      selection: trusted ? selectedText() : nil,
                      clipboard: clipboardText(pasteboard))
    }

    /// The decision itself, with the world passed in.
    ///
    /// Split out because the interesting case — permission granted, app refuses to hand
    /// over a selection, fall back to the clipboard — is the one that cannot be staged on
    /// a machine where the permission has never been granted. Keeping the rule pure means
    /// it is verifiable anywhere; only the two readers need a real Mac to exercise.
    static func decide(isTrusted: Bool, selection: String?, clipboard: String?) -> TextReading {
        guard isTrusted else {
            // `selection` is ignored here by construction — `read` never fetches one
            // without permission — and the assertion is worth keeping honest in tests.
            return TextReading(text: clipboard,
                               source: .clipboard,
                               reason: "select-to-speak is off "
                                     + "(no Accessibility permission, none requested)",
                               isTrusted: false)
        }

        if let selection {
            return TextReading(text: selection,
                               source: .selection,
                               reason: "read from the focused element",
                               isTrusted: true)
        }

        return TextReading(text: clipboard,
                           source: .clipboard,
                           reason: "select-to-speak is on, but the focused element "
                                 + "reported no selected text — fell back to the clipboard",
                           isTrusted: true)
    }

    // MARK: - The two sources

    /// The focused element's selected text, or nil.
    ///
    /// Two hops: system-wide element → whatever currently has focus → that element's
    /// `AXSelectedText`. Any hop can fail perfectly legitimately — nothing focused, an
    /// app that does not implement the attribute, a selection that is an image — and
    /// every one of those is a nil, not an error worth reporting. The caller's fallback
    /// is the report.
    static func selectedText() -> String? {
        guard isTrusted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement  // guarded by the type check above

        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused,
                                            kAXSelectedTextAttribute as CFString,
                                            &selectedValue) == .success,
              let text = selectedValue as? String else { return nil }

        return nonBlank(text)
    }

    private static func clipboardText(_ pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return nonBlank(text)
    }

    /// Whitespace is not speech. A selection of three spaces must read as "nothing
    /// selected" so the clipboard fallback gets its turn.
    private static func nonBlank(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
