import Foundation
import FoundationModels

/// The Stage 2 formatting pass: Apple's on-device Foundation Model cleans up the
/// raw transcript, and a mechanical guard keeps it honest.
///
/// The model makes judgments (disfluencies, false starts, "no wait X" corrections,
/// ITN); deterministic code enforces safety. If the rewrite drifts too far from
/// what was said, we discard it and insert the raw transcript — an invented word
/// the user can't detect is worse than a transcription error.
actor Formatter {
    /// Everything on-device. Runs offline.
    private var session: LanguageModelSession?

    private static let instructions = """
        You clean up dictated text. Remove filler words (um, uh, like) and false \
        starts. Apply corrections the speaker made mid-sentence ("no wait X" or \
        "I mean X" means use X). Convert spoken forms: "three thirty" becomes 3:30, \
        "twenty five dollars" becomes $25, "dot com" becomes .com. Keep the \
        speaker's wording and voice — do not rephrase, summarize, or add anything. \
        Output only the cleaned text.
        """

    /// Utterances this short aren't worth a model round-trip.
    private static let minimumWords = 3

    /// Reject rewrites where more than this fraction of the output words never
    /// appeared in the raw transcript. Deleting words is what disfluency removal
    /// *does*, so deletions don't count — invention is the failure mode. Some
    /// headroom is needed because ITN legitimately mints tokens ("three thirty"
    /// → "3:30").
    private static let maxInventionRatio = 0.4

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Call at bootstrap so the first dictation doesn't pay the cold start
    /// (~3s cold vs ~0.5s warm, measured on this machine).
    func prewarm() {
        guard isAvailable else { return }
        let session = LanguageModelSession(instructions: Self.instructions)
        session.prewarm()
        self.session = session
    }

    /// Returns the formatted text, or the raw text whenever anything — model
    /// unavailable, error, over-edit — argues for leaving it alone.
    func format(_ raw: String) async -> String {
        let words = raw.split(separator: " ")
        guard words.count >= Self.minimumWords, let session else { return raw }

        guard let reply = try? await session.respond(to: raw) else { return raw }
        let formatted = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formatted.isEmpty else { return raw }

        return Self.overEdited(raw: raw, formatted: formatted) ? raw : formatted
    }

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
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

}
