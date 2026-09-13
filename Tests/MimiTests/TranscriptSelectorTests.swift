@testable import Mimi
import XCTest

final class TranscriptSelectorTests: XCTestCase {
    func testPreferredSuccessDoesNotWaitForAppleOrItsTeardown() async {
        let appleGate = Gate()
        let teardownGate = Gate()
        let cancelStarted = expectation(description: "unused Apple work is canceled")
        let started = ContinuousClock.now
        let result = await TranscriptSelector.select(
            preferred: job("Parakeet text"), preferredDeadline: 1,
            fallback: {
                await appleGate.wait()
                return .init(text: "Apple text", runtimeMs: 2000)
            },
            cancelFallback: {
                cancelStarted.fulfill()
                await teardownGate.wait()
                await appleGate.open()
            })
        XCTAssertEqual(result.text, "Parakeet text")
        XCTAssertTrue(result.usedParakeet)
        XCTAssertNil(result.apple)
        XCTAssertEqual(result.fallbackWaitMs, 0)
        XCTAssertEqual(result.parakeetTotalMs, 17)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        await fulfillment(of: [cancelStarted], timeout: 1)
        await teardownGate.open()
    }

    func testFailedPreferredUsesApple() async {
        let result = await TranscriptSelector.select(
            preferred: Task { nil }, preferredDeadline: 1,
            fallback: { .init(text: "Apple fallback", runtimeMs: 25) },
            cancelFallback: {})
        XCTAssertFalse(result.usedParakeet)
        XCTAssertEqual(result.text, "Apple fallback")
        XCTAssertEqual(result.apple?.runtimeMs, 25)
        XCTAssertNil(result.parakeetTotalMs)
    }

    func testWhitespacePreferredUsesApple() async {
        let result = await TranscriptSelector.select(
            preferred: job(" \n "), preferredDeadline: 1,
            fallback: { .init(text: " fallback \n", runtimeMs: 25) },
            cancelFallback: {})
        XCTAssertFalse(result.usedParakeet)
        XCTAssertEqual(result.text, "fallback")
    }

    func testMissingPreferredUsesApple() async {
        let result = await TranscriptSelector.select(
            preferred: nil, preferredDeadline: 1,
            fallback: { .init(text: "Apple only", runtimeMs: 25) },
            cancelFallback: {})
        XCTAssertEqual(result.text, "Apple only")
        XCTAssertFalse(result.usedParakeet)
    }

    func testEarlierAppleResultDoesNotReplaceSuccessfulPreferred() async {
        let result = await TranscriptSelector.select(
            preferred: job("Preferred", delay: 0.1), preferredDeadline: 1,
            fallback: { .init(text: "Earlier fallback", runtimeMs: 1) },
            cancelFallback: {})
        XCTAssertEqual(result.text, "Preferred")
        XCTAssertTrue(result.usedParakeet)
        XCTAssertEqual(result.apple?.text, "Earlier fallback")
    }

    func testPreferredDeadlineCancelsItAndUsesApple() async {
        let preferred = job("Too late", delay: 30)
        let result = await TranscriptSelector.select(
            preferred: preferred, preferredDeadline: 0.03,
            fallback: { .init(text: "Fallback after timeout", runtimeMs: 1) },
            cancelFallback: {})
        XCTAssertTrue(preferred.isCancelled)
        XCTAssertFalse(result.usedParakeet)
        XCTAssertEqual(result.text, "Fallback after timeout")
    }

    func testHungAppleIsBoundedAndStoppedWhenBothEnginesFail() async {
        let appleGate = Gate()
        let stopped = expectation(description: "timed-out Apple work is stopped")
        let start = ContinuousClock.now
        let result = await TranscriptSelector.select(
            preferred: nil, preferredDeadline: 1, fallbackDeadline: 0.03,
            fallback: { await appleGate.wait(); return nil },
            cancelFallback: { stopped.fulfill(); await appleGate.open() })
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.usedParakeet)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testAppleDeadlineRunsWhilePreferredIsStillWorking() async {
        let appleGate = Gate()
        let stopped = expectation(description: "Apple has an independent deadline")
        let result = await TranscriptSelector.select(
            preferred: job("Preferred", delay: 0.15), preferredDeadline: 1,
            fallbackDeadline: 0.03,
            fallback: { await appleGate.wait(); return nil },
            cancelFallback: { stopped.fulfill(); await appleGate.open() })
        XCTAssertTrue(result.usedParakeet)
        XCTAssertEqual(result.text, "Preferred")
        await fulfillment(of: [stopped], timeout: 1)
    }

    private func job(_ text: String, delay: Double = 0) -> Task<EngineTranscript?, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return nil }
            return .init(text: text, runtimeMs: 17)
        }
    }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
}
