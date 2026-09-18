import Foundation

/// The build identity shown in the menu and logged at launch.
///
/// This exists because there is otherwise no way to tell which build is running. When the
/// owner reported the hotkeys failing on a second machine, the only way to find out what he
/// was actually running was to infer it from log lines — there was no version anywhere.
///
/// Three numbers, each answering a different question:
///   - `shortVersion` ("0.4.0") — a human-meaningful release, bumped deliberately when
///     something meaningful ships. Lives in the `VERSION` file at the repo root, not here.
///   - `buildNumber` (84) — the git commit count. Automatic and monotonic, so any two
///     builds order correctly even between deliberate version bumps. This is what
///     `build-app.sh` writes into `CFBundleVersion`, which macOS expects to be monotonic.
///   - `commitSHA` ("1dbb02b", or "1dbb02b-dirty") — the exact commit, which is the part
///     that actually matters when tracing a bug report back to code. `build-app.sh`
///     appends `-dirty` when the tree that built it had uncommitted changes, so a test
///     build built over a local edit is never mistaken for a real one.
///
/// Pure by construction: `read(bundle:)` is the only member that touches a `Bundle`, and
/// everything else — parsing, formatting, the dirty marker — is plain logic over three
/// optional values. That is deliberate: it is what makes the formatting testable without
/// standing up an `Info.plist`, and it is why the tests below exercise `AppVersion` values
/// built by hand rather than `AppVersion.read()`.
struct AppVersion: Equatable, Sendable {

    /// `CFBundleShortVersionString` — e.g. "0.4.0". `nil` when the key is absent or empty,
    /// which is the normal shape of a `.build` binary run straight from the command line:
    /// there is no `Info.plist` at all outside a bundle built by `build-app.sh`.
    let shortVersion: String?

    /// `CFBundleVersion` parsed as the git commit count. `nil` when the key is absent or
    /// is not a plain integer — a malformed value is treated exactly like a missing one
    /// rather than shown verbatim, since a garbled build number is worse than none.
    let buildNumber: Int?

    /// The custom `MoxSpeakCommitSHA` key `build-app.sh` writes. Carries its own
    /// `-dirty` suffix rather than a separate boolean flag — one field to read, and no way
    /// for a "dirty" bit to disagree with the SHA it is supposedly describing.
    let commitSHA: String?

    init(shortVersion: String?, buildNumber: Int?, commitSHA: String?) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.commitSHA = commitSHA
    }

    /// Reads what `build-app.sh` injected into the running app's `Info.plist`.
    ///
    /// A binary run out of `.build` during development — and the `.xctest` harness `swift
    /// test` runs under, where `Bundle.main` is the test runner, not this app — has none
    /// of these keys. `read()` reports that as three `nil`s rather than guessing; `display`
    /// is what turns that into something a human reads.
    static func read(bundle: Bundle = .main) -> AppVersion {
        let info = bundle.infoDictionary
        let shortVersion = (info?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let buildNumber = (info?["CFBundleVersion"] as? String).flatMap { Int($0) }
        let commitSHA = (info?["MoxSpeakCommitSHA"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return AppVersion(shortVersion: shortVersion, buildNumber: buildNumber, commitSHA: commitSHA)
    }

    /// True when the tree that produced this build had uncommitted changes at build time.
    /// Derived from the SHA's own suffix rather than stored separately — see `commitSHA`.
    var isDirty: Bool {
        commitSHA?.hasSuffix("-dirty") ?? false
    }

    /// The line shown in the menu and written to the launch log:
    /// `"0.4.0 (84) · 1dbb02b"`, or `"0.4.0 (84+) · 1dbb02b-dirty"` for an uncommitted
    /// build.
    ///
    /// Degrades field by field rather than all-or-nothing: a build with a version and a
    /// commit but a garbled build number still shows the version and the commit, because
    /// each of those is independently useful for tracing a bug report. Only a completely
    /// empty `AppVersion` — the unbundled, `.build`-during-development case — falls back
    /// to a fixed string, "dev build", so the row is never blank or, worse, an empty
    /// " · " that looks like something failed to load.
    var display: String {
        // An empty string is not a value any more than a missing key is — `.read()`
        // already normalizes that from a real Info.plist, but this treats the same rule
        // as part of `display`'s own contract rather than something only `.read()`'s
        // callers can rely on.
        let shortVersion = shortVersion.flatMap { $0.isEmpty ? nil : $0 }
        let commitSHA = commitSHA.flatMap { $0.isEmpty ? nil : $0 }

        var versionPart: String?
        if let shortVersion {
            versionPart = buildNumber.map { "\(shortVersion) (\($0)\(isDirty ? "+" : ""))" } ?? shortVersion
        } else if let buildNumber {
            versionPart = "(\(buildNumber)\(isDirty ? "+" : ""))"
        }

        var parts: [String] = []
        if let versionPart { parts.append(versionPart) }
        if let commitSHA { parts.append(commitSHA) }

        return parts.isEmpty ? "dev build" : parts.joined(separator: " · ")
    }

    /// One line for `AppLog` at launch, folded into the existing launch line rather than a
    /// line of its own — see `MoxSpeakAppDelegate.applicationDidFinishLaunching`.
    var logLine: String { "version \(display)" }
}
