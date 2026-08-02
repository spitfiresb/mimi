import AVFoundation
import Speech

/// Captures microphone audio and yields it as `AnalyzerInput` in whatever format
/// the transcriber asked for. We never hardcode 16kHz — `SpeechAnalyzer` tells us
/// the format via `bestAvailableAudioFormat(compatibleWith:)`.
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    func start(outputFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MimiError.audioConversionUnsupported
        }
        converter.primeMethod = .none
        self.converter = converter

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        // This block runs on a real-time audio thread. Keep it cheap; yielding to
        // an AsyncStream continuation is safe.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
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
