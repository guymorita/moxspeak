import Testing
import Foundation
@testable import MoxSpeakApp

// `Settings` was split the way it was so that these tests could exist. The resolving half
// is pure — stored value in, world in, safe value out — so every case below is asserted
// on the real functions with real inputs. The storing half gets its own round trip
// through a real `UserDefaults`, in a throwaway suite so no test ever writes into the
// app's own domain.

private let offered = MenuBarController.rates  // 0.75, 1.0, 1.25, 1.5, 2.0

// MARK: - First launch

@Test func nothingStoredYieldsTheDefaults() {
    #expect(Settings.resolveVoice(stored: nil, available: []) == Settings.defaultVoice)
    #expect(Settings.resolveRate(stored: nil, offered: offered) == Settings.defaultRate)
}

@Test func aFirstLaunchAgainstARealStoreReadsNothingBack() {
    withTemporaryDefaults { defaults in
        let settings = Settings(defaults: defaults)
        #expect(settings.storedVoice == nil)
        // The one that is easy to get wrong: `float(forKey:)` alone would answer 0 here,
        // and 0 resolves to a speed nobody chose.
        #expect(settings.storedRate == nil)
        #expect(Settings.resolveRate(stored: settings.storedRate, offered: offered) == 1.0)
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
        #expect(Settings.resolveRate(stored: reread.storedRate, offered: offered) == 1.5)
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
    // 9× is past what the audio unit will honour at all; it comes back as the fastest
    // speed the app actually offers rather than as 9, or as a silent clamp downstream
    // that leaves the menu showing something the ear never hears.
    #expect(Settings.resolveRate(stored: 9.0, offered: offered) == 2.0)
    #expect(Settings.resolveRate(stored: 0.01, offered: offered) == 0.75)
}

@Test func aNonsenseSpeedFallsBackRatherThanClamping() {
    // Zero, negative and NaN are not out-of-range speeds, they are corruption — a key
    // written by something that is not this app. Clamping them would dress junk up as a
    // choice; the default says plainly that nothing usable was found.
    #expect(Settings.resolveRate(stored: 0, offered: offered) == Settings.defaultRate)
    #expect(Settings.resolveRate(stored: -1.5, offered: offered) == Settings.defaultRate)
    #expect(Settings.resolveRate(stored: .nan, offered: offered) == Settings.defaultRate)
    #expect(Settings.resolveRate(stored: .infinity, offered: offered) == Settings.defaultRate)
}

@Test func anInRangeSpeedThatIsNotOnOfferSnapsToTheNearestOne() {
    // In range, so nothing downstream would complain — but no menu item would be ticked,
    // which is the "looks configured, isn't" state worth preventing.
    #expect(Settings.resolveRate(stored: 1.3, offered: offered) == 1.25)
    #expect(Settings.resolveRate(stored: 1.9, offered: offered) == 2.0)
}

@Test func everyOfferedSpeedSurvivesResolution() {
    for rate in offered {
        #expect(Settings.resolveRate(stored: rate, offered: offered) == rate)
    }
}

@Test func withNothingOnOfferAnInRangeSpeedIsLeftAlone() {
    #expect(Settings.resolveRate(stored: 1.3, offered: []) == 1.3)
    #expect(Settings.resolveRate(stored: 9.0, offered: []) == 3.0)  // still clamped
}

// MARK: - Helper

/// Runs `body` against a `UserDefaults` suite that exists only for this test.
/// Internal rather than file-private: `EngineChoiceTests` stores an engine preference
/// through the same round trip, and two copies of a throwaway-suite helper is how one of
/// them ends up not cleaning up after itself.
func withTemporaryDefaults(_ body: (UserDefaults) -> Void) {
    let name = "com.moxspeak.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        Issue.record("could not open a temporary UserDefaults suite")
        return
    }
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    body(defaults)
}
