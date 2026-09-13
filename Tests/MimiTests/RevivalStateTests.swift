@testable import Mimi
import XCTest

/// Pins the rules that keep two overlapping engine revivals from corrupting
/// each other.
///
/// Overlap is not hypothetical here. A revival can block inside CoreAudio
/// indefinitely and cannot be cancelled — on 2026-08-13 one sat in a mach_msg
/// for two days — so the watchdog writes off the stuck attempt and starts
/// another while the first thread is still alive. Everything below is about
/// what that first thread is allowed to do if it ever wakes up.
final class RevivalStateTests: XCTestCase {

    // MARK: - Coalescing

    func testSecondBeginIsRefusedWhileOneIsInFlight() {
        var state = RevivalState()
        state.requestCapture()
        XCTAssertEqual(state.begin(), 1)
        // Waking a Mac posts didWake and AVAudioEngineConfigurationChange
        // milliseconds apart; both call through to here.
        XCTAssertNil(state.begin())
        XCTAssertNil(state.begin())
    }

    func testBeginIsAllowedAgainOnceAnAttemptFinishes() {
        var state = RevivalState()
        state.requestCapture()
        let first = state.begin()
        XCTAssertNotNil(first)
        XCTAssertTrue(state.succeed(first!))
        XCTAssertEqual(state.begin(), 2)
    }

    // MARK: - Supersession

    func testStaleAttemptCannotPublishOverANewerOne() {
        var state = RevivalState()
        state.requestCapture()
        let stuck = state.begin()!            // gen 1, about to wedge

        _ = state.abandonIfStuck(stuck)       // watchdog writes it off
        let replacement = state.begin()!      // gen 2
        XCTAssertTrue(state.succeed(replacement))

        // Gen 1 finally returns from the HAL. It must not publish its engine
        // over the working one that replaced it.
        XCTAssertFalse(state.succeed(stuck))
    }

    func testStaleAttemptCannotTriggerItsOwnRetry() {
        var state = RevivalState()
        state.requestCapture()
        let stuck = state.begin()!
        _ = state.abandonIfStuck(stuck)
        let replacement = state.begin()!

        // A superseded failure must stay quiet: retrying on its behalf would
        // double up with whoever replaced it.
        XCTAssertNil(state.fail(stuck))

        // The current attempt is untouched by that stale report.
        XCTAssertTrue(state.isCurrent(replacement))
        XCTAssertTrue(state.succeed(replacement))
    }

    // MARK: - Watchdog

    func testWatchdogDoesNotFireOnAnAttemptThatAlreadySucceeded() {
        var state = RevivalState()
        state.requestCapture()
        let attempt = state.begin()!
        XCTAssertTrue(state.succeed(attempt))

        // The watchdog was armed when this attempt started and fires on
        // schedule regardless. It must not tear down a healthy engine.
        XCTAssertNil(state.abandonIfStuck(attempt))
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testWatchdogFiresOnAnAttemptStillInFlight() {
        var state = RevivalState()
        state.requestCapture()
        let attempt = state.begin()!
        XCTAssertEqual(state.abandonIfStuck(attempt), 1)
        XCTAssertFalse(state.inFlight, "a written-off attempt must not block the next one")
    }

    // MARK: - Backoff

    func testFailuresAccumulateAndSuccessResetsThem() {
        var state = RevivalState()
        state.requestCapture()
        for expected in 1...3 {
            let attempt = state.begin()!
            XCTAssertEqual(state.fail(attempt), expected)
        }
        let recovered = state.begin()!
        XCTAssertTrue(state.succeed(recovered))
        XCTAssertEqual(state.consecutiveFailures, 0)

        let next = state.begin()!
        XCTAssertEqual(state.fail(next), 1, "a success must clear the backoff")
    }

    func testBackoffGrowsThenHoldsAtAMinute() {
        XCTAssertEqual(RevivalState.backoff(consecutiveFailures: 1), 2)
        XCTAssertEqual(RevivalState.backoff(consecutiveFailures: 2), 4)
        XCTAssertEqual(RevivalState.backoff(consecutiveFailures: 5), 32)

        // Capped while the user still requests capture; suspend cancels retries.
        XCTAssertEqual(RevivalState.backoff(consecutiveFailures: 6), 60)
        XCTAssertEqual(RevivalState.backoff(consecutiveFailures: 500), 60)
    }

    func testIdleStartupAndDeviceChangesCannotStartCapture() {
        var state = RevivalState()
        XCTAssertFalse(state.captureRequested)
        XCTAssertNil(state.begin())
        XCTAssertNil(state.begin())
    }

    func testReleaseInvalidatesQueuedStartAndItsWatchdog() {
        var state = RevivalState()
        state.requestCapture()
        let queued = state.begin()!
        state.suspend()
        XCTAssertFalse(state.isCurrent(queued))
        XCTAssertFalse(state.succeed(queued))
        XCTAssertNil(state.abandonIfStuck(queued))
        XCTAssertNil(state.begin(), "wake/device changes must not reopen idle capture")
    }

    func testReleaseInvalidatesCallbacksFromAnAlreadyRunningEngine() {
        var state = RevivalState()
        state.requestCapture()
        let running = state.begin()!
        XCTAssertTrue(state.succeed(running))
        XCTAssertTrue(state.isCurrent(running))
        state.suspend()
        XCTAssertFalse(state.isCurrent(running), "late audio must not enter a finished recording")
    }

    func testQuickRepressRejectsThePreviousEngineAndFailure() {
        var state = RevivalState()
        state.requestCapture()
        let old = state.begin()!
        state.suspend()
        state.requestCapture()
        let fresh = state.begin()!
        XCTAssertFalse(state.succeed(old))
        XCTAssertNil(state.fail(old))
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertTrue(state.succeed(fresh))
        XCTAssertTrue(state.isCurrent(fresh))
    }

    func testReleaseCancelsBackoffAndNextPressStartsFresh() {
        var state = RevivalState()
        state.requestCapture()
        _ = state.fail(state.begin()!)
        let delayedRetry = state.begin()!
        state.suspend()
        XCTAssertFalse(state.isCurrent(delayedRetry))
        XCTAssertEqual(state.consecutiveFailures, 0)
        state.requestCapture()
        XCTAssertNotNil(state.begin())
    }

    func testCompletedAttemptCannotReportASecondOutcome() {
        var state = RevivalState()
        state.requestCapture()
        let attempt = state.begin()!
        XCTAssertTrue(state.succeed(attempt))
        XCTAssertFalse(state.succeed(attempt))
        XCTAssertNil(state.fail(attempt))
    }

}
