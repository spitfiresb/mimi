import AVFoundation
import AppKit
import ApplicationServices

enum Permissions {
    static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Accessibility has no Info.plist usage-description key — it is pure runtime
    /// TCC consent. Passing `prompt: true` shows the system dialog once.
    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url { NSWorkspace.shared.open(url) }
    }
}
