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

    private static var isRunning = false

    // MARK: - Lifecycle

    /// Starts crash reporting and usage events, or does nothing at all if the user has
    /// switched them off.
    static func start(settings: Settings) {
        guard settings.isTelemetryEnabled, !isRunning else { return }
        let installID = settings.installID()
        let version = AppVersion.read()
        let release = version.shortVersion ?? "0.0.0"

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
            options.beforeBreadcrumb = { _ in nil }
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

    // MARK: - Scrubbing

    /// The last gate before an event leaves. Everything here is already supposed to be
    /// off; doing it again means a future SDK default that starts collecting something
    /// cannot start shipping it without someone changing this file.
    private static func scrub(_ event: Event) -> Event? {
        event.request = nil
        if let user = event.user {
            user.ipAddress = nil
            user.email = nil
            user.username = nil
            user.name = nil
            user.data = nil
        }
        event.breadcrumbs = nil
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
