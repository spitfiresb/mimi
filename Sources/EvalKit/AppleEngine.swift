import AVFoundation
import Foundation
import Speech

/// The baseline arm: Apple's `SpeechTranscriber`, fed from a file the same way
/// the app feeds it from the mic — converted to the analyzer's preferred format
/// and streamed as `AnalyzerInput`. One final-only module; no preview, no
/// contextual strings, so this measures the engine, not Mimi's plumbing.
public final class AppleEngine: EvalEngine {
    public let name = "SpeechTranscriber"
    private let lock = NSLock()
    private nonisolated(unsafe) var locale: Locale?
    private nonisolated(unsafe) var format: AVAudioFormat?

    public init() {}

    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw EvalError.engineUnavailable("SpeechTranscriber is not available on this system")
        }
        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        }
        guard let locale = resolved else {
            throw EvalError.engineUnavailable("no supported locale")
        }

        let module = Self.makeModule(locale: locale)
        if await AssetInventory.status(forModules: [module]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw EvalError.engineUnavailable("no compatible audio format")
        }

        // Warm once so the first scored utterance doesn't carry model load time.
        let warmup = SpeechAnalyzer(modules: [Self.makeModule(locale: locale)], options: Self.options)
        try await warmup.prepareToAnalyze(in: format)
        await warmup.cancelAndFinishNow()

        lock.withLock {
            self.locale = locale
            self.format = format
        }
    }

    public func transcribe(_ audioURL: URL) async throws -> (text: String, processing: Duration) {
        let (locale, format) = lock.withLock { (self.locale, self.format) }
        guard let locale, let format else { throw EvalError.engineUnavailable("prepare() not called") }

        let buffers = try Self.readAndConvert(audioURL, to: format)

        let clock = ContinuousClock()
        let start = clock.now

        let module = Self.makeModule(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module], options: Self.options)

        let collector = Task {
            var text = AttributedString()
            for try await result in module.results {
                text += result.text
            }
            return String(text.characters)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for buffer in buffers {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()

        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value

        return (text, clock.now - start)
    }

    public static func audioSeconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static let options = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    private static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// Decode the whole file and convert to the analyzer's format in ~0.5s
    /// chunks. Decoding is excluded from the timed section deliberately — RTF
    /// should charge the engine for inference, not the harness for FLAC.
    private static func readAndConvert(_ url: URL, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw EvalError.audioConversionFailed(url.lastPathComponent)
        }

        let chunkFrames = AVAudioFrameCount(sourceFormat.sampleRate / 2)
        var buffers: [AVAudioPCMBuffer] = []

        while file.framePosition < file.length {
            guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                throw EvalError.audioConversionFailed(url.lastPathComponent)
            }
            try file.read(into: source, frameCount: chunkFrames)
            guard source.frameLength > 0 else { break }

            let ratio = format.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up) + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw EvalError.audioConversionFailed(url.lastPathComponent)
            }

            var fed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return source
            }
            if let conversionError { throw conversionError }
            if converted.frameLength > 0 { buffers.append(converted) }
        }

        return buffers
    }
}

public enum EvalError: Error, CustomStringConvertible {
    case engineUnavailable(String)
    case audioConversionFailed(String)

    public var description: String {
        switch self {
        case .engineUnavailable(let why): "engine unavailable: \(why)"
        case .audioConversionFailed(let file): "audio conversion failed: \(file)"
        }
    }
}
