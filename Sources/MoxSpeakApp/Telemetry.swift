import AppKit
import Foundation
import Sentry

/// Everything MoxSpeak sends off this machine, in one file.
///
/// If you are auditing this app, this is the file to read. Nothing else calls Sentry, and
/// nothing reaches the network except through `record` and the crash reporter configured
/// in `start`. What may be attached to an event is decided by `TelemetryPayload`, which is
/// a pure allowlist with its own tests.
///
/// ## What is sent
///
/// - **Crashes.** Stack traces, the OS and hardware generation, the app version.
/// - **A short list of usage events**, as structured logs. The full list of events and of
///   every attribute any of them may carry is `TelemetryEvent` and
///   `TelemetryPayload.allowedKeys`.
///
/// ## What is not, and why it cannot be by accident
///
/// - **`sendDefaultPii` is false.** Sentry's own quickstart sets it true; true attaches
///   the user's IP address and username. Neither is any of our business.
/// - **Breadcrumbs are dropped wholesale.** The SDK records UI and system activity
///   automatically, and those records can carry window titles and menu item text — which
///   on a machine running MoxSpeak means the name of whatever somebody was reading.
///   There is no filter here that would be safe, so the answer is none at all.
/// - **The user is a random UUID** made on this machine and cleared by "Reset MoxSpeak…".
///   It is not derived from hardware, so it cannot be correlated across a reinstall or
///   with any other product.
/// - **`beforeSend` is a last gate**, not the only one. It strips the IP and any user
///   fields the SDK filled in on its own, so a future SDK default that starts collecting
///   something new does not silently start shipping it.
/// - **The text being spoken is never an attribute**, and could not become one: the
///   allowlist has no key for it, and anything not on the list is dropped rather than
///   renamed or truncated.
///
/// ## Consent
///
/// On by default, stated on the welcome window, switchable under Advanced. When the
/// switch is off the SDK is never started — not started-and-filtered — so nothing is
/// collected, queued, or written to disk to be sent later.
@MainActor
enum Telemetry {

    /// Public by design. A Sentry DSN is a write-only ingest key: it can submit events to
    /// this project and can do nothing else — not read them, not change settings. It ships
    /// inside every copy of the app regardless, so keeping it out of a public repo would
    /// be theatre rather than security.
    private static let dsn =
        "https://9a14cd510ce767ced5caed0b8baf3963@o4511264714915840.ingest.us.sentry.io/4512119819141120"

    /// The only breadcrumb category that survives `beforeBreadcrumb`. Anything the SDK
    /// records on its own carries a different one and is dropped.
    /// `nonisolated` because the SDK's filter has to read it from whatever queue built
    /// the breadcrumb. It is an immutable String, so there is nothing to protect; leaving
    /// it main-actor isolated is what made the filter closure a cross-actor access and
    /// aborted the process on macOS 26+.
    nonisolated static let breadcrumbCategory = "moxspeak"

    private static var isRunning = false

    // MARK: - Lifecycle

    /// Starts crash reporting and usage events, or does nothing at all if the user has
    /// switched them off.
    static func start(settings: Settings) {
        guard settings.isTelemetryEnabled, !isRunning else { return }
        let installID = settings.installID()
        let version = AppVersion.read()
        let release = version.shortVersion ?? "0.0.0"
        // Read here, on the main actor, and captured as a plain value. The closures below
        // belong to the SDK and it calls them on whichever queue produced the event, so
        // nothing inside them may touch this @MainActor type. See `beforeBreadcrumb`.
        let ourCategory = Self.breadcrumbCategory

        SentrySDK.start { options in
            options.dsn = dsn
            // Off by default and never shipped on: Sentry's own debug output is verbose
            // and goes to stdout, which an LSUIElement app has nowhere useful to put. It
            // exists because "is anything actually being sent" is otherwise unanswerable
            // from outside — the SDK swallows transport failures by design, so a wrong
            // DSN, a proxy, or a feature that silently never flushes all look identical
            // to a quiet week.
            //   MOXSPEAK_SENTRY_DEBUG=1 MoxSpeak.app/Contents/MacOS/MoxSpeak
            options.debug = ProcessInfo.processInfo.environment["MOXSPEAK_SENTRY_DEBUG"] == "1"
            options.releaseName = "moxspeak@\(release)"
            // A dev build reports as such so local crashes never pollute what real users hit.
            let isDevelopment = version.shortVersion == nil || version.isDirty
            options.environment = isDevelopment ? "development" : "production"

            // Usage events ride the structured-log channel rather than being captured as
            // messages: a message becomes an "issue", and a few hundred healthy launches
            // a day would bury the crashes this is actually for.
            options.enableLogs = true

            // See the file comment. Each of these is a deliberate no.
            options.sendDefaultPii = false

            // The SDK's automatic breadcrumbs are off, and a filter drops anything that
            // is not ours even if a future default turns them back on.
            //
            // Dropping every breadcrumb, which is what this used to do, bought privacy at
            // the cost of the one thing that makes a crash report actionable: what
            // happened in the seconds before it. Automatic tracking is the part that is
            // unsafe — it records window titles and menu text, which on a machine running
            // MoxSpeak is the name of whatever somebody was reading. Our own breadcrumbs
            // carry no content at all, only which code path ran.
            options.enableAutoBreadcrumbTracking = false

            // Swizzling off, and the three integrations that ride on it off by name.
            //
            // `enableAutoBreadcrumbTracking = false` does not cover these: network
            // tracking is a separate integration that swizzles URLSession, and it kept
            // recording a breadcrumb every time a request finished — including the
            // update check, on every launch. Two consequences, one of them fatal:
            //
            // 1. The breadcrumb was built on CFNetwork's delegate queue, which is what
            //    called `beforeBreadcrumb` off the main actor. See below.
            // 2. A request breadcrumb carries the URL, which is automatic collection of
            //    exactly the kind this app promises not to do.
            //
            // Nothing here is wanted. The app makes one network call, it is ours, and we
            // record it ourselves if we want it recorded.
            options.enableSwizzling = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false

            // `ourCategory`, not `Self.breadcrumbCategory`. Sentry calls this on whatever
            // queue produced the breadcrumb, and `Telemetry` is @MainActor, so reading a
            // static of it from here is a cross-actor access. Under Swift 5 mode the
            // compiler allows it; the Swift 6 *runtime* on macOS 26 and later checks it
            // anyway and aborts the process — `_swift_task_checkIsolatedSwift` ->
            // `dispatch_assert_queue` -> SIGTRAP. It never fired on macOS 14 or 15, which
            // is why this shipped: the crash reports came from other people's machines.
            options.beforeBreadcrumb = { crumb in
                crumb.category == ourCategory ? crumb : nil
            }
            // Same rule: `scrub` is nonisolated precisely so this is safe. beforeSend runs
            // on the SDK's own queue, and it runs while reporting a crash — the one moment
            // a second crash is least welcome.
            options.beforeSend = { event in scrub(event) }
            options.beforeSendLog = { log in log }

            // Sessions are start/stop counts with no content, and they are where "how
            // many people actually use this" comes from.
            options.enableAutoSessionTracking = true
        }

        SentrySDK.configureScope { scope in
            // id and nothing else: no email, no username, no IP.
            let user = User()
            user.userId = installID
            scope.setUser(user)
            scope.setTag(value: release, key: "app_version")
            scope.setTag(value: systemVersion(), key: "macos")
            scope.setTag(value: hardwareModel(), key: "mac_model")
        }

        isRunning = true
        // A menu bar app is usually quit rather than closed, and the SDK batches. Without
        // an explicit flush at exit, the last session's events can die with the process.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in SentrySDK.flush(timeout: 2) }

        AppLog.write("telemetry: on — anonymous id \(installID.prefix(8))…, "
                     + "crash reports and \(TelemetryEvent.allCases.count) usage events")
    }

    /// Turns reporting off for good, or back on.
    ///
    /// Off closes the SDK rather than muting it, so nothing is buffered on disk waiting
    /// for a future launch to send. On cannot take effect until the next launch — Sentry
    /// has no supported restart-in-place — and says so rather than pretending.
    static func setEnabled(_ enabled: Bool, settings: Settings) {
        settings.isTelemetryEnabled = enabled
        if enabled {
            AppLog.write("telemetry: switched on — takes effect at the next launch")
        } else {
            if isRunning {
                record(.telemetryDisabled)
                SentrySDK.close()
                isRunning = false
            }
            AppLog.write("telemetry: switched off — nothing further is collected or sent")
        }
    }

    // MARK: - Events

    /// Reports one event. Attributes not on `TelemetryPayload.allowedKeys`, and values
    /// that do not look like the short tokens this is for, are dropped here.
    static func record(_ event: TelemetryEvent, _ attributes: [String: Any] = [:]) {
        guard isRunning else { return }
        SentrySDK.logger.info(event.rawValue,
                              attributes: TelemetryPayload.sanitize(attributes))
    }

    /// Proves the whole path end to end: start, record, flush, and say what happened.
    ///
    /// Exists because "is telemetry actually working" was unanswerable for an afternoon.
    /// The SDK is built to fail quietly — a wrong DSN, a proxy, a feature that never
    /// flushes, and a genuinely quiet week all look identical from the outside — so the
    /// only honest way to know is to send something on purpose and wait for the answer.
    ///
    ///     MOXSPEAK_TELEMETRY_TEST=1 MoxSpeak.app/Contents/MacOS/MoxSpeak
    static func runSelfTestIfAsked(settings: Settings) {
        guard ProcessInfo.processInfo.environment["MOXSPEAK_TELEMETRY_TEST"] == "1"
        else { return }

        print("telemetry self-test: running=\(isRunning), enabled=\(settings.isTelemetryEnabled)")
        guard isRunning else {
            print("telemetry self-test: SDK not started, nothing to test")
            exit(1)
        }

        // A message rather than a log line: messages take the event pipeline, which is
        // the one crash reports use and the one the debug transport narrates.
        let id = SentrySDK.capture(message: "moxspeak telemetry self-test")
        print("telemetry self-test: captured event \(id)")

        record(.appLaunched, ["app_version": "self-test", "engine": "native"])
        print("telemetry self-test: recorded a usage event")

        // flush is void and blocks up to the timeout, so the elapsed time is the signal:
        // a full 10 seconds means nothing drained.
        let start = Date()
        SentrySDK.flush(timeout: 10)
        print(String(format: "telemetry self-test: flush took %.2fs", Date().timeIntervalSince(start)))
        exit(0)
    }

    /// Records what the app just did, for the crash report that may follow.
    ///
    /// Never content. `message` is a fixed string chosen at the call site, and anything
    /// variable goes through the same allowlist events do, so a breadcrumb cannot become
    /// the back door through which the text being read escapes.
    static func note(_ message: String, _ attributes: [String: Any] = [:]) {
        guard isRunning else { return }
        let crumb = Breadcrumb(level: .info, category: breadcrumbCategory)
        crumb.message = message
        let clean = TelemetryPayload.sanitize(attributes)
        if !clean.isEmpty { crumb.data = clean }
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Facts about the session that a crash report should carry. Updated as they change,
    /// so a report says which engine and voice were in use rather than only which build.
    static func setContext(engine: String, voice: String, accessibility: Bool) {
        guard isRunning else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: engine, key: "engine")
            scope.setTag(value: voice, key: "voice")
            scope.setTag(value: accessibility ? "granted" : "not_granted",
                         key: "accessibility")
        }
    }

    // MARK: - Scrubbing

    /// The last gate before an event leaves. Everything here is already supposed to be
    /// off; doing it again means a future SDK default that starts collecting something
    /// cannot start shipping it without someone changing this file.
    /// `nonisolated` is load-bearing: the SDK calls this from `beforeSend`, on its own
    /// queue. Nothing in the body touches actor-isolated state, so there is nothing to
    /// hop for, and hopping is not an option anyway — `beforeSend` is synchronous.
    nonisolated static func scrub(_ event: Event) -> Event? {
        event.request = nil
        if let user = event.user {
            user.ipAddress = nil
            user.email = nil
            user.username = nil
            user.name = nil
            user.data = nil
        }
        // Breadcrumbs are deliberately *kept*. This line used to clear them, from when
        // every breadcrumb was dropped at the source; once `beforeBreadcrumb` started
        // admitting our own, clearing here quietly threw away the only record of what the
        // app was doing before it died, which is the whole reason for collecting them.
        // What survives to this point is ours by construction: a fixed message chosen at
        // the call site plus allowlisted data. No automatic breadcrumb can reach here —
        // swizzling is off and the category filter runs first.
        event.serverName = nil
        return event
    }

    // MARK: - Machine facts

    static func systemVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The hardware generation, e.g. "Mac14,12". A model identifier shared by every unit
    /// of that machine — not a serial number, and not unique to anybody.
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        // sysctl returns a C string, so the buffer ends in a NUL that must not become
        // part of the Swift string — a trailing \0 in a tag is invisible in a log and
        // makes two identical model names compare unequal.
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? "unknown" : text
    }
}
