import AppKit
import AVFoundation

final class MainWindow: NSWindow {
    private var statusLabel: NSTextField!
    private var hotkeyStatusLabel: NSTextField!
    private var audioCheckbox: NSButton!
    private var micCheckbox: NSButton!

    weak var mainDelegate: MainWindowDelegate?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        title = "Blink"
        isReleasedWhenClosed = false
        center()
        setupViews()
    }

    func updateRecordingStatus(_ recording: Bool) {
        if recording {
            statusLabel.stringValue = "Recording..."
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = "Ready — hold Right Option to record"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    func updateHotkeyStatus(granted: Bool) {
        if granted {
            hotkeyStatusLabel.stringValue = "Accessibility: Granted"
            hotkeyStatusLabel.textColor = .systemGreen
        } else {
            hotkeyStatusLabel.stringValue = "Accessibility: Not Granted — click below to fix"
            hotkeyStatusLabel.textColor = .systemOrange
        }
    }

    private func setupViews() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 460))

        // App title
        let titleLabel = NSTextField(labelWithString: "Blink")
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.frame = NSRect(x: 30, y: 400, width: 200, height: 40)
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Invisible Screen Recorder")
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 30, y: 375, width: 300, height: 20)
        container.addSubview(subtitleLabel)

        // Divider
        let divider = NSBox(frame: NSRect(x: 30, y: 365, width: 320, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        // Status
        statusLabel = NSTextField(labelWithString: "Ready — double-tap Right Control to record")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 30, y: 335, width: 320, height: 20)
        container.addSubview(statusLabel)

        // Hotkey instructions
        let instructionLabel = NSTextField(wrappingLabelWithString:
            "Double-tap Right Control — start recording\nDouble-tap Right Control again — stop recording"
        )
        instructionLabel.font = .systemFont(ofSize: 12)
        instructionLabel.textColor = .tertiaryLabelColor
        instructionLabel.frame = NSRect(x: 30, y: 290, width: 320, height: 35)
        container.addSubview(instructionLabel)

        // Divider
        let divider2 = NSBox(frame: NSRect(x: 30, y: 280, width: 320, height: 1))
        divider2.boxType = .separator
        container.addSubview(divider2)

        // Permissions
        let permLabel = NSTextField(labelWithString: "Permissions")
        permLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        permLabel.textColor = .tertiaryLabelColor
        permLabel.frame = NSRect(x: 30, y: 253, width: 100, height: 16)
        container.addSubview(permLabel)

        hotkeyStatusLabel = NSTextField(labelWithString: "Checking accessibility...")
        hotkeyStatusLabel.font = .systemFont(ofSize: 12)
        hotkeyStatusLabel.frame = NSRect(x: 30, y: 230, width: 280, height: 18)
        container.addSubview(hotkeyStatusLabel)

        let grantButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        grantButton.bezelStyle = .rounded
        grantButton.frame = NSRect(x: 30, y: 200, width: 200, height: 28)
        container.addSubview(grantButton)

        // Mic permission
        let micPermLabel = NSTextField(labelWithString: "Microphone: tap to grant")
        micPermLabel.font = .systemFont(ofSize: 12)
        micPermLabel.textColor = .systemOrange
        micPermLabel.frame = NSRect(x: 30, y: 172, width: 280, height: 18)
        container.addSubview(micPermLabel)

        let micGrantButton = NSButton(title: "Grant Microphone Access", target: self, action: #selector(requestMicPermission))
        micGrantButton.bezelStyle = .rounded
        micGrantButton.frame = NSRect(x: 30, y: 140, width: 200, height: 28)
        container.addSubview(micGrantButton)

        // Divider
        let divider3 = NSBox(frame: NSRect(x: 30, y: 128, width: 320, height: 1))
        divider3.boxType = .separator
        container.addSubview(divider3)

        // Settings
        let settingsLabel = NSTextField(labelWithString: "Settings")
        settingsLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        settingsLabel.textColor = .tertiaryLabelColor
        settingsLabel.frame = NSRect(x: 30, y: 100, width: 100, height: 16)
        container.addSubview(settingsLabel)

        audioCheckbox = NSButton(checkboxWithTitle: "Capture system audio", target: self, action: #selector(toggleAudio))
        audioCheckbox.frame = NSRect(x: 28, y: 74, width: 200, height: 22)
        audioCheckbox.state = Settings.shared.captureAudio ? .on : .off
        container.addSubview(audioCheckbox)

        micCheckbox = NSButton(checkboxWithTitle: "Capture microphone", target: self, action: #selector(toggleMic))
        micCheckbox.frame = NSRect(x: 28, y: 50, width: 200, height: 22)
        micCheckbox.state = Settings.shared.captureMicrophone ? .on : .off
        container.addSubview(micCheckbox)

        // Bottom info
        let infoLabel = NSTextField(labelWithString: "Recordings saved to ~/Recordings/Blink/")
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.frame = NSRect(x: 30, y: 12, width: 320, height: 16)
        container.addSubview(infoLabel)

        contentView = container
    }

    @objc private func openAccessibilitySettings() {
        HotkeyListener.promptAccessibility()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func requestMicPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    NSLog("Blink: Microphone permission granted")
                } else {
                    // Open privacy settings if denied
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc private func toggleAudio() {
        Settings.shared.captureAudio = (audioCheckbox.state == .on)
    }

    @objc private func toggleMic() {
        Settings.shared.captureMicrophone = (micCheckbox.state == .on)
    }
}

protocol MainWindowDelegate: AnyObject {}
