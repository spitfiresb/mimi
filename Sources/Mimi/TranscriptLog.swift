import Foundation

/// One dictation, recorded locally.
///
/// The three text fields are the training triple. Only `raw` exists today; the
/// other two are written by later stages, and are `nil` until then.
struct TranscriptEntry: Codable {
    /// Schema version. Bump when a field's meaning changes, not when one is added.
    var v = 1
    var id = UUID()
    var at = Date()

    /// Key press to key release, not time spent transcribing.
    var durationMs: Int
    var locale: String?

    /// Where the text was headed — the formatting pass will eventually key off this.
    var appBundleID: String?
    var appName: String?

    /// What the ASR produced, verbatim.
    var raw: String

    /// Per-result recognition detail: confidence spans and the n-best
    /// alternatives the recognizer considered. Collected to answer one question —
    /// when it's wrong, did it know, and was the right word in the list?
    var recognition: [RecognitionResult]?

    /// What the formatting pass produced.
    var formatted: String?

    /// What the text looked like after the user fixed it. The label.
    var corrected: String?
}

/// One final result from the recognizer, with what it almost said instead.
struct RecognitionResult: Codable {
    /// The text it committed to.
    var text: String
    /// Runner-up transcriptions, best first.
    var alts: [String]
    /// Confidence runs over `text`: `t` is the substring, `c` its 0–1 confidence
    /// (absent where the recognizer didn't attach one).
    var spans: [Span]

    struct Span: Codable {
        var t: String
        var c: Double?
    }
}

/// Append-only local log of every dictation, as JSONL.
///
/// Started at MVP on purpose. The corrections dataset is the only thing in this
/// project a competitor can't clone, and it can only be collected forward — every
/// day of real use without it is a day of data thrown away.
///
/// Never leaves the machine. Never takes dictation down with it: every failure
/// here is swallowed, because a broken log is worth less than a working app.
actor TranscriptLog {
    static let shared = TranscriptLog()

    static let directory = URL.applicationSupportDirectory.appending(
        path: "Mimi",
        directoryHint: .isDirectory
    )
    static let fileURL = directory.appending(path: "transcripts.jsonl")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted so the file diffs cleanly and reads consistently by eye.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func append(_ entry: TranscriptEntry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)  // JSONL: one object per line.

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)

            guard fm.fileExists(atPath: Self.fileURL.path) else {
                try line.write(to: Self.fileURL, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: Self.fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Deliberately silent.
        }
    }
}
