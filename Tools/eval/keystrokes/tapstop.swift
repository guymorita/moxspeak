import CoreGraphics
import Foundation
let src = CGEventSource(stateID: .hidSystemState)
let key: CGKeyCode = 47  // kVK_ANSI_Period
let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)!
let up   = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)!
let flags: CGEventFlags = [.maskAlternate, .maskShift]
down.flags = flags; up.flags = flags
down.post(tap: .cgSessionEventTap); usleep(60_000); up.post(tap: .cgSessionEventTap)
print("posted option+shift+period")
