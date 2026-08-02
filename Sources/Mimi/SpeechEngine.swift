import AVFoundation
import Foundation
import Speech

/// One recording's worth of transcription.
///
/// Two transcriber modules, which is Apple's documented pattern: a module that
/// emits volatile results is *not required* to reissue them as final if
/// finalization didn't change them, so filtering a single progressive module on
/// `isFinal` silently drops text. Instead one module provides the live preview
/// and a second, final-only module provides the authoritative transcript.
///
/// The progressive preset also includes `fastResults`, documented as "faster but
/// also less accurate" — fine for a preview, wrong for what we insert.
final class TranscriptionSession {
    private let previewTranscriber: SpeechTranscriber
    private let finalTranscriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer

    private var collector: Task<String, Error>?
    private var previewTask: Task<Void, Never>?

    init(locale: Locale, options: SpeechAnalyzer.Options) {
        let modules = SpeechEngine.makeModules(locale: locale)
        previewTranscriber = modules.preview
        finalTranscriber = modules.final
        analyzer = SpeechAnalyzer(modules: [modules.preview, modules.final], options: options)
    }

    func start(
        _ stream: AsyncStream<AnalyzerInput>,
        onPreview: @escaping @Sendable (String) -> Void
    ) async throws {
        let final = finalTranscriber
        collector = Task {
            var text = AttributedString()
            for try await result in final.results {
                text += result.text
            }
            return String(text.characters)
        }

        let preview = previewTranscriber
        previewTask = Task {
            // Volatile results are tentative for their range and get superseded,
            // so render committed text plus the current volatile tail rather than
            // appending every result.
            var committed = AttributedString()
            do {
                for try await result in preview.results {
                    if result.isFinal {
                        committed += result.text
                        onPreview(String(committed.characters))
                    } else {
                        var live = committed
                        live += result.text
                        onPreview(String(live.characters))
                    }
                }
            } catch {
                // Preview is best-effort; the final transcript is what matters.
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Call *after* the audio stream has been finished, or this will hang.
    func finish() async throws -> String {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector?.value ?? ""
        previewTask?.cancel()
        return text
    }

}

actor SpeechEngine {
    static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    static func makeModules(locale: Locale) -> (preview: SpeechTranscriber, final: SpeechTranscriber) {
        (
            preview: SpeechTranscriber(locale: locale, preset: .progressiveTranscription),
            final: SpeechTranscriber(locale: locale, preset: .transcription)
        )
    }

    private(set) var locale: Locale?
    private(set) var analyzerFormat: AVAudioFormat?

    func prepare(progress: @Sendable (String) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw MimiError.transcriberUnavailable }

        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let locale = resolved else { throw MimiError.noSupportedLocale }

        let pair = Self.makeModules(locale: locale)
        let modules: [any SpeechModule] = [pair.preview, pair.final]

        // "Zero bytes in the app bundle" still means a one-time OS-level asset
        // download. Request for both modules — they need different assets.
        if await AssetInventory.status(forModules: modules) != .installed {
            progress("Downloading speech model…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        }

        // Without a reservation the analyzer fails with .assetLocaleNotAllocated.
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw MimiError.noCompatibleAudioFormat
        }

        // Warm the models now so the first dictation isn't the slow one.
        progress("Warming up…")
        let warmup = SpeechAnalyzer(modules: modules, options: Self.analyzerOptions)
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
