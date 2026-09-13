import CoreGraphics
import XCTest
@testable import Mimi

final class FnGestureTests: XCTestCase {
    func testHoldStartsImmediatelyAndReleaseStops() {
        var gesture = FnGesture()
        XCTAssertEqual(gesture.press(at: 0), .start(locked: false))
        XCTAssertEqual(gesture.release(at: 5), .stop)
        XCTAssertFalse(gesture.isRecording)
        XCTAssertEqual(gesture.press(at: 5.1), .start(locked: false))
    }

    func testDoublePressLocksAndNextPressStopsWithoutRestartOnRelease() {
        var gesture = FnGesture()
        XCTAssertEqual(gesture.press(at: 0), .start(locked: false))
        XCTAssertEqual(gesture.release(at: 0.1), .cancel)
        XCTAssertEqual(gesture.press(at: 0.2), .start(locked: true))
        XCTAssertNil(gesture.release(at: 0.3))
        XCTAssertTrue(gesture.isRecording)
        XCTAssertTrue(gesture.isLocked)
        XCTAssertEqual(gesture.press(at: 10), .stop)
        XCTAssertNil(gesture.release(at: 10.1))
        XCTAssertFalse(gesture.isRecording)
        XCTAssertFalse(gesture.isLocked)
        XCTAssertEqual(gesture.press(at: 10.2), .start(locked: false))
    }

    func testSlowSecondPressDoesNotLock() {
        var gesture = FnGesture()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        XCTAssertEqual(gesture.press(at: 0.7), .start(locked: false))
    }

    func testDuplicateDownOrUpDoesNotChangeGesture() {
        var gesture = FnGesture()
        _ = gesture.press(at: 0)
        XCTAssertNil(gesture.press(at: 0.05))
        XCTAssertEqual(gesture.release(at: 0.1), .cancel)
        XCTAssertNil(gesture.release(at: 0.15))
        XCTAssertEqual(gesture.press(at: 0.2), .start(locked: true))
    }

    func testBusyAppCannotArmHandsFree() {
        var gesture = FnGesture()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        XCTAssertNil(gesture.press(at: 0.2, canStart: false))
        XCTAssertNil(gesture.release(at: 0.3))
        XCTAssertEqual(gesture.press(at: 0.4), .start(locked: false))
    }

    func testFnShortcutCancelsButHandsFreeTypingDoesNot() {
        var gesture = FnGesture()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.otherKey(), .cancel)
        XCTAssertNil(gesture.release(at: 0.1))
        XCTAssertEqual(gesture.press(at: 0.2), .start(locked: false))
        _ = gesture.release(at: 0.3)
        _ = gesture.press(at: 0.4)
        _ = gesture.release(at: 0.5)
        XCTAssertNil(gesture.otherKey())
        XCTAssertTrue(gesture.isLocked)
        XCTAssertTrue(gesture.isRecording)
    }

    func testInterveningTypingBreaksDoublePress() {
        var gesture = FnGesture()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        _ = gesture.otherKey()
        XCTAssertEqual(gesture.press(at: 0.2), .start(locked: false))
    }

    func testSleepAndWatchdogClearLockAndTapCandidate() {
        var gesture = FnGesture()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        gesture.reset()
        XCTAssertEqual(gesture.press(at: 0.2), .start(locked: false))
        _ = gesture.release(at: 0.3)
        _ = gesture.press(at: 0.4)
        gesture.reset(keepingKeyDown: true)
        XCTAssertFalse(gesture.isLocked)
        XCTAssertFalse(gesture.isRecording)
        XCTAssertNil(gesture.press(at: 0.5))
        XCTAssertNil(gesture.release(at: 0.6))
        XCTAssertEqual(gesture.press(at: 0.7), .start(locked: false))
    }

    // Exercise real event decoding without posting keys or opening a microphone.
    private func event(code: Int64 = 63, down: Bool, at: Double) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: code)
        event.flags = down ? .maskSecondaryFn : []
        event.timestamp = UInt64(at * 1_000_000_000)
        return event
    }

    func testEventTapRoutesHoldLockAndStop() {
        let monitor = HotkeyMonitor()
        var actions: [FnGesture.Action] = []
        monitor.onPress = { actions.append(.start(locked: $0)) }
        monitor.onRelease = { actions.append(.stop) }
        monitor.onCancel = { actions.append(.cancel) }
        for (down, time) in [(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3), (true, 5.0), (false, 5.1)] {
            XCTAssertNil(monitor.handle(type: .flagsChanged, event: event(down: down, at: time)))
        }
        XCTAssertEqual(actions, [.start(locked: false), .cancel, .start(locked: true), .stop])
    }

    func testFunctionRowAndSyntheticEventsCannotStartRecording() {
        let monitor = HotkeyMonitor()
        monitor.onPress = { _ in XCTFail("Not a physical Fn press") }
        let functionRow = event(code: 122, down: true, at: 0)
        XCTAssertNotNil(monitor.handle(type: .keyDown, event: functionRow))
        let synthetic = event(down: true, at: 0.1)
        synthetic.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticMarker)
        XCTAssertNotNil(monitor.handle(type: .flagsChanged, event: synthetic))
    }

    func testDoublePressSurvivesGlobeCompanionEventsInEitherOrderDuringStartup() {
        for globeFirst in [false, true] {
            let monitor = HotkeyMonitor()
            var actions: [FnGesture.Action] = []
            var startingMicrophone = false
            monitor.canStart = { !startingMicrophone }
            monitor.onPress = {
                startingMicrophone = true
                actions.append(.start(locked: $0))
            }
            monitor.onCancel = {
                startingMicrophone = false
                actions.append(.cancel)
            }
            monitor.onRelease = {
                startingMicrophone = false
                actions.append(.stop)
            }
            // Nothing ever becomes ready: the second tap must still lock,
            // and releasing it must not cancel its pending microphone start.
            for (down, time) in [(true, 0.0), (false, 0.06), (true, 0.12), (false, 0.2), (true, 5.0), (false, 5.1)] {
                let fn = event(down: down, at: time)
                let globe = event(code: 179, down: down, at: time + 0.001)
                globe.type = down ? .keyDown : .keyUp
                for e in globeFirst ? [globe, fn] : [fn, globe] {
                    XCTAssertNil(monitor.handle(type: e.type, event: e))
                }
                if time == 0.2 {
                    XCTAssertTrue(monitor.isLocked)
                    XCTAssertTrue(startingMicrophone)
                }
            }
            XCTAssertEqual(actions, [.start(locked: false), .cancel, .start(locked: true), .stop])
        }
    }

    func testGlobeEventsCannotCancelHoldOrActAsStopPress() {
        let monitor = HotkeyMonitor()
        var actions: [FnGesture.Action] = []
        monitor.onPress = { actions.append(.start(locked: $0)) }
        monitor.onCancel = { actions.append(.cancel) }
        monitor.onRelease = { actions.append(.stop) }
        _ = monitor.handle(type: .flagsChanged, event: event(down: true, at: 0))
        _ = monitor.handle(type: .keyDown, event: event(code: 179, down: true, at: 0.01))
        _ = monitor.handle(type: .keyDown, event: event(code: 179, down: true, at: 0.5))
        XCTAssertEqual(actions, [.start(locked: false)])
        _ = monitor.handle(type: .keyUp, event: event(code: 179, down: false, at: 1))
        _ = monitor.handle(type: .flagsChanged, event: event(down: false, at: 1.01))
        XCTAssertEqual(actions, [.start(locked: false), .stop])
    }

    func testDisabledTapCancelsLockedRecording() {
        let monitor = HotkeyMonitor()
        var cancellations = 0
        monitor.onCancel = { cancellations += 1 }
        for (down, time) in [(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3)] {
            _ = monitor.handle(type: .flagsChanged, event: event(down: down, at: time))
        }
        XCTAssertTrue(monitor.isLocked)
        _ = monitor.handle(type: .tapDisabledByTimeout, event: event(down: false, at: 1))
        XCTAssertFalse(monitor.isLocked)
        XCTAssertEqual(cancellations, 2)
    }
}
