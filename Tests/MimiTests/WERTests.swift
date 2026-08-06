import EvalKit
import XCTest

final class WERTests: XCTestCase {
    func testPerfectMatchIsZero() {
        let r = WER.score(reference: "the cat sat on the mat", hypothesis: "the cat sat on the mat")
        XCTAssertEqual(r.errors, 0)
        XCTAssertEqual(r.wer, 0)
        XCTAssertEqual(r.referenceWords, 6)
    }

    func testCasingAndPunctuationAreFree() {
        // LibriSpeech refs are SHOUTED and unpunctuated; engine output isn't.
        let r = WER.score(
            reference: "HELLO WORLD HOW ARE YOU",
            hypothesis: "Hello, world — how are you?"
        )
        XCTAssertEqual(r.errors, 0)
    }

    func testSubstitution() {
        let r = WER.score(reference: "the quarterly report", hypothesis: "the orderly report")
        XCTAssertEqual(r.substitutions, 1)
        XCTAssertEqual(r.insertions, 0)
        XCTAssertEqual(r.deletions, 0)
        XCTAssertEqual(r.wer, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testInsertionAndDeletion() {
        XCTAssertEqual(WER.score(reference: "push the release", hypothesis: "push the the release").insertions, 1)
        XCTAssertEqual(WER.score(reference: "push the release", hypothesis: "push release").deletions, 1)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let r = WER.score(reference: "one two three", hypothesis: "")
        XCTAssertEqual(r.deletions, 3)
        XCTAssertEqual(r.wer, 1.0)
    }

    func testApostrophesSurviveNormalization() {
        XCTAssertEqual(WER.normalize("Don't stop"), ["don't", "stop"])
        XCTAssertEqual(WER.score(reference: "DON'T STOP", hypothesis: "don't stop").errors, 0)
    }

    func testAggregationIsCorpusLevel() {
        // 1 error over 3 words + 0 errors over 7 words = 1/10, not mean(1/3, 0).
        let a = WER.score(reference: "a b c", hypothesis: "a b x")
        let b = WER.score(reference: "d e f g h i j", hypothesis: "d e f g h i j")
        let combined = a + b
        XCTAssertEqual(combined.wer, 0.1, accuracy: 1e-9)
    }

    func testKnownWERExample() {
        // Classic textbook case: ref 6 words, hyp has 1 sub + 1 del + 1 ins.
        let r = WER.score(
            reference: "the cat sat on the mat",
            hypothesis: "the cat sit on mat today"
        )
        XCTAssertEqual(r.errors, 3)
        XCTAssertEqual(r.wer, 0.5, accuracy: 1e-9)
    }
}
