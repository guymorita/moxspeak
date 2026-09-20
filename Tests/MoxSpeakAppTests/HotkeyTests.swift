import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import MoxSpeakApp

// The shortcut half of the app, tested where it is pure.
//
// Registering a hotkey needs Carbon, a run loop and a real keypress, none of which a
// `swift test` process can honestly provide — but *whether a combination can work at all*
// needs none of them. It is a function of two integers, and it is the part that was
// wrong: MoxSpeak shipped three shortcuts that macOS has silently refused to deliver
// since Sequoia, and every layer above them reported success. So that predicate, the
// migration built on it, and the round trip through a real `UserDefaults` are what these
// tests pin down.

// MARK: - The check that would have caught the defect

/// The one that matters. ⌥⇧S is exactly what MoxSpeak shipped and exactly what macOS 15
/// and later will not deliver: `RegisterEventHotKey` answers `noErr`, the handler
/// installs, and the callback is never called. Before this predicate existed there was
/// nothing anywhere in the app — or in this suite — that could tell that apart from a
/// working hotkey.
@Test func anOptionShiftOnlyCombinationIsRefused() {
    let shipped = Hotkey(keyCode: UInt32(kVK_ANSI_S),
                         modifiers: Hotkey.option | Hotkey.shift)

    #expect(shipped.label == "⌥⇧S")
    #expect(shipped.isUsable == false)
    #expect(shipped.rejection == .onlyOptionOrShift)
}

/// The other two shipped shortcuts, for the same reason: a fix that only covered the
/// letter would have left pause and stop dead.
@Test func allThreeShippedShortcutsAreRefused() {
    let shipped = [
        Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: Hotkey.option | Hotkey.shift),
        Hotkey(keyCode: UInt32(kVK_Space), modifiers: Hotkey.option | Hotkey.shift),
        Hotkey(keyCode: UInt32(kVK_ANSI_Period), modifiers: Hotkey.option | Hotkey.shift),
    ]
    for hotkey in shipped {
        #expect(hotkey.rejection == .onlyOptionOrShift,
                Comment(rawValue: "\(hotkey.label) was accepted and cannot fire"))
    }
}

/// Every strict subset of {Option, Shift}, including the empty one. The rule is about the
/// *absence* of Control and Command, not about Option and Shift both being present, and a
/// predicate that only caught the pair would let ⌥S and ⇧S through.
@Test func everySubsetOfOptionAndShiftIsRefused() {
    let key = UInt32(kVK_ANSI_S)
    #expect(Hotkey(keyCode: key, modifiers: 0).rejection == .noModifiers)
    #expect(Hotkey(keyCode: key, modifiers: Hotkey.option).rejection == .onlyOptionOrShift)
    #expect(Hotkey(keyCode: key, modifiers: Hotkey.shift).rejection == .onlyOptionOrShift)
    #expect(Hotkey(keyCode: key, modifiers: Hotkey.option | Hotkey.shift).rejection
            == .onlyOptionOrShift)
}

/// The complement: anything carrying Control or Command is fine, however it is dressed.
@Test func anythingWithControlOrCommandIsAccepted() {
    let key = UInt32(kVK_ANSI_S)
    let usable: [UInt32] = [
        Hotkey.control,
        Hotkey.command,
        Hotkey.control | Hotkey.option,
        Hotkey.command | Hotkey.shift,
        Hotkey.control | Hotkey.option | Hotkey.shift,
        Hotkey.control | Hotkey.option | Hotkey.shift | Hotkey.command,
    ]
    for modifiers in usable {
        let hotkey = Hotkey(keyCode: key, modifiers: modifiers)
        #expect(hotkey.isUsable, Comment(rawValue: "\(hotkey.label) was refused"))
        #expect(hotkey.rejection == nil)
    }
}

/// Caps Lock is a modifier bit Carbon knows about and this app does not use. It must not
/// be able to turn a dead combination into a live-looking one.
@Test func unrecognisedModifierBitsAreDroppedAndCannotRescueACombination() {
    let withCapsLock = Hotkey(keyCode: UInt32(kVK_ANSI_S),
                              modifiers: UInt32(alphaLock) | Hotkey.option | Hotkey.shift)
    #expect(withCapsLock.modifiers == Hotkey.option | Hotkey.shift)
    #expect(withCapsLock.rejection == .onlyOptionOrShift)
    #expect(withCapsLock == Hotkey(keyCode: UInt32(kVK_ANSI_S),
                                   modifiers: Hotkey.option | Hotkey.shift))
}

// MARK: - The defaults

/// The property that is not negotiable, asserted against the real defaults rather than
/// against a copy of them: no shipped shortcut may be one macOS refuses to deliver. If a
/// future change reintroduces an Option/Shift-only default, this fails before anyone
/// presses a key.
@Test func noDefaultShortcutIsOneMacOSWillIgnore() {
    for action in HotkeyAction.allCases {
        let hotkey = action.defaultHotkey
        #expect(hotkey.isUsable,
                Comment(rawValue: "the default \(action.rawValue) shortcut "
                                  + "\(hotkey.label) cannot fire on macOS 15 or later"))
        #expect(hotkey.modifiers & Hotkey.strongModifiers != 0)
    }
}

/// The defaults, and the properties that chose them.
///
/// The three labels are asserted so that changing one has to be deliberate. The rest is
/// the part with teeth: where a default is allowed to live, and what it is not allowed to
/// collide with.
@Test func theDefaultsAreOneHandedAndUncontested() {
    #expect(HotkeyAction.speak.defaultHotkey.label == "⌃⌥S")
    #expect(HotkeyAction.pause.defaultHotkey.label == "⌃⌥D")
    #expect(HotkeyAction.stop.defaultHotkey.label == "⌃⌥X")

    // Reachable by the same hand that is holding ⌃⌥ — whether that is thumb-on-modifiers
    // with the index pressing the key, which is how it is actually held, or pinky-and-ring
    // on the modifiers. A, Q and Z sit under the pinky, which is occupied in one grip and
    // out of reach in the other; everything right of T/G/B needs the second hand.
    let oneHanded: Set<UInt32> = [
        UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_E), UInt32(kVK_ANSI_R), UInt32(kVK_ANSI_T),
        UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_D), UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_G),
        UInt32(kVK_ANSI_X), UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_B),
    ]

    // Two combinations that were tried as defaults and turned out to be spoken for.
    // Space is Apple's own ⌃⌥ binding — Select Next Input Source, symbolic hotkey 61 —
    // so it is taken on any Mac that has not switched it off. Period collided with
    // something else on the machine this was built for: both handlers fired.
    let contested: Set<UInt32> = [UInt32(kVK_Space), UInt32(kVK_ANSI_Period)]

    for action in HotkeyAction.allCases {
        let hotkey = action.defaultHotkey
        #expect(oneHanded.contains(hotkey.keyCode),
                Comment(rawValue: "the default \(action.rawValue) shortcut "
                                  + "\(hotkey.label) cannot be pressed with one hand"))
        #expect(!contested.contains(hotkey.keyCode),
                Comment(rawValue: "the default \(action.rawValue) shortcut "
                                  + "\(hotkey.label) was measured as already taken"))
    }

    // Speak and Pause are the pair pressed over and over while reading, so they share the
    // home row and sit a column apart — no travel between them. With the thumb rolled
    // onto ⌃⌥ the hand rotates and the index finger lands around D and F, which puts the
    // bottom letter row down and to the left of it — that is why ⌃⌥C was rejected by the
    // person using it as a stretch.
    let homeRow: Set<UInt32> = [
        UInt32(kVK_ANSI_A), UInt32(kVK_ANSI_S), UInt32(kVK_ANSI_D),
        UInt32(kVK_ANSI_F), UInt32(kVK_ANSI_G),
    ]
    #expect(homeRow.contains(HotkeyAction.speak.defaultHotkey.keyCode))
    #expect(homeRow.contains(HotkeyAction.pause.defaultHotkey.keyCode))

    // Stop is the destructive one — it discards the queue — so it deliberately does not
    // sit next to the key the hand is already resting on.
    #expect(!homeRow.contains(HotkeyAction.stop.defaultHotkey.keyCode))

    // Three distinct keys behind one modifier set, so the hand learns one shape.
    let keys = HotkeyAction.allCases.map(\.defaultHotkey.keyCode)
    #expect(Set(keys).count == keys.count)
    #expect(Set(HotkeyAction.allCases.map(\.defaultHotkey.modifiers))
            == [Hotkey.control | Hotkey.option])
}

@Test func everyActionHasItsOwnSettingsKey() {
    let keys = HotkeyAction.allCases.map(\.settingsKey)
    #expect(Set(keys).count == keys.count)
    for key in keys { #expect(Settings.allKeys.contains(key)) }
}

// MARK: - Writing a combination down

@Test func modifiersAreWrittenInTheOrderMacOSWritesThem() {
    let all = Hotkey(keyCode: UInt32(kVK_ANSI_K),
                     modifiers: Hotkey.command | Hotkey.shift | Hotkey.option | Hotkey.control)
    #expect(all.label == "⌃⌥⇧⌘K")
}

@Test func keysWithoutALetterAreNamed() {
    #expect(Hotkey(keyCode: UInt32(kVK_Space), modifiers: Hotkey.control).label == "⌃Space")
    #expect(Hotkey(keyCode: UInt32(kVK_Return), modifiers: Hotkey.control).label == "⌃Return")
    #expect(Hotkey(keyCode: UInt32(kVK_F5), modifiers: Hotkey.control).label == "⌃F5")
    #expect(Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: Hotkey.command).label == "⌘←")
}

/// A key this build has no name for is still shown as *something*. An empty label would
/// make a registered shortcut look like no shortcut at all, which is the same class of
/// silence this whole feature is about.
@Test func anUnknownKeyIsNamedByItsNumberRatherThanLeftBlank() {
    let odd = Hotkey(keyCode: 200, modifiers: Hotkey.control)
    #expect(odd.label == "⌃Key 200")
}

@Test func modifierFlagsFromAppKitBecomeCarbonBits() {
    #expect(Hotkey.carbonModifiers(from: []) == 0)
    #expect(Hotkey.carbonModifiers(from: [.control, .option]) == Hotkey.control | Hotkey.option)
    #expect(Hotkey.carbonModifiers(from: [.command]) == Hotkey.command)
    #expect(Hotkey.carbonModifiers(from: [.shift]) == Hotkey.shift)
    // Flags AppKit sets that are not modifiers a hotkey can use.
    #expect(Hotkey.carbonModifiers(from: [.capsLock, .function, .numericPad]) == 0)
}

// MARK: - Repairing one that cannot work

/// The three shipped defaults become the three new defaults, so somebody who never
/// touched a setting lands on exactly what the menu now says.
@Test func theShippedShortcutsMigrateToTheNewDefaults() {
    for action in HotkeyAction.allCases {
        #expect(action.legacyHotkey.rejection == .onlyOptionOrShift)
        #expect(action.legacyHotkey.workingEquivalent(for: action) == action.defaultHotkey)
    }
}

/// Anything else that cannot work keeps the key the user picked and gains Control. There
/// is no default to converge on for a hand-picked binding, and the key is the part they
/// chose.
@Test func anyOtherDeadCombinationKeepsItsKeyAndGainsControl() {
    let dead = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: Hotkey.option | Hotkey.shift)
    let repaired = dead.workingEquivalent(for: .speak)
    #expect(repaired == Hotkey(keyCode: UInt32(kVK_ANSI_K),
                               modifiers: Hotkey.control | Hotkey.option | Hotkey.shift))
    #expect(repaired?.isUsable == true)
    #expect(repaired?.label == "⌃⌥⇧K")
}

@Test func aCombinationThatAlreadyWorksIsNotRepaired() {
    #expect(HotkeyAction.speak.defaultHotkey.workingEquivalent(for: .speak) == nil)
    #expect(Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: Hotkey.command)
                .workingEquivalent(for: .speak) == nil)
}

/// Repairing must never hand back something still unusable — the resolver trusts this.
@Test func everyRepairIsItselfUsable() {
    let deadModifiers: [UInt32] = [0, Hotkey.option, Hotkey.shift,
                                   Hotkey.option | Hotkey.shift]
    for action in HotkeyAction.allCases {
        for modifiers in deadModifiers {
            for key in [UInt32(kVK_ANSI_S), UInt32(kVK_Space), UInt32(kVK_ANSI_Q)] {
                let dead = Hotkey(keyCode: key, modifiers: modifiers)
                guard let repaired = dead.workingEquivalent(for: action) else {
                    Issue.record("\(dead.label) could not be repaired")
                    continue
                }
                #expect(repaired.isUsable)
            }
        }
    }
}

// MARK: - Storing one

@Test func aCombinationSurvivesBeingWrittenDownAndReadBack() {
    let originals = HotkeyAction.allCases.map(\.defaultHotkey) + [
        Hotkey(keyCode: UInt32(kVK_F13), modifiers: Hotkey.command | Hotkey.shift),
        Hotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: Hotkey.control),
    ]
    for original in originals {
        #expect(Hotkey(storageString: original.storageString) == original)
    }
}

/// What comes off disk is a rumour. Every one of these is something a future version, a
/// `defaults write` or a corrupted plist could plausibly leave behind, and none of them
/// may become a registration.
@Test func junkOnDiskDoesNotParse() {
    let junk = ["", "  ", "abc", "1", "1:2:3", "S:control", ":", "1:", ":1",
                "-1:2048", "1:-2048", "128:4096", "99999:4096", "1.5:4096"]
    for text in junk {
        #expect(Hotkey(storageString: text) == nil,
                Comment(rawValue: "\"\(text)\" parsed into a hotkey"))
    }
}

// MARK: - Resolving what was stored

@Test func nothingStoredYieldsTheDefaultQuietly() {
    for action in HotkeyAction.allCases {
        let resolved = Settings.resolveHotkey(stored: nil, action: action)
        #expect(resolved.hotkey == action.defaultHotkey)
        #expect(resolved.note == nil)
        #expect(resolved.shouldRestore == false)
    }
}

@Test func aStoredCombinationThatWorksComesBackUntouched() {
    let chosen = Hotkey(keyCode: UInt32(kVK_F13), modifiers: Hotkey.command | Hotkey.control)
    let resolved = Settings.resolveHotkey(stored: chosen.storageString, action: .speak)
    #expect(resolved.hotkey == chosen)
    #expect(resolved.note == nil)
    #expect(resolved.shouldRestore == false)
}

/// The migration, end to end and in the shape a real upgrade has it: the owner's stored
/// ⌥⇧S becomes ⌃⌥S, the log gets a line naming both, and the new value is written back so
/// nobody is left sitting on a shortcut that cannot fire.
@Test func aStoredOptionShiftOnlyBindingIsMigratedAndSaidSoOutLoud() {
    let stored = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: Hotkey.option | Hotkey.shift)
    let resolved = Settings.resolveHotkey(stored: stored.storageString, action: .speak)

    #expect(resolved.hotkey == HotkeyAction.speak.defaultHotkey)
    #expect(resolved.hotkey.isUsable)
    #expect(resolved.shouldRestore)

    let note = resolved.note ?? ""
    #expect(note.contains("⌥⇧S"))
    #expect(note.contains("⌃⌥S"))
    #expect(note.contains("cannot work"))
    #expect(note.contains("macOS 15"))
}

@Test func allThreeStoredLegacyBindingsMigrate() {
    for action in HotkeyAction.allCases {
        let resolved = Settings.resolveHotkey(stored: action.legacyHotkey.storageString,
                                              action: action)
        #expect(resolved.hotkey == action.defaultHotkey)
        #expect(resolved.note != nil)
        #expect(resolved.shouldRestore)
    }
}

/// A hand-picked binding that is no longer valid keeps its key rather than being replaced
/// by the default — the same defensive shape `resolveVoice` has, where what the user chose
/// is preserved as far as it honestly can be.
@Test func aCustomStoredBindingThatIsNoLongerValidKeepsItsKey() {
    let stored = Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: Hotkey.option)
    let resolved = Settings.resolveHotkey(stored: stored.storageString, action: .speak)

    #expect(resolved.hotkey.keyCode == UInt32(kVK_ANSI_K))
    #expect(resolved.hotkey.isUsable)
    #expect(resolved.hotkey != HotkeyAction.speak.defaultHotkey)
    #expect(resolved.shouldRestore)
    #expect(resolved.note?.contains("⌥K") == true)
}

@Test func anUnreadableStoredBindingFallsBackToTheDefaultAndSaysSo() {
    let resolved = Settings.resolveHotkey(stored: "who knows", action: .stop)
    #expect(resolved.hotkey == HotkeyAction.stop.defaultHotkey)
    #expect(resolved.shouldRestore)
    #expect(resolved.note?.contains("who knows") == true)
}

/// Whatever comes back, it is registrable. This is the invariant `AppController` leans on
/// when it hands the answer straight to Carbon without checking it again.
@Test func resolvingNeverYieldsSomethingMacOSWouldIgnore() {
    let inputs: [String?] = [
        nil, "", "   ", "garbage", "1:0", "1:2048", "1:512", "1:2560", "49:2560",
        "47:2560", "999:4096", HotkeyAction.speak.defaultHotkey.storageString,
    ]
    for action in HotkeyAction.allCases {
        for stored in inputs {
            let resolved = Settings.resolveHotkey(stored: stored, action: action)
            #expect(resolved.hotkey.isUsable,
                    Comment(rawValue: "\(stored ?? "nil") resolved to the unusable "
                                      + "\(resolved.hotkey.label)"))
        }
    }
}

// MARK: - Through a real store

@Test func aRebindingSurvivesARelaunch() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        let chosen = Hotkey(keyCode: UInt32(kVK_ANSI_J),
                            modifiers: Hotkey.command | Hotkey.option)
        settings.setStoredHotkey(chosen.storageString, for: .speak)

        let reread = Settings(defaults: defaults)
        let resolved = Settings.resolveHotkey(stored: reread.storedHotkey(.speak),
                                              action: .speak)
        #expect(resolved.hotkey == chosen)
        #expect(resolved.note == nil)
    }
}

@Test func aFirstLaunchAgainstARealStoreHasNoStoredShortcuts() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        for action in HotkeyAction.allCases {
            #expect(settings.storedHotkey(action) == nil)
            #expect(Settings.resolveHotkey(stored: settings.storedHotkey(action),
                                           action: action).hotkey == action.defaultHotkey)
        }
    }
}

/// The upgrade, against a real preferences file: a plist written by the old MoxSpeak, read
/// by this one, migrated, and — crucially — written back, so the second launch is quiet.
@Test func aStoredDeadBindingIsMigratedOnceAndThenLeftAlone() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        let old = Hotkey(keyCode: UInt32(kVK_ANSI_S),
                         modifiers: Hotkey.option | Hotkey.shift)
        settings.setStoredHotkey(old.storageString, for: .speak)

        // Launch one: migrated, announced, written back.
        let first = Settings.resolveHotkey(stored: settings.storedHotkey(.speak), action: .speak)
        #expect(first.note != nil)
        #expect(first.shouldRestore)
        settings.setStoredHotkey(first.hotkey.storageString, for: .speak)

        // Launch two: nothing to say, nothing to write.
        let second = Settings.resolveHotkey(stored: settings.storedHotkey(.speak), action: .speak)
        #expect(second.hotkey == first.hotkey)
        #expect(second.note == nil)
        #expect(second.shouldRestore == false)
    }
}

@Test func clearingAStoredShortcutReturnsTheDefault() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        settings.setStoredHotkey(Hotkey(keyCode: UInt32(kVK_ANSI_J),
                                        modifiers: Hotkey.control).storageString,
                                 for: .pause)
        settings.setStoredHotkey(nil, for: .pause)

        #expect(settings.storedHotkey(.pause) == nil)
        #expect(Settings.resolveHotkey(stored: settings.storedHotkey(.pause),
                                       action: .pause).hotkey
                == HotkeyAction.pause.defaultHotkey)
    }
}

/// The welcome window shows the glyphs and the words together, because ⌃ and ⌥ are used
/// by many more people than can name them.
@Test func aShortcutCanBeSpelledOutInWords() {
    #expect(HotkeyAction.speak.defaultHotkey.spelledOut == "Control + Option + S")
    #expect(HotkeyAction.pause.defaultHotkey.spelledOut == "Control + Option + D")
    #expect(HotkeyAction.stop.defaultHotkey.spelledOut == "Control + Option + X")

    // Apple's order, matching the glyph order and what System Settings calls them.
    let everything = Hotkey(keyCode: UInt32(kVK_ANSI_K),
                            modifiers: Hotkey.control | Hotkey.option
                                     | Hotkey.shift | Hotkey.command)
    #expect(everything.spelledOut == "Control + Option + Shift + Command + K")
    #expect(everything.label == "⌃⌥⇧⌘K")

    // Non-letter keys are named, not left blank — "Control + Space", never "Control + ".
    #expect(Hotkey(keyCode: UInt32(kVK_Space), modifiers: Hotkey.control).spelledOut
            == "Control + Space")

    // Every default must produce words for each of its glyphs; a spelled-out form that
    // silently drops a modifier would be worse than showing none.
    for action in HotkeyAction.allCases {
        let hotkey = action.defaultHotkey
        let glyphCount = hotkey.label.count - Hotkey.keyName(for: hotkey.keyCode).count
        #expect(hotkey.spelledOut.components(separatedBy: " + ").count == glyphCount + 1,
                Comment(rawValue: "\(hotkey.label) spelled out as \(hotkey.spelledOut)"))
    }
}

/// The shape of a bug that shipped: every successful shortcut change told the user
/// "MoxSpeak is shutting down".
///
/// `rebind` returns `String?`, where nil means it worked and a string is what went wrong.
/// The call site was `self?.rebind(...) ?? "MoxSpeak is shutting down"`, meaning to supply
/// that message only when the controller had gone away. But optional chaining does not
/// add a level of optionality to something already optional — `self?.method()` where the
/// method returns `String?` is `String?`, flattened — so the `??` could not tell a missing
/// receiver from a successful nil, and fired on every success.
///
/// Kept as a test because the expression reads as obviously correct, which is exactly why
/// it survived review.
@Test func optionalChainingCannotTellAMissingSelfFromANilResult() {
    final class Receiver { func rebind() -> String? { nil } }

    let present: Receiver? = Receiver()
    let absent: Receiver? = nil

    // The bug. A live receiver reporting success is indistinguishable from no receiver.
    #expect((present?.rebind() ?? "shutting down") == "shutting down")
    #expect((absent?.rebind() ?? "shutting down") == "shutting down")

    // The fix: unwrap the receiver first, then return its answer untouched.
    func resolved(_ receiver: Receiver?) -> String? {
        guard let receiver else { return "shutting down" }
        return receiver.rebind()
    }
    #expect(resolved(present) == nil, "success must report no problem")
    #expect(resolved(absent) == "shutting down")
}
