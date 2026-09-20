import Testing
@testable import MoxSpeakCore

/// The comparison an update check rests on. It can be wrong forever without anybody
/// noticing: a check that never offers an update looks exactly like one that has nothing
/// to offer.
@Suite struct ReleaseVersionTests {

    /// The bug this type exists to prevent. As strings, "0.10.0" sorts BEFORE "0.5.0",
    /// so a naive comparison stops telling anyone about updates on the day a tenth
    /// release ships, and keeps working perfectly for every release before that.
    @Test func tenComesAfterFiveNotBeforeIt() {
        let five = ReleaseVersion("0.5.0")!
        let ten = ReleaseVersion("0.10.0")!
        #expect(ten > five)
        #expect("0.10.0" < "0.5.0", "the string comparison this is guarding against")

        #expect(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
        #expect(ReleaseVersion("0.5.10")! > ReleaseVersion("0.5.9")!)
    }

    @Test func parsesTheFormsThatActuallyOccur() {
        // Git tags carry a v, CFBundleShortVersionString does not, and the two are
        // compared against each other.
        #expect(ReleaseVersion("v0.5.0") == ReleaseVersion("0.5.0"))
        #expect(ReleaseVersion("0.5") == ReleaseVersion("0.5.0"))
        #expect(ReleaseVersion("2") == ReleaseVersion("2.0.0"))
        #expect(ReleaseVersion("  0.5.0  ") == ReleaseVersion("0.5.0"))
        #expect(ReleaseVersion("0.5.0")?.description == "0.5.0")
    }

    /// Refusing to parse is safe, because the caller then offers no update. Guessing is
    /// not: a version read as something it is not can nag somebody forever about an
    /// update they already have.
    @Test func refusesAnythingItCannotBeSureOf() {
        for junk in ["", "v", "latest", "0.5.0-beta", "0.5.0+build7", "1.2.3.4",
                     "0..1", "-1.0.0", "1.0.x", "nightly", "０.５.０"] {
            #expect(ReleaseVersion(junk) == nil,
                    Comment(rawValue: "parsed \(junk), which it should not have"))
        }
    }

    @Test func orderingIsTotalAndSane() {
        let ordered = ["0.0.1", "0.1.0", "0.5.0", "0.5.1", "0.10.0", "1.0.0", "10.0.0"]
            .map { ReleaseVersion($0)! }
        #expect(ordered == ordered.sorted())
        #expect(ReleaseVersion("0.5.0")! == ReleaseVersion("0.5.0")!)
        #expect(!(ReleaseVersion("0.5.0")! < ReleaseVersion("0.5.0")!))
    }
}
