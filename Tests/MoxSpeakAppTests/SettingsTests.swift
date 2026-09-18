import Testing
import Foundation
@testable import MoxSpeakApp

// `Settings` was split the way it was so that these tests could exist. The resolving half
// is pure — stored value in, world in, safe value out — so every case below is asserted
// on the real functions with real inputs. The storing half gets its own round trip
// through a real `UserDefaults`, in a throwaway suite so no test ever writes into the
// app's own domain.

// MARK: - First launch

@Test func nothingStoredYieldsTheDefaults() {
    #expect(Settings.resolveVoice(stored: nil, available: []) == Settings.defaultVoice)
    #expect(Settings.resolveRate(stored: nil) == Settings.defaultRate)
}

@Test func aFirstLaunchAgainstARealStoreReadsNothingBack() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        #expect(settings.storedVoice == nil)
        // The one that is easy to get wrong: `float(forKey:)` alone would answer 0 here,
        // and 0 resolves to a speed nobody chose.
        #expect(settings.storedRate == nil)
        #expect(Settings.resolveRate(stored: settings.storedRate) == 1.0)
    }
}

// MARK: - Round trip

@Test func aValidStoredPairComesBackUnchanged() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        settings.storedVoice = "am_michael"
        settings.storedRate = 1.5

        let reread = Settings(defaults: defaults)
        #expect(reread.storedVoice == "am_michael")
        #expect(reread.storedRate == 1.5)

        let voices = ["af_bella", "am_michael", "bf_emma"]
        #expect(Settings.resolveVoice(stored: reread.storedVoice, available: voices) == "am_michael")
        #expect(Settings.resolveRate(stored: reread.storedRate) == 1.5)
    }
}

/// The whole point of a slider over five presets: a precise, non-preset value written by
/// the exact-value field has to come back exactly, not get pulled onto the nearest of the
/// old five. Snapping is a slider-drag behaviour now (`SpeedControlTests`), not a
/// restore-time one.
@Test func aPreciseNonPresetRateSurvivesTheRoundTrip() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        settings.storedRate = 1.32

        let reread = Settings(defaults: defaults)
        #expect(reread.storedRate == 1.32)
        #expect(Settings.resolveRate(stored: reread.storedRate) == 1.32)
    }
}

@Test func clearingAStoredValueRemovesIt() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        settings.storedVoice = "bf_emma"
        settings.storedRate = 2.0
        settings.storedVoice = nil
        settings.storedRate = nil
        #expect(settings.storedVoice == nil)
        #expect(settings.storedRate == nil)
    }
}

// MARK: - Voices that no longer exist

@Test func anUnknownVoiceFallsBackToTheDefault() {
    let available = ["af_bella", "am_michael"]
    #expect(Settings.resolveVoice(stored: "af_deleted", available: available) == "af_bella")
}

@Test func anUnknownVoiceFallsBackToWhateverExistsWhenEvenTheDefaultIsGone() {
    // Kokoro serves whatever voice files are on the machine. Neither the saved voice nor
    // the app's own default is guaranteed to be among them, and "no voice at all" is not
    // an acceptable answer when the engine is offering two.
    let available = ["zf_xiaobei", "zm_yunjian"]
    #expect(Settings.resolveVoice(stored: "af_deleted", available: available) == "zf_xiaobei")
}

@Test func aKnownVoiceIsKept() {
    let available = ["af_bella", "am_michael"]
    #expect(Settings.resolveVoice(stored: "am_michael", available: available) == "am_michael")
}

@Test func anEmptyVoiceListDoesNotCountAsEvidenceAgainstTheStoredVoice() {
    // This is the launch case and the engine-unreachable case. "We have not asked yet"
    // must not be confused with "we asked and it is gone" — confusing them would turn a
    // dead engine into a silently forgotten preference.
    #expect(Settings.resolveVoice(stored: "am_michael", available: []) == "am_michael")
}

@Test func aBlankStoredVoiceIsTreatedAsNothingStored() {
    #expect(Settings.resolveVoice(stored: "   ", available: ["af_bella"]) == "af_bella")
    #expect(Settings.resolveVoice(stored: "", available: []) == Settings.defaultVoice)
}

// MARK: - Speeds that are not speeds

@Test func anOutOfRangeSpeedClamps() {
    // 9× is past what `PlaybackEngine.rate` will honour at all — see
    // `rateOfZeroCannotHangPlayback` in `PlaybackEngineTests` for exactly what an
    // unclamped rate did before that clamp existed. It comes back at the range's edge
    // rather than as 9, or as a silent clamp downstream that leaves the menu showing a
    // number the ear never hears.
    #expect(Settings.resolveRate(stored: 9.0) == 3.0)
    #expect(Settings.resolveRate(stored: 0.01) == 0.5)
}

@Test func aNonsenseSpeedFallsBackRatherThanClamping() {
    // Zero, negative and NaN are not out-of-range speeds, they are corruption — a key
    // written by something that is not this app. Clamping them would dress junk up as a
    // choice; the default says plainly that nothing usable was found.
    #expect(Settings.resolveRate(stored: 0) == Settings.defaultRate)
    #expect(Settings.resolveRate(stored: -1.5) == Settings.defaultRate)
    #expect(Settings.resolveRate(stored: .nan) == Settings.defaultRate)
    #expect(Settings.resolveRate(stored: .infinity) == Settings.defaultRate)
}

@Test func anInRangePreciseSpeedIsLeftExactlyAlone() {
    // The old five-preset menu snapped an in-range stray value onto the nearest preset.
    // The slider offers the whole range now, so a value like 1.3 or 1.9 is not stray —
    // it is exactly the kind of thing the exact-value field exists to produce, and
    // restoring it as anything else would be losing the user's own choice.
    #expect(Settings.resolveRate(stored: 1.3) == 1.3)
    #expect(Settings.resolveRate(stored: 1.9) == 1.9)
}

@Test func everyCommonValueSurvivesResolutionUnchanged() {
    for rate in SpeedControl.commonValues {
        #expect(Settings.resolveRate(stored: rate) == rate)
    }
}

// MARK: - Helper

/// Runs `body` against a `UserDefaults` suite that exists only for this test.
/// Internal rather than file-private: `EngineChoiceTests` stores an engine preference
/// through the same round trip, and two copies of a throwaway-suite helper is how one of
/// them ends up not cleaning up after itself.
func withTemporaryDefaults(_ body: (UserDefaults) -> Void) {
    withTemporaryDefaults { defaults, _ in body(defaults) }
}

/// The same thing, plus the suite's name. `ResetTests` needs it: emptying a domain means
/// naming it, `UserDefaults` will not say what it was opened as, and a test that guessed
/// would be checking a different domain from the one it wrote to.
func withTemporaryDefaults(_ body: (UserDefaults, String) -> Void) {
    let name = "com.moxspeak.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        Issue.record("could not open a temporary UserDefaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
        removeSuiteFile(named: name)
    }
    body(defaults, name)
}

/// Deletes the suite's backing plist.
///
/// `removePersistentDomain` empties a domain; it does not remove it. What is left in
/// ~/Library/Preferences is a 42-byte plist containing an empty dictionary, one per suite
/// per run, and since every suite name carries a fresh UUID they never get reused — a few
/// hundred full test runs had deposited 1,118 of them on the machine this was found on.
/// Harmless in size, but the suite is not entitled to leave anything behind in a
/// developer's home directory, and "tests litter" is the kind of thing that gets noticed
/// right after the project is shared with somebody.
///
/// Silent on failure by design: cfprefsd may not have written the file yet, in which case
/// there is nothing to clean up and nothing to report.
private func removeSuiteFile(named name: String) {
    guard let library = FileManager.default.urls(for: .libraryDirectory,
                                                 in: .userDomainMask).first else { return }
    let plist = library.appendingPathComponent("Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: plist)
}
