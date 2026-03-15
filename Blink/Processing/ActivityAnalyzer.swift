import Foundation

struct ActivitySegment {
    enum Activity {
        case active
        case idle
        case click
    }

    let activity: Activity
    let startTime: TimeInterval
    let endTime: TimeInterval

    var duration: TimeInterval { endTime - startTime }
}

struct ActivityAnalyzer {
    static let idleThreshold: TimeInterval = 1.5
    static let clickWindowRadius: TimeInterval = 0.15

    static func analyze(events: [LoggedEvent], duration: TimeInterval) -> [ActivitySegment] {
        guard !events.isEmpty else { return [] }

        let sorted = events.sorted { $0.timestamp < $1.timestamp }

        var segments: [ActivitySegment] = []
        var segmentStart = 0.0
        var lastEventTime = 0.0

        for event in sorted {
            let t = event.timestamp

            if t - lastEventTime > idleThreshold && lastEventTime >= segmentStart {
                if lastEventTime > segmentStart {
                    segments.append(ActivitySegment(
                        activity: .active,
                        startTime: segmentStart,
                        endTime: lastEventTime
                    ))
                }
                segments.append(ActivitySegment(
                    activity: .idle,
                    startTime: lastEventTime,
                    endTime: t
                ))
                segmentStart = t
            }

            if event.type == .mouseClick {
                if t > segmentStart + clickWindowRadius {
                    segments.append(ActivitySegment(
                        activity: .active,
                        startTime: segmentStart,
                        endTime: t - clickWindowRadius
                    ))
                }
                segments.append(ActivitySegment(
                    activity: .click,
                    startTime: t - clickWindowRadius,
                    endTime: t + clickWindowRadius
                ))
                segmentStart = t + clickWindowRadius
            }

            lastEventTime = t
        }

        if lastEventTime > segmentStart {
            segments.append(ActivitySegment(
                activity: .active,
                startTime: segmentStart,
                endTime: lastEventTime
            ))
        }

        if lastEventTime < duration - idleThreshold {
            segments.append(ActivitySegment(
                activity: .idle,
                startTime: lastEventTime,
                endTime: duration
            ))
        } else if lastEventTime < duration {
            segments.append(ActivitySegment(
                activity: .active,
                startTime: lastEventTime,
                endTime: duration
            ))
        }

        return segments
    }
}
