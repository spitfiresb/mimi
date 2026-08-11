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
    /// Captured at key press.
    var appBundleID: String?
    var appName: String?

    /// Whatever was frontmost at the moment ⌘V was posted. Differs from
    /// `appName` when focus moved during the wait, which is the first thing to
    /// rule out when a dictation transcribes correctly and then never lands.
    var pasteTarget: String?

    /// What the ASR produced, verbatim.
    var raw: String

    /// Which engine produced `raw`: "parakeet-int8" or "apple" (fallback).
    /// Absent on entries logged before the Stage 5 default-engine swap.
    var engine: String?

    /// Apple's transcript of the same audio, kept when Parakeet produced `raw`
    /// — every dictation becomes a free A/B data point.
    var appleRaw: String?

    /// Per-result recognition detail: confidence spans and the n-best
    /// alternatives the recognizer considered. Collected to answer one question —
    /// when it's wrong, did it know, and was the right word in the list?
    var recognition: [RecognitionResult]?

    /// What the formatting pass produced.
    var formatted: String?

    /// Where the release-to-paste time went, in ms. The user feels the sum;
    /// this says which stage to blame.
    var timings: Timings?

    /// Capture-side health. A dictation that transcribes to nothing has two
    /// very different causes — the mic fed us silence, or the engines failed on
    /// good audio — and only the recording's level can tell them apart.
    var audio: AudioHealth?

    struct AudioHealth: Codable {
        /// The input device the tap was reading from.
        var device: String?
        /// That device's nominal hardware sample rate at capture time.
        var deviceRate: Double?
        /// The rate the tap believed it was receiving. Disagreement with
        /// `deviceRate` means the input node's cached format went stale across
        /// a device pin or route change — the leading suspect when a recording
        /// comes back as garble.
        var tapRate: Double?
        /// Peak absolute sample of the 16kHz recording, 0–1. Spoken audio
        /// peaks well above 0.05; ~0 means the mic fed us silence.
        var peak: Float?
        /// Seconds of audio actually captured.
        var seconds: Double?
    }

    struct Timings: Codable {
        /// finalizeAndFinishThroughEndOfInput + collecting results.
        var finalizeMs: Int
        /// The Foundation Models pass (0 when skipped or verbatim).
        var formatMs: Int
        /// The settle hold — showing the cleaned text before pasting.
        var settleMs: Int
        /// Waiting for modifiers to clear + posting ⌘V.
        var insertMs: Int
        /// The Parakeet transcription of the buffered audio (0 = not run).
        var parakeetMs: Int?
        /// Keypress → session accepting audio (makeSession + context + start).
        var startupMs: Int?
        /// Keypress → first live preview text on screen.
        var firstPreviewMs: Int?
        /// Worst gap between a word being spoken and the preview showing it,
        /// per the recognizer's own audio timestamps.
        var maxPreviewLagMs: Int?
    }

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
