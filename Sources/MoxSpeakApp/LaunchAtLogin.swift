import AppKit
import ServiceManagement

/// Whether macOS relaunches MoxSpeak when the user logs in.
///
/// Wrapped rather than called directly for two reasons. `SMAppService` throws from both
/// `register()` and `unregister()`, and neither failure is worth interrupting anybody
/// over — the checkbox is a convenience, and a menu bar app that refuses to continue
/// because a login item would not register is a worse app than one that quietly stays
/// off. And the whole API only works from inside a bundle: run from `swift build` there
/// is no bundle to register, and calling it raises rather than returning an error.
///
/// So: every call is safe from anywhere, `isEnabled` reports the truth, and the caller
/// finds out whether a change took by reading it back.
enum LaunchAtLogin {

    /// False when there is no bundle to register — a `swift build` binary or a test host.
    /// Checked by identifier rather than by path so it cannot be fooled by a bundle that
    /// exists but is not ours.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Turns the login item on or off. Returns whether the system ended up in the state
    /// that was asked for, which is not the same as whether the call threw: a user can
    /// have MoxSpeak disabled in System Settings > General > Login Items, and `register()`
    /// then succeeds while `status` stays `.requiresApproval`.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLog.write("login item: could not \(enabled ? "register" : "unregister") — \(error)")
            return isEnabled == enabled
        }
        let settled = isEnabled == enabled
        if !settled {
            AppLog.write("login item: asked for \(enabled), system reports "
                         + "\(SMAppService.mainApp.status.rawValue) — probably needs "
                         + "approval in System Settings > General > Login Items")
        }
        return settled
    }
}
