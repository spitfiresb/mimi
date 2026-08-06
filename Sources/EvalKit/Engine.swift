import Foundation

/// What every ASR engine under test looks like to the harness. Stage 4's
/// ParakeetEngine conforms to this same protocol and appears on the same report.
public protocol EvalEngine: Sendable {
    var name: String { get }
    func prepare() async throws
    /// Transcribe one audio file, returning the text and how long inference took.
    func transcribe(_ audioURL: URL) async throws -> (text: String, processing: Duration)
}

/// One utterance's scored outcome.
public struct UtteranceScore: Codable, Sendable {
    public let id: String
    public let reference: String
    public let hypothesis: String
    public let wer: Double
    public let errors: Int
    public let referenceWords: Int
    public let audioSeconds: Double
    public let processingSeconds: Double

    public var rtf: Double { audioSeconds > 0 ? processingSeconds / audioSeconds : 0 }
}

/// The aggregate an engine walks away with.
public struct EngineReport: Codable, Sendable {
    public let engine: String
    public let utterances: [UtteranceScore]
    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int
    public let referenceWords: Int
    public let audioSeconds: Double
    public let processingSeconds: Double

    /// Corpus-level WER: total errors over total reference words, the standard
    /// aggregation (not a mean of per-utterance rates, which overweights short
    /// clips).
    public var wer: Double {
        referenceWords == 0 ? 0 : Double(substitutions + insertions + deletions) / Double(referenceWords)
    }
    public var rtf: Double { audioSeconds > 0 ? processingSeconds / audioSeconds : 0 }

    public init(engine: String, utterances: [UtteranceScore], aggregate: WERResult,
                audioSeconds: Double, processingSeconds: Double) {
        self.engine = engine
        self.utterances = utterances
        self.substitutions = aggregate.substitutions
        self.insertions = aggregate.insertions
        self.deletions = aggregate.deletions
        self.referenceWords = aggregate.referenceWords
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
    }
}

public enum Harness {
    /// Run one engine over the set. Sequential on purpose: parallel decodes
    /// would contend for the same accelerator and poison the RTF numbers.
    public static func run(
        engine: any EvalEngine,
        over utterances: [Utterance],
        audioSeconds: @Sendable (URL) throws -> Double,
        progress: @Sendable (Int, Int, UtteranceScore) -> Void = { _, _, _ in }
    ) async throws -> EngineReport {
        try await engine.prepare()

        var scores: [UtteranceScore] = []
        var aggregate = WERResult.zero
        var totalAudio = 0.0
        var totalProcessing = 0.0

        for (index, utterance) in utterances.enumerated() {
            let seconds = try audioSeconds(utterance.audioURL)
            let (text, processing) = try await engine.transcribe(utterance.audioURL)
            let result = WER.score(reference: utterance.reference, hypothesis: text)
            let processingSeconds = Double(processing.components.seconds)
                + Double(processing.components.attoseconds) / 1e18

            let score = UtteranceScore(
                id: utterance.id,
                reference: utterance.reference,
                hypothesis: text,
                wer: result.wer,
                errors: result.errors,
                referenceWords: result.referenceWords,
                audioSeconds: seconds,
                processingSeconds: processingSeconds
            )
            scores.append(score)
            aggregate = aggregate + result
            totalAudio += seconds
            totalProcessing += processingSeconds
            progress(index + 1, utterances.count, score)
        }

        return EngineReport(
            engine: engine.name,
            utterances: scores,
            aggregate: aggregate,
            audioSeconds: totalAudio,
            processingSeconds: totalProcessing
        )
    }
}
