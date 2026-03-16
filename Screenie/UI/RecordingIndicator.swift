import AppKit

final class RecordingIndicator {
    private var statusItem: NSStatusItem?
    private var pulseTimer: Timer?

    func show() {
        let item = NSStatusBar.system.statusItem(withLength: 12)
        if let button = item.button {
            button.wantsLayer = true
            let dot = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            button.image = dot
        }
        statusItem = item
        startPulse()
    }

    func hide() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func startPulse() {
        var visible = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            visible.toggle()
            self?.statusItem?.button?.alphaValue = visible ? 1.0 : 0.3
        }
    }

    func showProcessing() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: 18)
        if let button = item.button {
            let spinner = NSProgressIndicator(frame: NSRect(x: 2, y: 2, width: 14, height: 14))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            button.image = nil
            button.addSubview(spinner)
        }
        statusItem = item
    }
}
