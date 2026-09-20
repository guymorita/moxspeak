import Foundation
import Testing
@testable import MoxSpeakApp

/// The welcome window says "no text you select or copy ever leaves your Mac", and the
/// website will say it too. This is the suite that makes that a fact rather than an
/// intention — `TelemetryPayload` is the only thing standing between a careless call
/// site and a sentence from somebody's document arriving in a log.
@Suite struct TelemetryPayloadTests {

    // MARK: - The promise

    /// The failure this exists to prevent, written as the mistake somebody will actually
    /// make: attaching the thing being spoken, under a plausible-looking name.
    @Test func theTextBeingSpokenCannotBeAttachedUnderAnyName() {
        let secret = "Dear Rachel, the results of your biopsy came back on Tuesday."
        let attempts: [String: Any] = [
            "text": secret,
            "content": secret,
            "selection": secret,
            "clipboard": secret,
            "message": secret,
            "body": secret,
            "reason": secret,          // an allowed key — but prose, so still dropped
            "failed_app": secret,
        ]
        let clean = TelemetryPayload.sanitize(attempts)
        #expect(clean.isEmpty, Comment(rawValue: "leaked \(clean.keys.sorted())"))
        for value in clean.values {
            #expect((value as? String)?.contains("biopsy") != true)
        }
    }

    /// An exact character count is close to a fingerprint for a particular document, so
    /// only the band is ever sent.
    @Test func onlyACoarseLengthBandIsEverReported() {
        #expect(TelemetryPayload.lengthBucket(characters: 0) == "xs")
        #expect(TelemetryPayload.lengthBucket(characters: 199) == "xs")
        #expect(TelemetryPayload.lengthBucket(characters: 200) == "s")
        #expect(TelemetryPayload.lengthBucket(characters: 4_999) == "m")
        #expect(TelemetryPayload.lengthBucket(characters: 20_000) == "xl")
        #expect(TelemetryPayload.lengthBucket(characters: -1) == "unknown")

        // No bucket may be the number itself.
        for count in [0, 37, 200, 1_234, 50_000] {
            #expect(TelemetryPayload.lengthBucket(characters: count) != "\(count)")
        }
    }

    // MARK: - The allowlist

    @Test func onlyAllowlistedKeysSurvive() {
        let clean = TelemetryPayload.sanitize([
            "tier": "ax",
            "voice": "af_bella",
            "speed": 1.25,
            "accessibility": true,
            "unexpected_key": "harmless",
            "user_email": "someone@example.com",
        ])
        #expect(Set(clean.keys) == ["tier", "voice", "speed", "accessibility"])
    }

    /// Anything that is not a plain scalar is dropped rather than stringified. Turning an
    /// arbitrary object into text via `description` is exactly how a document ends up in
    /// a field that was meant to hold an enum.
    @Test func compoundValuesAreDroppedNotStringified() {
        let clean = TelemetryPayload.sanitize([
            "tier": ["ax", "clipboard"],
            "voice": ["name": "af_bella"],
            "reason": URL(string: "file:///Users/someone/Documents/taxes.pdf")!,
        ])
        #expect(clean.isEmpty, Comment(rawValue: "kept \(clean)"))
    }

    @Test func longAndProseLikeValuesAreDropped() {
        // Spaces are the giveaway: every legitimate value is one token.
        #expect(TelemetryPayload.sanitize(["tier": "ax and then clipboard"]).isEmpty)
        // Over the length cap.
        let long = String(repeating: "a", count: TelemetryPayload.maximumValueLength + 1)
        #expect(TelemetryPayload.sanitize(["voice": long]).isEmpty)
        // At the cap it is fine.
        let atCap = String(repeating: "a", count: TelemetryPayload.maximumValueLength)
        #expect(TelemetryPayload.sanitize(["voice": atCap]).count == 1)
        #expect(TelemetryPayload.sanitize(["voice": ""]).isEmpty)
    }

    @Test func realAttributesPassThroughUnchanged() {
        let clean = TelemetryPayload.sanitize([
            "tier": "ax",
            "length_bucket": "m",
            "voice": "am_michael",
            "speed": 1.25,
            "accessibility": true,
            "failed_app": "com.googlecode.iterm2",
            "app_version": "0.5.0",
            "mac_model": "Mac14,12",
            "progress_bucket": "75-99",
        ])
        #expect(clean.count == 9)
        #expect(clean["tier"] as? String == "ax")
        #expect(clean["speed"] as? Double == 1.25)
        #expect(clean["accessibility"] as? Bool == true)
        #expect(clean["failed_app"] as? String == "com.googlecode.iterm2")
    }

    // MARK: - Progress

    @Test func progressIsReportedInQuarters() {
        #expect(TelemetryPayload.progressBucket(played: 0, total: 100) == "0-25")
        #expect(TelemetryPayload.progressBucket(played: 30, total: 100) == "25-50")
        #expect(TelemetryPayload.progressBucket(played: 80, total: 100) == "75-99")
        #expect(TelemetryPayload.progressBucket(played: 100, total: 100) == "100")
        #expect(TelemetryPayload.progressBucket(played: 5, total: 0) == "unknown")
        #expect(TelemetryPayload.progressBucket(played: -1, total: 10) == "unknown")
        // Playing past the end (rate changes, rounding) still reads as finished.
        #expect(TelemetryPayload.progressBucket(played: 120, total: 100) == "100")
    }

    // MARK: - The list itself

    /// A new event or attribute should be a deliberate act, so the list is asserted. If
    /// this fails because you added something, read what you added and ask whether it
    /// belongs — then update the test.
    @Test func theSurfaceAreaIsSmallAndDeclared() {
        #expect(TelemetryPayload.allowedKeys.count == 15)
        #expect(TelemetryEvent.allCases.count == 11)

        // Nothing in the allowlist may be named for content.
        for key in TelemetryPayload.allowedKeys {
            for forbidden in ["text", "content", "selection", "clipboard", "body",
                              "message", "title", "url", "path", "document"] {
                #expect(key != forbidden, Comment(rawValue: "\(key) names content"))
            }
        }
        // Event names are stable wire identifiers: lowercase, underscored, no spaces.
        for event in TelemetryEvent.allCases {
            #expect(event.rawValue == event.rawValue.lowercased())
            #expect(!event.rawValue.contains(" "))
        }
    }
}
