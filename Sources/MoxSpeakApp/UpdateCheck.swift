import Foundation
import MoxSpeakCore

/// Asks GitHub whether a newer MoxSpeak has been released.
///
/// ## Why this exists, and why it is this small
///
/// Without it, whatever somebody installs is what they run forever. MoxSpeak is given
/// away to people who will not go looking for a changelog, so a fix that cannot reach
/// them is a fix that did not happen.
///
/// What it deliberately is not is Sparkle. Sparkle downloads, verifies and installs
/// updates in place, and costs an EdDSA keypair, an appcast to host and keep correct, and
/// a new way for the app to break on somebody else's machine. This asks one public
/// endpoint for a version string, compares it, and at most puts a row in a menu that
/// opens a download page. The user does the rest, exactly as they did the first time.
///
/// ## Rules it follows
///
/// - **Never blocks anything.** It runs after launch, off the main actor, and a failure
///   is silent. No alert, no dialog, no retry storm. Somebody with no network, behind a
///   proxy, or on a plane must not be told about it.
/// - **Once per launch, and at most once a day.** A menu bar app can run for weeks, so
///   "on launch" alone would mean never for the people most likely to be out of date; a
///   check every time the menu opens would be rude to GitHub and to their battery.
/// - **Never downgrades or nags.** Only a strictly greater version is reported, so a
///   build from source that is ahead of the latest release stays quiet.
/// - **Sends nothing.** It is a GET of a public JSON document. No identifier, no version
///   in a query string, nothing that makes it a telemetry channel by the back door.
struct UpdateCheck: Sendable {

    /// The public releases endpoint. Unauthenticated, rate-limited to 60 requests an hour
    /// per IP, which one check a day per user is in no danger of approaching.
    static let endpoint = URL(string: "https://api.github.com/repos/guymorita/moxspeak/releases/latest")!

    static let downloadPage = URL(string: "https://guymorita.github.io/moxspeak/")!

    /// How long to wait before asking again. Long enough that a menu bar app left running
    /// for a fortnight still learns about a release, short enough to be invisible.
    static let interval: TimeInterval = 24 * 60 * 60

    /// Just enough of GitHub's release JSON to answer the question.
    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
        }
    }

    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        // No cookies, no credentials, no cache that could outlive the process.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// The newest released version, or nil if that cannot be established right now.
    ///
    /// Drafts and pre-releases are skipped: `releases/latest` already excludes them, and
    /// the check is belt and braces against a future where that changes.
    func latestRelease() async -> ReleaseVersion? {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MoxSpeak", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease
        else { return nil }
        return ReleaseVersion(release.tagName)
    }

    /// The version to tell the user about, or nil when there is nothing to say.
    ///
    /// Pure given its inputs so the interesting cases — same version, older remote,
    /// unparsable local version — are testable without a network.
    static func update(installed: String?, latest: ReleaseVersion?) -> ReleaseVersion? {
        guard let latest,
              let installed = installed.flatMap(ReleaseVersion.init),
              latest > installed
        else { return nil }
        return latest
    }
}
