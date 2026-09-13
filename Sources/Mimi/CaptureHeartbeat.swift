import Foundation

/// Real readiness and recovery eligibility are different: a new engine needs
/// time to deliver its first buffer, but must not be reported ready until it does.
struct CaptureHeartbeat {
    private var startedAt: TimeInterval?
    private var lastBufferAt: TimeInterval?
    static let stallThreshold: TimeInterval = 1

    mutating func started(at time: TimeInterval) { startedAt = time }
    mutating func receivedBuffer(at time: TimeInterval) { lastBufferAt = time }
    mutating func reset() { startedAt = nil; lastBufferAt = nil }

    func isDelivering(at time: TimeInterval) -> Bool {
        guard startedAt != nil, let lastBufferAt else { return false }
        return time - lastBufferAt <= Self.stallThreshold
    }

    func needsRecovery(at time: TimeInterval) -> Bool {
        guard let startedAt else { return true }
        return time - (lastBufferAt ?? startedAt) > Self.stallThreshold
    }
}
