// Screenie/Capture/EventLogger.swift
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
    private var startTime: TimeInterval = 0
    private var lastWindowName: String?
    private var mousePollTimer: DispatchSourceTimer?
    private var lastMousePosition: CGPoint = .zero
    private var globalClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?

    func start() {
        events = []
        startTime = CACurrentMediaTime()
        startMousePolling()
        startEventMonitors()
        observeWindowChanges()
        NSLog("Screenie: EventLogger started")
    }

    func stop() -> [LoggedEvent] {
        mousePollTimer?.cancel()
        mousePollTimer = nil
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        globalClickMonitor = nil
        globalKeyMonitor = nil
        localClickMonitor = nil
        localKeyMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)

        let clickCount = events.filter { $0.type == .mouseClick }.count
        let keyCount = events.filter { $0.type == .keyPress }.count
        let moveCount = events.filter { $0.type == .mouseMove }.count
        NSLog("Screenie: EventLogger stopped — %d clicks, %d keys, %d moves", clickCount, keyCount, moveCount)

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
        timer.schedule(deadline: .now(), repeating: .milliseconds(16)) // ~60fps mouse tracking
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pos = NSEvent.mouseLocation
            let point = CGPoint(x: pos.x, y: pos.y)
            if point.distance(to: self.lastMousePosition) > 1 { // 1px threshold for smooth tracking
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

    private func startEventMonitors() {
        // Global monitors (when other apps are focused)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.recordClick(event)
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recordKeyPress(event)
        }
        // Local monitors (when Screenie is focused)
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.recordClick(event)
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recordKeyPress(event)
            return event
        }
    }

    private func recordClick(_ event: NSEvent) {
        let pos = NSEvent.mouseLocation
        events.append(LoggedEvent(
            timestamp: elapsed,
            type: .mouseClick,
            x: pos.x, y: pos.y,
            windowName: nil
        ))
        NSLog("Screenie: Click at (%.0f, %.0f) t=%.1f", pos.x, pos.y, elapsed)
    }

    private func recordKeyPress(_ event: NSEvent) {
        events.append(LoggedEvent(
            timestamp: elapsed,
            type: .keyPress,
            x: nil, y: nil,
            windowName: nil
        ))
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
