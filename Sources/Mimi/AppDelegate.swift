import AVFoundation
import AppKit
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = SpeechEngine()
    private let audio = AudioCapture()
    private let hotkey = HotkeyMonitor()

    private var session: TranscriptionSession?
    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBarItem()
        setState(symbol: "mic", status: "Starting…")
        Task { await bootstrap() }
    }

    // MARK: - Setup

    private func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let hint = NSMenuItem(title: "Hold ⌃⌥Space to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Open Accessibility Settings…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem(
            title: "Quit Mimi",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private func bootstrap() async {
        guard await Permissions.microphoneAuthorized() else {
            setState(symbol: "mic.slash", status: "Microphone access denied")
            return
        }

        // Prompt once, then poll — granting Accessibility shouldn't require a restart.
        if !Permissions.accessibilityTrusted(prompt: true) {
            setState(symbol: "mic.slash", status: "Waiting for Accessibility permission…")
            while !Permissions.accessibilityTrusted(prompt: false) {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        do {
            try await engine.prepare { message in
                Task { @MainActor in self.setState(symbol: "mic", status: message) }
            }
        } catch {
            setState(symbol: "mic.slash", status: "Error: \(error.localizedDescription)")
            return
        }

        hotkey.onPress = { [weak self] in Task { @MainActor in await self?.beginRecording() } }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.endRecording() } }

        guard hotkey.start() else {
            setState(symbol: "mic.slash", status: "Could not install the hotkey — check Accessibility")
            return
        }

        setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
    }

    // MARK: - Recording

    private func beginRecording() async {
        guard !isRecording else { return }
        isRecording = true
        setState(symbol: "mic.fill", status: "Listening…")

        do {
            let (session, format) = try await engine.makeSession()
            let stream = try audio.start(outputFormat: format)
            try await session.start(stream)
            self.session = session
        } catch {
            isRecording = false
            audio.stop()
            setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
        }
    }

    private func endRecording() async {
        guard isRecording, let session else { return }
        isRecording = false
        self.session = nil
        setState(symbol: "mic", status: "Transcribing…")

        // Finishing the audio stream is what lets finalize() return.
        audio.stop()

        do {
            let text = try await session.finish()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                await TextInserter.insert(trimmed)
            }
            setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
        } catch {
            setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
        }
    }

    // MARK: - UI

    private func setState(symbol: String, status: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mimi")
        statusItem.button?.toolTip = "Mimi — \(status)"
        statusItem.menu?.item(at: 0)?.title = status
    }

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }
}
