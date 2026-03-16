import AppKit

/// Wispr Flow-style floating pill indicator that appears during recording
final class FloatingIndicator: NSPanel {
    private var dotView: NSView!
    private var timeLabel: NSTextField!
    private var pulseTimer: Timer?
    private var durationTimer: Timer?
    private var startTime: Date?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setupUI()
    }

    private func setupUI() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 36))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor

        dotView = NSView(frame: NSRect(x: 14, y: 12, width: 12, height: 12))
        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        dotView.layer?.cornerRadius = 6
        container.addSubview(dotView)

        timeLabel = NSTextField(labelWithString: "0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.frame = NSRect(x: 34, y: 8, width: 72, height: 20)
        container.addSubview(timeLabel)

        contentView = container
    }

    func show() {
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = screenFrame.midX - frame.width / 2
            let y = screenFrame.maxY - 60
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        startTime = Date()
        timeLabel.stringValue = "0:00"

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }

        startPulse()
        startDurationTimer()
    }

    func hide() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    private func startPulse() {
        var bright = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let dot = self?.dotView else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                dot.animator().alphaValue = bright ? 0.3 : 1.0
            }
            bright.toggle()
        }
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            self.timeLabel.stringValue = String(format: "%d:%02d", mins, secs)
        }
    }
}
