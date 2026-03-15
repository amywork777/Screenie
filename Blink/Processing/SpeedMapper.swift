import Foundation

struct TimeMapping {
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let speed: Double

    var sourceDuration: TimeInterval { sourceEnd - sourceStart }
    var outputDuration: TimeInterval { sourceDuration / speed }
}

struct SpeedMapper {
    static func map(segments: [ActivitySegment]) -> [TimeMapping] {
        segments.map { segment in
            let speed: Double
            switch segment.activity {
            case .active:
                speed = 1.0
            case .click:
                speed = 0.75
            case .idle:
                speed = idleSpeed(duration: segment.duration)
            }
            return TimeMapping(
                sourceStart: segment.startTime,
                sourceEnd: segment.endTime,
                speed: speed
            )
        }
    }

    private static func idleSpeed(duration: TimeInterval) -> Double {
        let minSpeed = 4.0
        let maxSpeed = 8.0
        let minDuration = 1.5
        let maxDuration = 3.0

        if duration <= minDuration { return minSpeed }
        if duration >= maxDuration { return maxSpeed }

        let t = (duration - minDuration) / (maxDuration - minDuration)
        return minSpeed + t * (maxSpeed - minSpeed)
    }
}
