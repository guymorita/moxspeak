import Testing
import Sentry
@testable import MoxSpeakApp

/// Sentry calls `beforeSend` and `beforeBreadcrumb` on whichever queue produced the
/// event, never on the main actor. `Telemetry` is a `@MainActor` enum, so anything those
/// closures reach has to be `nonisolated` — under Swift 5 mode the compiler permits the
/// cross-actor access and the Swift 6 runtime on macOS 26+ aborts the process for it.
/// That shipped in 0.6.0 and 0.7.1 and crashed on every launch that completed an update
/// check, on machines newer than the one it was developed on.
///
/// This suite is deliberately **not** `@MainActor`. Its value is mostly at compile time:
/// if `scrub` stops being `nonisolated`, these calls stop building.
@Suite struct TelemetryIsolationTests {

    @Test func scrubIsCallableOffTheMainActor() {
        let event = Event()
        #expect(Telemetry.scrub(event) != nil)
    }

    @Test func scrubKeepsBreadcrumbsBecauseThatIsWhatMakesACrashReadable() {
        let event = Event()
        let crumb = Breadcrumb()
        crumb.category = Telemetry.breadcrumbCategory
        crumb.message = "first sound"
        event.breadcrumbs = [crumb]

        let scrubbed = Telemetry.scrub(event)

        #expect(scrubbed?.breadcrumbs?.count == 1)
        #expect(scrubbed?.breadcrumbs?.first?.message == "first sound")
    }

    @Test func scrubStillStripsEverythingIdentifying() {
        let event = Event()
        let user = User()
        user.userId = "anonymous-install-id"
        user.email = "someone@example.com"
        user.username = "someone"
        user.name = "Some One"
        user.ipAddress = "203.0.113.7"
        event.user = user
        event.serverName = "someones-macbook.local"

        let scrubbed = Telemetry.scrub(event)

        #expect(scrubbed?.user?.email == nil)
        #expect(scrubbed?.user?.username == nil)
        #expect(scrubbed?.user?.name == nil)
        #expect(scrubbed?.user?.ipAddress == nil)
        #expect(scrubbed?.serverName == nil)
        // The anonymous install id is the one thing that must survive: without it every
        // crash looks like a different person and "one user hit this 40 times" is
        // indistinguishable from "40 users hit this once".
        #expect(scrubbed?.user?.userId == "anonymous-install-id")
    }
}
