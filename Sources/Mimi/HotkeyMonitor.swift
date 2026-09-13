import AppKit
import CoreGraphics
import os

/// Global Fn hold-to-talk and double-press hands-free via a CGEventTap.
///
/// Requires Accessibility permission: we use `.defaultTap` (not `.listenOnly`)
/// so we can swallow standalone Fn and stop it reaching the focused app.
final class HotkeyMonitor {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "hotkey")

    var canStart: (() -> Bool)?
    var onPress: ((Bool) -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Stamped onto events we synthesize, so we never react to our own ⌘V.
    static let syntheticMarker: Int64 = 0x4D_49_4D_49  // "MIMI"

    private static let fnKeyCode: Int64 = 63
    private static let globeKeyCode: Int64 = 179

    private var tap: CFMachPort?
    private var gesture = FnGesture()
    var isLocked: Bool { gesture.isLocked }

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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Sleep can drop key-up. The first press after wake must start fresh.
    func resetPressedState(keepingKeyDown: Bool = false) {
        gesture.reset(keepingKeyDown: keepingKeyDown)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that take too long, silently. Without this the
        // hotkey just stops working with no error.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.warning("event tap disabled (\(type.rawValue)); cancelling gesture and re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

            // A dropped key-up must not leave either a hold or hands-free
            // capture running. Discard the session and clear the gesture;
            // re-enabling alone would leave the microphone open indefinitely.
            let wasRecording = gesture.isRecording
            resetPressedState()
            if wasRecording { onCancel?() }
            return Unmanaged.passUnretained(event)
        }

        // Never react to events we posted ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // macOS also emits Globe keyDown/keyUp (179) for physical Fn (63).
        // They can arrive before or after the flagsChanged edge. Use only 63
        // for gesture transitions: treating 179 as another shortcut cancels
        // the hold or clears the first tap before the second press arrives.
        // https://github.com/4over7/SpeakOut/blob/main/CHANGELOG.md (1.3.2)
        if keyCode == Self.globeKeyCode, type == .keyDown || type == .keyUp {
            return nil
        }
        if type == .flagsChanged, keyCode == Self.fnKeyCode {
            let time = Double(event.timestamp) / 1_000_000_000
            let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            let action: FnGesture.Action?
            if event.flags.contains(.maskSecondaryFn) {
                action = gesture.press(at: time,
                    canStart: event.flags.intersection(modifiers).isEmpty && (canStart?() ?? true))
            } else {
                action = gesture.release(at: time)
            }
            dispatch(action)
            return nil
        }
        if type == .keyDown || type == .flagsChanged {
            dispatch(gesture.otherKey())
        }
        return Unmanaged.passUnretained(event)
    }

    private func dispatch(_ action: FnGesture.Action?) {
        switch action {
        case .start(let locked):
            Self.log.notice("Fn recording requested: locked=\(locked)")
            onPress?(locked)
        case .stop:
            Self.log.notice("Fn recording stopped")
            onRelease?()
        case .cancel:
            Self.log.notice("Fn tap or keyboard shortcut cancelled capture")
            onCancel?()
        case nil: break
        }
    }
}
