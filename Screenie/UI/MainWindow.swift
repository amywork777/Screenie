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
    private var monitorCheckbox: NSButton!
    private var colorWell: NSColorWell!
    private var autoZoomCheckbox: NSButton!
    private var autoFollowCheckbox: NSButton!
    private var cursorBounceCheckbox: NSButton!
    private var speedRampCheckbox: NSButton!
    private var keystrokeCheckbox: NSButton!
    private var cursorSmoothCheckbox: NSButton!
    private var advancedBox: NSView!

    weak var mainDelegate: MainWindowDelegate?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        title = "Screenie"
        isReleasedWhenClosed = false
        setupViews()
        sizeToContent(animate: false)
        center()
    }

    func updateRecordingStatus(_ recording: Bool) {
        if recording {
            statusLabel.stringValue = "Recording..."
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = "Ready — double-tap Right Control to record"
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

    // MARK: - Layout

    private func setupViews() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 16, right: 24)

        // Title
        let titleLabel = NSTextField(labelWithString: "Screenie")
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(titleLabel)

        let subtitle = NSTextField(labelWithString: "Fast Screen Recordings")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)

        stack.addArrangedSubview(makeDivider())

        // Status
        statusLabel = NSTextField(labelWithString: "Ready — double-tap Right Control to record")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        stack.addArrangedSubview(makeDivider())

        // Permissions
        stack.addArrangedSubview(makeSectionLabel("Permissions"))
        stack.addArrangedSubview(makePermRow(label: "Screen Recording", fixAction: #selector(openScreenRecSettings), assignTo: &screenRecLabel))
        let accRow = makePermRow(label: "Accessibility", fixAction: #selector(openAccessibilitySettings), assignTo: &hotkeyStatusLabel)
        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(onRefreshPerms))
        refreshBtn.bezelStyle = .inline
        refreshBtn.font = .systemFont(ofSize: 10)
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        accRow.addSubview(refreshBtn)
        NSLayoutConstraint.activate([refreshBtn.trailingAnchor.constraint(equalTo: accRow.trailingAnchor), refreshBtn.centerYAnchor.constraint(equalTo: accRow.centerYAnchor)])
        stack.addArrangedSubview(accRow)
        stack.addArrangedSubview(makePermRow(label: "Microphone", fixAction: #selector(openMicSettings), assignTo: &micStatusLabel))

        stack.addArrangedSubview(makeDivider())

        // Settings
        stack.addArrangedSubview(makeSectionLabel("Settings"))
        audioCheckbox = makeCheckbox("Capture system audio", action: #selector(toggleAudio), on: Settings.shared.captureAudio)
        stack.addArrangedSubview(audioCheckbox)
        micCheckbox = makeCheckbox("Capture microphone", action: #selector(toggleMic), on: Settings.shared.captureMicrophone)
        stack.addArrangedSubview(micCheckbox)
        monitorCheckbox = makeCheckbox("Monitor style frame", action: #selector(toggleMonitorStyle), on: Settings.shared.monitorStyle)
        stack.addArrangedSubview(monitorCheckbox)

        let bgRow = NSStackView()
        bgRow.orientation = .horizontal
        bgRow.spacing = 8
        let bgLabel = NSTextField(labelWithString: "Background:")
        bgLabel.font = .systemFont(ofSize: 11)
        bgLabel.textColor = .secondaryLabelColor
        bgRow.addArrangedSubview(bgLabel)
        let bg = Settings.shared.bgColor
        colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        colorWell.color = NSColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1.0)
        colorWell.target = self
        colorWell.action = #selector(bgColorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([colorWell.widthAnchor.constraint(equalToConstant: 32), colorWell.heightAnchor.constraint(equalToConstant: 20)])
        bgRow.addArrangedSubview(colorWell)
        stack.addArrangedSubview(bgRow)

        stack.addArrangedSubview(makeDivider())

        // Advanced toggle
        let advButton = NSButton(title: "▶ Advanced", target: self, action: #selector(toggleAdvanced))
        advButton.bezelStyle = .inline
        advButton.font = .systemFont(ofSize: 11, weight: .medium)
        advButton.tag = 0
        stack.addArrangedSubview(advButton)

        // Advanced content (hidden)
        advancedBox = NSStackView()
        let advStack = advancedBox as! NSStackView
        advStack.orientation = .vertical
        advStack.alignment = .leading
        advStack.spacing = 2

        advStack.addArrangedSubview(makeSectionLabel("Editing"))
        autoZoomCheckbox = makeCheckbox("Auto-zoom on clicks", action: #selector(toggleAutoZoom), on: Settings.shared.autoZoom)
        advStack.addArrangedSubview(autoZoomCheckbox)
        autoFollowCheckbox = makeCheckbox("Camera auto-follow", action: #selector(toggleAutoFollow), on: Settings.shared.autoFollow)
        advStack.addArrangedSubview(autoFollowCheckbox)
        speedRampCheckbox = makeCheckbox("Speed ramping", action: #selector(toggleSpeedRamp), on: Settings.shared.speedRamping)
        advStack.addArrangedSubview(speedRampCheckbox)
        cursorBounceCheckbox = makeCheckbox("Cursor bounce on click", action: #selector(toggleCursorBounce), on: Settings.shared.cursorBounce)
        advStack.addArrangedSubview(cursorBounceCheckbox)
        cursorSmoothCheckbox = makeCheckbox("Cursor smoothing", action: #selector(toggleCursorSmooth), on: Settings.shared.cursorSmoothing)
        advStack.addArrangedSubview(cursorSmoothCheckbox)
        keystrokeCheckbox = makeCheckbox("Keystroke overlay", action: #selector(toggleKeystroke), on: Settings.shared.keystrokeOverlay)
        advStack.addArrangedSubview(keystrokeCheckbox)

        advancedBox.isHidden = true
        stack.addArrangedSubview(advancedBox)

        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        contentView = scroll

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 340)
        ])

        refreshPermissions()
    }

    private func sizeToContent(animate: Bool) {
        guard let stack = (contentView as? NSScrollView)?.documentView else { return }
        stack.layoutSubtreeIfNeeded()
        let contentHeight = stack.fittingSize.height
        // Add title bar height (~28px) to content height
        let titleBarHeight = frame.height - contentLayoutRect.height
        let targetHeight = min(contentHeight + titleBarHeight + 4, 700)
        let frame = self.frame
        let newFrame = NSRect(x: frame.origin.x, y: frame.origin.y - (targetHeight - frame.height),
                              width: frame.width, height: targetHeight)
        setFrame(newFrame, display: true, animate: animate)
    }

    // MARK: - View builders

    private func makeDivider() -> NSBox {
        let d = NSBox()
        d.boxType = .separator
        d.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([d.widthAnchor.constraint(equalToConstant: 292)])
        return d
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private func makeCheckbox(_ title: String, action: Selector, on: Bool) -> NSButton {
        let cb = NSButton(checkboxWithTitle: title, target: self, action: action)
        cb.font = .systemFont(ofSize: 12)
        cb.state = on ? .on : .off
        return cb
    }

    private func makePermRow(label: String, fixAction: Selector, assignTo: inout NSTextField!) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: 292)])

        let status = NSTextField(labelWithString: "\(label): checking...")
        status.font = .systemFont(ofSize: 11)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(status)
        assignTo = status

        let fix = NSButton(title: "Fix", target: self, action: fixAction)
        fix.bezelStyle = .inline
        fix.font = .systemFont(ofSize: 10)
        row.addArrangedSubview(fix)

        return row
    }

    // MARK: - Advanced toggle

    @objc private func toggleAdvanced(_ sender: NSButton) {
        advancedBox.isHidden.toggle()
        sender.title = advancedBox.isHidden ? "▶ Advanced" : "▼ Advanced"
        sizeToContent(animate: true)
    }

    // MARK: - Permissions

    func refreshPermissions() {
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

        if AXIsProcessTrusted() {
            hotkeyStatusLabel.stringValue = "Accessibility: Granted"
            hotkeyStatusLabel.textColor = .systemGreen
        } else {
            hotkeyStatusLabel.stringValue = "Accessibility: Not Granted"
            hotkeyStatusLabel.textColor = .systemOrange
        }

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

    // MARK: - Actions

    @objc private func onRefreshPerms() { refreshPermissions() }

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

    @objc private func toggleAudio() { Settings.shared.captureAudio = (audioCheckbox.state == .on) }
    @objc private func toggleMic() { Settings.shared.captureMicrophone = (micCheckbox.state == .on) }
    @objc private func toggleMonitorStyle() { Settings.shared.monitorStyle = (monitorCheckbox.state == .on) }
    @objc private func bgColorChanged() {
        let c = colorWell.color.usingColorSpace(.deviceRGB) ?? colorWell.color
        Settings.shared.bgColor = (r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }
    @objc private func toggleAutoZoom() { Settings.shared.autoZoom = (autoZoomCheckbox.state == .on) }
    @objc private func toggleAutoFollow() { Settings.shared.autoFollow = (autoFollowCheckbox.state == .on) }
    @objc private func toggleCursorBounce() { Settings.shared.cursorBounce = (cursorBounceCheckbox.state == .on) }
    @objc private func toggleSpeedRamp() { Settings.shared.speedRamping = (speedRampCheckbox.state == .on) }
    @objc private func toggleKeystroke() { Settings.shared.keystrokeOverlay = (keystrokeCheckbox.state == .on) }
    @objc private func toggleCursorSmooth() { Settings.shared.cursorSmoothing = (cursorSmoothCheckbox.state == .on) }
}

protocol MainWindowDelegate: AnyObject {}
