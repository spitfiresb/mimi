import AVFoundation
import AppKit
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem?
    private let engine = SpeechEngine()
    private let audio = AudioCapture()
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayPanel()

    private var session: TranscriptionSession?
    private var isRecording = false

    /// Captured when recording starts, so the log records where the text was
    /// headed rather than wherever focus ended up afterwards.
    private struct RecordingContext {
        let startedAt: ContinuousClock.Instant
        let appBundleID: String?
        let appName: String?
    }
    private var context: RecordingContext?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBarItem()
        enableLaunchAtLoginOnFirstRun()
        setState(symbol: "mic", status: "Starting…")
        Task { await bootstrap() }
    }

    /// On by default, but only decided once — if the user turns it off later, that
    /// sticks. Anything else would be the app arguing with them every launch.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "hasSetLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else {
            refreshLaunchAtLoginState()
            return
        }
        try? LoginItem.setEnabled(true)
        UserDefaults.standard.set(true, forKey: key)
        refreshLaunchAtLoginState()
    }

    // MARK: - Setup

    private func buildMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        let hint = NSMenuItem(title: "Hold ⌃⌥Space to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let launchAtLogin = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        self.launchAtLoginItem = launchAtLogin

        let revealLog = NSMenuItem(
            title: "Show Transcript Log…",
            action: #selector(showTranscriptLog),
            keyEquivalent: ""
        )
        revealLog.target = self
        menu.addItem(revealLog)

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

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            setState(symbol: "mic", status: "Couldn't change login item: \(error.localizedDescription)")
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem?.state = LoginItem.isEnabled ? .on : .off
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

        let frontmost = NSWorkspace.shared.frontmostApplication
        context = RecordingContext(
            startedAt: .now,
            appBundleID: frontmost?.bundleIdentifier,
            appName: frontmost?.localizedName
        )

        setState(symbol: "mic.fill", status: "Listening…")
        overlay.show("Listening…")

        do {
            let (session, format) = try await engine.makeSession()
            let stream = try audio.start(outputFormat: format)
            try await session.start(stream) { [weak self] text in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.overlay.update(text.isEmpty ? "Listening…" : text)
                }
            }
            self.session = session
        } catch {
            isRecording = false
            context = nil
            audio.stop()
            overlay.hide()
            setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
        }
    }

    private func endRecording() async {
        guard isRecording, let session else { return }
        isRecording = false
        self.session = nil
        let context = self.context
        self.context = nil
        setState(symbol: "mic", status: "Transcribing…")
        overlay.update("Transcribing…")

        // Finishing the audio stream is what lets finalize() return.
        audio.stop()

        do {
            let text = try await session.finish()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Hide before pasting so the overlay is never in the way.
            overlay.hide()

            if !trimmed.isEmpty {
                await TextInserter.insert(trimmed)
                await log(trimmed, context: context)
            }
            setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
        } catch {
            overlay.hide()
            setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Logging

    private func log(_ raw: String, context: RecordingContext?) async {
        let elapsed = context.map { ContinuousClock.now - $0.startedAt } ?? .zero
        let entry = TranscriptEntry(
            durationMs: Int(elapsed / .milliseconds(1)),
            locale: await engine.locale?.identifier,
            appBundleID: context?.appBundleID,
            appName: context?.appName,
            raw: raw
        )
        await TranscriptLog.shared.append(entry)
    }

    // MARK: - UI

    private func setState(symbol: String, status: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mimi")
        statusItem.button?.toolTip = "Mimi — \(status)"
        statusItem.menu?.item(at: 0)?.title = status
    }

    // MARK: - NSMenuDelegate

    /// The login item can be flipped in System Settings behind our back, so read
    /// the real state each time the menu opens rather than trusting a cached flag.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLaunchAtLoginState()
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    /// Selects the file in Finder rather than opening it — the point is that the
    /// log is yours to read or throw away.
    @objc private func showTranscriptLog() {
        let url = TranscriptLog.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.open(TranscriptLog.directory)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
