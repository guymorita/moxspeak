import Foundation
import Testing
@testable import MoxSpeakApp

/// The automation surface. Anyone on the machine can call it, so what it accepts and what
/// it ignores are both part of the contract.
@Suite struct URLCommandTests {

    static func parse(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init)
    }

    @Test func theThreeActionsParse() {
        #expect(Self.parse("moxspeak://speak") == .speak)
        #expect(Self.parse("moxspeak://pause") == .pause)
        #expect(Self.parse("moxspeak://stop") == .stop)
        // Words people will reasonably reach for, mapped to the toggle they mean.
        #expect(Self.parse("moxspeak://toggle") == .pause)
        #expect(Self.parse("moxspeak://resume") == .pause)
    }

    /// `moxspeak://speak` puts the action in the host; `moxspeak:speak` puts it in the
    /// path. Both get typed, so both work.
    @Test func bothURLShapesWork() {
        #expect(Self.parse("moxspeak:speak") == .speak)
        #expect(Self.parse("moxspeak:///stop") == .stop)
        #expect(Self.parse("MoxSpeak://SPEAK") == .speak)
    }

    /// Launchers get the same fifteen seconds the media keys move by, without spending
    /// a global shortcut on it.
    @MainActor
    @Test func skippingMatchesTheMediaKeys() {
        #expect(Self.parse("moxspeak://back") == .skip(seconds: -15))
        #expect(Self.parse("moxspeak://rewind") == .skip(seconds: -15))
        #expect(Self.parse("moxspeak://forward") == .skip(seconds: 15))
        #expect(Self.parse("moxspeak://skip?seconds=30") == .skip(seconds: 30))
        #expect(Self.parse("moxspeak://skip?seconds=-45") == .skip(seconds: -45))
        // One skip distance, not two. The URL and the media key must agree.
        #expect(URLCommand.defaultSkip == NowPlayingController.skipSeconds)
        // Skipping acts on what is already playing, so it has no reason to wait.
        #expect(URLCommand.skip(seconds: -15).focusSettlingDelay == 0)
    }

    @Test func textCanBeSuppliedDirectly() {
        #expect(Self.parse("moxspeak://speak?text=hello%20there")
                == .speakText("hello there"))
        // Empty or whitespace-only text is not text; fall back to reading the selection
        // rather than speaking nothing and looking broken.
        #expect(Self.parse("moxspeak://speak?text=") == .speak)
        #expect(Self.parse("moxspeak://speak?text=%20%20") == .speak)
        // A query that is not `text` is ignored rather than guessed at.
        #expect(Self.parse("moxspeak://speak?voice=af_heart") == .speak)
    }

    /// Anything unrecognised does nothing at all. Guessing would mean a typo in somebody's
    /// script silently starting speech when they meant to stop it.
    @Test func unknownInputIsRefusedRatherThanGuessed() {
        for junk in ["moxspeak://", "moxspeak://spea", "moxspeak://quit",
                     "moxspeak://reset", "moxspeak://speaking", "moxspeak://play",
                     "https://speak", "moxspeek://speak", "moxspeak"] {
            #expect(Self.parse(junk) == nil,
                    Comment(rawValue: "\(junk) parsed as something"))
        }
    }

    /// A launcher is frontmost while it runs your script and its window is still going
    /// away. Reading the selection at that instant asks Raycast what Raycast has
    /// selected, which is nothing, and the user gets their clipboard instead of the
    /// paragraph they highlighted.
    @Test func onlyTheSelectionReadingCaseWaitsForFocus() {
        #expect(URLCommand.speak.focusSettlingDelay > 0)
        #expect(URLCommand.speakText("x").focusSettlingDelay == 0)
        #expect(URLCommand.pause.focusSettlingDelay == 0)
        #expect(URLCommand.stop.focusSettlingDelay == 0)
    }

    /// Never long enough to feel like lag.
    @Test func theWaitIsShort() {
        #expect(URLCommand.speak.focusSettlingDelay <= 0.4)
    }
}
