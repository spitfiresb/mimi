import Foundation

/// User vocabulary fed to the recognizer as `contextualStrings` — names, jargon,
/// anything it keeps mishearing. Manual for now; Stage 4 learns it from
/// corrections instead.
///
/// One term per line in vocabulary.txt, `#` for comments. Read at each session
/// start, so edits apply to the next dictation without a restart.
enum Vocabulary {
    static let fileURL = TranscriptLog.directory.appending(path: "vocabulary.txt")

    private static let template = """
        # Mimi vocabulary — one term per line.
        # Words the recognizer should favor: names, jargon, project names.
        # Edits apply from the next dictation. Lines starting with # are ignored.
        """

    /// Creates the file with instructions on first call so it's discoverable.
    static func terms() -> [String] {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            try? fm.createDirectory(at: TranscriptLog.directory, withIntermediateDirectories: true)
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
            return []
        }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
