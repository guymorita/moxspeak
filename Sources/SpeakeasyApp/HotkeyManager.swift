import AppKit
import Carbon.HIToolbox

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
/// ## Why registration failure is loud
///
/// `RegisterEventHotKey` fails when another running application already owns the
/// combination, and the failure is total and silent: the key simply does nothing forever
/// and the user has no way to tell that from a broken app. Every registration result is
/// therefore surfaced to the caller, which puts it in front of the user.
@MainActor
final class HotkeyManager {

    /// One key-plus-modifiers combination.
    struct Shortcut: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
        /// How to write it for a human: "⌥⇧S".
        let label: String

        static let optionShiftS = Shortcut(
            keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧S")

        static let optionShiftSpace = Shortcut(
            keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧Space")
    }

    enum Failure: Error, CustomStringConvertible {
        /// `RegisterEventHotKey` refused. Almost always means another app owns the combo.
        case alreadyTaken(shortcut: Shortcut, status: OSStatus)
        /// The Carbon event handler itself would not install. Nothing will fire.
        case handlerUnavailable(status: OSStatus)

        var description: String {
            switch self {
            case .alreadyTaken(let shortcut, let status):
                return "\(shortcut.label) is already taken by another app (OSStatus \(status))"
            case .handlerUnavailable(let status):
                return "the system refused to install a hotkey handler (OSStatus \(status))"
            }
        }
    }

    /// Our own four-character signature, so hotkey ids cannot collide with another
    /// component's inside the same process.
    private static let signature: OSType = 0x53_50_4B_59  // 'SPKY'

    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    deinit {
        // `deinit` cannot touch main-actor state, and the process is exiting anyway:
        // Carbon tears the registrations down with the application event target.
    }

    /// Registers one shortcut. Throws rather than returning a Bool so the reason reaches
    /// the user; a hotkey that silently does nothing is indistinguishable from a bug.
    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws {
        try installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         shortcut.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &reference)
        guard status == noErr, let reference else {
            throw Failure.alreadyTaken(shortcut: shortcut, status: status)
        }

        registrations[id] = reference
        handlers[id] = handler
        AppLog.write("hotkey: registered \(shortcut.label) as id \(id)")
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         speakeasyHotkeyHandler,
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
    fileprivate func fire(id: UInt32) {
        guard let handler = handlers[id] else { return }
        handler()
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
private func speakeasyHotkeyHandler(_ callRef: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x53_50_4B_59 else {
        return OSStatus(eventNotHandledErr)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        manager.fire(id: id)
    }
    return noErr
}
