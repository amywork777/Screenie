import AppKit
import ScreenCaptureKit
import AVFoundation

final class OnboardingWindow: NSWindow {
    private var onComplete: (() -> Void)?
    private var currentStep = 0
    private var stepTitle: NSTextField!
    private var stepDesc: NSTextField!
    private var stepIcon: NSTextField!
    private var actionButton: NSButton!
    private var skipButton: NSButton!
    private var dots: [NSView] = []

    private let steps: [(icon: String, title: String, desc: String, action: String)] = [
        ("🖥", "Welcome to Screenie",
         "Fast screen recordings that edit themselves.\nDouble-tap Control to record, double-tap to stop.\nScreenie auto-edits with zoom, speed ramp, and cursor tracking.",
         "Get Started"),
        ("🔒", "Screen Recording",
         "Screenie needs permission to capture your screen.\nClick below and macOS will ask you to allow it.",
         "Enable Screen Recording"),
        ("⌨️", "Accessibility",
         "Screenie needs Accessibility access to detect your Control key double-tap.\nClick below to open System Settings and add Screenie.",
         "Enable Accessibility"),
        ("🎤", "Microphone (Optional)",
         "If you want to record your voice alongside your screen, enable microphone access.\nYou can skip this and enable it later in Settings.",
         "Enable Microphone"),
        ("✨", "You're all set!",
         "Double-tap Control to start recording.\nDouble-tap Control again to stop.\nYour edited recording will be copied to your clipboard automatically.",
         "Start Using Screenie"),
    ]

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        title = "Screenie Setup"
        isReleasedWhenClosed = false
        center()
        setupViews()
        showStep(0)
    }

    private func setupViews() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))

        stepIcon = NSTextField(labelWithString: "")
        stepIcon.font = .systemFont(ofSize: 48)
        stepIcon.alignment = .center
        stepIcon.frame = NSRect(x: 0, y: 300, width: 480, height: 56)
        container.addSubview(stepIcon)

        stepTitle = NSTextField(labelWithString: "")
        stepTitle.font = .systemFont(ofSize: 22, weight: .bold)
        stepTitle.alignment = .center
        stepTitle.frame = NSRect(x: 30, y: 260, width: 420, height: 32)
        container.addSubview(stepTitle)

        stepDesc = NSTextField(wrappingLabelWithString: "")
        stepDesc.font = .systemFont(ofSize: 13)
        stepDesc.textColor = .secondaryLabelColor
        stepDesc.alignment = .center
        stepDesc.frame = NSRect(x: 40, y: 140, width: 400, height: 110)
        container.addSubview(stepDesc)

        actionButton = NSButton(title: "", target: self, action: #selector(onAction))
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.frame = NSRect(x: 140, y: 70, width: 200, height: 40)
        actionButton.keyEquivalent = "\r"
        container.addSubview(actionButton)

        skipButton = NSButton(title: "Skip", target: self, action: #selector(onSkip))
        skipButton.bezelStyle = .inline
        skipButton.isBordered = false
        skipButton.font = .systemFont(ofSize: 12)
        skipButton.contentTintColor = .tertiaryLabelColor
        skipButton.frame = NSRect(x: 200, y: 40, width: 80, height: 24)
        container.addSubview(skipButton)

        // Step dots
        let dotsX = 480 / 2 - CGFloat(steps.count * 14) / 2
        for i in 0..<steps.count {
            let dot = NSView(frame: NSRect(x: dotsX + CGFloat(i) * 14, y: 18, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            container.addSubview(dot)
            dots.append(dot)
        }

        contentView = container
    }

    private func showStep(_ step: Int) {
        currentStep = step
        let s = steps[step]
        stepIcon.stringValue = s.icon
        stepTitle.stringValue = s.title
        stepDesc.stringValue = s.desc
        actionButton.title = s.action

        // Show skip only for mic step
        skipButton.isHidden = step != 3

        // Update dots
        for (i, dot) in dots.enumerated() {
            dot.layer?.backgroundColor = (i == step
                ? NSColor(red: 0.91, green: 0.45, blue: 0.54, alpha: 1) // pink
                : NSColor.tertiaryLabelColor).cgColor
        }
    }

    @objc private func onAction() {
        switch currentStep {
        case 0:
            // Welcome → next
            showStep(1)

        case 1:
            // Screen Recording
            Task {
                _ = try? await SCShareableContent.current
                DispatchQueue.main.async {
                    self.showStep(2)
                }
            }

        case 2:
            // Accessibility
            HotkeyListener.promptAccessibility()
            // Give user time to grant, then advance
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showStep(3)
            }

        case 3:
            // Microphone
            requestMicPermission {
                DispatchQueue.main.async {
                    self.showStep(4)
                }
            }

        case 4:
            // Done
            Settings.shared.hasCompletedOnboarding = true
            close()
            onComplete?()

        default:
            break
        }
    }

    @objc private func onSkip() {
        // Skip mic, go to done
        showStep(4)
    }

    private func requestMicPermission(completion: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                completion()
            }
        } else if status == .denied || status == .restricted {
            // Open system settings for mic
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                completion()
            }
        } else {
            completion()
        }
    }
}
