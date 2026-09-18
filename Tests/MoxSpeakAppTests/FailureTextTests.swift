import Testing
import Foundation
import MoxSpeakCore
@testable import MoxSpeakApp

// The other pure-logic corner of the app: turning a failure into the sentence the menu
// shows. Worth pinning because it is the place the project's central principle actually
// becomes visible — a chunk that failed while everything looked fine has exactly one
// chance to be noticed, and it is this string.

// MARK: - humanize: SpeechSession's stringified errors

@Test func transportFailuresShowTheUnderlyingMessage() {
    // This is verbatim what the app received with nothing listening on the port.
    let reason = #"transport("Could not connect to the server.")"#
    #expect(AppController.humanize(reason) == "Could not connect to the server.")
}

@Test func badResponseFailuresShowTheUnderlyingMessage() {
    let reason = #"badResponse("cannot decode 3 bytes as PCM")"#
    #expect(AppController.humanize(reason) == "cannot decode 3 bytes as PCM")
}

@Test func emptyAudioIsNamedAsTheSilentFailureItIs() {
    // HTTP 200 with no audio is *the* failure this project exists to make visible.
    #expect(AppController.humanize("emptyAudio") == "engine returned no audio")
}

@Test func shortAudioIsNamedPlainly() {
    let reason = "shortAudio(expected: 4.0, got: 1.2)"
    #expect(AppController.humanize(reason) == "engine returned truncated audio")
}

@Test func httpStatusKeepsTheCode() {
    let reason = #"httpStatus(code: 503, body: "upstream unavailable")"#
    #expect(AppController.humanize(reason) == "engine returned HTTP 503")
}

@Test func formatMismatchIsNamedPlainly() {
    #expect(AppController.humanize("formatMismatch(expected: ..., got: ...)")
            == "engine returned an unexpected audio format")
}

@Test func anUnrecognizedReasonIsPassedThroughRatherThanSwallowed() {
    // A reason nobody anticipated is still more useful on screen than a shrug, and
    // silently dropping it would be the exact behavior this app is built against.
    #expect(AppController.humanize("cancelled") == "cancelled")
    #expect(AppController.humanize("something nobody planned for")
            == "something nobody planned for")
}

@Test func humanizeNeverReturnsAnEmptyString() {
    // An empty status line is indistinguishable from no failure at all.
    for reason in ["", "transport()", #"transport("")"#, "emptyAudio", "weird"] {
        let result = AppController.humanize(reason)
        if reason.isEmpty {
            #expect(result.isEmpty, "an empty reason has nothing to say")
        } else {
            #expect(!result.isEmpty, "\(reason) produced an empty message")
        }
    }
}

@Test func humanizeIsDrivenByRealSpeechErrorDescriptions() {
    // Guards against the thing that actually breaks this: SpeechError's synthesized
    // description changing shape, leaving humanize matching a format that no longer
    // exists. These are generated from the real type, not typed out by hand.
    let cases: [(SpeechError, String)] = [
        (.emptyAudio, "engine returned no audio"),
        (.shortAudio(expected: 4.0, got: 1.0), "engine returned truncated audio"),
        (.httpStatus(code: 500, body: "boom"), "engine returned HTTP 500"),
        (.transport("Could not connect to the server."), "Could not connect to the server."),
        (.badResponse("unsupported audio format"), "unsupported audio format"),
    ]
    for (error, expected) in cases {
        // Exactly how SpeechSession builds the reason it stores on a failed chunk.
        let reason = "\(error)"
        #expect(AppController.humanize(reason) == expected,
                "\(reason) rendered as \(AppController.humanize(reason))")
    }
}

// MARK: - failureHeadline

@Test func aSingleChunkDocumentDoesNotCountChunksAtTheUser() {
    // "All 1 chunk failed" is how a machine talks.
    #expect(AppController.failureHeadline(failed: 1, of: 1) == "Speech failed")
    #expect(AppController.failureHeadline(failed: 0, of: 0) == "Speech failed")
}

@Test func totalFailureSaysSo() {
    #expect(AppController.failureHeadline(failed: 5, of: 5) == "All 5 chunks failed")
}

@Test func partialFailureGivesBothNumbers() {
    // The count matters: two failed chunks out of forty is a glitch, forty out of forty
    // is a broken engine, and the user should be able to tell which they have.
    #expect(AppController.failureHeadline(failed: 2, of: 40) == "2 of 40 chunks failed")
}

// MARK: - Now Playing titles

@Test func shortTextIsItsOwnNowPlayingTitle() {
    #expect(NowPlayingController.title(for: "Hello there.") == "Hello there.")
}

@Test func nowPlayingTitlesAreFlattenedToOneLine() {
    // Control Center shows a single line; embedded newlines turn into a mangled title.
    let title = NowPlayingController.title(for: "First line.\n\nSecond   line.\t Third.")
    #expect(title == "First line. Second line. Third.")
    #expect(!title.contains("\n"))
}

@Test func longTextIsTruncatedWithAnEllipsis() {
    let text = String(repeating: "word ", count: 100)
    let title = NowPlayingController.title(for: text, limit: 20)
    #expect(title.count <= 21, "20 characters plus the ellipsis")
    #expect(title.hasSuffix("…"))
    #expect(!title.hasSuffix(" …"), "the ellipsis must not float off a trailing space")
}

@Test func emptyTextStillGetsATitle() {
    // An untitled Now Playing entry looks like a system glitch rather than this app.
    #expect(NowPlayingController.title(for: "   \n  ") == "Clipboard")
}
