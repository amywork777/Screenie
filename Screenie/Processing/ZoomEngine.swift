import Foundation
import CoreGraphics

struct ZoomFrame {
    let timestamp: TimeInterval
    let cropRect: CGRect
    let zoomLevel: CGFloat
}

private struct ZoomTrigger {
    let timestamp: TimeInterval
    let center: CGPoint
}

private struct ZoomCluster {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let center: CGPoint
}

struct ZoomEngine {
    static let zoomInLevel: CGFloat = 1.5
    static let transitionDuration: TimeInterval = 0.3
    static let holdAfterCluster: TimeInterval = 0.5
    static let clusterGap: TimeInterval = 0.8
    static let frameInterval: TimeInterval = 1.0 / 30.0

    static func generateFrames(
        events: [LoggedEvent],
        screenSize: CGSize,
        timeMappings: [TimeMapping],
        duration: TimeInterval
    ) -> [ZoomFrame] {
        let clusters = buildZoomClusters(events: events, screenSize: screenSize)
        var frames: [ZoomFrame] = []
        let fullRect = CGRect(origin: .zero, size: screenSize)
        var t: TimeInterval = 0

        while t <= duration {
            let (zoom, center) = zoomAt(time: t, clusters: clusters, screenSize: screenSize)
            let cropRect = zoom > 1.0
                ? cropRectForZoom(center: center, zoom: zoom, screenSize: screenSize)
                : fullRect
            frames.append(ZoomFrame(timestamp: t, cropRect: cropRect, zoomLevel: zoom))
            t += frameInterval
        }

        return frames
    }

    // MARK: - Cluster building

    private static func buildZoomClusters(events: [LoggedEvent], screenSize: CGSize) -> [ZoomCluster] {
        var triggers: [ZoomTrigger] = []
        var lastMousePos = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)

        let keyTimes = events.filter { $0.type == .keyPress }.map { $0.timestamp }.sorted()

        for event in events {
            if let x = event.x, let y = event.y {
                lastMousePos = CGPoint(x: x, y: y)
            }
            if event.type == .mouseClick, let x = event.x, let y = event.y {
                triggers.append(ZoomTrigger(timestamp: event.timestamp, center: CGPoint(x: x, y: y)))
            }
            if event.type == .keyPress {
                // Only zoom on isolated keypresses (shortcuts), skip typing bursts
                if isIsolatedKeypress(event.timestamp, allKeyTimes: keyTimes) {
                    triggers.append(ZoomTrigger(timestamp: event.timestamp, center: lastMousePos))
                }
            }
        }

        triggers.sort { $0.timestamp < $1.timestamp }

        // Group nearby triggers into clusters
        var clusters: [ZoomCluster] = []
        var pending: [ZoomTrigger] = []

        for trigger in triggers {
            if let last = pending.last, trigger.timestamp - last.timestamp > clusterGap {
                if let cluster = makeCluster(from: pending) {
                    clusters.append(cluster)
                }
                pending = [trigger]
            } else {
                pending.append(trigger)
            }
        }
        if let cluster = makeCluster(from: pending) {
            clusters.append(cluster)
        }

        return clusters
    }

    private static func isIsolatedKeypress(_ time: TimeInterval, allKeyTimes: [TimeInterval]) -> Bool {
        let window: TimeInterval = 0.5
        var count = 0
        for t in allKeyTimes {
            if abs(t - time) <= window {
                count += 1
            }
            if count >= 3 { return false }
        }
        return true
    }

    private static func makeCluster(from triggers: [ZoomTrigger]) -> ZoomCluster? {
        guard !triggers.isEmpty else { return nil }
        return ZoomCluster(
            startTime: triggers.first!.timestamp,
            endTime: triggers.last!.timestamp,
            center: triggers.last!.center
        )
    }

    // MARK: - Zoom evaluation

    private static func zoomAt(
        time: TimeInterval,
        clusters: [ZoomCluster],
        screenSize: CGSize
    ) -> (CGFloat, CGPoint) {
        var bestZoom: CGFloat = 1.0
        var bestCenter = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)

        for cluster in clusters {
            let zoomEnd = cluster.endTime + holdAfterCluster

            if time < cluster.startTime - transitionDuration {
                continue
            } else if time < cluster.startTime {
                // Easing in before cluster
                let progress = 1.0 - ((cluster.startTime - time) / transitionDuration)
                let zoom = 1.0 + (zoomInLevel - 1.0) * easeInOut(CGFloat(progress))
                if zoom > bestZoom {
                    bestZoom = zoom
                    bestCenter = cluster.center
                }
            } else if time <= zoomEnd {
                // Holding through cluster + brief hold after
                if zoomInLevel > bestZoom {
                    bestZoom = zoomInLevel
                    bestCenter = cluster.center
                }
            } else if time < zoomEnd + transitionDuration {
                // Easing out
                let progress = (time - zoomEnd) / transitionDuration
                let zoom = zoomInLevel - (zoomInLevel - 1.0) * easeInOut(CGFloat(progress))
                if zoom > bestZoom {
                    bestZoom = zoom
                    bestCenter = cluster.center
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
