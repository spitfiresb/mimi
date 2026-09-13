import XCTest
@testable import Mimi

final class SilenceGateTests: XCTestCase {
    private func tone(_ milliseconds: Int, amplitude: Float = 0.01) -> [Float] {
        (0..<(milliseconds * 16)).map { amplitude * sin(Float($0) * 2 * .pi * 200 / 16_000) }
    }

    func testEmptyZeroAndDCOffsetAreSilent() {
        XCTAssertFalse(SilenceGate.assess([]).hasSignal)
        XCTAssertFalse(SilenceGate.assess([Float](repeating: 0, count: 16_000)).hasSignal)
        XCTAssertFalse(SilenceGate.assess([Float](repeating: 0.02, count: 16_000)).hasSignal)
    }

    func testLowLevelRecordingsThatProducedHallucinationsAreRejected() {
        // Upper bounds from the user's silent 0.26–0.43 second recordings.
        // Even a sustained waveform at these peaks cannot clear the RMS floor.
        for peak: Float in [0.001953125, 0.0013427734, 0.0016784668, 0.0016479492] {
            XCTAssertFalse(SilenceGate.assess(tone(430, amplitude: peak)).hasSignal)
        }
    }

    func testIsolatedClicksDoNotAccumulateIntoSpeech() {
        let quiet = [Float](repeating: 0, count: 3200)
        let samples = tone(20, amplitude: 0.5) + quiet + tone(20, amplitude: 0.5) + quiet + tone(20, amplitude: 0.5)
        let result = SilenceGate.assess(samples)
        XCTAssertFalse(result.hasSignal)
        XCTAssertEqual(result.activeMs, 60)
        XCTAssertEqual(result.longestActiveMs, 20)
    }

    func testShortQuietWordLengthSignalPasses() {
        let result = SilenceGate.assess(tone(100, amplitude: 0.004))
        XCTAssertTrue(result.hasSignal)
        XCTAssertEqual(result.longestActiveMs, 100)
    }

    func testLongPausesDoNotDiluteOneShortSignal() {
        let quiet = [Float](repeating: 0, count: 16_000 * 10)
        XCTAssertTrue(SilenceGate.assess(quiet + tone(100) + quiet).hasSignal)
    }

    func testPartialFinalFrameCannotInflateSignalDuration() {
        XCTAssertFalse(SilenceGate.assess(tone(59)).hasSignal)
        XCTAssertTrue(SilenceGate.assess(tone(60)).hasSignal)
    }

    func testNonfiniteInputDoesNotCountAsSound() {
        XCTAssertFalse(SilenceGate.assess([Float](repeating: .nan, count: 3200)).hasSignal)
        XCTAssertFalse(SilenceGate.assess([Float](repeating: .infinity, count: 3200)).hasSignal)
    }
}
