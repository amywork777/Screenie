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
    private var statusLabel: NSTextField!
    private var dots: [NSView] = []
    private var pollTimer: Timer?
    private var secondaryButton: NSButton!

    private let steps: [(icon: String, title: String, desc: String, action: String)] = [
        ("🖥", "Welcome to Screenie",
         "Fast screen recordings that edit themselves.\nDouble-tap Control to record, double-tap to stop.\nScreenie handles zoom, speed ramp, and cursor tracking.",
         "Get Started"),
        ("🔒", "Screen & Audio Recording",
         "Screenie needs permission to capture your screen and system audio.\nA system dialog will appear — click Allow.\n\nThis lets Screenie record what's on screen and any audio playing on your Mac.",
         "Enable Screen & Audio"),
        ("⌨️", "Accessibility",
         "Screenie needs Accessibility to detect your keyboard shortcut.\n\n1. Click the button below to open System Settings\n2. Find Screenie in the list and toggle it ON\n3. Come back here — Screenie will detect it automatically",
         "Open Accessibility Settings"),
        ("🎤", "Microphone (Optional)",
         "Enable this to record your voice alongside your screen.\n\n1. Click the button below\n2. If a system dialog appears, click Allow\n3. If not, find Screenie in System Settings → Microphone and toggle it ON",
         "Enable Microphone"),
        ("✨", "You're all set!",
         "Double-tap Control to start recording.\nDouble-tap Control again to stop.\n\nYour edited recording is copied to your clipboard automatically.",
         "Start Using Screenie"),
    ]

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))

        stepIcon = NSTextField(labelWithString: "")
        stepIcon.font = .systemFont(ofSize: 48)
        stepIcon.alignment = .center
        stepIcon.frame = NSRect(x: 0, y: 320, width: 480, height: 56)
        container.addSubview(stepIcon)

        stepTitle = NSTextField(labelWithString: "")
        stepTitle.font = .systemFont(ofSize: 22, weight: .bold)
        stepTitle.alignment = .center
        stepTitle.frame = NSRect(x: 30, y: 280, width: 420, height: 32)
        container.addSubview(stepTitle)

        stepDesc = NSTextField(wrappingLabelWithString: "")
        stepDesc.font = .systemFont(ofSize: 13)
        stepDesc.textColor = .secondaryLabelColor
        stepDesc.alignment = .center
        stepDesc.frame = NSRect(x: 40, y: 145, width: 400, height: 125)
        container.addSubview(stepDesc)

        // Status label (for "Waiting for permission..." type messages)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 40, y: 115, width: 400, height: 20)
        container.addSubview(statusLabel)

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
        skipButton.frame = NSRect(x: 200, y: 42, width: 80, height: 24)
        container.addSubview(skipButton)

        // Secondary button — "Reopen Settings" for when user closes the settings window
        secondaryButton = NSButton(title: "Reopen Settings", target: self, action: #selector(onSecondary))
        secondaryButton.bezelStyle = .inline
        secondaryButton.isBordered = false
        secondaryButton.font = .systemFont(ofSize: 12, weight: .medium)
        secondaryButton.contentTintColor = .secondaryLabelColor
        secondaryButton.frame = NSRect(x: 160, y: 42, width: 160, height: 24)
        secondaryButton.isHidden = true
        container.addSubview(secondaryButton)

        // Progress dots
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
        pollTimer?.invalidate()
        pollTimer = nil
        currentStep = step
        let s = steps[step]
        stepIcon.stringValue = s.icon
        stepTitle.stringValue = s.title
        stepDesc.stringValue = s.desc
        actionButton.title = s.action
        actionButton.isEnabled = true
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor

        // Show skip only for mic step
        skipButton.isHidden = step != 3
        // Show "Reopen Settings" only during accessibility and mic steps
        secondaryButton.isHidden = true

        // Update dots
        for (i, dot) in dots.enumerated() {
            dot.layer?.backgroundColor = (i == step
                ? NSColor(red: 0.91, green: 0.45, blue: 0.54, alpha: 1)
                : NSColor.tertiaryLabelColor).cgColor
        }

        // If on accessibility step, check if already granted
        if step == 2 && AXIsProcessTrusted() {
            statusLabel.stringValue = "✓ Already granted!"
            statusLabel.textColor = .systemGreen
            actionButton.title = "Continue"
        }
    }

    @objc private func onAction() {
        switch currentStep {
        case 0:
            showStep(1)

        case 1:
            // Screen Recording — trigger the system dialog
            actionButton.isEnabled = false
            statusLabel.stringValue = "Requesting permission..."
            Task {
                _ = try? await SCShareableContent.current
                DispatchQueue.main.async {
                    self.showStep(2)
                }
            }

        case 2:
            // Accessibility
            if AXIsProcessTrusted() {
                // Already granted — move on
                showStep(3)
            } else {
                // Open settings and start polling
                HotkeyListener.promptAccessibility()
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)

                actionButton.isEnabled = false
                actionButton.title = "Waiting..."
                statusLabel.stringValue = "Toggle Screenie ON in Settings, then come back here"
                statusLabel.textColor = .systemOrange
                secondaryButton.isHidden = false
                secondaryButton.title = "Reopen Accessibility Settings"

                // Poll every 1s until granted
                pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if AXIsProcessTrusted() {
                        self.pollTimer?.invalidate()
                        self.pollTimer = nil
                        self.statusLabel.stringValue = "✓ Accessibility granted!"
                        self.statusLabel.textColor = .systemGreen
                        self.actionButton.title = "Continue"
                        self.actionButton.isEnabled = true

                        // Auto-advance after a moment
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            if self.currentStep == 2 {
                                self.showStep(3)
                            }
                        }
                    }
                }
            }

        case 3:
            // Microphone — try to actually use the mic to trigger the system dialog
            actionButton.isEnabled = false
            statusLabel.stringValue = "Requesting permission..."

            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                statusLabel.stringValue = "✓ Already granted!"
                statusLabel.textColor = .systemGreen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.showStep(4)
                }
            } else {
                // Try to start an actual capture session to force the dialog
                do {
                    let session = AVCaptureSession()
                    if let mic = AVCaptureDevice.default(for: .audio) {
                        let input = try AVCaptureDeviceInput(device: mic)
                        if session.canAddInput(input) {
                            session.addInput(input)
                            session.startRunning()
                            statusLabel.stringValue = "System dialog should appear — click Allow"
                            statusLabel.textColor = .systemOrange

                            // Poll for permission grant
                            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                                guard let self else { return }
                                let newStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                if newStatus == .authorized {
                                    self.pollTimer?.invalidate()
                                    session.stopRunning()
                                    self.statusLabel.stringValue = "✓ Microphone granted!"
                                    self.statusLabel.textColor = .systemGreen
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                        self.showStep(4)
                                    }
                                }
                            }

                            secondaryButton.isHidden = false
                            secondaryButton.title = "Open Microphone Settings"
                            return
                        }
                    }
                } catch {
                    NSLog("Screenie: Mic capture session error: %@", error.localizedDescription)
                }

                // Fallback — open settings directly
                statusLabel.stringValue = "Open Settings and toggle Screenie ON for Microphone"
                statusLabel.textColor = .systemOrange
                secondaryButton.isHidden = false
                secondaryButton.title = "Open Microphone Settings"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }

                // Poll for permission
                pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        self.pollTimer?.invalidate()
                        self.statusLabel.stringValue = "✓ Microphone granted!"
                        self.statusLabel.textColor = .systemGreen
                        self.actionButton.title = "Continue"
                        self.actionButton.isEnabled = true
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    // Auto-advance after 15s if user doesn't grant
                    guard let self, self.currentStep == 3 else { return }
                    self.pollTimer?.invalidate()
                    self.showStep(4)
                }
            }

        case 4:
            // Done
            pollTimer?.invalidate()
            Settings.shared.hasCompletedOnboarding = true
            close()
            onComplete?()

        default:
            break
        }
    }

    @objc private func onSkip() {
        showStep(4)
    }

    @objc private func onSecondary() {
        if currentStep == 2 {
            // Reopen Accessibility settings
            HotkeyListener.promptAccessibility()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else if currentStep == 3 {
            // Reopen Microphone settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}
