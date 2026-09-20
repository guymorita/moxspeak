import AppKit
import Carbon.HIToolbox

/// Our own four-character signature, so hotkey ids cannot collide with another
/// component's inside the same process.
///
/// File scope rather than a `static` on `HotkeyManager`, and that placement is the point.
/// The Carbon callback below is a bare C function and therefore `nonisolated`, so it
/// cannot read a `static let` that lives on a `@MainActor` type. The previous version
/// worked around that by writing the literal `0x53_50_4B_59` a second time inside the
/// callback and comparing against it — two copies of one constant, in two places, where
/// the only symptom of them drifting apart is a hotkey that silently never fires. One
/// constant, visible to both, removes that failure mode by construction.
private let moxspeakHotkeySignature: OSType = 0x53_50_4B_59  // 'SPKY'

/// Global hotkeys, via Carbon's `RegisterEventHotKey`.
///
/// ## Why Carbon, in 2026
///
/// This is the only global-hotkey API on macOS that needs no Accessibility permission.
/// `CGEventTap` and `NSEvent.addGlobalMonitorForEvents` both require the user to grant
/// Accessibility in System Settings, which means a permission prompt, a trip through
/// Privacy & Security, and a relaunch — before the app has done anything useful once.
/// `RegisterEventHotKey` asks for nothing. Verified directly: from a bundled `.app`
/// launched through LaunchServices with `AXIsProcessTrusted() == false`, registration and
/// handler installation both returned `noErr` and no prompt appeared.
///
/// That is the whole reason this app is cheap to ship — no entitlements, no developer
/// account, no permissions dialog. The deprecation warnings Carbon collects are a price
/// worth paying for it.
///
/// ## Why every step of the path is logged
///
/// A hotkey is the one part of this app with no visible surface. There is no button that
/// looked pressed, no window that failed to open — the user presses a key combination and
/// either something happens or nothing does. That makes a *working* hotkey and a *dead*
/// one produce exactly the same evidence unless the code says which one it is.
///
/// This was not hypothetical. An earlier version logged registration and nothing else,
/// and was reported as broken on the strength of a log that stopped at launch: pressing
/// the combination appeared to do nothing, because a successful firing wrote no line
/// anywhere. Under instrumentation the whole path — callback, parameter fetch, signature,
/// dispatch, handler — turned out to run correctly every time. The bug was the silence.
///
/// So the firing path logs, permanently: once when a hotkey fires, and once for each way
/// the Carbon callback can decline an event. Nothing on this path is allowed to return
/// `eventNotHandledErr` without saying why.
///
/// ## Why registration failure is loud
///
/// `RegisterEventHotKey` can refuse, and the refusal is total and silent: the key simply
/// does nothing forever and the user has no way to tell that from a broken app. Every
/// registration result is therefore surfaced to the caller, which puts it in front of the
/// user.
///
/// Worth knowing what this does *not* buy, so nobody reads more into a `noErr` than it
/// means: registering a combination another running process already holds succeeds. Two
/// processes were run side by side on ⌥⇧S, both registrations returned `noErr`, and both
/// handlers fired on the same keystroke. So a successful registration is not a claim of
/// exclusivity, and a stolen-looking hotkey will not show up here as an error.
///
/// ## Why `noErr` is not proof of a working hotkey
///
/// The larger version of the same warning, and the one that cost this app its headline
/// feature on every Mac running macOS 15 or later. Since Sequoia, the system silently
/// declines to *deliver* a hotkey whose modifiers are only Option and/or Shift —
/// registration returns `noErr`, the handler installs, the log says `registered`, and the
/// callback is never called. MoxSpeak's three original shortcuts were all exactly that
/// shape.
///
/// The defence is `Hotkey.rejection`, checked in `register` **before** Carbon ever sees
/// the combination, so a hotkey that cannot work is refused loudly instead of accepted
/// quietly. `Hotkey` documents the restriction and its source.
@MainActor
final class HotkeyManager {

    /// Why a hotkey could not be put in place.
    enum Failure: Error, CustomStringConvertible {
        /// macOS will not deliver this combination at all, so it is never handed to
        /// Carbon. Caught here rather than discovered by a user pressing a dead key:
        /// `RegisterEventHotKey` answers `noErr` for these and then nothing ever fires.
        /// See `Hotkey.rejection` for what the rule is and where it came from.
        case unusable(hotkey: Hotkey, reason: Hotkey.Rejection)
        /// `RegisterEventHotKey` refused. Almost always means another app owns the combo.
        case alreadyTaken(hotkey: Hotkey, status: OSStatus)
        /// MoxSpeak's own other shortcut has it. Separated from `alreadyTaken` because
        /// the fix is entirely different, and because blaming "another app" for our own
        /// binding would send the user looking in the wrong place.
        case clashesWithOurOwn(hotkey: Hotkey, other: HotkeyAction)
        /// The Carbon event handler itself would not install. Nothing will fire.
        case handlerUnavailable(status: OSStatus)

        var description: String {
            switch self {
            case .unusable(let hotkey, let reason):
                return "\(hotkey.label) cannot work. \(reason)"
            case .alreadyTaken(let hotkey, let status):
                return "\(hotkey.label) is already taken by another app (OSStatus \(status))"
            case .clashesWithOurOwn(let hotkey, let other):
                return "\(hotkey.label) is already MoxSpeak's \(other.rawValue) shortcut"
            case .handlerUnavailable(let status):
                return "the system refused to install a hotkey handler (OSStatus \(status))"
            }
        }

        /// The long form, for a tooltip or the shortcuts window — where there is room to
        /// say why, and where the user is standing at the moment they need to know.
        var explanation: String {
            switch self {
            case .unusable(_, let reason):
                return reason.explanation
            case .alreadyTaken(let hotkey, _):
                return "macOS would not register \(hotkey.label). Another app almost "
                     + "certainly has it. Pick a different combination."
            case .clashesWithOurOwn(let hotkey, let other):
                return "\(hotkey.label) is already MoxSpeak's \(other.title) shortcut. "
                     + "Change that one first, or pick a different combination."
            case .handlerUnavailable:
                return "macOS refused to install MoxSpeak's keyboard handler, so no "
                     + "shortcut can work. Quitting and reopening MoxSpeak usually fixes "
                     + "it."
            }
        }
    }

    /// What one registered id maps to.
    ///
    /// The hotkey is carried alongside the handler for two reasons. The log line at
    /// firing time can name the combination the user actually pressed — "⌃⌥S fired" is a
    /// fact about the world, "id 1 fired" is a fact about this file — and `register` needs
    /// to recognise both a re-registration of the combination already in force and a clash
    /// with one of our own other actions.
    private struct Registration {
        let action: HotkeyAction
        let hotkey: Hotkey
        let reference: EventHotKeyRef
        let handler: @MainActor () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    /// Which Carbon id currently belongs to each action, so rebinding can find the one
    /// registration it has to replace without searching.
    private var idsByAction: [HotkeyAction: UInt32] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    deinit {
        // `deinit` cannot touch main-actor state, and the process is exiting anyway:
        // Carbon tears the registrations down with the application event target.
    }

    /// What is registered for an action right now, or nil if nothing is.
    func hotkey(for action: HotkeyAction) -> Hotkey? {
        idsByAction[action].flatMap { registrations[$0]?.hotkey }
    }

    /// Registers one hotkey for one action, replacing whatever that action had.
    ///
    /// Throws rather than returning a Bool so the reason reaches the user; a hotkey that
    /// silently does nothing is indistinguishable from a bug.
    ///
    /// Validation comes first, and it comes first for a reason that is easy to lose:
    /// `RegisterEventHotKey` **succeeds** for a combination macOS has no intention of
    /// delivering. If the check ran after registration — or not at all, which is how this
    /// app shipped — the log would read `registered` and the key would be dead. So a
    /// combination the system will not deliver is never handed to Carbon at all.
    func register(_ hotkey: Hotkey,
                  for action: HotkeyAction,
                  handler: @escaping @MainActor () -> Void) throws {
        if let reason = hotkey.rejection {
            throw Failure.unusable(hotkey: hotkey, reason: reason)
        }

        // Already where it needs to be. Not merely an optimisation: Carbon answers
        // `eventHotKeyExistsErr` (-9878) when a process registers a combination it
        // already holds, so re-registering an unchanged binding — which is what "Use
        // Defaults" does for any action already on its default — would fail and be
        // reported to the user as a conflict with another app.
        if self.hotkey(for: action) == hotkey { return }

        // The same combination held for a *different* action is a real conflict, and it is
        // ours, not another app's. Saying so is the difference between a user hunting
        // through their other apps and a user moving one of their own two shortcuts.
        if let clash = HotkeyAction.allCases.first(where: { $0 != action && self.hotkey(for: $0) == hotkey }) {
            throw Failure.clashesWithOurOwn(hotkey: hotkey, other: clash)
        }

        try installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: moxspeakHotkeySignature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode,
                                         hotkey.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &reference)
        guard status == noErr, let reference else {
            throw Failure.alreadyTaken(hotkey: hotkey, status: status)
        }

        // Only once the new one is in place, so a failed registration never costs the
        // user the binding they already had.
        unregister(action)

        registrations[id] = Registration(action: action,
                                         hotkey: hotkey,
                                         reference: reference,
                                         handler: handler)
        idsByAction[action] = id
        AppLog.write("hotkey: registered \(hotkey.label) for \(action.rawValue) as id \(id)")
    }

    /// Releases whatever an action holds. Quiet when it holds nothing.
    func unregister(_ action: HotkeyAction) {
        guard let id = idsByAction[action], let registration = registrations[id] else { return }
        UnregisterEventHotKey(registration.reference)
        registrations[id] = nil
        idsByAction[action] = nil
        AppLog.write("hotkey: released \(registration.hotkey.label) for \(action.rawValue)")
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         moxspeakHotkeyHandler,
                                         1,
                                         &spec,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &reference)
        guard status == noErr else {
            throw Failure.handlerUnavailable(status: status)
        }
        eventHandler = reference
    }

    /// Called from the Carbon callback below, already on the main thread.
    ///
    /// The log line here is the permanent one: it is the only proof, from outside the
    /// process, that a keystroke made it all the way through Carbon and into this app.
    fileprivate func fire(id: UInt32) {
        guard let registration = registrations[id] else {
            // Our signature but not our id. Cannot happen as long as ids only come from
            // `register`, which is exactly why it is worth hearing about if it ever does.
            AppLog.write("hotkey: fired with unknown id \(id) — ignored")
            return
        }
        AppLog.write("hotkey: \(registration.hotkey.label) fired")
        registration.handler()
    }
}

/// Carbon hands back a bare C function pointer with no context, so the manager arrives
/// through `userData` — set to an unretained pointer to it at `InstallEventHandler` time.
/// Unretained is correct: the manager outlives the handler by construction (it owns the
/// `EventHandlerRef`), and retaining here would make that cycle permanent.
///
/// Handlers installed on `GetApplicationEventTarget()` are dispatched by the main run
/// loop, so this genuinely runs on the main thread; `assumeIsolated` states that rather
/// than hopping, which would turn a keypress into a queued task and lose the ordering
/// guarantee against menu actions.
private func moxspeakHotkeyHandler(_ callRef: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else {
        AppLog.write("hotkey: callback reached with no event or no manager — ignored")
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else {
        AppLog.write("hotkey: could not read the hotkey id off the event (OSStatus \(status))")
        return OSStatus(eventNotHandledErr)
    }

    // A different signature is somebody else's hotkey arriving on the shared application
    // event target. Declining it is correct and routine, so it stays quiet — this is the
    // one silent exit on this path, and it is silent because it is not a failure.
    guard hotKeyID.signature == moxspeakHotkeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        manager.fire(id: id)
    }
    return noErr
}
