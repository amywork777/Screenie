import Cocoa

/// A floating visual indicator inspired by Wispr Flow, providing real-time feedback for recording state
class FloatingIndicator: NSView {
    private let pulseLayer = CAShapeLayer()
    private let statusLabel = NSTextField()
    private var isRecording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        self.layer?.cornerRadius = 8

        // Configure pulse layer for animation
        pulseLayer.fillColor = NSColor.systemBlue.cgColor
        self.layer?.addSublayer(pulseLayer)

        // Configure status label
        statusLabel.stringValue = "Ready"
        statusLabel.isEditable = false
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.textColor = .labelColor
        self.addSubview(statusLabel)
    }

    func startRecording() {
        isRecording = true
        statusLabel.stringValue = "Recording"
        animatePulse()
    }

    func stopRecording() {
        isRecording = false
        statusLabel.stringValue = "Ready"
        pulseLayer.removeAllAnimations()
    }

    private func animatePulse() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.3
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.repeatCount = .infinity
        animation.autoreverses = true

        pulseLayer.add(animation, forKey: "pulse")
    }
}
