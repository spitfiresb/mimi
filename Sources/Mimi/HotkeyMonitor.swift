import AppKit
import CoreGraphics

/// Global push-to-talk on ⌃⌥Space via a CGEventTap.
///
/// Requires Accessibility permission: we use `.defaultTap` (not `.listenOnly`)
/// so we can swallow the chord and stop it reaching the focused app.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// Stamped onto events we synthesize, so we never react to our own ⌘V.
    static let syntheticMarker: Int64 = 0x4D_49_4D_49  // "MIMI"

    private static let spaceKeyCode: Int64 = 49

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that take too long, silently. Without this the
        // hotkey just stops working with no error.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Never react to events we posted ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let chordHeld = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .keyDown where keyCode == Self.spaceKeyCode && chordHeld:
            if !isDown {
                isDown = true
                onPress?()
            }
            return nil  // swallow, so no space is typed

        case .keyUp where keyCode == Self.spaceKeyCode:
            if isDown {
                isDown = false
                onRelease?()
                return nil
            }

        case .flagsChanged:
            // Modifier released while space was still held.
            if isDown && !chordHeld {
                isDown = false
                onRelease?()
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}
