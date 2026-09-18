import AppKit
import Carbon.HIToolbox

/// One key-plus-modifiers combination, as Carbon wants it: a virtual key code and a
/// Carbon modifier mask.
///
/// A plain value type, deliberately outside `HotkeyManager`. Everything interesting about
/// a shortcut — whether macOS will actually deliver it, how to write it for a human, how
/// to store it, and what to do about one that was stored before we knew better — is a
/// pure function of these two integers, and none of it needs a registered hotkey, an
/// event handler or a main actor to be true. That is what makes the part of this feature
/// most likely to be wrong the part that is completely testable.
///
/// ## The restriction this type exists to enforce
///
/// Since macOS 15 (Sequoia), the system **refuses to deliver** a hotkey whose modifiers
/// are only Option and/or Shift. It is deliberate anti-key-logging hardening — Shift and
/// Option are how you type alternate characters, so a process that could observe them
/// globally could read passwords — and an Apple Frameworks engineer confirmed it on the
/// Developer Forums (thread 763878, FB15163561, September 2024). Apple's rule, stated
/// plainly: **a hotkey must include at least one modifier that is neither Shift nor
/// Option.**
///
/// The failure is the worst possible shape. `RegisterEventHotKey` returns `noErr`,
/// `InstallEventHandler` returns `noErr`, the registration appears in the log, and the
/// callback is simply never called. Nothing anywhere reports a problem; the key just does
/// nothing, forever. MoxSpeak shipped three hotkeys — ⌥⇧S, ⌥⇧Space, ⌥⇧. — that are all
/// exactly this, which meant its headline feature was dead for every user on macOS 15 or
/// later while its log looked perfectly healthy. See
/// `.superpowers/carbon-hotkeys-macos26.md` for the full research.
///
/// So `rejection` is not a nicety. It is the check that would have caught that defect,
/// and it runs before anything is handed to Carbon — at launch, at migration time, and on
/// every combination the user records in the shortcuts window.
struct Hotkey: Equatable, Hashable, Sendable {

    /// A Carbon virtual key code (`kVK_ANSI_S` and friends). 0...127.
    let keyCode: UInt32

    /// Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), already
    /// masked to those four.
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        // Masked on the way in, so two `Hotkey`s that mean the same combination are ==
        // and hash alike regardless of what junk (alphaLock, a future version's bits, an
        // NSEvent flag that leaked through) came with them.
        self.modifiers = modifiers & Hotkey.allModifiers
    }

    // MARK: - Modifier bits

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    /// The four this app recognises. Anything else in a mask is dropped.
    static let allModifiers = command | shift | option | control

    /// The two macOS will not deliver a hotkey for on their own.
    static let weakModifiers = option | shift

    /// At least one of these has to be present, or the system silently swallows the key.
    static let strongModifiers = command | control

    // MARK: - Validation

    /// Why macOS could not deliver this combination.
    enum Rejection: Equatable, Sendable, CustomStringConvertible {
        /// No modifiers at all. A bare key would be a keylogger with extra steps, and the
        /// system treats it the same way it treats Option/Shift-only.
        case noModifiers
        /// Modifiers are a subset of {Option, Shift}. *This* is the macOS 15 restriction.
        case onlyOptionOrShift

        /// Short enough to sit in the menu's warning row, which sets the menu's width.
        /// The long version lives in `explanation`, shown in the shortcuts window and as
        /// a tooltip.
        var description: String {
            switch self {
            case .noModifiers:
                return "a shortcut needs Control or Command"
            case .onlyOptionOrShift:
                return "macOS ignores Option/Shift-only shortcuts — add Control or Command"
            }
        }

        /// The same fact stated as a cause rather than as an instruction. The menu warning
        /// tells the user what to do about it; a log line describing a migration that has
        /// already happened should say why it happened, not order them to do it again.
        var logReason: String {
            switch self {
            case .noModifiers:
                return "it has no modifiers"
            case .onlyOptionOrShift:
                return "macOS 15 and later ignore Option/Shift-only shortcuts"
            }
        }

        var explanation: String {
            switch self {
            case .noModifiers:
                return "A global shortcut needs at least one modifier, and it has to be "
                     + "Control or Command — macOS will not deliver a shortcut held down "
                     + "with only Option or Shift."
            case .onlyOptionOrShift:
                return "Since macOS 15, the system refuses to deliver a global shortcut "
                     + "whose only modifiers are Option and Shift — it is a deliberate "
                     + "anti-key-logging measure, and it fails silently rather than "
                     + "reporting an error. Add Control or Command."
            }
        }
    }

    /// Nil when macOS can deliver this combination, and the reason when it cannot.
    ///
    /// One line of logic, and it is the whole fix: the modifiers must intersect
    /// {Control, Command}. Everything else — the migration, the recorder's refusal, the
    /// menu warning — is that predicate wearing different clothes.
    var rejection: Rejection? {
        if modifiers & Hotkey.strongModifiers != 0 { return nil }
        return modifiers == 0 ? .noModifiers : .onlyOptionOrShift
    }

    var isUsable: Bool { rejection == nil }

    // MARK: - Repairing one that cannot work

    /// The nearest combination macOS will actually deliver, or nil when this one is
    /// already fine.
    ///
    /// Two rules, and the split matters. A binding that is exactly what MoxSpeak *shipped*
    /// becomes the action's new default, so somebody who never touched a setting ends up
    /// on precisely the combination the menu and the shortcuts window now name. Anything
    /// else keeps every key the user chose and gains Control — there is no default to
    /// converge on for a hand-picked binding, and the key is the part they picked.
    ///
    /// Control rather than Command for the repair: ⌃ collides with far less than ⌘ does.
    func workingEquivalent(for action: HotkeyAction) -> Hotkey? {
        guard rejection != nil else { return nil }
        if self == action.legacyHotkey { return action.defaultHotkey }
        let repaired = Hotkey(keyCode: keyCode, modifiers: modifiers | Hotkey.control)
        return repaired.isUsable ? repaired : nil
    }

    // MARK: - Writing it for a human

    /// "⌃⌥S". Modifiers in the order macOS writes them — Control, Option, Shift, Command.
    var label: String {
        Hotkey.modifierLabel(for: modifiers) + Hotkey.keyName(for: keyCode)
    }

    /// The modifier symbols alone, in the same order. The shortcut recorder shows this
    /// while keys are being held and no key has been pressed yet.
    static func modifierLabel(for modifiers: UInt32) -> String {
        var text = ""
        if modifiers & control != 0 { text += "⌃" }
        if modifiers & option != 0 { text += "⌥" }
        if modifiers & shift != 0 { text += "⇧" }
        if modifiers & command != 0 { text += "⌘" }
        return text
    }

    /// What one virtual key code is called.
    ///
    /// A table rather than `UCKeyTranslate` against the live layout, because the table is
    /// what Carbon is actually registering: `RegisterEventHotKey` takes virtual key codes,
    /// so the honest label for what got registered is the name of that physical key.
    /// Anything unrecognised is named by its number, which is ugly and true — better than
    /// an empty string that makes a working shortcut look like no shortcut.
    static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",

            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",

            UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_Minus): "-",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Semicolon): ";",
            UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Comma): ",",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Grave): "`",

            UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "Delete",
            UInt32(kVK_Escape): "Esc", UInt32(kVK_ForwardDelete): "Forward Delete",
            UInt32(kVK_Home): "Home", UInt32(kVK_End): "End",
            UInt32(kVK_PageUp): "Page Up", UInt32(kVK_PageDown): "Page Down",
            UInt32(kVK_Help): "Help",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",

            UInt32(kVK_ANSI_KeypadClear): "Clear", UInt32(kVK_ANSI_KeypadEnter): "Enter",
            UInt32(kVK_ANSI_KeypadDecimal): "Keypad .",
            UInt32(kVK_ANSI_KeypadMultiply): "Keypad *",
            UInt32(kVK_ANSI_KeypadPlus): "Keypad +",
            UInt32(kVK_ANSI_KeypadDivide): "Keypad /",
            UInt32(kVK_ANSI_KeypadMinus): "Keypad -",
            UInt32(kVK_ANSI_KeypadEquals): "Keypad =",
            UInt32(kVK_ANSI_Keypad0): "Keypad 0", UInt32(kVK_ANSI_Keypad1): "Keypad 1",
            UInt32(kVK_ANSI_Keypad2): "Keypad 2", UInt32(kVK_ANSI_Keypad3): "Keypad 3",
            UInt32(kVK_ANSI_Keypad4): "Keypad 4", UInt32(kVK_ANSI_Keypad5): "Keypad 5",
            UInt32(kVK_ANSI_Keypad6): "Keypad 6", UInt32(kVK_ANSI_Keypad7): "Keypad 7",
            UInt32(kVK_ANSI_Keypad8): "Keypad 8", UInt32(kVK_ANSI_Keypad9): "Keypad 9",
        ]
        let functionKeys: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"),
            (kVK_F5, "F5"), (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"),
            (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
            (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
            (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
        ]
        for (code, name) in functionKeys { names[UInt32(code)] = name }
        return names
    }()

    // MARK: - Storing it

    /// What goes into `UserDefaults`: the two numbers, as `"keyCode:modifiers"`.
    ///
    /// Numbers rather than `"control+option+s"` on purpose. These two integers are
    /// *exactly* what is handed to `RegisterEventHotKey`, so storing them stores the
    /// thing itself; a name table in the plist would be a second spelling of the same
    /// fact, and the only symptom of the two drifting apart is a hotkey that silently
    /// does the wrong thing — which is the entire class of bug this file exists to close.
    var storageString: String { "\(keyCode):\(modifiers)" }

    /// The inverse, and defensive about it. What comes back off disk is a rumour: it may
    /// have been written by a future version, hand-edited with `defaults write`, or be
    /// left over from a format that no longer exists. Anything that is not two plausible
    /// numbers is nil, and the caller falls back to a default rather than registering
    /// nonsense.
    init?(storageString: String) {
        let parts = storageString.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let key = UInt32(parts[0]),
              let mods = UInt32(parts[1]),
              key <= 0x7F  // Carbon virtual key codes are a single byte.
        else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    // MARK: - Coming in from AppKit

    /// Carbon modifier bits for an `NSEvent`'s flags. The shortcut recorder is the only
    /// caller: AppKit reports what the user held down, Carbon needs it in its own
    /// currency, and the conversion is a pure mapping worth testing on its own.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= command }
        if flags.contains(.control) { mask |= control }
        if flags.contains(.option) { mask |= option }
        if flags.contains(.shift) { mask |= shift }
        return mask
    }
}

/// The three things a global hotkey can do, and the one place their defaults, storage
/// keys and names are written down.
///
/// An enum rather than three properties on `AppController` so that registering,
/// resolving, migrating, persisting and rebinding are all "for each action" loops. A
/// fourth hotkey would be one case and nothing else.
enum HotkeyAction: String, CaseIterable, Sendable {
    case speak
    case pause
    case stop

    /// ⌃⌥S, ⌃⌥D, ⌃⌥X — three keys under one left hand, with the two you press constantly
    /// side by side on the home row.
    ///
    /// **Why Control-Option.** The combination has to contain Control or Command (see
    /// `Hotkey.rejection`). ⌘⌥ is heavily used by browsers and editors; ⌃⌥ is close to
    /// empty on a stock Mac. So ⌃⌥ throughout.
    ///
    /// **Why one hand, and which hand.** Playback controls get pressed while the other
    /// hand is on the trackpad, scrolling the thing being read. A shortcut that needs two
    /// hands is a shortcut that interrupts reading to use. So all three live on the left.
    ///
    /// **Why the home row specifically, and how that was got wrong once.** The first
    /// version put Pause on C, reasoned from a grip where ⌃ is under the pinky and ⌥
    /// under the ring finger. That is not how the person using it holds it: the thumb
    /// rolls left onto ⌃⌥ and the index finger presses the key. Under that grip the hand
    /// rotates and the index falls around D and F, so C — down *and* left of where the
    /// index now sits — is a real stretch, which is what it was reported as. D is
    /// directly under the index finger instead.
    ///
    /// Both grips agree on the conclusion even though only one of them predicted it,
    /// because the home row is the short move from either. Speak and Pause are the pair
    /// pressed over and over while reading, so they get S and D, one column apart, with
    /// no travel between them. The lesson is the usual one for this project: the model of
    /// how somebody uses the thing is a guess until they say otherwise.
    ///
    /// **Why Stop is the exception.** X is the Mac's cancel key everywhere else, and
    /// Stop is the destructive one — it throws away the queue. Putting it a row down and
    /// a column left is deliberate: far enough that a slip while reaching for pause
    /// cannot land on it, close enough to stay one-handed.
    ///
    /// **What they had to avoid.** The first attempt used Space and Period, and both
    /// were occupied. ⌃⌥Space is the macOS default for Select Next Input Source
    /// (symbolic hotkey 61) — shipped by Apple, so it is taken on every Mac that has not
    /// turned it off. ⌃⌥. collided with something else locally: MoxSpeak's handler fired
    /// and so did another one.
    ///
    /// Karabiner-Elements, which a lot of people who care about keyboards run, commonly
    /// remaps a block of Control-plus-letter that includes D. It does not take ⌃⌥D: those
    /// rules declare `mandatory: [control]` with `optional: [caps_lock]`, and Karabiner
    /// does not match a manipulator when a modifier outside both lists is held. Holding
    /// Option is enough to pass straight through. This was checked against the config
    /// rather than assumed — an earlier pass ruled out the whole letter block on the
    /// assumption that it would match, and gave up the best key on the keyboard for no
    /// reason.
    ///
    /// Anyone who disagrees rebinds in Keyboard Shortcuts…; these are only the defaults.
    var defaultHotkey: Hotkey {
        switch self {
        case .speak:
            return Hotkey(keyCode: UInt32(kVK_ANSI_S),
                          modifiers: Hotkey.control | Hotkey.option)
        case .pause:
            return Hotkey(keyCode: UInt32(kVK_ANSI_D),
                          modifiers: Hotkey.control | Hotkey.option)
        case .stop:
            return Hotkey(keyCode: UInt32(kVK_ANSI_X),
                          modifiers: Hotkey.control | Hotkey.option)
        }
    }

    /// What MoxSpeak shipped, and what macOS 15 stopped delivering. Kept — rather than
    /// deleted along with the bug — because it is what a preferences file written by an
    /// older MoxSpeak contains, and recognising it by name is how the migration can move
    /// somebody onto the *documented* new default instead of mechanically bolting Control
    /// onto a shortcut nobody deliberately chose. See `Hotkey.workingEquivalent(for:)`.
    var legacyHotkey: Hotkey {
        switch self {
        case .speak:
            return Hotkey(keyCode: UInt32(kVK_ANSI_S),
                          modifiers: Hotkey.option | Hotkey.shift)
        case .pause:
            return Hotkey(keyCode: UInt32(kVK_Space),
                          modifiers: Hotkey.option | Hotkey.shift)
        case .stop:
            return Hotkey(keyCode: UInt32(kVK_ANSI_Period),
                          modifiers: Hotkey.option | Hotkey.shift)
        }
    }

    /// The `UserDefaults` key. Namespaced so a hotkey key can never be confused with
    /// `voice`, `rate` or `engine` — and so `Settings.allKeys` reads as a list.
    var settingsKey: String { "hotkey.\(rawValue)" }

    /// What the shortcuts window calls this row.
    var title: String {
        switch self {
        case .speak: return "Speak"
        case .pause: return "Pause / Resume"
        case .stop: return "Stop"
        }
    }

    /// The one-line "what does this actually do", for the row's tooltip.
    var detail: String {
        switch self {
        case .speak: return "Read the selected text, or the clipboard."
        case .pause: return "Pause what is being spoken, or resume it."
        case .stop: return "Stop speaking and clear what is queued."
        }
    }

    /// For the log, where "speak" alone would be ambiguous next to the speak *command*.
    var logName: String { "\(rawValue) hotkey" }
}
