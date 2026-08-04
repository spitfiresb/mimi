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

    private var collector: Task<(String, [RecognitionResult]), Error>?
    private var previewTask: Task<Void, Never>?

    init(locale: Locale, options: SpeechAnalyzer.Options) {
        let modules = SpeechEngine.makeModules(locale: locale)
        previewTranscriber = modules.preview
        finalTranscriber = modules.final
        analyzer = SpeechAnalyzer(modules: [modules.preview, modules.final], options: options)
    }

    /// `audioEpoch` is when the audio stream's clock started: the keypress minus
    /// the pre-roll. Each preview callback reports how far behind the spoken
    /// word the recognizer is running — wall clock now vs. the audio timestamp
    /// of the result it just produced.
    func start(
        _ stream: AsyncStream<AnalyzerInput>,
        audioEpoch: ContinuousClock.Instant,
        onPreview: @escaping @Sendable (_ committed: String, _ volatile: String, _ lagMs: Int) -> Void
    ) async throws {
        let final = finalTranscriber
        collector = Task {
            var text = AttributedString()
            var detail: [RecognitionResult] = []
            for try await result in final.results {
                text += result.text
                detail.append(Self.recognitionDetail(of: result))
            }
            return (String(text.characters), detail)
        }

        let preview = previewTranscriber
        previewTask = Task {
            // Volatile results are tentative for their range and get superseded,
            // so render committed text plus the current volatile tail rather than
            // appending every result.
            var committed = AttributedString()
            do {
                for try await result in preview.results {
                    let audioEnd = result.range.end.seconds
                    let lagMs = audioEnd.isFinite
                        ? Int((ContinuousClock.now - audioEpoch) / .milliseconds(1)) - Int(audioEnd * 1000)
                        : 0
                    if result.isFinal {
                        committed += result.text
                        onPreview(String(committed.characters), "", lagMs)
                    } else {
                        onPreview(String(committed.characters), String(result.text.characters), lagMs)
                    }
                }
            } catch {
                // Preview is best-effort; the final transcript is what matters.
            }
        }

        // Bias recognition toward the user's vocabulary. Read per session so
        // edits to the file apply to the next dictation. Whether SpeechTranscriber
        // honors this is roadmap open question #1 — the log will tell us.
        let terms = Vocabulary.terms()
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try? await analyzer.setContext(context)
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Call *after* the audio stream has been finished, or this will hang.
    func finish() async throws -> (text: String, recognition: [RecognitionResult]) {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (text, recognition) = try await collector?.value ?? ("", [])
        previewTask?.cancel()
        return (text, recognition)
    }

    /// Tear down without waiting for graceful finalization — the escape hatch
    /// when `finish()` doesn't return.
    func abort() async {
        previewTask?.cancel()
        collector?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private static func recognitionDetail(of result: SpeechTranscriber.Result) -> RecognitionResult {
        var spans: [RecognitionResult.Span] = []
        for (confidence, range) in result.text.runs[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
            let t = String(result.text[range].characters)
            guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            spans.append(.init(t: t, c: confidence))
        }
        return RecognitionResult(
            text: String(result.text.characters),
            alts: result.alternatives.prefix(3).map { String($0.characters) },
            spans: spans
        )
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
            // Explicit init instead of the .transcription preset: we also want the
            // n-best alternatives and per-run confidence the recognizer computes
            // anyway and normally discards. Logged now, used by the formatting
            // pass later.
            final: SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.alternativeTranscriptions],
                attributeOptions: [.transcriptionConfidence]
            )
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
