import Foundation

/// A released version of MoxSpeak, and whether one is newer than another.
///
/// Separated from the network entirely, because the comparison is the part that can be
/// subtly wrong forever without anybody noticing. An update check that never offers an
/// update looks identical to one that has nothing to offer, and a check that offers the
/// version already installed looks like a bug in the app rather than in a comparison.
///
/// String comparison is the trap this exists to avoid. `"0.10.0" < "0.5.0"` is true for
/// strings and false for versions, and the day that matters is the day a tenth release
/// ships and every user quietly stops being told about updates.
public struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "1.2.3", "v1.2.3", "1.2" and "1". Anything else is nil.
    ///
    /// Tolerant about the leading `v` because git tags carry one and
    /// `CFBundleShortVersionString` does not, and the two are compared against each
    /// other. Tolerant about missing components because "1.2" plainly means 1.2.0.
    /// Intolerant about everything else: a pre-release suffix, a build number, trailing
    /// text. Refusing to parse is safe — the caller offers no update — while guessing is
    /// not.
    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        guard !value.isEmpty else { return nil }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0, part.allSatisfy(\.isNumber) else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
