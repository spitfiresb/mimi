import AVFoundation
import AppKit
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem?
    private var formattingItem: NSMenuItem?

    /// Stored inverted so formatting defaults to on without a registration dance.
    private static let verbatimKey = "verbatimMode"
    private let engine = SpeechEngine()
    private let audio = AudioCapture()
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayPanel()
    private let formatter = Formatter()

    /// Session startup is async; the user can release the key before it lands.
    /// endRecording awaits this task instead of reading a `session` var that may
    /// not be populated yet — the old shape dropped the utterance and left the
    /// overlay stranded on screen.
    private var startTask: Task<TranscriptionSession?, Never>?
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

        let formatting = NSMenuItem(
            title: "Clean Up Dictation",
            action: #selector(toggleFormatting),
            keyEquivalent: ""
        )
        formatting.target = self
        menu.addItem(formatting)
        self.formattingItem = formatting

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
            // Mic goes hot now and stays hot — starting it at keypress loses the
            // first second of speech to hardware spin-up.
            guard let format = await engine.analyzerFormat else { throw MimiError.notPrepared }
            try audio.prepare(outputFormat: format)

            // Sleep kills the engine; wake must revive it or the next dictation
            // records silence.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.audio.ensureRunning() }
            }
        } catch {
            setState(symbol: "mic.slash", status: "Error: \(error.localizedDescription)")
            return
        }

        // Warm the formatter alongside the transcriber; cold start is ~3s,
        // warm is ~0.5s. Fire-and-forget — dictation must not wait on it.
        Task { await formatter.prewarm() }

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

        // Belt to the wake notification's suspenders — if anything else stopped
        // the engine, revive it before capturing.
        audio.ensureRunning()

        // Capture audio from the first instant; the stream buffers while the
        // session spins up.
        let stream = audio.start()

        startTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let (session, _) = try await engine.makeSession()
                try await session.start(stream) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.isRecording else { return }
                        self.overlay.update(text.isEmpty ? "Listening…" : text)
                    }
                }
                return session
            } catch {
                setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func endRecording() async {
        guard isRecording else { return }
        isRecording = false
        let context = self.context
        self.context = nil

        // Wait for startup to land — however brief the press was, there may be
        // buffered audio worth transcribing.
        let session = await startTask?.value
        startTask = nil

        guard let session else {
            audio.stop()
            overlay.hide()
            return
        }
        setState(symbol: "mic", status: "Transcribing…")
        overlay.update("Transcribing…")

        // Finishing the audio stream is what lets finalize() return.
        audio.stop()

        do {
            let (text, recognition) = try await Self.withTimeout(seconds: 10) {
                try await session.finish()
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Hide before pasting so the overlay is never in the way.
            overlay.hide()

            if !trimmed.isEmpty {
                let formattingOn = !UserDefaults.standard.bool(forKey: Self.verbatimKey)
                let output = formattingOn ? await formatter.format(trimmed) : trimmed
                await TextInserter.insert(output)
                await log(
                    trimmed,
                    formatted: output == trimmed ? nil : output,
                    recognition: recognition,
                    context: context
                )
            }
            setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
        } catch {
            // However finalization failed, the UI must come back — a stuck
            // "Transcribing…" panel is worse than a lost utterance.
            await session.abort()
            overlay.hide()
            setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
        }
    }

    /// Race a job against a deadline. Finalization has hung before (sleep/wake
    /// killed the engine mid-recording); nothing user-visible may await it
    /// unbounded.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ job: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await job() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MimiError.finalizeTimedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Logging

    private func log(
        _ raw: String,
        formatted: String?,
        recognition: [RecognitionResult],
        context: RecordingContext?
    ) async {
        let elapsed = context.map { ContinuousClock.now - $0.startedAt } ?? .zero
        let entry = TranscriptEntry(
            durationMs: Int(elapsed / .milliseconds(1)),
            locale: await engine.locale?.identifier,
            appBundleID: context?.appBundleID,
            appName: context?.appName,
            raw: raw,
            recognition: recognition.isEmpty ? nil : recognition,
            formatted: formatted
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
        formattingItem?.state = UserDefaults.standard.bool(forKey: Self.verbatimKey) ? .off : .on
    }

    @objc private func toggleFormatting() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Self.verbatimKey), forKey: Self.verbatimKey)
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
