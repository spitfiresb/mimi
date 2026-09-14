import AVFoundation
import AppKit
import EvalKit
import Speech
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "flow")
    private var statusItem: NSStatusItem!
    private var launchAtLoginItem: NSMenuItem?
    private var formattingItem: NSMenuItem?

    /// Cleanup is opt-in; registered defaults preserve explicit user preferences.
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
    private var overlayReveal: Task<Void, Never>?
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
    private var recordingReady = false
    private var isProcessing = false
    private var recordingGeneration = 0

    /// Captured when recording starts, so the log records where the text was
    /// headed rather than wherever focus ended up afterwards.
    private struct RecordingContext {
        let startedAt: ContinuousClock.Instant
        let appBundleID: String?
        let appName: String?
    }
    private var context: RecordingContext?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.notice("Overlay renderer: native lens v2 (live backdrop); screen-capture renderer excluded from this build")
        UserDefaults.standard.register(defaults: [Self.verbatimKey: true])
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
        let hint = NSMenuItem(title: "Hold Fn to dictate", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        let lockHint = NSMenuItem(title: "Double-press Fn to lock · press Fn to finish", action: nil, keyEquivalent: "")
        lockHint.isEnabled = false
        menu.addItem(lockHint)
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
        Self.log.notice("bootstrap: checking microphone")
        guard await Permissions.microphoneAuthorized() else {
            Self.log.error("bootstrap: microphone denied")
            setState(symbol: "mic.slash", status: "Microphone access denied")
            return
        }

        // Prompt once, then poll — granting Accessibility shouldn't require a restart.
        if !Permissions.accessibilityTrusted(prompt: true) {
            Self.log.warning("bootstrap: waiting for Accessibility grant")
            setState(symbol: "mic.slash", status: "Waiting for Accessibility permission…")
            while !Permissions.accessibilityTrusted(prompt: false) {
                try? await Task.sleep(for: .seconds(1))
            }
            Self.log.notice("bootstrap: Accessibility granted")
        }

        let format: AVAudioFormat
        do {
            try await engine.prepare { message in
                Task { @MainActor in self.setState(symbol: "mic", status: message) }
            }
            guard let analyzerFormat = await engine.analyzerFormat else { throw MimiError.notPrepared }
            format = analyzerFormat
        } catch {
            // No transcriber means no dictation, so this one is still fatal to
            // bootstrap. An unavailable *mic* is not — see below.
            setState(symbol: "mic.slash", status: "Error: \(error.localizedDescription)")
            return
        }

        // Configuration does not open the mic. Only an explicit gesture does.
        audio.prepare(outputFormat: format)

        // Sleep, display sleep and session switching cancel a held dictation.
        // Only the next explicit press can reopen the mic after wake.
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hotkey.resetPressedState()
                    self?.cancelRecordingForSleep()
                }
            }
        }

        // Warm the formatter only when cleanup is enabled. Launching in
        // verbatim mode should not load a model it will never use; enabling
        // cleanup later creates a session on the first sentence needing it.
        if !UserDefaults.standard.bool(forKey: Self.verbatimKey) {
            Task { await formatter.prewarm() }
        }

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

        hotkey.canStart = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return false }
                return !self.isRecording && !self.isProcessing
            }
        }
        // Fn transitions run on the main run loop. Apply starts/cancellations
        // synchronously so a quick first tap cannot race the second press.
        hotkey.onPress = { [weak self] locked in
            MainActor.assumeIsolated { self?.beginRecording(locked: locked) }
        }
        hotkey.onCancel = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelRecordingForSleep(resetHotkey: false)
            }
        }
        hotkey.onRelease = { [weak self] in Task { @MainActor in await self?.endRecording() } }

        guard hotkey.start() else {
            Self.log.error("bootstrap: event tap creation failed")
            setState(symbol: "mic.slash", status: "Could not install the hotkey — check Accessibility")
            return
        }

        Self.log.notice("bootstrap: ready, hotkey installed")
        setState(symbol: "mic", status: "Mic off — hold Fn or double-press Fn")
    }

    // MARK: - Recording

    private func beginRecording(locked: Bool) {
        guard !isRecording, !isProcessing else { return }
        Self.log.notice("beginRecording: starting microphone")
        recordingGeneration += 1
        let generation = recordingGeneration
        isRecording = true
        recordingReady = false

        let frontmost = NSWorkspace.shared.frontmostApplication
        context = RecordingContext(
            startedAt: .now,
            appBundleID: frontmost?.bundleIdentifier,
            appName: frontmost?.localizedName
        )
        setState(symbol: "mic", status: "Starting microphone…")
        overlayReveal?.cancel()
        overlay.hideImmediately()
        overlay.setLocked(locked)

        // Startup has its own deadline, even if the user keeps holding the key.
        // Stop requesting hardware on failure; no retry may outlive this press.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.sessionStartDeadlineSeconds))
            guard !Task.isCancelled, let self,
                  self.recordingGeneration == generation, self.isRecording, !self.recordingReady else { return }
            self.failRecordingStart("Microphone didn't start — release and try again", generation: generation)
        }

        let stream = audio.start()
        previewStats = PreviewStats()
        let pressAt = ContinuousClock.now
        startTask = Task { [weak self] in
            guard let self else { return nil }
            guard await audio.waitUntilReady(), !Task.isCancelled,
                  self.isRecording, self.recordingGeneration == generation,
                  let audioEpoch = audio.captureEpoch else { return nil }

            var session: TranscriptionSession?
            do {
                let (prepared, _) = try await engine.makeSession()
                session = prepared
                guard !Task.isCancelled, self.isRecording, self.recordingGeneration == generation else {
                    await prepared.abort()
                    return nil
                }
                try await prepared.start(
                    stream,
                    audioEpoch: audioEpoch,
                    onFinalResult: { _, _ in }
                ) { [weak self] committed, volatile, lagMs in
                    Task { @MainActor in
                        guard let self, self.isRecording, self.recordingReady,
                              self.recordingGeneration == generation else { return }
                        self.previewStats.record(lagMs: lagMs, sincePress: pressAt)
                        self.overlay.update(
                            committed: committed,
                            volatile: committed.isEmpty && volatile.isEmpty ? "Speak now" : volatile)
                    }
                }
                guard !Task.isCancelled, self.isRecording, self.recordingGeneration == generation else {
                    await prepared.abort()
                    return nil
                }
                recordingReady = true
                previewStats.startupMs = Int((ContinuousClock.now - pressAt) / .milliseconds(1))
                Self.log.notice("microphone ready: speak now (startup \(self.previewStats.startupMs ?? 0)ms)")
                setState(symbol: hotkey.isLocked ? "lock.fill" : "mic.fill",
                         status: hotkey.isLocked ? "Hands-free" : "Listening — release Fn to finish")
                overlayReveal = Task { [weak self] in
                    guard let self else { return }
                    // A short first tap must never flash a panel, even if the
                    // microphone starts unusually quickly. Locked recordings
                    // can appear as soon as audio and recognition are ready.
                    if !self.hotkey.isLocked {
                        let elapsed = Double((ContinuousClock.now - pressAt) / .milliseconds(1)) / 1000
                        let remaining = max(0, FnGesture.tapDuration - elapsed)
                        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                    }
                    guard !Task.isCancelled, self.isRecording, self.recordingReady,
                          self.recordingGeneration == generation else { return }
                    self.overlay.show(message: "Speak now")
                }
                watchdog?.cancel()
                watchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.maxRecordingSeconds))
                    guard !Task.isCancelled, let self, self.recordingGeneration == generation else { return }
                    self.hotkey.resetPressedState(keepingKeyDown: true)
                    await self.endRecording()
                }
                return prepared
            } catch {
                failRecordingStart("Microphone unavailable — release and try again", generation: generation)
                await session?.abort()
                return nil
            }
        }
    }

    private func failRecordingStart(_ message: String, generation: Int) {
        guard recordingGeneration == generation, isRecording else { return }
        Self.log.error("recording startup failed; stopping microphone")
        cancelRecordingForSleep()
        setState(symbol: "mic.slash", status: message)
        overlay.show(message: message)
    }

    /// Also used for a release before readiness. Late startup completions are
    /// cancelled and generation-guarded, so they cannot revive capture or the UI.
    private func cancelRecordingForSleep(resetHotkey: Bool = true) {
        if resetHotkey { hotkey.resetPressedState(keepingKeyDown: true) }
        recordingGeneration += 1
        isRecording = false
        recordingReady = false
        watchdog?.cancel()
        watchdog = nil
        let pending = startTask
        startTask = nil
        pending?.cancel()
        audio.stop()
        overlayReveal?.cancel()
        overlayReveal = nil
        overlay.setLocked(false)
        _ = audio.takeRecordedSamples16k()
        context = nil
        overlay.hide()
        if !isProcessing { setState(symbol: "mic", status: "Mic off — hold Fn or double-press Fn") }
        if let pending {
            Task {
                if let session = await pending.value { await session.abort() }
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
        let releasedAt = ContinuousClock.now
        Self.log.notice("endRecording: isRecording=\(self.isRecording)")
        guard !isProcessing else { return }
        guard isRecording else {
            // A release with nothing recording means the press and release
            // transitions raced, or the press was lost. Either way the panel may
            // be sitting on "Listening" with nothing behind it, so the UI has to
            // be put back — a stuck panel is indistinguishable from a dead
            // hotkey, and the user has no way out of it.
            overlay.hide()
            setState(symbol: "mic", status: "Mic off — hold Fn or double-press Fn")
            return
        }
        guard recordingReady else {
            Self.log.notice("released before microphone ready; startup cancelled")
            cancelRecordingForSleep()
            return
        }
        isRecording = false
        recordingReady = false
        isProcessing = true
        overlayReveal?.cancel()
        overlayReveal = nil
        defer { isProcessing = false }
        // Release closes the mic before any recognizer/formatter wait.
        audio.stop()
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
        let samples = audio.takeRecordedSamples16k()
        let audioSeconds = Double(samples.count) / MelFrontend.sampleRate
        let signal = SilenceGate.assess(samples)
        let health = audio.captureHealth()
        let audioHealth = TranscriptEntry.AudioHealth(
            device: health.device, deviceRate: health.deviceRate, tapRate: health.tapRate,
            peak: signal.peak, seconds: audioSeconds,
            maxFrameRMS: signal.maxFrameRMS, activeMs: signal.activeMs,
            longestActiveMs: signal.longestActiveMs, silenceSkipped: !signal.hasSignal)
        if !signal.hasSignal {
            // Do not finalize either recognizer, format, or touch the clipboard.
            // Apple's live preview may already have guessed words from noise;
            // those guesses are not evidence that the user spoke.
            overlay.hideImmediately()
            setState(symbol: "mic", status: "Mic off — hold Fn or double-press Fn")
            Self.log.notice("silence skipped: peak=\(signal.peak) maxRMS=\(signal.maxFrameRMS) sustained=\(signal.longestActiveMs)ms")
            pending?.cancel()
            Task {
                if let session = await pending?.value { await session.abort() }
            }
            await log("", formatted: nil, recognition: [],
                      timings: .init(finalizeMs: 0, formatMs: 0, settleMs: 0, insertMs: 0,
                                     startupMs: previewStats.startupMs,
                                     cleanupEnabled: !UserDefaults.standard.bool(forKey: Self.verbatimKey)),
                      audio: audioHealth, context: context)
            return
        }
        let session = await Self.abandoning(after: Self.sessionStartDeadlineSeconds) {
            await pending?.value
        } ?? nil

        guard let session else {
            Self.log.error("endRecording: session never started; dictation dropped")
            pending?.cancel()
            audio.stop()
            overlay.hide()
            setState(symbol: "mic.slash", status: "Transcriber didn't start — try again")
            return
        }
        setState(symbol: "mic", status: "Transcribing…")
        overlay.waiting()

        // Start Parakeet immediately. Apple finalization will run concurrently
        // as a bounded fallback, but cannot delay a successful Parakeet result.
        let parakeetTask: Task<EngineTranscript?, Never>? = (parakeetReady && !samples.isEmpty)
            ? Task.detached(priority: .userInitiated) { [parakeet] in
                let startedAt = ContinuousClock.now
                let text = (try? parakeet.transcribe(samples16k: samples)) ?? ""
                return EngineTranscript(
                    text: text,
                    runtimeMs: Int((ContinuousClock.now - startedAt) / .milliseconds(1)))
            }
            : nil
        let cleanupEnabled = !UserDefaults.standard.bool(forKey: Self.verbatimKey)

        let clock = ContinuousClock()
        var stamp = clock.now
        func lap() -> Int {
            let now = clock.now
            defer { stamp = now }
            return Int((now - stamp) / .milliseconds(1))
        }

        let selection = await TranscriptSelector.select(
            preferred: parakeetTask,
            preferredDeadline: max(10, audioSeconds),
            fallback: {
                let startedAt = ContinuousClock.now
                guard let result = try? await session.finish() else { return nil }
                return EngineTranscript(
                    text: result.text,
                    runtimeMs: Int((ContinuousClock.now - startedAt) / .milliseconds(1)),
                    recognition: result.recognition)
            },
            cancelFallback: { await session.abort() })
        let finalizeMs = selection.fallbackWaitMs
        let parakeetMs = selection.parakeetWaitMs
        let appleTrimmed = selection.apple?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let recognition = selection.apple?.recognition ?? []
        let usedParakeet = selection.usedParakeet
        let trimmed = selection.text
        // The two waits above partition selection time; formatting begins now.
        stamp = clock.now
        Self.log.notice("transcript selected: parakeet=\(usedParakeet) preferredWait=\(parakeetMs)ms fallbackWait=\(finalizeMs)ms cleanup=\(cleanupEnabled)")

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
                    maxPreviewLagMs: previewStats.maxPreviewLagMs,
                    parakeetTotalMs: selection.parakeetTotalMs,
                    appleFinalizeMs: selection.apple?.runtimeMs,
                    releaseToPasteMs: nil,
                    cleanupEnabled: cleanupEnabled
                ),
                audio: audioHealth,
                context: context
            )
        } else {
            var output = trimmed
            if cleanupEnabled,
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
            let releaseToPasteMs = Int((ContinuousClock.now - releasedAt) / .milliseconds(1))
            Self.log.notice("paste posted: releaseToPaste=\(releaseToPasteMs)ms parakeetTotal=\(selection.parakeetTotalMs ?? -1)ms")

            await log(
                trimmed,
                engine: usedParakeet ? "parakeet-int8" : "apple",
                appleRaw: usedParakeet && !appleTrimmed.isEmpty ? appleTrimmed : nil,
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
                    maxPreviewLagMs: previewStats.maxPreviewLagMs,
                    parakeetTotalMs: selection.parakeetTotalMs,
                    appleFinalizeMs: selection.apple?.runtimeMs,
                    releaseToPasteMs: releaseToPasteMs,
                    cleanupEnabled: cleanupEnabled
                ),
                pasteTarget: pasteTarget,
                audio: audioHealth,
                context: context
            )
        }
        if audioSeconds == 0 {
            setState(symbol: "mic.slash", status: "Mic heard nothing — try again")
        } else {
            setState(symbol: "mic", status: "Mic off — hold Fn or double-press Fn")
        }
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

    static func awaitValue<T: Sendable>(          // internal for DeadlineTests
        of task: Task<T?, Never>?, deadline seconds: Double
    ) async -> T? {
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
