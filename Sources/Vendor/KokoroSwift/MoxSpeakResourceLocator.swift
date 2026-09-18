import Foundation

/// **MoxSpeak addition, not upstream.** Finds this target's SwiftPM resource bundle in a
/// place a signed `.app` is allowed to keep it.
///
/// SwiftPM generates `Bundle.module` as
/// `Bundle(path: Bundle.main.bundleURL.appendingPathComponent("MoxSpeak_KokoroSwift.bundle"))`
/// with a hardcoded absolute `.build` path as the fallback. For an app bundle
/// `Bundle.main.bundleURL` is `MoxSpeak.app` itself, so that first path asks for a
/// directory at the **root** of the bundle, next to `Contents/`. `codesign` refuses to
/// sign that:
///
///     MoxSpeak.app: unsealed contents present in the bundle root
///
/// Everything in a signed app has to live under `Contents/`, so the bundle ships at
/// `Contents/Resources/MoxSpeak_KokoroSwift.bundle` and this looks there — that is
/// `Bundle.main.resourceURL`, the standard location, and it is also exactly where a plain
/// `swift build` leaves the bundle relative to a bare executable (`Bundle.main.resourceURL`
/// for an unbundled binary is the directory the binary sits in).
///
/// When neither applies — `swift test`, where `Bundle.main` is the `.xctest` harness —
/// this falls back to SwiftPM's own `Bundle.module`, which is what has always worked
/// there. `Bundle.module` is only *touched* on that fallback path, deliberately: its
/// accessor calls `fatalError` when it cannot find the bundle, so reaching for it first
/// and recovering afterwards is not possible.
enum MoxSpeakResourceLocator {

    private static let bundleName = "MoxSpeak_KokoroSwift.bundle"

    /// The resource bundle colocated with the running binary, or nil if there isn't one.
    private static let colocated: Bundle? = {
        // `.absoluteURL`: `Bundle.resourceURL` is base-relative, and `URL.path()` on such a
        // URL returns only the relative half — which is how `MLX.loadArrays(url:)` reads
        // the BART weights below. Collapse the base once, here.
        guard let resources = Bundle.main.resourceURL?.absoluteURL else { return nil }
        return Bundle(url: resources.appendingPathComponent(bundleName))
    }()

    /// Same contract as `Bundle.module.url(forResource:withExtension:subdirectory:)`.
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let colocated,
           let url = colocated.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
            return url.absoluteURL
        }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")?
            .absoluteURL
    }
}
