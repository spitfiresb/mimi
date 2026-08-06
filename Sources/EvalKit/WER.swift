import Foundation

/// Word error rate, the standard ASR metric: (substitutions + insertions +
/// deletions) / reference words, computed over normalized tokens via edit
/// distance.
public struct WERResult: Sendable {
    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int
    public let referenceWords: Int

    public var errors: Int { substitutions + insertions + deletions }
    public var wer: Double {
        referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords)
    }

    public static func + (lhs: WERResult, rhs: WERResult) -> WERResult {
        WERResult(
            substitutions: lhs.substitutions + rhs.substitutions,
            insertions: lhs.insertions + rhs.insertions,
            deletions: lhs.deletions + rhs.deletions,
            referenceWords: lhs.referenceWords + rhs.referenceWords
        )
    }

    public static let zero = WERResult(substitutions: 0, insertions: 0, deletions: 0, referenceWords: 0)

    public init(substitutions: Int, insertions: Int, deletions: Int, referenceWords: Int) {
        self.substitutions = substitutions
        self.insertions = insertions
        self.deletions = deletions
        self.referenceWords = referenceWords
    }
}

public enum WER {
    /// Lowercase, keep letters/digits/apostrophes, split on everything else.
    /// Both sides pass through the same normalizer, so casing and punctuation —
    /// which LibriSpeech references don't carry and engine output does — never
    /// count as errors.
    ///
    /// Known limitation, deliberate: no ITN denormalization. An engine that
    /// writes "1842" against a reference of "eighteen forty two" is charged for
    /// it. Both engines under test face the same charge, so A/B comparisons are
    /// fair; absolute numbers will read slightly high vs. published figures.
    public static func normalize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        // Strip possessive-style stray apostrophes left at token edges ("'em" stays).
        return tokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein over words with backtrace, so the error *kinds* are counted,
    /// not just the distance.
    public static func score(reference: String, hypothesis: String) -> WERResult {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)

        if ref.isEmpty {
            return WERResult(substitutions: 0, insertions: hyp.count, deletions: 0, referenceWords: 0)
        }
        if hyp.isEmpty {
            return WERResult(substitutions: 0, insertions: 0, deletions: ref.count, referenceWords: ref.count)
        }

        // d[i][j] = edit distance between ref[..<i] and hyp[..<j]
        var d = [[Int]](repeating: [Int](repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for i in 0...ref.count { d[i][0] = i }
        for j in 0...hyp.count { d[0][j] = j }
        for i in 1...ref.count {
            for j in 1...hyp.count {
                if ref[i - 1] == hyp[j - 1] {
                    d[i][j] = d[i - 1][j - 1]
                } else {
                    d[i][j] = 1 + min(d[i - 1][j - 1], d[i - 1][j], d[i][j - 1])
                }
            }
        }

        var subs = 0, ins = 0, dels = 0
        var i = ref.count, j = hyp.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, ref[i - 1] == hyp[j - 1], d[i][j] == d[i - 1][j - 1] {
                i -= 1; j -= 1
            } else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 {
                subs += 1; i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                dels += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }

        return WERResult(substitutions: subs, insertions: ins, deletions: dels, referenceWords: ref.count)
    }
}
