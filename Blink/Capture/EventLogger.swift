import Foundation
import CoreGraphics
import AppKit

struct LoggedEvent: Codable {
    let timestamp: TimeInterval
    let type: EventType
    let x: CGFloat?
    let y: CGFloat?
    let windowName: String?

    enum EventType: String, Codable {
        case mouseMove
        case mouseClick
        case keyPress
        case windowChange
    }
}

final class EventLogger {
    private var events: [LoggedEvent] = []
    private var eventTap: CFMachPort?
    private var startTime: TimeInterval = 0
    private var lastWindowName: String?
    private var mousePollTimer: DispatchSourceTimer?
    private var lastMousePosition: CGPoint = .zero

    func start() {
        events = []
        startTime = CACurrentMediaTime()
        startMousePolling()
        startEventTap()
        observeWindowChanges()
    }

    func stop() -> [LoggedEvent] {
        mousePollTimer?.cancel()
        mousePollTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        NotificationCenter.default.removeObserver(self)
        return events
    }

    func writeToFile(at url: URL) throws {
        let encoder = JSONEncoder()
        let lines = try events.map { try encoder.encode($0) }
            .map { String(data: $0, encoding: .utf8)! }
            .joined(separator: "\n")
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    private var elapsed: TimeInterval {
        CACurrentMediaTime() - startTime
    }

    private func startMousePolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pos = NSEvent.mouseLocation
            let point = CGPoint(x: pos.x, y: pos.y)
            if point.distance(to: self.lastMousePosition) > 5 {
                self.lastMousePosition = point
                self.events.append(LoggedEvent(
                    timestamp: self.elapsed,
                    type: .mouseMove,
                    x: point.x, y: point.y,
                    windowName: nil
                ))
            }
        }
        timer.resume()
        mousePollTimer = timer
    }

    private func startEventTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let logger = Unmanaged<EventLogger>.fromOpaque(refcon!).takeUnretainedValue()
                logger.handleTapEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        let pos = event.location
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .leftMouseDown:
                self.events.append(LoggedEvent(
                    timestamp: self.elapsed,
                    type: .mouseClick,
                    x: pos.x, y: pos.y,
                    windowName: nil
                ))
            case .keyDown:
                self.events.append(LoggedEvent(
                    timestamp: self.elapsed,
                    type: .keyPress,
                    x: nil, y: nil,
                    windowName: nil
                ))
            default:
                break
            }
        }
    }

    private func observeWindowChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let appName = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName
            if appName != self.lastWindowName {
                self.lastWindowName = appName
                self.events.append(LoggedEvent(
                    timestamp: self.elapsed,
                    type: .windowChange,
                    x: nil, y: nil,
                    windowName: appName
                ))
            }
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        sqrt(pow(x - other.x, 2) + pow(y - other.y, 2))
    }
}
