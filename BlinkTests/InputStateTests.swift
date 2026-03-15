import XCTest
@testable import Blink

final class InputStateTests: XCTestCase {

    var state: InputState!

    override func setUp() {
        state = InputState()
    }

    // MARK: - Hold-to-record path

    func testStartsIdle() {
        XCTAssertEqual(state.current, .idle)
    }

    func testKeyDownTransitionsToPressed() {
        let action = state.handleKeyDown()
        XCTAssertEqual(state.current, .pressed)
        XCTAssertNil(action)
    }

    func testHoldBeyondThresholdStartsRecording() {
        _ = state.handleKeyDown()
        let action = state.handleHoldTimerFired()
        XCTAssertEqual(state.current, .holdRecording)
        XCTAssertEqual(action, .startRecording)
    }

    func testKeyUpDuringHoldRecordingStops() {
        _ = state.handleKeyDown()
        _ = state.handleHoldTimerFired()
        let action = state.handleKeyUp()
        XCTAssertEqual(state.current, .idle)
        XCTAssertEqual(action, .stopRecording)
    }

    // MARK: - Double-tap path

    func testQuickReleaseTransitionsToAwaitSecondTap() {
        _ = state.handleKeyDown()
        let action = state.handleKeyUp()
        XCTAssertEqual(state.current, .awaitSecondTap)
        XCTAssertNil(action)
    }

    func testSecondTapStartsToggleRecording() {
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleKeyDown()
        let action = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleRecording)
        XCTAssertEqual(action, .startRecording)
    }

    func testDoubleTapWhileToggleRecordingStops() {
        // Start toggle recording
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

    func testAwaitSecondTapTimeoutReturnsToIdle() {
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        let action = state.handleDoubleTapTimerFired()
        XCTAssertEqual(state.current, .idle)
        XCTAssertNil(action)
    }

    // MARK: - Edge cases

    func testKeyDownWhileAlreadyRecordingIsIgnored() {
        _ = state.handleKeyDown()
        _ = state.handleHoldTimerFired()
        let action = state.handleKeyDown()
        XCTAssertEqual(state.current, .holdRecording)
        XCTAssertNil(action)
    }

    func testHoldTimerInWrongStateIsIgnored() {
        let action = state.handleHoldTimerFired()
        XCTAssertEqual(state.current, .idle)
        XCTAssertNil(action)
    }

    func testToggleStopAwaitTimeoutReturnsToToggleRecording() {
        // Enter toggle recording
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleRecording)

        // Single tap (not double) — should timeout back to toggleRecording
        _ = state.handleKeyDown()
        _ = state.handleKeyUp()
        XCTAssertEqual(state.current, .toggleStopAwait)

        let action = state.handleDoubleTapTimerFired()
        XCTAssertEqual(state.current, .toggleRecording)
        XCTAssertNil(action)
    }
}
