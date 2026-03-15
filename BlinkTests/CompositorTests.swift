import XCTest
@testable import Blink

final class CompositorTests: XCTestCase {

    func testSourceTimeToOutputTimeMapping() {
        let mappings = [
            TimeMapping(sourceStart: 0, sourceEnd: 5, speed: 1.0),
            TimeMapping(sourceStart: 5, sourceEnd: 15, speed: 8.0),
            TimeMapping(sourceStart: 15, sourceEnd: 20, speed: 1.0),
        ]

        let totalOutput = mappings.reduce(0.0) { $0 + $1.outputDuration }
        XCTAssertEqual(totalOutput, 11.25, accuracy: 0.01)

        let compositor = Compositor(storage: StorageManager())

        let t0 = compositor.sourceTimeToOutputTime(sourceTime: 0, timeMappings: mappings)
        XCTAssertEqual(t0, 0.0, accuracy: 0.01)

        let t5 = compositor.sourceTimeToOutputTime(sourceTime: 5, timeMappings: mappings)
        XCTAssertEqual(t5, 5.0, accuracy: 0.01)

        let t15 = compositor.sourceTimeToOutputTime(sourceTime: 15, timeMappings: mappings)
        XCTAssertEqual(t15, 6.25, accuracy: 0.01)

        let t20 = compositor.sourceTimeToOutputTime(sourceTime: 20, timeMappings: mappings)
        XCTAssertEqual(t20, 11.25, accuracy: 0.01)
    }
}
