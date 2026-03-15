import AppKit
import AVFoundation

protocol PreviewHUDDelegate: AnyObject {
    func previewHUDDidDiscard(clipboardURL: URL, archiveURL: URL)
}

final class PreviewHUD: NSPanel {
    weak var hudDelegate: PreviewHUDDelegate?

    private var clipboardURL: URL?
    private var archiveURL: URL?
    private var dismissTimer: DispatchWorkItem?
    private var thumbnailView: NSImageView!
    private var durationLabel: NSTextField!
    private var copiedBadge: NSTextField!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false

        setupViews()
    }

    func show(clipboardURL: URL, archiveURL: URL, duration: TimeInterval) {
        self.clipboardURL = clipboardURL
        self.archiveURL = archiveURL

        let asset = AVURLAsset(url: clipboardURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
            thumbnailView.image = NSImage(cgImage: cgImage, size: NSSize(width: 260, height: 146))
        }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        durationLabel.stringValue = String(format: "%d:%02d", minutes, seconds)

        copyToClipboard()

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let origin = NSPoint(
                x: screenFrame.maxX - frame.width - 16,
                y: screenFrame.minY + 16
            )
            setFrameOrigin(origin)
        }

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            animator().alphaValue = 1
        }

        startDismissTimer()
    }

    private func setupViews() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 12

        thumbnailView = NSImageView(frame: NSRect(x: 0, y: 54, width: 260, height: 146))
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 12
        thumbnailView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        thumbnailView.layer?.masksToBounds = true

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(previewVideo))
        thumbnailView.addGestureRecognizer(clickGesture)

        durationLabel = NSTextField(labelWithString: "0:00")
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = NSColor(white: 0, alpha: 0.7)
        durationLabel.isBezeled = false
        durationLabel.frame = NSRect(x: 210, y: 60, width: 40, height: 16)

        copiedBadge = NSTextField(labelWithString: "Copied to clipboard")
        copiedBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        copiedBadge.textColor = .white
        copiedBadge.backgroundColor = .systemGreen
        copiedBadge.isBezeled = false
        copiedBadge.frame = NSRect(x: 8, y: 178, width: 120, height: 16)

        let buttonY = 0
        let buttonW = 260 / 3

        let copyBtn = makeButton(title: "Copy", x: 0, y: buttonY, width: buttonW, action: #selector(copyAction))
        let openBtn = makeButton(title: "Open", x: buttonW, y: buttonY, width: buttonW, action: #selector(openAction))
        let discardBtn = makeButton(title: "Discard", x: buttonW * 2, y: buttonY, width: buttonW, action: #selector(discardAction))
        discardBtn.contentTintColor = .secondaryLabelColor

        container.addSubview(thumbnailView)
        container.addSubview(durationLabel)
        container.addSubview(copiedBadge)
        container.addSubview(copyBtn)
        container.addSubview(openBtn)
        container.addSubview(discardBtn)

        contentView = container

        let trackingArea = NSTrackingArea(
            rect: container.bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        container.addTrackingArea(trackingArea)
    }

    private func makeButton(title: String, x: Int, y: Int, width: Int, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: y, width: width, height: 44))
        btn.title = title
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 12)
        btn.contentTintColor = .labelColor
        btn.target = self
        btn.action = action
        return btn
    }

    private func copyToClipboard() {
        guard let url = clipboardURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Write both the file URL and the file itself so pasting works everywhere
        pasteboard.writeObjects([url as NSURL])
        // Also set file contents for apps that expect data
        if let data = try? Data(contentsOf: url) {
            pasteboard.setData(data, forType: .fileURL)
        }
        NSLog("Blink: Copied to clipboard: %@", url.path)
    }

    @objc private func copyAction() {
        copyToClipboard()
        dismiss()
    }

    @objc private func openAction() {
        // Try archive first, fall back to clipboard version
        let url = archiveURL ?? clipboardURL
        guard let url else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let fallback = clipboardURL, FileManager.default.fileExists(atPath: fallback.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fallback])
        }
        dismiss()
    }

    @objc private func discardAction() {
        if let cb = clipboardURL, let ar = archiveURL {
            hudDelegate?.previewHUDDidDiscard(clipboardURL: cb, archiveURL: ar)
        }
        dismiss()
    }

    @objc private func previewVideo() {
        // Open in default video player
        let url = clipboardURL ?? archiveURL
        guard let url else { return }
        NSLog("Blink: Opening preview: %@", url.path)
        NSWorkspace.shared.open(url)
    }

    override func mouseEntered(with event: NSEvent) {
        dismissTimer?.cancel()
    }

    override func mouseExited(with event: NSEvent) {
        startDismissTimer()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
        }
    }

    private func startDismissTimer() {
        dismissTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timer)
    }

    private func dismiss() {
        dismissTimer?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}
