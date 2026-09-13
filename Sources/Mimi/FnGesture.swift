/// Fn holds start immediately; a short first tap arms a hands-free second press.
/// No release delay or idle microphone is needed to recognize the double press.
struct FnGesture {
    enum Action: Equatable {
        case start(locked: Bool)
        case stop
        case cancel
    }

    static let tapDuration = 0.3
    static let doublePressInterval = 0.5

    private(set) var keyDown = false
    private(set) var isRecording = false
    private(set) var isLocked = false
    private var pressedAt: Double?
    private var firstTapAt: Double?

    mutating func press(at time: Double, canStart: Bool = true) -> Action? {
        guard !keyDown else { return nil }
        keyDown = true
        if isLocked {
            reset(keepingKeyDown: true)
            return .stop
        }
        guard canStart else {
            firstTapAt = nil
            return nil
        }
        isLocked = firstTapAt.map { time - $0 <= Self.doublePressInterval } ?? false
        firstTapAt = nil
        pressedAt = time
        isRecording = true
        return .start(locked: isLocked)
    }

    mutating func release(at time: Double) -> Action? {
        guard keyDown else { return nil }
        keyDown = false
        guard isRecording, !isLocked else { return nil }
        isRecording = false
        let shortTap = pressedAt.map { time - $0 < Self.tapDuration } ?? false
        firstTapAt = shortTap ? pressedAt : nil
        pressedAt = nil
        // Discard the first tap, even if microphone startup happened to finish.
        // It must not start transcription and block the second press.
        return shortTap ? .cancel : .stop
    }

    /// Fn+another key is a keyboard shortcut, not a dictation gesture. Typing
    /// without Fn while hands-free is intentionally allowed.
    mutating func otherKey() -> Action? {
        firstTapAt = nil
        guard keyDown, isRecording, !isLocked else { return nil }
        reset(keepingKeyDown: true)
        return .cancel
    }

    mutating func reset(keepingKeyDown: Bool = false) {
        let wasDown = keyDown
        self = Self()
        keyDown = keepingKeyDown && wasDown
    }
}
