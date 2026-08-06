import Foundation

/// One test case: an audio file and its human-verified reference transcript.
public struct Utterance: Sendable {
    public let id: String
    public let audioURL: URL
    public let reference: String

    public init(id: String, audioURL: URL, reference: String) {
        self.id = id
        self.audioURL = audioURL
        self.reference = reference
    }
}

/// Loads a LibriSpeech-format directory: FLAC files alongside `*.trans.txt`
/// manifests, each line `<utterance-id> <TRANSCRIPT IN CAPS>`.
/// openslr.org ships test-clean/test-other this way; scripts/fetch-librispeech.sh
/// puts one under datasets/.
public enum LibriSpeech {
    public static func load(from root: URL) throws -> [Utterance] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var utterances: [Utterance] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(".trans.txt") {
            let dir = url.deletingLastPathComponent()
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let space = line.firstIndex(of: " ") else { continue }
                let id = String(line[..<space])
                let reference = String(line[line.index(after: space)...])
                let audio = dir.appendingPathComponent("\(id).flac")
                guard fm.fileExists(atPath: audio.path) else { continue }
                utterances.append(Utterance(id: id, audioURL: audio, reference: reference))
            }
        }
        return utterances.sorted { $0.id < $1.id }
    }
}
