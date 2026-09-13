import AVFoundation
import ObjCShims
import QuartzCore
import Speech
import os

/// Captures microphone audio and yields it as `AnalyzerInput` in whatever format
/// the transcriber asked for. We never hardcode 16kHz — `SpeechAnalyzer` tells us
/// the format via `bestAvailableAudioFormat(compatibleWith:)`.
///
/// Capture runs only between an explicit start and stop. Startup is asynchronous;
/// callers wait for a real buffer before telling the user to speak. There is no
/// idle pre-roll, microphone I/O or resampling.
final class AudioCapture {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "audio")

    /// Recreated wholesale on revival: an AVAudioEngine that has gone zombie
    /// (isRunning=true, zero buffers delivered) can throw NSExceptions from
    /// installTap on formats that are perfectly valid — its internal state is
    /// not trustworthy once the input has died under it (2026-08-11).
    ///
    /// Optional and lock-guarded because a revival *detaches* the old engine
    /// before tearing it down: if that teardown blocks in the HAL, the stuck
    /// thread is left holding the only reference to a engine nothing else will
    /// ever touch again, instead of wedging the next attempt.
    private var engine: AVAudioEngine?

    /// Guards every field below; the tap callback runs on a real-time audio
    /// thread, revivals run on a background queue, and start/stop run on the
    /// main actor.
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var firstBufferAt: ContinuousClock.Instant?

    /// The recording's converted buffers, kept alongside the analyzer stream so
    /// Parakeet can transcribe the same audio the analyzer heard. Bounded by
    /// `stop()` — one dictation's worth.
    private var recorded: [AVAudioPCMBuffer] = []

    private var outputFormat: AVAudioFormat?

    /// Set when the tap is installed, reported per dictation in the log.
    private var pinnedDevice: AudioDeviceID?
    private var tapRate: Double = 0

    /// Device facts snapshotted on the engine queue at tap-install time, so
    /// `captureHealth()` can answer from memory. See that method for why they
    /// are not read live.
    private var deviceNameSnapshot: String?
    private var deviceRateSnapshot: Double?

    /// Real-buffer readiness, separate from the grace period before recovery.
    private var heartbeat = CaptureHeartbeat()

    /// Revival bookkeeping, guarded by `lock` like everything else here.
    private var revival = RevivalState()

    /// How long a revival may run before it is written off as wedged in the
    /// HAL. Generous: a healthy revival on a cold device takes ~2s, and the
    /// cost of declaring one dead early is a redundant engine rebuild.
    private static let revivalTimeout: TimeInterval = 12.0

    /// Capture-side facts for the transcript log: which device fed the tap, its
    /// hardware rate, and the rate the tap was installed with. A mismatch
    /// between the last two means the input node's cached format went stale
    /// across the device pin — audio arrives garbled at the wrong speed.
    ///
    /// Answers from a snapshot taken at tap-install time rather than querying
    /// CoreAudio now. This runs on the main actor at the end of every
    /// dictation, and `AudioObjectGetPropertyData` is a synchronous round trip
    /// to coreaudiod that can block for as long as coreaudiod is unwell — the
    /// same hazard that froze the app on 2026-08-13, on a path that only exists
    /// to decorate a log line.
    func captureHealth() -> (device: String?, deviceRate: Double?, tapRate: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (deviceNameSnapshot, deviceRateSnapshot, tapRate > 0 ? tapRate : nil)
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
            let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
            rate > 0 else { return nil }
        return rate
    }

    /// The first built-in input device, or nil if this Mac somehow has none —
    /// in which case we fall back to whatever the default input is.
    private static func builtInInputDeviceID() -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else {
            return nil
        }
        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            system, &devicesAddress, 0, nil, &size, &devices) == noErr else { return nil }

        for device in devices {
            // Output-only devices share the same list; require input streams.
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 else {
                continue
            }

            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport) == noErr else {
                continue
            }
            if transport == kAudioDeviceTransportTypeBuiltIn { return device }
        }
        return nil
    }

    /// Configure the output and route observer without opening the microphone.
    func prepare(outputFormat: AVAudioFormat) {
        lock.lock()
        self.outputFormat = outputFormat
        lock.unlock()

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let changed = notification.object as? AVAudioEngine else { return }
            self?.configurationChanged(on: changed)
        }
    }

    private func configurationChanged(on changed: AVAudioEngine) {
        lock.lock()
        let generation = revival.generation
        let relevant = revival.captureRequested && engine === changed
        lock.unlock()
        guard relevant else { return }
        // A start/pin also posts configuration changes. Give its first buffer
        // time to arrive, and ignore notifications from old or unrelated engines.
        DispatchQueue.global().asyncAfter(deadline: .now() + CaptureHeartbeat.stallThreshold + 0.1) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.ensureRunning()
        }
    }

    /// Whether the mic is usable right now, without starting anything.
    var isAvailable: Bool { isDelivering() }

    /// Whether the tap is delivering audio right now.
    ///
    /// Cheap, non-blocking, and safe from any thread, because it reads only
    /// Mimi's own bookkeeping. It deliberately does not consult
    /// `AVAudioEngine.isRunning`: that takes the engine's internal state lock,
    /// which a revival wedged inside the HAL may be holding, so the health
    /// check would hang on exactly the failure it exists to detect.
    private func isDelivering() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revival.captureRequested && heartbeat.isDelivering(at: CACurrentMediaTime())
    }

    /// Recover an active dictation without ever starting capture while idle.
    /// Reads only local state: AVAudioEngine.isRunning can itself hang on a
    /// CoreAudio lock, so it must not be queried from the main thread.
    @discardableResult
    func ensureRunning() -> Bool {
        lock.lock()
        let now = CACurrentMediaTime()
        let ready = revival.captureRequested && heartbeat.isDelivering(at: now)
        let shouldRecover = revival.captureRequested && heartbeat.needsRecovery(at: now)
        lock.unlock()
        if shouldRecover { scheduleRevival(reason: "engine not delivering") }
        return ready
    }

    /// Start or recover only while capture is requested. Coalesce configuration
    /// notifications and reject all idle or already-running requests.
    private func scheduleRevival(reason: String, delay: TimeInterval = 0) {
        lock.lock()
        let claimed = revival.begin()
        lock.unlock()
        guard let generation = claimed else { return }

        Self.log.warning("reviving engine (gen \(generation)): \(reason)")

        // A concurrent queue, not a serial one. A serial queue would be poisoned
        // by the first wedged attempt: every retry would queue behind a block
        // that never returns, which is the original bug with a background thread
        // substituted for the main one. Overlapping attempts are made safe
        // instead — each builds its own engine and publishes only if it still
        // holds the newest generation.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.revive(generation: generation)
        }

        // A revival stuck in the HAL cannot be cancelled or killed; the thread
        // is gone for as long as coreaudiod says so. All that can be done is
        // stop waiting on it and let a later attempt try a fresh engine, only
        // if the user still wants capture.
        DispatchQueue.global().asyncAfter(deadline: .now() + delay + Self.revivalTimeout) { [weak self] in
            self?.abandonRevivalIfStuck(generation: generation)
        }
    }

    private func revive(generation: Int) {
        lock.lock()
        guard revival.isCurrent(generation), revival.inFlight else {
            lock.unlock()
            return
        }
        let outputFormat = self.outputFormat
        // Detach the old engine before touching it. If its teardown blocks in
        // the HAL, this thread is left holding the only reference to it and no
        // later attempt can be dragged down with it.
        let old = self.engine
        self.engine = nil
        heartbeat.reset()
        lock.unlock()

        guard let outputFormat else {
            Self.log.error("revival with no output format; nothing to install")
            finish(generation: generation)
            return
        }

        if let old, let error = MMCatchException({
            old.stop()
            old.inputNode.removeTap(onBus: 0)
        }) {
            Self.log.warning("old engine teardown threw (continuing): \(error.localizedDescription)")
        }

        guard isCurrent(generation) else { return }
        let fresh = AVAudioEngine()
        do {
            let facts = try installTapAndStart(on: fresh, outputFormat: outputFormat, generation: generation)
            publish(engine: fresh, facts: facts, generation: generation)
        } catch {
            Self.log.error("engine revival failed: \(error.localizedDescription)")
            if let objcError = MMCatchException({ fresh.stop() }) {
                Self.log.warning("failed engine stop threw: \(objcError.localizedDescription)")
            }
            finish(generation: generation)
        }
    }

    /// Adopt a freshly started engine, unless a newer attempt got there first.
    private func publish(engine fresh: AVAudioEngine, facts: TapFacts, generation: Int) {
        lock.lock()
        guard revival.succeed(generation) else {
            lock.unlock()
            Self.log.notice("revival gen \(generation) superseded; discarding its engine")
            if let error = MMCatchException({ fresh.stop() }) {
                Self.log.warning("superseded engine stop threw: \(error.localizedDescription)")
            }
            return
        }
        self.engine = fresh
        heartbeat.started(at: CACurrentMediaTime())
        pinnedDevice = facts.pinnedDevice
        tapRate = facts.tapRate
        deviceNameSnapshot = facts.deviceName
        deviceRateSnapshot = facts.deviceRate
        lock.unlock()

        Self.log.notice("capture engine started; waiting for audio")
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revival.isCurrent(generation)
    }

    /// Readiness requires a real converted buffer, not merely engine.start().
    /// The caller owns the startup deadline and cancellation.
    func waitUntilReady() async -> Bool {
        while !Task.isCancelled {
            if isAvailable { return true }
            guard captureRequested else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        return false
    }

    private var captureRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return revival.captureRequested
    }

    var captureEpoch: ContinuousClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAt
    }

    /// Retire a failed attempt and queue the next one. Only the newest
    /// generation may touch shared state: a superseded attempt changes nothing.
    private func finish(generation: Int) {
        lock.lock()
        let failures = revival.fail(generation)
        lock.unlock()

        guard let failures else {
            Self.log.notice("revival gen \(generation) superseded; discarding its result")
            return
        }

        scheduleRevival(
            reason: "retry after \(failures) failed attempt(s)",
            delay: RevivalState.backoff(consecutiveFailures: failures))
    }

    /// Fires `revivalTimeout` after an attempt started. If that attempt is still
    /// the current one and still in flight, it is blocked in a HAL call that
    /// will not return on any schedule Mimi controls.
    private func abandonRevivalIfStuck(generation: Int) {
        lock.lock()
        let failures = revival.abandonIfStuck(generation)
        lock.unlock()

        guard let failures else { return }

        Self.log.error(
            "revival gen \(generation) still blocked after \(Self.revivalTimeout, format: .fixed(precision: 0))s — abandoning that thread, retrying on a new engine")
        scheduleRevival(
            reason: "previous attempt wedged in CoreAudio",
            delay: RevivalState.backoff(consecutiveFailures: failures))
    }

    /// What a tap install learned about the device it attached to, handed back
    /// rather than written straight to `self`: the caller publishes these only
    /// if its attempt is still the current one.
    private struct TapFacts {
        var pinnedDevice: AudioDeviceID?
        var tapRate: Double
        var deviceName: String?
        var deviceRate: Double?
    }

    /// Builds and starts a tap on `engine`, returning what it learned.
    ///
    /// Runs on a background queue only. Several calls in here — `inputNode`,
    /// `inputFormat(forBus:)`, every `AudioObject` query — are synchronous round
    /// trips to coreaudiod that block for as long as coreaudiod takes to
    /// answer, which after a wake is sometimes forever.
    private func installTapAndStart(
        on engine: AVAudioEngine, outputFormat: AVAudioFormat, generation: Int
    ) throws -> TapFacts {
        guard isCurrent(generation) else { throw CancellationError() }
        let input = engine.inputNode
        var facts = TapFacts(pinnedDevice: nil, tapRate: 0, deviceName: nil, deviceRate: nil)

        // Pin the built-in mic instead of following the system default input.
        //
        // Following the default input can put AirPods into headset mode and
        // degrade playback while dictating. Keep the existing built-in mic
        // preference and avoid Bluetooth route instability.
        if let builtIn = Self.builtInInputDeviceID(), let unit = input.audioUnit {
            var device = builtIn
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            facts.pinnedDevice = builtIn
        }

        // inputFormat, not outputFormat: after pinning a device onto the AUHAL,
        // outputFormat(forBus:) keeps reporting the *previous* default device's
        // rate — measured live: AirPods at 24kHz as system default, built-in
        // pinned at 48kHz, outputFormat still says 24kHz while inputFormat
        // correctly tracks the pinned hardware (2026-08-11). A tap installed at
        // the stale rate gets zero callbacks from CoreAudio, silently, forever:
        // that is what every "dictation heard nothing" today actually was.
        let inputFormat = input.inputFormat(forBus: 0)
        facts.tapRate = inputFormat.sampleRate

        // Snapshot the device facts here, on this background thread, so
        // `captureHealth()` never has to ask CoreAudio from the main actor.
        let device = facts.pinnedDevice ?? Self.defaultInputDeviceID()
        facts.deviceName = device.flatMap(Self.deviceName)
        facts.deviceRate = device.flatMap(Self.nominalSampleRate)

        if let hardwareRate = facts.deviceRate, hardwareRate != inputFormat.sampleRate {
            Self.log.warning(
                "tap rate \(inputFormat.sampleRate) still disagrees with hardware \(hardwareRate); capture may be dead")
        }

        // A dead or mid-transition input device reports a 0Hz/0ch format here.
        // Feeding that to installTap raises an Objective-C NSException that no
        // Swift catch can stop — it unwinds through whatever async caller is on
        // the stack and strands its state (the frozen "Listening" panel,
        // 2026-08-11). Refuse it as a Swift error instead.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Self.log.error("input format invalid (rate=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)); refusing tap install")
            throw MimiError.audioConversionUnsupported
        }

        Self.log.notice("installing tap: input \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch -> output \(outputFormat.sampleRate)Hz")
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MimiError.audioConversionUnsupported
        }
        converter.primeMethod = .none

        // This converter belongs to *this* tap, so the closure captures it
        // instead of reading it back off `self`. A revival that swapped a
        // shared converter mid-flight would leave the outgoing tap resampling
        // at the new engine's rate for the moments before it is removed —
        // garbled audio, from a race that simply cannot arise this way.
        guard isCurrent(generation) else { throw CancellationError() }

        // installTap and start report misuse as NSExceptions, which would
        // otherwise unwind uncatchably through whatever async caller is on the
        // stack. The shim turns them into errors we can log and survive.
        if let objcError = MMCatchException({
            // This block runs on a real-time audio thread. Keep it cheap;
            // yielding to an AsyncStream continuation is safe.
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self, self.isCurrent(generation) else { return }
                guard let converted = self.convert(buffer, using: converter) else { return }

                self.lock.lock()
                // Release or a replacement engine may have raced conversion.
                guard self.revival.isCurrent(generation), let continuation = self.continuation else {
                    self.lock.unlock()
                    return
                }
                self.heartbeat.receivedBuffer(at: CACurrentMediaTime())
                if self.firstBufferAt == nil {
                    let duration = Double(converted.frameLength) / converted.format.sampleRate
                    self.firstBufferAt = ContinuousClock.now - .seconds(duration)
                }
                self.recorded.append(converted)
                continuation.yield(AnalyzerInput(buffer: converted))
                self.lock.unlock()
            }
            engine.prepare()
        }) {
            Self.log.error("tap install threw: \(objcError.localizedDescription)")
            throw objcError
        }

        // Do not open hardware for a request released while device setup ran.
        // A release racing the uninterruptible start itself is handled by publish,
        // which rejects the stale engine and stops it on this background thread.
        guard isCurrent(generation) else { throw CancellationError() }
        var startError: Error?
        if let objcError = MMCatchException({
            do { try engine.start() } catch { startError = error }
        }) {
            Self.log.error("engine start threw: \(objcError.localizedDescription)")
            throw objcError
        }
        if let startError {
            Self.log.error("engine start failed: \(startError.localizedDescription)")
            throw startError
        }

        return facts
    }

    /// Request capture. Hardware startup stays off the main thread; the stream
    /// holds the first buffers while the recognizer prepares.
    func start() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.lock()
        recorded.removeAll()
        firstBufferAt = nil
        heartbeat.reset()
        revival.requestCapture()
        self.continuation = continuation
        lock.unlock()
        scheduleRevival(reason: "hotkey pressed")
        return stream
    }

    /// The finished recording as 16kHz mono Float samples for Parakeet.
    /// Call after `stop()`; drains the recording buffer.
    func takeRecordedSamples16k() -> [Float] {
        lock.lock()
        let buffers = recorded
        recorded = []
        lock.unlock()
        guard let first = buffers.first else { return [] }

        let sourceFormat = first.format
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ) else { return [] }

        var samples: [Float] = []
        if sourceFormat.sampleRate == 16000, sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32 {
            for buffer in buffers {
                guard let data = buffer.floatChannelData else { continue }
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            return samples
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { return [] }
        for buffer in buffers {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / sourceFormat.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { continue }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        }
        return samples
    }

    /// Stop accepting audio immediately, cancel queued starts/retries, and
    /// detach hardware before shutting it down off the main thread. No idle tap
    /// or pre-roll remains. Recorded buffers survive until the caller drains them.
    func stop() {
        lock.lock()
        revival.suspend()
        let continuation = self.continuation
        self.continuation = nil
        let old = engine
        engine = nil
        heartbeat.reset()
        lock.unlock()
        continuation?.finish()
        Self.log.notice("capture stopped; microphone shutdown requested")
        if let old {
            DispatchQueue.global(qos: .userInitiated).async {
                if let error = MMCatchException({
                    old.stop()
                    old.inputNode.removeTap(onBus: 0)
                }) {
                    Self.log.error("microphone shutdown failed: \(error.localizedDescription)")
                } else {
                    Self.log.notice("microphone stopped")
                }
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
