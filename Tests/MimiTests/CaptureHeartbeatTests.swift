@testable import Mimi
import XCTest

final class CaptureHeartbeatTests: XCTestCase {
    func testNewEngineIsNotReadyButConfigurationNotificationMustNotRestartIt() {
        var heartbeat = CaptureHeartbeat()
        heartbeat.started(at: 10)
        // Live regression: own configuration notification arrived ~64ms after
        // start, before the first ~85ms audio buffer, creating a rebuild loop.
        XCTAssertFalse(heartbeat.isDelivering(at: 10.064))
        XCTAssertFalse(heartbeat.needsRecovery(at: 10.064))
        heartbeat.receivedBuffer(at: 10.085)
        XCTAssertTrue(heartbeat.isDelivering(at: 10.1))
        XCTAssertFalse(heartbeat.needsRecovery(at: 10.1))
    }

    func testMissingFirstBufferEventuallyAllowsRecovery() {
        var heartbeat = CaptureHeartbeat()
        heartbeat.started(at: 10)
        XCTAssertFalse(heartbeat.isDelivering(at: 11.1))
        XCTAssertTrue(heartbeat.needsRecovery(at: 11.1))
    }

    func testAStalledPreviouslyHealthyEngineAllowsRecovery() {
        var heartbeat = CaptureHeartbeat()
        heartbeat.started(at: 10)
        heartbeat.receivedBuffer(at: 12)
        XCTAssertTrue(heartbeat.isDelivering(at: 12.5))
        XCTAssertFalse(heartbeat.isDelivering(at: 13.1))
        XCTAssertTrue(heartbeat.needsRecovery(at: 13.1))
    }

    func testBufferBeforeStartReturnsIsPreservedButResetClearsReadiness() {
        var heartbeat = CaptureHeartbeat()
        heartbeat.receivedBuffer(at: 10)
        XCTAssertFalse(heartbeat.isDelivering(at: 10.01))
        heartbeat.started(at: 10.02)
        XCTAssertTrue(heartbeat.isDelivering(at: 10.03))
        heartbeat.reset()
        XCTAssertFalse(heartbeat.isDelivering(at: 10.04))
    }
}
