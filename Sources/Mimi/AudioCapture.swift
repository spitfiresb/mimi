import AVFoundation
import Speech

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
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    private static let preRollSeconds = 0.5

    /// Guards the three fields below; the tap callback runs on a real-time
    /// audio thread while start/stop run on the main actor.
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0

    private var maxPreRollFrames: AVAudioFrameCount = 0

    /// Call once at bootstrap. The engine stays running for the app's lifetime.
    func prepare(outputFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MimiError.audioConversionUnsupported
        }
        converter.primeMethod = .none
        self.converter = converter
        maxPreRollFrames = AVAudioFrameCount(outputFormat.sampleRate * Self.preRollSeconds)

        // This block runs on a real-time audio thread. Keep it cheap; yielding to
        // an AsyncStream continuation is safe.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }

            self.lock.lock()
            if let continuation = self.continuation {
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

        engine.prepare()
        try engine.start()
    }

    /// Begin a recording: returns a stream that starts with the pre-roll and
    /// continues with live audio until `stop()`.
    func start() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Flush the pre-roll before publishing the continuation, inside the lock,
        // so a live frame from the tap can't jump ahead of buffered audio.
        lock.lock()
        for buffer in preRoll {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        preRoll.removeAll()
        preRollFrames = 0
        self.continuation = continuation
        lock.unlock()

        return stream
    }

    /// End the recording. The engine keeps running; audio goes back to the
    /// pre-roll buffer.
    func stop() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
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
