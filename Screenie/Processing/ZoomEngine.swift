import Foundation
import CoreGraphics

struct ZoomFrame {
    let timestamp: TimeInterval
    let cropRect: CGRect
    let zoomLevel: CGFloat
}

struct ZoomTrigger {
    let timestamp: TimeInterval
    let center: CGPoint
}

struct ZoomEngine {
    static let zoomInLevel: CGFloat = 1.5
    static let transitionDuration: TimeInterval = 0.3
    static let holdDuration: TimeInterval = 1.5
    static let frameInterval: TimeInterval = 1.0 / 30.0

    static func generateFrames(
        events: [LoggedEvent],
        screenSize: CGSize,
        timeMappings: [TimeMapping],
        duration: TimeInterval
    ) -> [ZoomFrame] {
        let zoomTriggers = buildZoomTriggers(events: events, screenSize: screenSize)
        var frames: [ZoomFrame] = []
        let fullRect = CGRect(origin: .zero, size: screenSize)
        var t: TimeInterval = 0

        while t <= duration {
            let (zoom, center) = zoomAt(time: t, triggers: zoomTriggers, screenSize: screenSize)
            let cropRect = zoom > 1.0
                ? cropRectForZoom(center: center, zoom: zoom, screenSize: screenSize)
                : fullRect
            frames.append(ZoomFrame(timestamp: t, cropRect: cropRect, zoomLevel: zoom))
            t += frameInterval
        }

        return frames
    }

    private static func buildZoomTriggers(events: [LoggedEvent], screenSize: CGSize) -> [ZoomTrigger] {
        var triggers: [ZoomTrigger] = []
        var lastMousePos = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)

        for event in events {
            if let x = event.x, let y = event.y {
                lastMousePos = CGPoint(x: x, y: y)
            }
            if event.type == .mouseClick, let x = event.x, let y = event.y {
                triggers.append(ZoomTrigger(timestamp: event.timestamp, center: CGPoint(x: x, y: y)))
            }
            if event.type == .keyPress {
                triggers.append(ZoomTrigger(timestamp: event.timestamp, center: lastMousePos))
            }
        }

        return triggers
    }

    private static func zoomAt(
        time: TimeInterval,
        triggers: [ZoomTrigger],
        screenSize: CGSize
    ) -> (CGFloat, CGPoint) {
        var bestZoom: CGFloat = 1.0
        var bestCenter = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)

        for trigger in triggers {
            let clickCenter = trigger.center
            let timeSinceClick = time - trigger.timestamp

            if timeSinceClick < 0 {
                let timeUntil = -timeSinceClick
                if timeUntil < transitionDuration {
                    let progress = 1.0 - (timeUntil / transitionDuration)
                    let zoom = 1.0 + (zoomInLevel - 1.0) * easeInOut(CGFloat(progress))
                    if zoom > bestZoom {
                        bestZoom = zoom
                        bestCenter = clickCenter
                    }
                }
            } else if timeSinceClick < holdDuration {
                bestZoom = zoomInLevel
                bestCenter = clickCenter
            } else if timeSinceClick < holdDuration + transitionDuration {
                let progress = (timeSinceClick - holdDuration) / transitionDuration
                let zoom = zoomInLevel - (zoomInLevel - 1.0) * easeInOut(CGFloat(progress))
                if zoom > bestZoom {
                    bestZoom = zoom
                    bestCenter = clickCenter
                }
            }
        }

        return (bestZoom, bestCenter)
    }

    private static func cropRectForZoom(
        center: CGPoint,
        zoom: CGFloat,
        screenSize: CGSize
    ) -> CGRect {
        let cropW = screenSize.width / zoom
        let cropH = screenSize.height / zoom
        var x = center.x - cropW / 2
        var y = center.y - cropH / 2

        x = max(0, min(x, screenSize.width - cropW))
        y = max(0, min(y, screenSize.height - cropH))

        return CGRect(x: x, y: y, width: cropW, height: cropH)
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
