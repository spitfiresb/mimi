import Foundation
import FoundationModels

/// The Stage 2 formatting pass: Apple's on-device Foundation Model cleans up the
/// raw transcript, and a mechanical guard keeps it honest.
///
/// The model makes judgments (disfluencies, false starts, "no wait X" corrections,
/// ITN); deterministic code enforces safety. If a rewrite drifts too far from
/// what was said, we discard it and keep the raw text — an invented word the user
/// can't detect is worse than a transcription error.
///
/// Cost control, measured not guessed: a 50-word utterance took 5.9s because the
/// model regenerated every word, mostly words that needed no change. So the pass
/// is sentence-selective — only sentences showing evidence of mess (disfluencies,
/// spoken numbers, low recognizer confidence) go to the model; clean sentences
/// pass through verbatim. And it streams: partial output surfaces via `onPartial`
/// so the overlay can show the cleanup happening instead of freezing.
actor Formatter {
    /// Set once prewarm has confirmed the model is available and loaded.
    private var ready = false

    private static let instructions = """
        You clean up dictated text. Remove filler words (um, uh, like) and false \
        starts. Apply corrections the speaker made mid-sentence ("no wait X" or \
        "I mean X" means use X). Convert spoken forms: "three thirty" becomes 3:30, \
        "twenty five dollars" becomes $25, "dot com" becomes .com, a spoken "slash" \
        in a web address becomes /. Keep the speaker's wording and voice — do not \
        rephrase, summarize, or add anything. Output only the cleaned text.
        """

    /// Utterances this short aren't worth a model round-trip.
    private static let minimumWords = 3

    /// Reject rewrites where more than this fraction of the output words never
    /// appeared in the raw transcript. Deleting words is what disfluency removal
    /// *does*, so deletions don't count — invention is the failure mode. Some
    /// headroom is needed because ITN legitimately mints tokens ("three thirty"
    /// → "3:30").
    private static let maxInventionRatio = 0.4

    /// Below this, a recognizer span marks its sentence as worth a model pass.
    /// From the first logged data: real errors scored 0.31–0.73, correct words
    /// mostly 0.9+. A false positive just costs one sentence's cleanup.
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

    /// A fresh session per utterance. Sessions are stateful — every response
    /// appends to their transcript, so a reused session re-reads an ever-growing
    /// history before each reply and dictation slows down all day. The model
    /// itself stays loaded; only the empty conversation is new.
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Self.instructions)
    }

    /// Returns the formatted text, or the raw text whenever anything — model
    /// unavailable, error, over-edit — argues for leaving it alone.
    ///
    /// `suspectTokens` are words the recognizer was unsure of (from the
    /// confidence log); sentences containing them get the model pass even
    /// without visible disfluencies. `onPartial` receives the assembled output
    /// as it grows, for live display.
    func format(
        _ raw: String,
        suspectTokens: Set<String> = [],
        onPartial: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> String {
        let words = raw.split(separator: " ")
        guard words.count >= Self.minimumWords, ready else { return raw }
        let session = makeSession()

        var output = ""
        for sentence in Self.sentences(raw) {
            if Self.needsCleaning(sentence, suspectTokens: suspectTokens) {
                let prefix = output
                output += await clean(sentence, with: session) { partial in
                    onPartial(prefix + partial)
                }
            } else {
                output += sentence
            }
            onPartial(output)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One sentence through the model, streamed. Falls back to the original on
    /// any error or an over-edited rewrite.
    private func clean(
        _ sentence: String,
        with session: LanguageModelSession,
        onPartial: @escaping @Sendable (String) -> Void
    ) async -> String {
        let lead = String(sentence.prefix(while: \.isWhitespace))
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)

        do {
            var latest = ""
            for try await snapshot in session.streamResponse(to: trimmed) {
                latest = snapshot.content
                onPartial(lead + latest)
            }
            let cleaned = latest.trimmingCharacters(in: .whitespacesAndNewlines)
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
