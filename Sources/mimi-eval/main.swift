import EvalKit
import Foundation

/// mimi-eval — score ASR engines against a LibriSpeech-format dataset.
///
///     swift run -c release mimi-eval datasets/LibriSpeech/test-clean [--limit N]
///
/// Prints per-engine WER and RTF, lists the worst utterances, and writes the
/// full per-utterance report to eval-results/<engine>-<count>.json.

func usage() -> Never {
    print("usage: mimi-eval <librispeech-dir> [--limit N] [--engine apple|parakeet-int8|parakeet-fp16|all] [--models <dir>]")
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var limit = Int.max
var engineChoice = "apple"
var modelsDir = URL(fileURLWithPath: "tools/convert/models")
if let flag = arguments.firstIndex(of: "--limit") {
    guard flag + 1 < arguments.count, let n = Int(arguments[flag + 1]), n > 0 else { usage() }
    limit = n
    arguments.removeSubrange(flag...(flag + 1))
}
if let flag = arguments.firstIndex(of: "--engine") {
    guard flag + 1 < arguments.count else { usage() }
    engineChoice = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
}
if let flag = arguments.firstIndex(of: "--models") {
    guard flag + 1 < arguments.count else { usage() }
    modelsDir = URL(fileURLWithPath: arguments[flag + 1])
    arguments.removeSubrange(flag...(flag + 1))
}
guard arguments.count == 1 else { usage() }

let root = URL(fileURLWithPath: arguments[0])
guard FileManager.default.fileExists(atPath: root.path) else {
    print("no such directory: \(root.path)")
    print("fetch a dataset first: ./scripts/fetch-librispeech.sh")
    exit(1)
}

let all = try LibriSpeech.load(from: root)
guard !all.isEmpty else {
    print("no utterances found under \(root.path) — expected LibriSpeech layout (*.trans.txt + .flac)")
    exit(1)
}
let utterances = Array(all.prefix(limit))
print("scoring \(utterances.count) of \(all.count) utterances from \(root.lastPathComponent)\n")

let engines: [any EvalEngine] = switch engineChoice {
case "apple": [AppleEngine()]
case "parakeet-int8": [ParakeetEngine(modelsDir: modelsDir, int8: true)]
case "parakeet-fp16": [ParakeetEngine(modelsDir: modelsDir, int8: false)]
case "all": [AppleEngine(),
             ParakeetEngine(modelsDir: modelsDir, int8: false),
             ParakeetEngine(modelsDir: modelsDir, int8: true)]
default: usage()
}

for engine in engines {
    print("== \(engine.name) ==")
    let report = try await Harness.run(
        engine: engine,
        over: utterances,
        audioSeconds: { try AppleEngine.audioSeconds(of: $0) },
        progress: { done, total, score in
            print(String(format: "  %d/%d  %@  wer %.0f%%  %.1fs", done, total, score.id, score.wer * 100, score.processingSeconds))
            fflush(stdout)
        }
    )

    print(String(format: "  WER  %.2f%%  (%d sub, %d ins, %d del over %d words)",
                 report.wer * 100, report.substitutions, report.insertions,
                 report.deletions, report.referenceWords))
    print(String(format: "  RTF  %.3fx  (%.1fs of audio in %.1fs)",
                 report.rtf, report.audioSeconds, report.processingSeconds))

    let worst = report.utterances.sorted { $0.wer > $1.wer }.prefix(3)
    if let top = worst.first, top.errors > 0 {
        print("  worst utterances:")
        for score in worst where score.errors > 0 {
            print(String(format: "    %@  %.0f%%", score.id, score.wer * 100))
            print("      ref: \(score.reference.lowercased())")
            print("      hyp: \(score.hypothesis)")
        }
    }

    let outDir = URL(fileURLWithPath: "eval-results")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let out = outDir.appendingPathComponent("\(report.engine)-\(utterances.count).json")
    try encoder.encode(report).write(to: out)
    print("  full report: \(out.path)\n")
}
