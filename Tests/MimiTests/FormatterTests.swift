@testable import Mimi
import XCTest

/// Pins the deterministic halves of the Stage 2 formatting layer: routing
/// (which sentences reach the model) and the invention guard (which rewrites
/// survive). The model itself isn't under test — its judgments vary; these
/// rules must not.
final class FormatterTests: XCTestCase {
    // MARK: Routing

    func testFillerWordsRouteToTheModel() {
        XCTAssertTrue(Formatter.needsCleaning("um so this is the thing", suspectTokens: []))
        XCTAssertTrue(Formatter.needsCleaning("it was like really good", suspectTokens: []))
    }

    func testFillerPhrasesRouteToTheModel() {
        XCTAssertTrue(Formatter.needsCleaning("send it to Bob no wait Sarah", suspectTokens: []))
        XCTAssertTrue(Formatter.needsCleaning("scratch that last part", suspectTokens: []))
    }

    func testSpokenNumbersRouteToTheModel() {
        XCTAssertTrue(Formatter.needsCleaning("meet me at three thirty", suspectTokens: []))
        XCTAssertTrue(Formatter.needsCleaning("it costs twenty five dollars", suspectTokens: []))
    }

    func testSuspectTokensRouteToTheModel() {
        XCTAssertTrue(Formatter.needsCleaning("the quarterly report", suspectTokens: ["quarterly"]))
    }

    func testCleanSentencesSkipTheModel() {
        XCTAssertFalse(Formatter.needsCleaning("We should push the release to Friday.", suspectTokens: []))
    }

    // MARK: Sentence splitting

    func testSentencesSplitOnTerminators() {
        XCTAssertEqual(
            Formatter.sentences("First one. Second one! Third?"),
            ["First one.", " Second one!", " Third?"]
        )
    }

    func testTrailingFragmentIsKept() {
        XCTAssertEqual(Formatter.sentences("Done. and then"), ["Done.", " and then"])
    }

    func testLeadingWhitespaceReassemblesByteIdentical() {
        let text = "One. Two. Three."
        XCTAssertEqual(Formatter.sentences(text).joined(), text)
    }

    // MARK: Invention guard

    func testDeletionsAreNotInvention() {
        // Disfluency removal deletes; that's the job.
        XCTAssertFalse(Formatter.overEdited(
            raw: "um so basically we should uh push the release",
            formatted: "We should push the release."
        ))
    }

    func testWholesaleRewriteIsRejected() {
        XCTAssertTrue(Formatter.overEdited(
            raw: "push the release to friday",
            formatted: "The deployment schedule has been amended accordingly."
        ))
    }

    func testITNHeadroomSurvives() {
        // "three thirty" → "3:30" mints a token the raw never had; must pass.
        XCTAssertFalse(Formatter.overEdited(
            raw: "meet me at three thirty",
            formatted: "Meet me at 3:30."
        ))
    }

    func testTokensStripPunctuationAndCase() {
        XCTAssertEqual(Formatter.tokens("Push, the Release!"), ["push", "the", "release"])
    }
}
