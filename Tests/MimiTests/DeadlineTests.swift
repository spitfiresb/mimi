@testable import Mimi
import XCTest

/// Pins the Parakeet deadline, which failed silently once and cost 29 seconds.
///
/// The original raced the decode against a sleep inside a `withTaskGroup`. That
/// looks like a timeout and isn't: the group waits for *every* child before it
/// returns, and `cancelAll()` has no reach into a detached task running
/// synchronous Core ML work. So the timeout fired on schedule, the group went on
/// waiting for the decode anyway, and then threw the answer away — a 59s
/// dictation burned 29.2s and pasted the fallback engine's text (2026-08-11).
///
/// Both halves of that failure get a test: the wait must actually be bounded,
/// and work that beats the deadline must not be discarded.
final class DeadlineTests: XCTestCase {

    /// The regression that matters. The job here is synchronous and blocking —
    /// the shape ParakeetEngine's decode loop has — so the only way out is a
    /// cooperative cancellation check. Left alone it runs ~10s; the deadline is
    /// 0.3s. The old implementation waited the full 10s before returning nil.
    func testDeadlineBoundsTheWaitAndDoesNotJustReportATimeout() async {
        let job = Task.detached(priority: .userInitiated) { () -> String? in
            for _ in 0..<2_000 {
                if Task.isCancelled { return nil }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return "ran to completion"
        }

        let clock = ContinuousClock()
        let start = clock.now
        let result = await AppDelegate.awaitValue(of: job, deadline: 0.3)
        let elapsed = clock.now - start

        XCTAssertNil(result, "an overrunning decode must yield nil so the fallback engine's text is used")
        XCTAssertLessThan(
            elapsed, .seconds(3),
            "the deadline must abandon the work, not wait for it and then report a timeout")
    }

    /// The other half: a decode that finishes in time is the whole point of
    /// running Parakeet at all, so its result must survive.
    func testWorkThatBeatsTheDeadlineKeepsItsResult() async {
        let job = Task.detached { () -> String? in "the better transcript" }
        let result = await AppDelegate.awaitValue(of: job, deadline: 30)
        XCTAssertEqual(result, "the better transcript")
    }

    /// No engine, no task — the caller falls straight through to Apple's text.
    func testNoTaskYieldsNil() async {
        let result = await AppDelegate.awaitValue(of: nil, deadline: 1)
        XCTAssertNil(result)
    }

    /// The formatting pass has the same deadline now, and the dangerous failure
    /// there is different: `output` accumulates sentence by sentence, so a pass
    /// cut off partway holds a *truncated* transcript. Pasting that would look
    /// like a successful dictation that silently lost its second half.
    func testCancelledFormattingYieldsNilRatherThanAPartialTranscript() async {
        let pipeline = FormatPipeline(formatter: Formatter()) { _ in }
        await pipeline.feed("First sentence. Next sentence. Last sentence.", spans: [])
        await pipeline.cancel()
        let result = await pipeline.finish()
        XCTAssertNil(result, "a cut-short format pass must not hand back half a transcript")
    }

    /// The formatting budget needs a stronger guarantee than the decode one: a
    /// single `respond()` round trip is uninterruptible, so cooperative checks
    /// alone let one slow sentence overrun the budget (12.1s against 2.5s,
    /// 2026-08-11). `abandoning` must return on time even when the work it
    /// raced cannot be stopped at all.
    func testAbandoningReturnsOnTimeAgainstWorkThatCannotBeCancelled() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await AppDelegate.abandoning(after: 0.3) { () -> String? in
            // No cancellation checks anywhere — the point of the test.
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: 5)
                    continuation.resume(returning: "far too late")
                }
            }
        }
        let elapsed = clock.now - start

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .seconds(3), "the deadline must not inherit the job's duration")
    }

    /// Racing must not cost the answer when the work is quick.
    func testAbandoningKeepsAResultThatArrivesInTime() async {
        let result = await AppDelegate.abandoning(after: 30) { () -> String? in "in time" }
        XCTAssertEqual(result, "in time")
    }

    /// And the pass that isn't cut off still returns its text. These sentences
    /// have no cleanup triggers, so lazy routing passes them through without
    /// creating a model session, even on a machine where the model is available.
    func testUncancelledFormattingReturnsItsText() async {
        let pipeline = FormatPipeline(formatter: Formatter()) { _ in }
        await pipeline.feed("First sentence. Next sentence.", spans: [])
        let result = await pipeline.finish()
        XCTAssertEqual(result, "First sentence. Next sentence.")
    }
}
