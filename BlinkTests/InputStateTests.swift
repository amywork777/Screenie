import XCTest
@testable import Blink

final class InputStateTests: XCTestCase {

    var state: InputState!

    override func setUp() {
        state = InputState()
    }

    // MARK: - Basic states

    func testStartsIdle() {
        XCTAssertEqual(state.current, .idle)
    }

    func testKeyDownTransitionsToPressed() {
        let action = state.handleKeyDown()
        XCTAssertEqual(state.current, .pressed)
        XCTAssertNil(action)
    }

    func testQuickReleaseTransitionsToAwaitSecondTap() {
        _ = state.handleKeyDown()
        let action = state.handleKeyUp()
        XCTAssertEqual(state.current, .awaitSecondTap)
        XCTAssertNil(action)
    }

    // MARK: - Double-tap to start

    func testDoubleTapStartsRecording() {
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleKeyDown()
        let action = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleRecording)
        XCTAssertEqual(action, .startRecording)
    }

    // MARK: - Double-tap to stop

    func testDoubleTapWhileRecordingStops() {
        // Start recording
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleRecording)

        // Double-tap to stop
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleKeyDown()
        let action = state.handleKeyUp()
        XCTAssertEqual(state.current, .idle)
        XCTAssertEqual(action, .stopRecording)
    }

    // MARK: - Timeouts

    func testAwaitSecondTapTimeoutReturnsToIdle() {
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        let action = state.handleDoubleTapTimerFired()
        XCTAssertEqual(state.current, .idle)
        XCTAssertNil(action)
    }

    func testStopAwaitTimeoutReturnsToRecording() {
        // Start recording
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleRecording)

        // Single tap (not double) — timeout back to recording
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleStopAwait)

        let action = state.handleDoubleTapTimerFired()
        XCTAssertEqual(state.current, .toggleRecording)
        XCTAssertNil(action)
    }

    // MARK: - Edge cases

    func testSingleTapDoesNothing() {
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleDoubleTapTimerFired()
        XCTAssertEqual(state.current, .idle)
    }
}
