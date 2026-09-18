import Testing
import Foundation
@testable import MoxSpeakApp

// AppVersion's parsing and formatting are the pure half of build-identity reporting — the
// other half is `build-app.sh` injecting the three plist keys, and `.read()` doing the
// reading, neither of which is tested here (see the type's own doc comment). Every case
// below builds an AppVersion by hand, exactly as `.read()` would have from a real or absent
// Info.plist, and asserts on `display`/`logLine`/`isDirty`.

// MARK: - Well-formed

@Test func aFullyFormedVersionRendersTheAgreedString() {
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: 84, commitSHA: "1dbb02b")
    #expect(version.display == "0.4.0 (84) · 1dbb02b")
    #expect(version.isDirty == false)
}

@Test func logLineWrapsDisplayWithAConstantPrefix() {
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: 84, commitSHA: "1dbb02b")
    #expect(version.logLine == "version 0.4.0 (84) · 1dbb02b")
}

// MARK: - Dirty marker

@Test func aDirtySHASuffixMarksTheBuildNumberAndIsReportedAsDirty() {
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: 84, commitSHA: "1dbb02b-dirty")
    #expect(version.isDirty == true)
    #expect(version.display == "0.4.0 (84+) · 1dbb02b-dirty")
}

@Test func aCleanSHADoesNotGetAPlus() {
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: 84, commitSHA: "1dbb02b")
    #expect(version.display.contains("+") == false)
}

@Test func dirtyWithNoBuildNumberStillMarksTheVersion() {
    // Malformed CFBundleVersion alongside a genuinely dirty SHA: the "+" belongs on the
    // build number when there is one, but its absence should not swallow the dirty SHA.
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: nil, commitSHA: "1dbb02b-dirty")
    #expect(version.display == "0.4.0 · 1dbb02b-dirty")
}

// MARK: - Missing and malformed input degrade sensibly

@Test func whollyAbsentVersionInfoReadsAsDevBuild() {
    // The shape `.read()` sees for a binary run straight out of `.build`, or under `swift
    // test`, where Bundle.main has no Info.plist at all. Must not crash, and must not show
    // something that looks like a parsing failure — "dev build" says plainly what it is.
    let version = AppVersion(shortVersion: nil, buildNumber: nil, commitSHA: nil)
    #expect(version.display == "dev build")
    #expect(version.isDirty == false)
}

@Test func emptyShortVersionIsTreatedAsAbsent() {
    // .read() itself maps "" to nil (CFBundleShortVersionString should never be empty,
    // but an empty string is not a version either); this pins the same rule at the
    // formatting layer for a value built directly, the way a test double would.
    let version = AppVersion(shortVersion: "", buildNumber: nil, commitSHA: nil)
    #expect(version.display == "dev build")
}

@Test func versionAloneWithNoBuildNumberOrSHAStillShowsSomething() {
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: nil, commitSHA: nil)
    #expect(version.display == "0.4.0")
}

@Test func buildNumberAloneWithNoVersionIsStillShownParenthesized() {
    let version = AppVersion(shortVersion: nil, buildNumber: 84, commitSHA: nil)
    #expect(version.display == "(84)")
}

@Test func shaAloneIsStillShownAndIsTheMostImportantSingleField() {
    // The SHA is "the part that matters in a bug report" per the spec; a build that has
    // lost its version and build number but kept its SHA should still be traceable.
    let version = AppVersion(shortVersion: nil, buildNumber: nil, commitSHA: "1dbb02b")
    #expect(version.display == "1dbb02b")
}

@Test func versionAndSHAWithNoBuildNumberOmitTheParens() {
    let version = AppVersion(shortVersion: "0.4.0", buildNumber: nil, commitSHA: "1dbb02b")
    #expect(version.display == "0.4.0 · 1dbb02b")
}

// MARK: - .read() against a bundle with no Info.plist keys

@Test func readAgainstTheTestBundleDegradesToDevBuild() {
    // Bundle.main inside `swift test` is the .xctest harness: no CFBundleShortVersionString,
    // no CFBundleVersion, no MoxSpeakCommitSHA. This is the actual code path `.read()`
    // takes in this test run, not a simulation of it.
    let version = AppVersion.read()
    #expect(version.shortVersion == nil)
    #expect(version.buildNumber == nil)
    #expect(version.commitSHA == nil)
    #expect(version.display == "dev build")
}
