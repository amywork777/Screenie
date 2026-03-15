import XCTest
@testable import Blink

final class ActivityAnalyzerTests: XCTestCase {

    func testEmptyEventsProducesEmptyTimeline() {
        let timeline = ActivityAnalyzer.analyze(events: [], duration: 10.0)
        XCTAssertTrue(timeline.isEmpty)
    }

    func testSingleClickProducesClickSegment() throws {
        let events = [
            LoggedEvent(timestamp: 2.0, type: .mouseClick, x: 100, y: 200, windowName: nil)
        ]
        let timeline = ActivityAnalyzer.analyze(events: events, duration: 5.0)
        let clickSegments = timeline.filter { $0.activity == .click }
        XCTAssertEqual(clickSegments.count, 1)
        let startTime = try XCTUnwrap(clickSegments.first?.startTime)
        XCTAssertEqual(startTime, 2.0, accuracy: 0.2)
    }

    func testContinuousTypingIsActive() {
        let events = (0..<20).map { i in
            LoggedEvent(timestamp: Double(i) * 0.1, type: .keyPress, x: nil, y: nil, windowName: nil)
        }
        let timeline = ActivityAnalyzer.analyze(events: events, duration: 2.0)
        let activeSegments = timeline.filter { $0.activity == .active }
        XCTAssertFalse(activeSegments.isEmpty)
    }

    func testGapBeyondThresholdIsIdle() {
        let events = [
            LoggedEvent(timestamp: 0.0, type: .keyPress, x: nil, y: nil, windowName: nil),
            LoggedEvent(timestamp: 5.0, type: .keyPress, x: nil, y: nil, windowName: nil),
        ]
        let timeline = ActivityAnalyzer.analyze(events: events, duration: 6.0)
        let idleSegments = timeline.filter { $0.activity == .idle }
        XCTAssertFalse(idleSegments.isEmpty)
        let longIdle = idleSegments.first { $0.duration > 2.0 }
        XCTAssertNotNil(longIdle)
    }

    func testMouseMovementIsActive() {
        let events = (0..<10).map { i in
            LoggedEvent(timestamp: Double(i) * 0.2, type: .mouseMove,
                        x: CGFloat(i * 50), y: 100, windowName: nil)
        }
        let timeline = ActivityAnalyzer.analyze(events: events, duration: 2.0)
        let activeSegments = timeline.filter { $0.activity == .active }
        XCTAssertFalse(activeSegments.isEmpty)
    }
}
