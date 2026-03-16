import XCTest
@testable import Screenie

final class SpeedMapperTests: XCTestCase {

    func testActiveSegmentsMapTo1x() {
        let segments = [
            ActivitySegment(activity: .active, startTime: 0, endTime: 5)
        ]
        let mappings = SpeedMapper.map(segments: segments)
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings[0].speed, 1.0, accuracy: 0.01)
    }

    func testClickSegmentsMapToSlowDown() {
        let segments = [
            ActivitySegment(activity: .click, startTime: 2, endTime: 2.3)
        ]
        let mappings = SpeedMapper.map(segments: segments)
        XCTAssertEqual(mappings[0].speed, 0.75, accuracy: 0.01)
    }

    func testShortIdleMapsto4x() {
        let segments = [
            ActivitySegment(activity: .idle, startTime: 0, endTime: 1.5)
        ]
        let mappings = SpeedMapper.map(segments: segments)
        XCTAssertEqual(mappings[0].speed, 4.0, accuracy: 0.01)
    }

    func testLongIdleMapsTo8x() {
        let segments = [
            ActivitySegment(activity: .idle, startTime: 0, endTime: 10.0)
        ]
        let mappings = SpeedMapper.map(segments: segments)
        XCTAssertEqual(mappings[0].speed, 8.0, accuracy: 0.5)
    }

    func testOutputDurationShorterThanInput() {
        let segments = [
            ActivitySegment(activity: .active, startTime: 0, endTime: 5),
            ActivitySegment(activity: .idle, startTime: 5, endTime: 15),
            ActivitySegment(activity: .active, startTime: 15, endTime: 20),
        ]
        let mappings = SpeedMapper.map(segments: segments)
        let outputDuration = mappings.reduce(0) { $0 + $1.outputDuration }
        let inputDuration = 20.0
        XCTAssertLessThan(outputDuration, inputDuration)
    }
}
