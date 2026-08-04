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
        overlay.show()

        // Belt to the wake notification's suspenders — if anything else stopped
        // the engine, revive it before capturing.
        audio.ensureRunning()

        // Capture audio from the first instant; the stream buffers while the
        // session spins up.
        let stream = audio.start()

        previewStats = PreviewStats()
        let pressAt = ContinuousClock.now
        // Audio time zero is the head of the pre-roll, half a second before the
        // press.
        let audioEpoch = pressAt - .milliseconds(500)

        // Clean sentences while the user is still speaking; nil in verbatim mode.
        let pipeline: FormatPipeline?
        if UserDefaults.standard.bool(forKey: Self.verbatimKey) {
            pipeline = nil
        } else {
            pipeline = FormatPipeline(formatter: formatter) { [weak self] partial in
                Task { @MainActor in
                    // Only surface cleaned text once the user has released —
                    // during speech the overlay belongs to the live preview.
                    guard let self, !self.isRecording else { return }
                    self.overlay.stream(partial)
                }
            }
        }
        self.pipeline = pipeline

        startTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let (session, _) = try await engine.makeSession()
                try await session.start(
                    stream,
                    audioEpoch: audioEpoch,
                    onFinalResult: { text, spans in
                        await pipeline?.feed(text, spans: spans)
                    }
                ) { [weak self] committed, volatile, lagMs in
                    Task { @MainActor in
                        guard let self, self.isRecording else { return }
                        self.previewStats.record(lagMs: lagMs, sincePress: pressAt)
                        if committed.isEmpty && volatile.isEmpty {
                            self.overlay.update(committed: "", volatile: "Listening…")
                        } else {
                            self.overlay.update(committed: committed, volatile: volatile)
                        }
                    }
                }
                previewStats.startupMs = Int((ContinuousClock.now - pressAt) / .milliseconds(1))
                return session
            } catch {
                setState(symbol: "mic", status: "Error: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Live-preview health, reset per recording, folded into the log entry.
    private struct PreviewStats {
        var startupMs: Int?
        var firstPreviewMs: Int?
        var maxPreviewLagMs: Int?

        mutating func record(lagMs: Int, sincePress: ContinuousClock.Instant) {
            if firstPreviewMs == nil {
                firstPreviewMs = Int((ContinuousClock.now - sincePress) / .milliseconds(1))
            }
            maxPreviewLagMs = max(maxPreviewLagMs ?? 0, lagMs)
        }
    }
    private var previewStats = PreviewStats()
    private var pipeline: FormatPipeline?

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
        overlay.waiting()

        // Finishing the audio stream is what lets finalize() return.
        audio.stop()

        do {
            let clock = ContinuousClock()
            var stamp = clock.now
            func lap() -> Int {
                let now = clock.now
                defer { stamp = now }
                return Int((now - stamp) / .milliseconds(1))
            }

            let (text, recognition) = try await Self.withTimeout(seconds: 10) {
                try await session.finish()
            }
            let finalizeMs = lap()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                overlay.hide()
            } else {
                // Most sentences were already cleaned while the user spoke;
                // this waits only for the tail.
                var output = trimmed
                if let pipeline, trimmed.split(separator: " ").count >= Formatter.minimumWords {
                    let cleaned = await pipeline.finish()
                    if !cleaned.isEmpty { output = cleaned }
                }
                self.pipeline = nil
                let formatMs = lap()

                // Let the cleaned sentence land on screen before it lands in
                // the document — but only when cleanup changed something;
                // there's nothing to reveal about text the user already watched
                // arrive verbatim.
                if output != trimmed {
                    await overlay.settle(output)
                }
                overlay.hide()
                let settleMs = lap()
                await TextInserter.insert(output)
                let insertMs = lap()

                await log(
                    trimmed,
                    formatted: output == trimmed ? nil : output,
                    recognition: recognition,
                    timings: .init(
                        finalizeMs: finalizeMs,
                        formatMs: formatMs,
                        settleMs: settleMs,
                        insertMs: insertMs,
                        startupMs: previewStats.startupMs,
                        firstPreviewMs: previewStats.firstPreviewMs,
                        maxPreviewLagMs: previewStats.maxPreviewLagMs
                    ),
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
        timings: TranscriptEntry.Timings? = nil,
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
            formatted: formatted,
            timings: timings
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
