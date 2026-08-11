import AVFoundation
import AppKit
import EvalKit
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem?
    private var formattingItem: NSMenuItem?

    /// Stored inverted so formatting defaults to on without a registration dance.
    private static let verbatimKey = "verbatimMode"

    /// How long the formatting pass may hold the paste. Short dictations finish
    /// in ~40ms because routing skips them entirely; only multi-sentence takes
    /// reach the model, and those are the ones that ran to 6.4s and 11.2s. Raise
    /// it to favour cleanup, lower it to favour landing the text.
    private static let formatDeadlineSeconds = 2.5

    /// How long the key release will wait for session startup before giving the
    /// UI back. Generous — startup normally lands in tens of milliseconds, and
    /// abandoning it costs the whole utterance — but finite, because the
    /// alternative is an overlay wedged on "Listening" forever.
    private static let sessionStartDeadlineSeconds = 8.0

    /// Ceiling on a single dictation. Not a feature — a floor under the worst
    /// case, so a lost key-up costs one utterance instead of the whole session.
    private static let maxRecordingSeconds = 120.0

    /// Force-ends a recording that outlives `maxRecordingSeconds`.
    private var watchdog: Task<Void, Never>?
    private let engine = SpeechEngine()
    private let audio = AudioCapture()
    private let hotkey = HotkeyMonitor()
    private let overlay = OverlayPanel()
    private let formatter = Formatter()

    /// The Stage 5 default: Parakeet-int8 on the Neural Engine transcribes the
    /// buffered session audio at release (WER 1.92% vs SpeechTranscriber's
    /// 2.34% on the harness). Apple's engine still runs live for the preview
    /// overlay and remains the fallback whenever Parakeet is unavailable or
    /// errors — principle 3, both arms stay wired.
    private let parakeet = ParakeetEngine(modelsDir: AppDelegate.parakeetModelsDir())
    private var parakeetReady = false

    /// Dev-machine layout until 'ship it' bundles weights: an override via
    /// `defaults write`, else the repo checkout this binary was built from.
    private static func parakeetModelsDir() -> URL {
        if let override = UserDefaults.standard.string(forKey: "ParakeetModelsDir") {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)  // Sources/Mimi/AppDelegate.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/convert/models")
    }

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

        // Load Parakeet off the critical path. If anything fails (missing
        // packages, bad models dir) the app quietly stays on Apple's engine.
        Task { [parakeet] in
            do {
                try await parakeet.prepare()
                await Task.detached(priority: .utility) { parakeet.warmEncoders() }.value
                await MainActor.run { self.parakeetReady = true }
            } catch {
                // Fallback path: parakeetReady stays false, Apple transcribes.
            }
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
        overlay.show()

        // Last line of defence against a recording that never ends. Every known
        // route to a wedged "Listening" panel is now handled individually, but
        // they all reduce to the same thing — a key-up that never arrives — and
        // the user has no way out of it when it happens. A dictation this long
        // is not a real one, so ending it costs nothing and the transcript of
        // whatever was captured still lands.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxRecordingSeconds))
            guard !Task.isCancelled else { return }
            await self?.endRecording()
        }

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

        // Formatting now happens at release on whichever engine's text wins
        // (Parakeet's arrives all at once, so there's nothing to pre-clean
        // mid-speech; Apple's chunked-feed optimization went with it).
        startTask = Task { [weak self] in
            guard let self else { return nil }
            do {
                let (session, _) = try await engine.makeSession()
                try await session.start(
                    stream,
                    audioEpoch: audioEpoch,
                    onFinalResult: { _, _ in }
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

    private func endRecording() async {
        guard isRecording else {
            // A release with nothing recording means the press and release
            // transitions raced, or the press was lost. Either way the panel may
            // be sitting on "Listening" with nothing behind it, so the UI has to
            // be put back — a stuck panel is indistinguishable from a dead
            // hotkey, and the user has no way out of it.
            overlay.hide()
            setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
            return
        }
        isRecording = false
        watchdog?.cancel()
        watchdog = nil
        let context = self.context
        self.context = nil

        // Wait for startup to land — however brief the press was, there may be
        // buffered audio worth transcribing.
        //
        // Bounded, because this await is the one place a stall is unrecoverable:
        // `overlay.waiting()` is still below us, so the panel sits on "Listening"
        // with no path forward and no way for the user to tell a wedged app from
        // a dead hotkey. Session startup contends with the encoder warm-up and
        // the system's own speech assets, and on a loaded machine it can take a
        // very long time (2026-08-11).
        let pending = startTask
        startTask = nil
        let session = await Self.abandoning(after: Self.sessionStartDeadlineSeconds) {
            await pending?.value
        } ?? nil

        guard let session else {
            pending?.cancel()
            audio.stop()
            overlay.hide()
            setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
            return
        }
        setState(symbol: "mic", status: "Transcribing…")
        overlay.waiting()

        // Finishing the audio stream is what lets finalize() return.
        audio.stop()

        // Parakeet transcribes the same audio the analyzer heard, concurrently
        // with Apple's finalization. ~36ms/15s window on the ANE, so the race
        // costs nothing; the winner is decided below.
        let samples = audio.takeRecordedSamples16k()
        let audioSeconds = Double(samples.count) / MelFrontend.sampleRate
        let parakeetTask: Task<String?, Never>? = (parakeetReady && !samples.isEmpty)
            ? Task.detached(priority: .userInitiated) { [parakeet] in
                try? parakeet.transcribe(samples16k: samples)
            }
            : nil

        // Capture-side health for the log. A dictation that "heard nothing"
        // looks identical to one that heard silence; the peak level and the
        // device/tap rates are what tell those apart afterwards.
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        let health = audio.captureHealth()
        let audioHealth = TranscriptEntry.AudioHealth(
            device: health.device,
            deviceRate: health.deviceRate,
            tapRate: health.tapRate,
            peak: peak,
            seconds: audioSeconds
        )

        let clock = ContinuousClock()
        var stamp = clock.now
        func lap() -> Int {
            let now = clock.now
            defer { stamp = now }
            return Int((now - stamp) / .milliseconds(1))
        }

        // Apple's finalization can hang outright: finish() awaits a collector
        // that only ends when the analyzer delivers end-of-stream, and a broken
        // session never does. The old withTimeout threw on schedule, but its
        // task group still waited for the hung child on the way out — so
        // endRecording suspended here forever, panel up, main thread idle,
        // nothing on any thread for a sample to even see (2026-08-11, caught
        // live). Abandon the wait instead, and tear the session down on the way
        // past: a hung Apple finalize must not cost the dictation when Parakeet
        // has the same audio.
        let appleResult = await Self.abandoning(after: 10) {
            try? await session.finish()
        }
        if appleResult == nil { await session.abort() }
        let finalizeMs = lap()
        let appleText = appleResult?.text ?? ""
        let recognition = appleResult?.recognition ?? []

        // Never spend more wall clock on the decode than the audio itself
        // lasted. A decode slower than 1x real time is pathology, not
        // slowness — measured worst case is 0.50x on a 59s dictation — and
        // Apple's text is already in hand as the fallback. Drop the floor
        // or the multiplier to trade transcript quality for a faster paste.
        let parakeetText = await Self.awaitValue(
            of: parakeetTask, deadline: max(10, audioSeconds))
        let parakeetMs = lap()

        // Parakeet's text is the default; Apple's is the fallback for an
        // empty or failed decode. Both are logged either way.
        let appleTrimmed = appleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parakeetTrimmed = parakeetText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usedParakeet = !parakeetTrimmed.isEmpty
        let trimmed = usedParakeet ? parakeetTrimmed : appleTrimmed

        if trimmed.isEmpty {
            overlay.hide()
            // The "it heard nothing" bug report. Logged with the capture
            // health rather than vanishing without a trace — an empty
            // dictation with peak ~0 is a mic problem; one with a healthy
            // peak is an engine problem (2026-08-11).
            await log(
                "",
                formatted: nil,
                recognition: recognition,
                timings: .init(
                    finalizeMs: finalizeMs,
                    formatMs: 0,
                    settleMs: 0,
                    insertMs: 0,
                    parakeetMs: parakeetMs,
                    startupMs: previewStats.startupMs,
                    firstPreviewMs: previewStats.firstPreviewMs,
                    maxPreviewLagMs: previewStats.maxPreviewLagMs
                ),
                audio: audioHealth,
                context: context
            )
        } else {
            var output = trimmed
            if !UserDefaults.standard.bool(forKey: Self.verbatimKey),
               trimmed.split(separator: " ").count >= Formatter.minimumWords {
                let pipeline = FormatPipeline(formatter: formatter) { [weak self] partial in
                    Task { @MainActor in
                        guard let self, !self.isRecording else { return }
                        self.overlay.stream(partial)
                    }
                }
                await pipeline.feed(trimmed, spans: [])

                // Cleaning is one model round-trip per sentence, run
                // serially, so the cost scales with how long the user spoke:
                // 6.4s on a 39s take and 11.2s on a 47s one, both of which
                // returned the transcript unchanged (2026-08-11). Parakeet
                // already emits punctuation and casing, so pasting
                // unformatted is a fine outcome — a paste the user gave up
                // waiting for is not.
                // Cancelling between sentences is not enough on its own: a
                // single `respond()` round trip cannot be interrupted, and
                // one slow sentence took the pass to 12.1s against a 2.5s
                // budget (2026-08-11). So the wait is abandoned outright and
                // the orphan is told to stop on its way out.
                let cleaned = await Self.abandoning(after: Self.formatDeadlineSeconds) {
                    await pipeline.finish()
                }
                if let cleaned, !cleaned.isEmpty {
                    output = cleaned
                } else {
                    await pipeline.cancel()
                }
            }
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
            let pasteTarget = NSWorkspace.shared.frontmostApplication?.localizedName
            await TextInserter.insert(output)
            let insertMs = lap()

            await log(
                trimmed,
                engine: usedParakeet ? "parakeet-int8" : "apple",
                appleRaw: usedParakeet ? appleTrimmed : nil,
                formatted: output == trimmed ? nil : output,
                recognition: recognition,
                timings: .init(
                    finalizeMs: finalizeMs,
                    formatMs: formatMs,
                    settleMs: settleMs,
                    insertMs: insertMs,
                    parakeetMs: parakeetMs,
                    startupMs: previewStats.startupMs,
                    firstPreviewMs: previewStats.firstPreviewMs,
                    maxPreviewLagMs: previewStats.maxPreviewLagMs
                ),
                pasteTarget: pasteTarget,
                audio: audioHealth,
                context: context
            )
        }
        setState(symbol: "mic", status: "Ready — hold ⌃⌥Space")
    }

    /// Timeout for non-throwing async work: returns nil if the deadline passes.
    /// A hung ANE prediction must not strand the "Transcribing…" panel.
    /// Await `task`, abandoning it if it outruns `deadline`.
    ///
    /// The previous shape raced the work against a sleep inside a task group,
    /// which is a trap: `withTaskGroup` waits for *every* child before it
    /// returns, so the timeout fired on schedule, `cancelAll()` couldn't touch
    /// a detached task running synchronous Core ML work, and the group then sat
    /// on that work anyway. The deadline neither bounded the wait nor kept the
    /// answer — a 59s dictation spent 29.2s decoding, discarded the result, and
    /// pasted Apple's text instead (2026-08-11). Cancelling the task directly
    /// is what actually stops it; ParakeetEngine checks for it per decode frame.
    /// Run `job`, but stop waiting after `seconds` and return nil — *without*
    /// waiting for it to finish.
    ///
    /// The distinction matters for work that cannot be interrupted. Awaiting a
    /// task, in any shape, means inheriting its duration no matter what the
    /// deadline says; that is what made both `withDeadline` and the first cut of
    /// the formatting budget useless. Here the loser of the race is simply
    /// abandoned and finishes into the void.
    static func abandoning<T: Sendable>(   // internal for DeadlineTests
        after seconds: Double, _ job: @escaping @Sendable () async -> T?
    ) async -> T? {
        let gate = FirstWins<T>()
        Task { await gate.settle(await job()) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            await gate.settle(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            Task { await gate.hold(continuation) }
        }
    }

    /// Resumes its continuation exactly once, with whichever racer settled
    /// first — including when that happens before anyone is waiting.
    private actor FirstWins<T: Sendable> {
        private var continuation: CheckedContinuation<T?, Never>?
        private var settled = false
        private var stored: T?

        func hold(_ continuation: CheckedContinuation<T?, Never>) {
            if settled {
                continuation.resume(returning: stored)
            } else {
                self.continuation = continuation
            }
        }

        func settle(_ value: T?) {
            guard !settled else { return }
            settled = true
            stored = value
            if let waiting = continuation {
                continuation = nil
                waiting.resume(returning: value)
            }
        }
    }

    static func awaitValue(          // internal for DeadlineTests
        of task: Task<String?, Never>?, deadline seconds: Double
    ) async -> String? {
        guard let task else { return nil }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(seconds))
            task.cancel()
        }
        defer { watchdog.cancel() }
        // Cancellation is cooperative — the decode checks per frame — but a
        // single Core ML prediction that never returns would ignore it and
        // inherit the hang. Stop waiting shortly after the deadline regardless.
        return await abandoning(after: seconds + 2) { await task.value } ?? nil
    }

    // MARK: - Logging

    private func log(
        _ raw: String,
        engine engineName: String? = nil,
        appleRaw: String? = nil,
        formatted: String?,
        recognition: [RecognitionResult],
        timings: TranscriptEntry.Timings? = nil,
        pasteTarget: String? = nil,
        audio: TranscriptEntry.AudioHealth? = nil,
        context: RecordingContext?
    ) async {
        let elapsed = context.map { ContinuousClock.now - $0.startedAt } ?? .zero
        let entry = TranscriptEntry(
            durationMs: Int(elapsed / .milliseconds(1)),
            locale: await engine.locale?.identifier,
            appBundleID: context?.appBundleID,
            appName: context?.appName,
            pasteTarget: pasteTarget,
            raw: raw,
            engine: engineName,
            appleRaw: appleRaw,
            recognition: recognition.isEmpty ? nil : recognition,
            formatted: formatted,
            timings: timings,
            audio: audio
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
