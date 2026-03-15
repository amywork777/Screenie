import AppKit
import ScreenCaptureKit

final class OnboardingWindow: NSWindow {
    private var onComplete: (() -> Void)?

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        title = "Welcome to Blink"
        isReleasedWhenClosed = false
        center()
        setupViews()
    }

    private func setupViews() {
        let container = NSView(frame: contentView!.bounds)

        let title = NSTextField(labelWithString: "Blink")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.frame = NSRect(x: 30, y: 270, width: 380, height: 40)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Hold Right Option to record your screen.\nDouble-tap Right Option to toggle recording.\n\nBlink auto-edits your recording with smart speed ramping and zoom, then copies it to your clipboard."
        )
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.frame = NSRect(x: 30, y: 150, width: 380, height: 110)

        let getStarted = NSButton(
            title: "Get Started",
            target: self,
            action: #selector(requestPermissions)
        )
        getStarted.bezelStyle = .rounded
        getStarted.controlSize = .large
        getStarted.frame = NSRect(x: 155, y: 30, width: 130, height: 40)
        getStarted.keyEquivalent = "\r"

        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(getStarted)
        contentView = container
    }

    @objc private func requestPermissions() {
        Task {
            _ = try? await SCShareableContent.current

            Settings.shared.hasCompletedOnboarding = true
            DispatchQueue.main.async {
                self.close()
                self.onComplete?()
            }
        }
    }
}
