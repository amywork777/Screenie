import AppKit
import AVFoundation
import ScreenCaptureKit

final class MainWindow: NSWindow {
    private var statusLabel: NSTextField!
    private var hotkeyStatusLabel: NSTextField!
    private var screenRecLabel: NSTextField!
    private var micStatusLabel: NSTextField!
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
        title = "Screenie"
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
        let titleLabel = NSTextField(labelWithString: "Screenie")
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.frame = NSRect(x: 30, y: 400, width: 200, height: 40)
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Fast Screen Recordings")
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

        // Permissions — all three
        let permLabel = NSTextField(labelWithString: "Permissions")
        permLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        permLabel.textColor = .tertiaryLabelColor
        permLabel.frame = NSRect(x: 30, y: 253, width: 100, height: 16)
        container.addSubview(permLabel)

        // Screen Recording
        screenRecLabel = NSTextField(labelWithString: "Screen Recording: checking...")
        screenRecLabel.font = .systemFont(ofSize: 12)
        screenRecLabel.frame = NSRect(x: 30, y: 235, width: 200, height: 18)
        container.addSubview(screenRecLabel)

        let fixScreenBtn = NSButton(title: "Fix", target: self, action: #selector(openScreenRecSettings))
        fixScreenBtn.bezelStyle = .inline
        fixScreenBtn.font = .systemFont(ofSize: 11)
        fixScreenBtn.frame = NSRect(x: 240, y: 234, width: 40, height: 20)
        container.addSubview(fixScreenBtn)

        // Accessibility
        hotkeyStatusLabel = NSTextField(labelWithString: "Accessibility: checking...")
        hotkeyStatusLabel.font = .systemFont(ofSize: 12)
        hotkeyStatusLabel.frame = NSRect(x: 30, y: 212, width: 200, height: 18)
        container.addSubview(hotkeyStatusLabel)

        let fixAccessBtn = NSButton(title: "Fix", target: self, action: #selector(openAccessibilitySettings))
        fixAccessBtn.bezelStyle = .inline
        fixAccessBtn.font = .systemFont(ofSize: 11)
        fixAccessBtn.frame = NSRect(x: 240, y: 211, width: 40, height: 20)
        container.addSubview(fixAccessBtn)

        // Microphone
        micStatusLabel = NSTextField(labelWithString: "Microphone: checking...")
        micStatusLabel.font = .systemFont(ofSize: 12)
        micStatusLabel.frame = NSRect(x: 30, y: 189, width: 200, height: 18)
        container.addSubview(micStatusLabel)

        let fixMicBtn = NSButton(title: "Fix", target: self, action: #selector(openMicSettings))
        fixMicBtn.bezelStyle = .inline
        fixMicBtn.font = .systemFont(ofSize: 11)
        fixMicBtn.frame = NSRect(x: 240, y: 188, width: 40, height: 20)
        container.addSubview(fixMicBtn)

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(onRefreshPerms))
        refreshBtn.bezelStyle = .inline
        refreshBtn.font = .systemFont(ofSize: 11)
        refreshBtn.frame = NSRect(x: 290, y: 211, width: 60, height: 20)
        container.addSubview(refreshBtn)

        // Divider
        let divider3 = NSBox(frame: NSRect(x: 30, y: 148, width: 320, height: 1))
        divider3.boxType = .separator
        container.addSubview(divider3)

        // Settings
        let settingsLabel = NSTextField(labelWithString: "Settings")
        settingsLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        settingsLabel.textColor = .tertiaryLabelColor
        settingsLabel.frame = NSRect(x: 30, y: 120, width: 100, height: 16)
        container.addSubview(settingsLabel)

        audioCheckbox = NSButton(checkboxWithTitle: "Capture system audio", target: self, action: #selector(toggleAudio))
        audioCheckbox.frame = NSRect(x: 28, y: 94, width: 200, height: 22)
        audioCheckbox.state = Settings.shared.captureAudio ? .on : .off
        container.addSubview(audioCheckbox)

        micCheckbox = NSButton(checkboxWithTitle: "Capture microphone", target: self, action: #selector(toggleMic))
        micCheckbox.frame = NSRect(x: 28, y: 70, width: 200, height: 22)
        micCheckbox.state = Settings.shared.captureMicrophone ? .on : .off
        container.addSubview(micCheckbox)

        // Bottom info
        let infoLabel = NSTextField(labelWithString: "Recordings saved to ~/Recordings/Screenie/")
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.frame = NSRect(x: 30, y: 12, width: 320, height: 16)
        container.addSubview(infoLabel)

        // Check all permissions on load
        refreshPermissions()

        contentView = container
    }

    func refreshPermissions() {
        // Screen Recording — check by trying to get shareable content
        Task {
            do {
                _ = try await SCShareableContent.current
                await MainActor.run {
                    screenRecLabel.stringValue = "Screen Recording: Granted"
                    screenRecLabel.textColor = .systemGreen
                }
            } catch {
                await MainActor.run {
                    screenRecLabel.stringValue = "Screen Recording: Not Granted"
                    screenRecLabel.textColor = .systemOrange
                }
            }
        }

        // Accessibility
        if AXIsProcessTrusted() {
            hotkeyStatusLabel.stringValue = "Accessibility: Granted"
            hotkeyStatusLabel.textColor = .systemGreen
        } else {
            hotkeyStatusLabel.stringValue = "Accessibility: Not Granted"
            hotkeyStatusLabel.textColor = .systemOrange
        }

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            micStatusLabel.stringValue = "Microphone: Granted"
            micStatusLabel.textColor = .systemGreen
        case .denied, .restricted:
            micStatusLabel.stringValue = "Microphone: Denied"
            micStatusLabel.textColor = .systemRed
        case .notDetermined:
            micStatusLabel.stringValue = "Microphone: Not Yet Asked"
            micStatusLabel.textColor = .systemOrange
        @unknown default:
            micStatusLabel.stringValue = "Microphone: Unknown"
            micStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func onRefreshPerms() {
        refreshPermissions()
    }

    @objc private func openScreenRecSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        HotkeyListener.promptAccessibility()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func requestMicPermission() {
        NSLog("Screenie: Requesting mic permission...")

        // Actually try to use the mic — this forces macOS to show the permission dialog
        do {
            let session = AVCaptureSession()
            guard let mic = AVCaptureDevice.default(for: .audio) else {
                NSLog("Screenie: No microphone device found")
                return
            }
            let input = try AVCaptureDeviceInput(device: mic)
            if session.canAddInput(input) {
                session.addInput(input)
                session.startRunning()
                // Brief capture to trigger the dialog
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    session.stopRunning()
                    NSLog("Screenie: Mic test session stopped, permission should be granted now")
                }
            }
        } catch {
            NSLog("Screenie: Mic access error: %@ — opening settings", error.localizedDescription)
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
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
