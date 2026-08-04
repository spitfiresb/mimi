import Foundation
import FoundationModels

/// The Stage 2 formatting pass: Apple's on-device Foundation Model cleans up the
/// transcript sentence by sentence, and a mechanical guard keeps it honest.
///
/// The model makes judgments (disfluencies, false starts, "no wait X" corrections,
/// ITN); deterministic code enforces safety. If a rewrite drifts too far from
/// what was said, we discard it and keep the raw sentence — an invented word the
/// user can't detect is worse than a transcription error.
///
/// Output is constrained: the model fills a @Generable struct via guided
/// decoding, so conversational preamble ("Here is the cleaned up text:") is
/// structurally impossible, not just prompt-discouraged. A 3B model treats
/// instructions as suggestions; the decoder doesn't.
actor Formatter {
    @Generable
    struct Cleaned {
        @Guide(description: "The cleaned-up sentence, and nothing else")
        var text: String
    }

    private static let instructions = """
        You clean up dictated text one sentence at a time. Remove filler words \
        (um, uh, like) and false starts. Apply corrections the speaker made \
        mid-sentence ("no wait X" or "I mean X" means use X). Convert spoken \
        forms: "three thirty" becomes 3:30, "twenty five dollars" becomes $25, \
        "dot com" becomes .com, a spoken "slash" in a web address becomes /. \
        Keep the speaker's wording and voice — do not rephrase, summarize, or \
        add anything.
        """

    /// Utterances this short aren't worth a model round-trip.
    static let minimumWords = 3

    /// Reject rewrites where more than this fraction of the output words never
    /// appeared in the raw sentence. Deleting words is what disfluency removal
    /// *does*, so deletions don't count — invention is the failure mode. Some
    /// headroom because ITN legitimately mints tokens ("three thirty" → "3:30").
    private static let maxInventionRatio = 0.4

    /// Below this, a recognizer span marks its sentence as worth a model pass.
    /// From logged data: real errors scored 0.31–0.73, correct words mostly 0.9+.
    static let lowConfidence = 0.8

    /// Sentence-level evidence of mess. Not a rulebook — none of these *fix*
    /// anything; they only route a sentence to the model, which does the judging.
    /// False positives are cheap (one extra model pass), so err broad.
    private static let fillerWords: Set<String> = [
        "um", "uh", "uhm", "umm", "erm", "like", "basically", "actually",
    ]
    private static let fillerPhrases = [
        "you know", "i mean", "no wait", "scratch that", "sort of", "kind of",
    ]
    private static let spokenFormWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "dollar", "dollars", "cents", "percent",
        "o'clock", "slash", "dot",
    ]

    /// Set once prewarm has confirmed the model is available and loaded.
    private var ready = false

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Call at bootstrap so the first dictation doesn't pay the cold start
    /// (~3s cold vs ~0.5s warm, measured on this machine).
    func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
        ready = true
    }

    /// One sentence: routed, cleaned under guided decoding, guarded. Returns the
    /// original whenever anything argues for leaving it alone. Leading
    /// whitespace is preserved so sentences reassemble cleanly.
    func cleanSentence(_ sentence: String, suspectTokens: Set<String>) async -> String {
        guard ready, Self.needsCleaning(sentence, suspectTokens: suspectTokens) else {
            return sentence
        }

        let lead = String(sentence.prefix(while: \.isWhitespace))
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)

        // Sessions are stateful — a reused one re-reads its whole history before
        // every reply. Fresh session, empty conversation; the model stays loaded.
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let cleaned = try await session.respond(to: trimmed, generating: Cleaned.self)
                .content.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  !Self.overEdited(raw: trimmed, formatted: cleaned) else { return sentence }
            return lead + cleaned
        } catch {
            return sentence
        }
    }

    // MARK: - Routing

    /// Split keeping each sentence's leading whitespace, so pass-through
    /// sentences reassemble byte-identical.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                result.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current)
        }
        return result
    }

    static func needsCleaning(_ sentence: String, suspectTokens: Set<String>) -> Bool {
        let words = tokens(sentence)
        if words.contains(where: {
            fillerWords.contains($0) || spokenFormWords.contains($0) || suspectTokens.contains($0)
        }) {
            return true
        }
        let lower = sentence.lowercased()
        return fillerPhrases.contains { lower.contains($0) }
    }

    // MARK: - Guard

    /// One deterministic rule, not a rulebook.
    static func overEdited(raw: String, formatted: String) -> Bool {
        let source = Set(tokens(raw))
        let output = tokens(formatted)
        guard !source.isEmpty, !output.isEmpty else { return false }
        let invented = output.filter { !source.contains($0) }.count
        return Double(invented) / Double(output.count) > maxInventionRatio
    }

    /// Lowercased, punctuation-stripped words — the guard cares about *wording*,
    /// not the punctuation and casing the model is supposed to change.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Formats the utterance *while it's being spoken*. The recognizer hands over
/// finalized chunks mid-dictation; complete sentences are cleaned in the
/// background as the user speaks the next one. Generation runs ~8 words/s and
/// speech ~2–3 words/s, so the model keeps pace and release-to-paste shrinks to
/// roughly one sentence's worth of work.
actor FormatPipeline {
    private let formatter: Formatter
    private let onProgress: @Sendable (String) -> Void

    private var suspect: Set<String> = []
    private var pending = ""
    private var output = ""
    private var processing: Task<Void, Never>?

    init(formatter: Formatter, onProgress: @escaping @Sendable (String) -> Void) {
        self.formatter = formatter
        self.onProgress = onProgress
    }

    /// Fast by design — heavy work happens on a chained background task, so the
    /// recognizer's collector never waits on the model.
    func feed(_ chunk: String, spans: [RecognitionResult.Span]) {
        for span in spans where (span.c ?? 1.0) < Formatter.lowConfidence {
            suspect.formUnion(Formatter.tokens(span.t))
        }
        pending += chunk

        var parts = Formatter.sentences(pending)
        if let last = parts.last, !(last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?")) {
            pending = last
            parts.removeLast()
        } else {
            pending = ""
        }
        if !parts.isEmpty { schedule(parts) }
    }

    func finish() async -> String {
        let tail = pending
        pending = ""
        if !tail.trimmingCharacters(in: .whitespaces).isEmpty {
            schedule([tail])
        }
        await processing?.value
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func schedule(_ sentences: [String]) {
        let previous = processing
        let suspectSnapshot = suspect
        processing = Task {
            await previous?.value
            for sentence in sentences {
                let cleaned = await formatter.cleanSentence(sentence, suspectTokens: suspectSnapshot)
                append(cleaned)
            }
        }
    }

    private func append(_ text: String) {
        output += text
        onProgress(output)
    }
}
