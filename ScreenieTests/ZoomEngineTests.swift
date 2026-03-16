import XCTest
import CoreGraphics
@testable import Screenie

final class ZoomEngineTests: XCTestCase {

    let screenSize = CGSize(width: 1920, height: 1080)

    func testNoEventsProducesFullScreenFrames() {
        let frames = ZoomEngine.generateFrames(
            events: [], screenSize: screenSize, timeMappings: [], duration: 5.0
        )
        XCTAssertTrue(frames.allSatisfy { $0.zoomLevel == 1.0 })
    }

    func testClickProducesZoomIn() {
        let events = [
            LoggedEvent(timestamp: 2.0, type: .mouseClick, x: 960, y: 540, windowName: nil)
        ]
        let frames = ZoomEngine.generateFrames(
            events: events, screenSize: screenSize, timeMappings: [], duration: 5.0
        )
        let zoomedFrames = frames.filter { $0.zoomLevel > 1.0 }
        XCTAssertFalse(zoomedFrames.isEmpty)
    }

    func testZoomCentersOnClick() {
        let events = [
            LoggedEvent(timestamp: 2.0, type: .mouseClick, x: 960, y: 500, windowName: nil)
        ]
        let frames = ZoomEngine.generateFrames(
            events: events, screenSize: screenSize, timeMappings: [], duration: 5.0
        )
        let zoomedFrame = frames.first { $0.zoomLevel > 1.0 }!
        let centerX = zoomedFrame.cropRect.midX
        let centerY = zoomedFrame.cropRect.midY
        XCTAssertEqual(centerX, 960, accuracy: 100)
        XCTAssertEqual(centerY, 500, accuracy: 100)
    }

    func testZoomLevelIs150Percent() {
        let events = [
            LoggedEvent(timestamp: 2.0, type: .mouseClick, x: 960, y: 540, windowName: nil)
        ]
        let frames = ZoomEngine.generateFrames(
            events: events, screenSize: screenSize, timeMappings: [], duration: 5.0
        )
        let maxZoom = frames.map(\.zoomLevel).max()!
        XCTAssertEqual(maxZoom, 1.5, accuracy: 0.1)
    }

    func testIdleReturnsToFullScreen() {
        let events = [
            LoggedEvent(timestamp: 1.0, type: .mouseClick, x: 960, y: 540, windowName: nil)
        ]
        let frames = ZoomEngine.generateFrames(
            events: events, screenSize: screenSize, timeMappings: [], duration: 10.0
        )
        let lastFrame = frames.last!
        XCTAssertEqual(lastFrame.zoomLevel, 1.0, accuracy: 0.1)
    }
}
