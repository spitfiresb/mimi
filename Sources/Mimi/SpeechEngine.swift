import AVFoundation
import Foundation
import Speech

/// One recording's worth of transcription. Cheap to create — the models stay
/// resident across sessions thanks to `.processLifetime` retention.
final class TranscriptionSession {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var collector: Task<String, Error>?

    init(locale: Locale, options: SpeechAnalyzer.Options) {
        transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
    }

    func start(_ stream: AsyncStream<AnalyzerInput>) async throws {
        let transcriber = self.transcriber
        collector = Task {
            var text = AttributedString()
            for try await result in transcriber.results {
                text += result.text
            }
            return String(text.characters)
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Call *after* the audio stream has been finished, or this will hang.
    func finish() async throws -> String {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector?.value ?? ""
    }

    func cancel() async {
        collector?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

actor SpeechEngine {
    static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    private(set) var locale: Locale?
    private(set) var analyzerFormat: AVAudioFormat?

    var isReady: Bool { locale != nil && analyzerFormat != nil }

    func prepare(progress: @Sendable (String) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw MimiError.transcriberUnavailable }

        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let locale = resolved else { throw MimiError.noSupportedLocale }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // "Zero bytes in the app bundle" still means a one-time OS-level asset
        // download the first time a locale is used.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            progress("Downloading speech model…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

        // Without a reservation the analyzer fails with .assetLocaleNotAllocated.
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MimiError.noCompatibleAudioFormat
        }

        // Warm the models now so the first dictation isn't the slow one.
        progress("Warming up…")
        let warmup = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)
        try await warmup.prepareToAnalyze(in: format)
        await warmup.cancelAndFinishNow()

        self.locale = locale
        self.analyzerFormat = format
    }

    func makeSession() throws -> (TranscriptionSession, AVAudioFormat) {
        guard let locale, let analyzerFormat else { throw MimiError.notPrepared }
        return (TranscriptionSession(locale: locale, options: Self.analyzerOptions), analyzerFormat)
    }
}
