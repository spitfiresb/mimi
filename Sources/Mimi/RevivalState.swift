import Foundation

/// Bookkeeping for audio engine revivals, kept apart from AVFoundation so the
/// races it exists to prevent can be tested without a microphone.
///
/// The problem it solves: a revival can block inside CoreAudio for an unbounded
/// time and cannot be cancelled (2026-08-13 — a wake-time `AVAudioEngine`
/// call sat in a mach_msg for two days). Mimi's only recourse is to stop
/// waiting on a stuck attempt and start another, which means two attempts can
/// be alive at once, each holding its own engine. Generations decide which one
/// is allowed to publish its result: the newest, and only the newest.
///
/// Not thread-safe on its own — `AudioCapture` only touches it under its lock.
struct RevivalState {
    /// Hardware work is allowed only during an explicit dictation request.
    private(set) var captureRequested = false

    mutating func requestCapture() {
        captureRequested = true
    }

    /// Invalidates queued starts, callbacks, completions and watchdogs, including
    /// attempts still blocked in CoreAudio. A later press gets a new generation.
    mutating func suspend() {
        captureRequested = false
        generation += 1
        inFlight = false
        consecutiveFailures = 0
    }

    /// Rises with every attempt started. An attempt carries the generation it
    /// was issued, and compares it back before touching anything shared.
    private(set) var generation = 0

    /// Whether an attempt is currently believed to be running. "Believed"
    /// because a wedged attempt is written off while its thread is still stuck
    /// in the HAL — this goes false, that thread keeps running, and its
    /// generation is what stops it doing damage when it finally returns.
    private(set) var inFlight = false

    /// Failures in a row, used to back off. Reset by any success.
    private(set) var consecutiveFailures = 0

    /// Claims the next generation, or nil when an attempt is already running.
    ///
    /// Coalescing is the point: waking a Mac posts `didWakeNotification` and
    /// `AVAudioEngineConfigurationChange` within milliseconds of each other,
    /// and a keypress can land on top of both. Three revivals racing to install
    /// three taps on the same device is its own outage.
    mutating func begin() -> Int? {
        guard captureRequested, !inFlight else { return nil }
        inFlight = true
        generation += 1
        return generation
    }

    /// Whether this attempt's result still matters, or whether a newer one has
    /// taken over while it was blocked.
    func isCurrent(_ attemptGeneration: Int) -> Bool {
        captureRequested && attemptGeneration == generation
    }

    /// Records a successful attempt. False means it was superseded and its
    /// engine should be thrown away rather than published.
    mutating func succeed(_ attemptGeneration: Int) -> Bool {
        guard isCurrent(attemptGeneration), inFlight else { return false }
        inFlight = false
        consecutiveFailures = 0
        return true
    }

    /// Records a failed attempt, returning the consecutive-failure count to
    /// back off by. Nil means the attempt was superseded and should stay quiet:
    /// retrying on its behalf would double up with whoever replaced it.
    mutating func fail(_ attemptGeneration: Int) -> Int? {
        guard isCurrent(attemptGeneration), inFlight else { return nil }
        inFlight = false
        consecutiveFailures += 1
        return consecutiveFailures
    }

    /// The watchdog's version of `fail`, which additionally requires the attempt
    /// to still be running. Without that check a watchdog armed for an attempt
    /// that has since finished cleanly would report a phantom failure and
    /// trigger a pointless rebuild of a perfectly good engine.
    mutating func abandonIfStuck(_ attemptGeneration: Int) -> Int? {
        guard isCurrent(attemptGeneration), inFlight else { return nil }
        return fail(attemptGeneration)
    }

    /// Retry only while capture is requested. Release/sleep invalidates the
    /// queued attempt; another keypress starts with a fresh failure count.
    static func backoff(consecutiveFailures: Int) -> TimeInterval {
        min(pow(2.0, Double(min(consecutiveFailures, 6))), 60)
    }
}
