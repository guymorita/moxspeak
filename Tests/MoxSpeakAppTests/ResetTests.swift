import Testing
import Foundation
@testable import MoxSpeakApp

// `Reset` is the uninstall promise made checkable. The claim is "install MoxSpeak and
// nothing else; uninstall it and nothing is left to consider", and the app can only keep
// the second half of that for the two things macOS keeps on every app's behalf: the
// preferences domain and the log file.
//
// Both halves are exercised against real storage — a throwaway `UserDefaults` suite and a
// real file in a temporary directory — because both are thin wrappers over system calls
// that either happen or do not, and a mock of either would be asserting that the test's
// own stub works.

// MARK: - Preferences

@Test func erasingTakesEveryStoredPreferenceWithIt() {
    withTemporaryDefaults { defaults, domain in
        let settings = Settings(defaults: defaults, domain: domain)
        settings.storedVoice = "am_michael"
        settings.storedRate = 1.25
        settings.storedEngine = "http"

        let result = Reset.erasePreferences(in: defaults, domain: settings.domain)

        #expect(result.cleared)
        #expect(result.leftoverKeys.isEmpty)
        #expect(settings.storedVoice == nil)
        #expect(settings.storedRate == nil)
        #expect(settings.storedEngine == nil)
    }
}

/// The domain sweep is what takes keys this app never wrote — AppKit stores the status
/// item's position in the same domain, and a per-key removal would leave it there.
@Test func erasingTakesKeysTheAppItselfNeverWrote() {
    withTemporaryDefaults { defaults, domain in
        defaults.set(268, forKey: "NSStatusItem Preferred Position Item-0")
        defaults.set("something a future version wrote", forKey: "unknownFutureKey")

        Reset.erasePreferences(in: defaults, domain: domain)

        #expect(defaults.object(forKey: "NSStatusItem Preferred Position Item-0") == nil)
        #expect(defaults.object(forKey: "unknownFutureKey") == nil)
    }
}

/// Running the binary straight out of `.build` has no Info.plist and therefore no domain
/// to sweep. That is a normal development state, not a failure, and the preferences still
/// have to go.
@Test func withNoBundleIdentifierTheKnownKeysStillGo() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults, domain: nil)
        settings.storedVoice = "bf_emma"
        settings.storedRate = 2.0
        settings.storedEngine = "native"

        let result = Reset.erasePreferences(in: defaults, domain: nil)

        #expect(result.cleared)
        #expect(settings.storedVoice == nil)
        #expect(settings.storedRate == nil)
        #expect(settings.storedEngine == nil)
    }
}

/// The one that would be silent: a key added to `Settings.Key` and not to `allKeys` is a
/// preference that survives a reset on a build with no bundle identifier, and nothing
/// else in the app would ever notice.
@Test func everyKeySettingsWritesIsOneResetKnowsAbout() {
    withTemporaryDefaults { defaults, domain in
        let settings = Settings(defaults: defaults, domain: domain)
        settings.storedVoice = "af_bella"
        settings.storedRate = 1.5
        settings.storedEngine = "http"
        for action in HotkeyAction.allCases {
            settings.setStoredHotkey(action.defaultHotkey.storageString, for: action)
        }

        // The domain itself, not `dictionaryRepresentation`, which folds in the global
        // and registration domains and would swamp three keys in several hundred.
        let written = Set((defaults.persistentDomain(forName: domain) ?? [:]).keys)

        #expect(written == Set(Settings.allKeys),
                Comment(rawValue: "Settings wrote \(written.sorted()) but Reset knows "
                                  + "about \(Settings.allKeys.sorted())"))
    }
}

/// Resetting twice is not an error, and the second one must not report a failure it did
/// not have.
@Test func erasingAnAlreadyEmptyDomainIsQuietlyFine() {
    withTemporaryDefaults { defaults, domain in
        let first = Reset.erasePreferences(in: defaults, domain: domain)
        let second = Reset.erasePreferences(in: defaults, domain: domain)
        #expect(first.cleared)
        #expect(second.cleared)
        #expect(second.leftoverKeys.isEmpty)
    }
}

/// The property the phase is actually accountable to, asserted through the real
/// resolvers rather than by looking at the plist: after a reset, what the app *uses* is
/// what a machine that has never run MoxSpeak gets.
@Test func afterAResetTheAppResolvesExactlyWhatAFirstLaunchResolves() {
    withTemporaryDefaults { defaults, domain in
        let settings = Settings(defaults: defaults, domain: domain)
        settings.storedVoice = "am_michael"
        settings.storedRate = 1.25
        settings.storedEngine = "http"

        Reset.erasePreferences(in: defaults, domain: settings.domain)

        let voices = ["af_bella", "am_michael", "bf_emma"]
        #expect(Settings.resolveVoice(stored: settings.storedVoice, available: voices)
                == Settings.defaultVoice)
        #expect(Settings.resolveRate(stored: settings.storedRate) == Settings.defaultRate)
        #expect(Settings.resolveEngine(stored: settings.storedEngine)
                == Settings.defaultEngine)
        // And the default engine is the one that needs nothing else installed, which is
        // the whole reason a reset is allowed to drop the user's engine choice.
        #expect(Settings.defaultEngine == .native)
    }
}

// MARK: - The log file

@Test func erasingRemovesTheLogFile() {
    withTemporaryFile(containing: "2026-09-18 05:00:00.000 launch: pid 1\n") { url in
        let result = Reset.eraseFile(at: url)
        #expect(result.cleared)
        #expect(result.problem == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// A log that was never written, or a reset run twice. The caller asked for the file to
/// be gone and it is gone; calling that a failure would make the second reset look broken.
@Test func aLogThatWasNeverThereCountsAsCleared() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("moxspeak-reset-\(UUID().uuidString).log")
    let result = Reset.eraseFile(at: url)
    #expect(result.cleared)
    #expect(result.problem == nil)
}

@Test func aLogItCannotLocateIsReportedRatherThanSilentlySkipped() {
    let result = Reset.eraseFile(at: nil)
    #expect(!result.cleared)
    #expect(result.problem != nil)
}

/// `Reset` deletes `AppLog`'s own URL rather than a second spelling of the same path —
/// two copies of a path is how an uninstall ends up leaving the log behind.
@Test func theLogTheAppWritesIsTheLogAResetDeletes() throws {
    let url = try #require(AppLog.fileURL)
    #expect(url.path.hasSuffix("/Library/Logs/MoxSpeak.log"))
}

// MARK: - What the user is told

/// The honesty requirement, pinned. The Accessibility grant is macOS's, keyed to the
/// app's signing identity, and not revocable by the app it was granted to — so the
/// confirmation has to name it and say who removes it, rather than implying a clean slate
/// MoxSpeak cannot deliver.
@Test func theConfirmationAdmitsTheOnePermissionItCannotTakeBack() {
    let text = Reset.confirmationDetail
    #expect(text.contains("Select-to-Speak"))
    #expect(text.contains("System Settings"))
    #expect(text.contains("Accessibility"))
    #expect(text.contains("macOS remembers that approval, not MoxSpeak"))
}

/// Everything it *does* touch, named where the user can read it before agreeing.
@Test func theConfirmationNamesEverythingItErases() {
    let text = Reset.confirmationDetail
    #expect(text.contains("voice"))
    #expect(text.contains("speed"))
    #expect(text.contains("engine"))
    #expect(text.contains("~/Library/Logs/MoxSpeak.log"))
    #expect(text.contains("cannot be undone"))
}

/// A destructive item that reads like a harmless one is how it gets clicked by accident.
/// The ellipsis is the platform's promise that a confirmation is coming, and the button
/// says what it does rather than "OK".
@Test func theMenuItemWarnsBeforeItIsClicked() {
    #expect(Reset.menuTitle.hasSuffix("…"))
    #expect(Reset.confirmButton != "OK")
    #expect(Reset.cancelButton == "Cancel")
}

// MARK: - Reporting

@Test func acleanResetSaysSoAndAPartialOneDoesNot() {
    let clean = Reset.Outcome(preferencesCleared: true, leftoverKeys: [],
                              logCleared: true, logProblem: nil)
    #expect(clean.isClean)
    #expect(clean.summary.contains("Reset"))

    let logStuck = Reset.Outcome(preferencesCleared: true, leftoverKeys: [],
                                 logCleared: false, logProblem: "permission denied")
    #expect(!logStuck.isClean)
    #expect(logStuck.summary.contains("incomplete"))
    #expect(logStuck.summary.contains("permission denied"))

    let prefsStuck = Reset.Outcome(preferencesCleared: false, leftoverKeys: ["voice"],
                                   logCleared: true, logProblem: nil)
    #expect(!prefsStuck.isClean)
    #expect(prefsStuck.summary.contains("incomplete"))
    #expect(prefsStuck.summary.contains("settings"))
}

// MARK: - Helpers

private func withTemporaryFile(containing contents: String, _ body: (URL) -> Void) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("moxspeak-reset-\(UUID().uuidString).log")
    try? contents.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    body(url)
}
