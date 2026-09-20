import Testing
@testable import MoxSpeakApp
@testable import MoxSpeakCore

/// What the app decides to tell the user, given a local version and whatever GitHub said.
@Suite struct UpdateCheckTests {

    @Test func offersOnlyAStrictlyNewerVersion() {
        let latest = ReleaseVersion("0.6.0")!
        #expect(UpdateCheck.update(installed: "0.5.0", latest: latest) == latest)
        #expect(UpdateCheck.update(installed: "0.6.0", latest: latest) == nil)
    }

    /// A build from source is routinely ahead of the newest release. Telling that person
    /// to "update" to an older version is worse than saying nothing.
    @Test func neverOffersToMoveBackwards() {
        #expect(UpdateCheck.update(installed: "0.7.0",
                                   latest: ReleaseVersion("0.6.0")!) == nil)
        #expect(UpdateCheck.update(installed: "0.10.0",
                                   latest: ReleaseVersion("0.9.9")!) == nil)
    }

    /// Every way the check can fail has to end in silence, not in a wrong answer. A menu
    /// bar app on a plane must not sprout an update row it invented.
    @Test func anythingUnknownMeansSayNothing() {
        #expect(UpdateCheck.update(installed: "0.5.0", latest: nil) == nil)
        #expect(UpdateCheck.update(installed: nil,
                                   latest: ReleaseVersion("9.9.9")!) == nil)
        // An unparsable local version, e.g. a bundle with no version at all.
        #expect(UpdateCheck.update(installed: "dev",
                                   latest: ReleaseVersion("9.9.9")!) == nil)
        #expect(UpdateCheck.update(installed: "", latest: ReleaseVersion("1.0.0")!) == nil)
    }

    /// The endpoint is a public document and the request must stay a plain GET of it.
    /// If a version or an identifier ever ends up in that URL, the update check has
    /// quietly become a telemetry channel that no privacy switch turns off.
    @Test func theEndpointCarriesNothingAboutTheUser() {
        let url = UpdateCheck.endpoint.absoluteString
        #expect(url == "https://api.github.com/repos/guymorita/moxspeak/releases/latest")
        #expect(!url.contains("?"))
        #expect(UpdateCheck.interval >= 60 * 60, "checking more than hourly is rude")
    }
}
