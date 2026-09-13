import Foundation

struct EngineTranscript: Sendable {
    var text: String
    var runtimeMs: Int
    var recognition: [RecognitionResult] = []
}

struct TranscriptSelection: Sendable {
    var text: String
    var usedParakeet: Bool
    var apple: EngineTranscript?
    var parakeetTotalMs: Int?
    var parakeetWaitMs: Int
    var fallbackWaitMs: Int
}

/// Parakeet is preferred, not gated on Apple finalization. The fallback starts
/// concurrently and has its own deadline, even if Parakeet takes much longer.
enum TranscriptSelector {
    static func select(
        preferred: Task<EngineTranscript?, Never>?,
        preferredDeadline: Double,
        fallbackDeadline: Double = 10,
        fallback: @escaping @Sendable () async -> EngineTranscript?,
        cancelFallback: @escaping @Sendable () async -> Void
    ) async -> TranscriptSelection {
        let state = FallbackState()
        let appleTask = Task {
            await withTaskCancellationHandler {
                let result = await AppDelegate.abandoning(after: fallbackDeadline, fallback)
                await state.finish(result)
                if result == nil { await state.stop(using: cancelFallback) }
                return result
            } onCancel: {
                Task { await state.stop(using: cancelFallback) }
            }
        }

        let start = ContinuousClock.now
        let parakeet = await AppDelegate.awaitValue(of: preferred, deadline: preferredDeadline)
        let parakeetWaitMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        let text = parakeet?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            // Read an already-finished result for diagnostics; never await it.
            let apple = await state.result
            appleTask.cancel()
            return .init(
                text: text, usedParakeet: true, apple: apple,
                parakeetTotalMs: parakeet?.runtimeMs,
                parakeetWaitMs: parakeetWaitMs, fallbackWaitMs: 0)
        }

        let fallbackStart = ContinuousClock.now
        let apple = await appleTask.value
        return .init(
            text: apple?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            usedParakeet: false, apple: apple,
            parakeetTotalMs: parakeet?.runtimeMs,
            parakeetWaitMs: parakeetWaitMs,
            fallbackWaitMs: Int((ContinuousClock.now - fallbackStart) / .milliseconds(1)))
    }

    private actor FallbackState {
        private(set) var result: EngineTranscript?
        private var finished = false
        private var stopRequested = false

        func finish(_ result: EngineTranscript?) {
            self.result = result
            finished = true
        }

        func stop(using cancel: @escaping @Sendable () async -> Void) {
            guard !stopRequested, !(finished && result != nil) else { return }
            stopRequested = true
            // Framework teardown may be slow. Request it exactly once without
            // making transcript selection or paste wait for completion.
            Task { await cancel() }
        }
    }
}
