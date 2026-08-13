import AVFoundation
import ObjCShims
import QuartzCore
import Speech
import os

/// Captures microphone audio and yields it as `AnalyzerInput` in whatever format
/// the transcriber asked for. We never hardcode 16kHz — `SpeechAnalyzer` tells us
/// the format via `bestAvailableAudioFormat(compatibleWith:)`.
///
/// The engine runs continuously from `prepare()`, not from keypress. Starting the
/// engine on demand loses the first ~1s of speech to hardware spin-up, which turns
/// "the quarterly report" into "orderly report". While idle, converted audio goes
/// into a small rolling pre-roll buffer; on `start()` the pre-roll is flushed into
/// the stream first, so words spoken slightly before the press still land.
///
/// Privacy: the mic is hot while Mimi runs, but nothing is retained beyond the
/// pre-roll window and nothing ever leaves the process, let alone the machine.
final class AudioCapture {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "audio")

    /// Recreated wholesale on revival: an AVAudioEngine that has gone zombie
    /// (isRunning=true, zero buffers delivered) can throw NSExceptions from
    /// installTap on formats that are perfectly valid — its internal state is
    /// not trustworthy once the input has died under it (2026-08-11).
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    private static let preRollSeconds = 0.5

    /// Guards the three fields below; the tap callback runs on a real-time
    /// audio thread while start/stop run on the main actor.
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0

    /// The recording's converted buffers, kept alongside the analyzer stream so
    /// Parakeet can transcribe the same audio the analyzer heard. Bounded by
    /// `stop()` — one dictation's worth.
    private var recorded: [AVAudioPCMBuffer] = []
    private var isRecordingAudio = false

    private var maxPreRollFrames: AVAudioFrameCount = 0

    private var outputFormat: AVAudioFormat?

    /// Set when the tap is installed, reported per dictation in the log.
    private var pinnedDevice: AudioDeviceID?
    private var tapRate: Double = 0

    /// When the tap last delivered a buffer, guarded by `lock`. At 4096 frames
    /// of 48kHz audio the cadence is ~85ms, so a second of silence from the
    /// callback means the input is dead no matter what `isRunning` says.
    private var lastBufferAt: TimeInterval = 0
    private static let stallThreshold: TimeInterval = 1.0

    /// Capture-side facts for the transcript log: which device fed the tap, its
    /// hardware rate right now, and the rate the tap was installed with. A
    /// mismatch between the last two means the input node's cached format went
    /// stale across the device pin — audio arrives garbled at the wrong speed.
    func captureHealth() -> (device: String?, deviceRate: Double?, tapRate: Double?) {
        let device = pinnedDevice ?? Self.defaultInputDeviceID()
        return (
            device.flatMap(Self.deviceName),
            device.flatMap(Self.nominalSampleRate),
            tapRate > 0 ? tapRate : nil
        )
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

    /// Call once at bootstrap. The engine stays running for the app's lifetime.
    func prepare(outputFormat: AVAudioFormat) throws {
        self.outputFormat = outputFormat
        try installTapAndStart(outputFormat: outputFormat)

        // A route/device change (headphones in, AirPods out, rate switch) stops
        // the engine's I/O and posts this instead of throwing anywhere.
        // object is nil, not the engine: revival replaces the engine instance,
        // and an observer pinned to the old object would go deaf exactly when
        // it matters most.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.ensureRunning()
        }
    }

    /// Sleep/wake and device changes silently stop the engine — a hot mic is only
    /// hot until the first lid close. Re-prepares from scratch: the input format
    /// may have changed while we were down (different mic, different rate).
    ///
    /// `engine.isRunning` alone is not a health check: after a configuration
    /// change the engine can report running while the input render callbacks
    /// have stopped for good. That zombie state recorded peak=0/seconds=0 for
    /// every dictation across 8 minutes of retries while this guard kept
    /// returning early (2026-08-11). So trust the buffer heartbeat instead:
    /// running-but-silent past the stall threshold gets torn down and rebuilt.
    /// Returns whether the engine is delivering (or was just revived and should
    /// be) — false means the mic is genuinely unavailable and the caller must
    /// not pretend to listen.
    @discardableResult
    func ensureRunning() -> Bool {
        guard let outputFormat else { return false }
        lock.lock()
        let last = lastBufferAt
        lock.unlock()
        let sinceBuffer = CACurrentMediaTime() - last
        let stalled = engine.isRunning && sinceBuffer > Self.stallThreshold
        guard !engine.isRunning || stalled else { return true }
        Self.log.warning(
            "reviving engine: isRunning=\(self.engine.isRunning) sinceBuffer=\(sinceBuffer, format: .fixed(precision: 2))s")

        // Tear the old engine down defensively — it may throw from any call at
        // this point — and replace it outright rather than reuse it.
        if let error = MMCatchException({
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
        }) {
            Self.log.warning("old engine teardown threw (continuing): \(error.localizedDescription)")
        }
        engine = AVAudioEngine()

        lock.lock()
        preRoll.removeAll()
        preRollFrames = 0
        lock.unlock()
        do {
            try installTapAndStart(outputFormat: outputFormat)
            Self.log.notice("engine revived")
            return true
        } catch {
            Self.log.error("engine revival failed: \(error.localizedDescription)")
            return false
        }
    }

    private func installTapAndStart(outputFormat: AVAudioFormat) throws {
        let input = engine.inputNode

        // Pin the built-in mic instead of following the system default input.
        //
        // The engine runs for the app's lifetime, so following the default means
        // a connected pair of AirPods sits in microphone mode permanently: macOS
        // hands their controls to the capturing app ("Cannot Control Mic with
        // AirPods"), a tap that should play music does nothing, and both
        // earpieces drop to headset audio quality the whole time Mimi is open.
        // Bluetooth route changes are also the least stable input an
        // AVAudioEngine can be handed. A laptop with a good built-in array has
        // nothing to gain here. Becomes a setting once there's UI for it.
        if let builtIn = Self.builtInInputDeviceID(), let unit = input.audioUnit {
            var device = builtIn
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            pinnedDevice = builtIn
        }

        // inputFormat, not outputFormat: after pinning a device onto the AUHAL,
        // outputFormat(forBus:) keeps reporting the *previous* default device's
        // rate — measured live: AirPods at 24kHz as system default, built-in
        // pinned at 48kHz, outputFormat still says 24kHz while inputFormat
        // correctly tracks the pinned hardware (2026-08-11). A tap installed at
        // the stale rate gets zero callbacks from CoreAudio, silently, forever:
        // that is what every "dictation heard nothing" today actually was.
        let inputFormat = input.inputFormat(forBus: 0)
        tapRate = inputFormat.sampleRate

        if let pinnedDevice, let hardwareRate = Self.nominalSampleRate(pinnedDevice),
           hardwareRate != inputFormat.sampleRate {
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
        self.converter = converter
        maxPreRollFrames = AVAudioFrameCount(outputFormat.sampleRate * Self.preRollSeconds)

        // installTap and start report misuse as NSExceptions, which would
        // otherwise unwind uncatchably through whatever async caller is on the
        // stack. The shim turns them into errors we can log and survive.
        if let objcError = MMCatchException({
            // This block runs on a real-time audio thread. Keep it cheap;
            // yielding to an AsyncStream continuation is safe.
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                self.lock.lock()
                self.lastBufferAt = CACurrentMediaTime()
                self.lock.unlock()
                guard let converted = self.convert(buffer) else { return }

                self.lock.lock()
                if let continuation = self.continuation {
                    if self.isRecordingAudio { self.recorded.append(converted) }
                    self.lock.unlock()
                    continuation.yield(AnalyzerInput(buffer: converted))
                } else {
                    self.preRoll.append(converted)
                    self.preRollFrames += converted.frameLength
                    while self.preRollFrames > self.maxPreRollFrames, !self.preRoll.isEmpty {
                        self.preRollFrames -= self.preRoll.removeFirst().frameLength
                    }
                    self.lock.unlock()
                }
            }
            self.engine.prepare()
        }) {
            Self.log.error("tap install threw: \(objcError.localizedDescription)")
            throw objcError
        }

        var startError: Error?
        if let objcError = MMCatchException({
            do { try self.engine.start() } catch { startError = error }
        }) {
            Self.log.error("engine start threw: \(objcError.localizedDescription)")
            throw objcError
        }
        if let startError {
            Self.log.error("engine start failed: \(startError.localizedDescription)")
            throw startError
        }

        // Seed the heartbeat so a dictation begun before the first buffer
        // arrives doesn't read as a stall and tear the engine straight down.
        lock.lock()
        lastBufferAt = CACurrentMediaTime()
        lock.unlock()
    }

    /// Begin a recording: returns a stream that starts with the pre-roll and
    /// continues with live audio until `stop()`.
    func start() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Flush the pre-roll before publishing the continuation, inside the lock,
        // so a live frame from the tap can't jump ahead of buffered audio.
        lock.lock()
        recorded = preRoll
        isRecordingAudio = true
        for buffer in preRoll {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        preRoll.removeAll()
        preRollFrames = 0
        self.continuation = continuation
        lock.unlock()

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

    /// End the recording. The engine keeps running; audio goes back to the
    /// pre-roll buffer.
    func stop() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        isRecordingAudio = false
        lock.unlock()
        continuation?.finish()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }

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
