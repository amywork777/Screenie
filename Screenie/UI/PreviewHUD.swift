import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

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
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true

        setupViews()
    }

    // Allow clicks on a non-activating panel
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(clipboardURL: URL, archiveURL: URL, duration: TimeInterval, originalDuration: TimeInterval = 0) {
        self.clipboardURL = clipboardURL
        self.archiveURL = archiveURL

        let asset = AVURLAsset(url: clipboardURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) {
            thumbnailView.image = NSImage(cgImage: cgImage, size: NSSize(width: 260, height: 146))
        }

        if originalDuration > 0 && duration > 0 && duration < originalDuration {
            durationLabel.stringValue = String(format: "%.0fs → %.0fs", originalDuration, duration)
        } else {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            durationLabel.stringValue = String(format: "%d:%02d", minutes, seconds)
        }

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

        copiedBadge = NSTextField(labelWithString: "  Copied to clipboard  ")
        copiedBadge.font = .systemFont(ofSize: 11, weight: .bold)
        copiedBadge.textColor = .white
        copiedBadge.backgroundColor = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1.0)
        copiedBadge.isBezeled = false
        copiedBadge.wantsLayer = true
        copiedBadge.layer?.cornerRadius = 4
        copiedBadge.layer?.masksToBounds = true
        copiedBadge.frame = NSRect(x: 8, y: 176, width: 140, height: 18)

        let buttonY = 0
        let buttonW = 260 / 4

        let copyBtn = makeButton(title: "Copy", x: 0, y: buttonY, width: buttonW, action: #selector(copyAction))
        let gifBtn = makeButton(title: "GIF", x: buttonW, y: buttonY, width: buttonW, action: #selector(gifAction))
        let openBtn = makeButton(title: "Open", x: buttonW * 2, y: buttonY, width: buttonW, action: #selector(openAction))
        let discardBtn = makeButton(title: "Discard", x: buttonW * 3, y: buttonY, width: buttonW, action: #selector(discardAction))
        discardBtn.contentTintColor = .secondaryLabelColor

        container.addSubview(thumbnailView)
        container.addSubview(durationLabel)
        container.addSubview(copiedBadge)
        container.addSubview(copyBtn)
        container.addSubview(gifBtn)
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

    private func makeButton(title: String, x: Int, y: Int, width: Int, action: Selector) -> FirstMouseButton {
        let btn = FirstMouseButton(frame: NSRect(x: x, y: y, width: width, height: 44))
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("Screenie: Clipboard file doesn't exist: %@", url.path)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Write as file URL (like Finder copy) — enables paste in Finder, Slack, etc.
        pasteboard.declareTypes([.fileURL, .string], owner: nil)
        pasteboard.setString(url.absoluteString, forType: .fileURL)
        pasteboard.setString(url.path, forType: .string)
        NSLog("Screenie: Copied file to clipboard: %@", url.path)
    }

    @objc private func copyAction() {
        copyToClipboard()
        dismiss()
    }

    @objc private func openAction() {
        guard let url = archiveURL ?? clipboardURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismiss()
    }

    @objc private func gifAction() {
        guard let url = archiveURL ?? clipboardURL else { return }
        copiedBadge.stringValue = "  Exporting GIF...  "
        copiedBadge.backgroundColor = .systemOrange

        Task.detached { [weak self] in
            let gifURL = url.deletingLastPathComponent().appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".gif"
            )
            do {
                try await GIFExporter.export(videoURL: url, outputURL: gifURL, fps: 12, width: 480)
                await MainActor.run {
                    // Copy GIF to clipboard
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.declareTypes([.fileURL, .string], owner: nil)
                    pasteboard.setString(gifURL.absoluteString, forType: .fileURL)
                    pasteboard.setString(gifURL.path, forType: .string)

                    self?.copiedBadge.stringValue = "  GIF copied to clipboard  "
                    self?.copiedBadge.backgroundColor = NSColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1.0)
                    self?.startDismissTimer()
                }
            } catch {
                NSLog("Screenie: GIF export failed: %@", error.localizedDescription)
                await MainActor.run {
                    self?.copiedBadge.stringValue = "  GIF export failed  "
                    self?.copiedBadge.backgroundColor = .systemRed
                }
            }
        }
    }

    @objc private func discardAction() {
        NSLog("Screenie: Discard button clicked")
        if let cb = clipboardURL, let ar = archiveURL {
            hudDelegate?.previewHUDDidDiscard(clipboardURL: cb, archiveURL: ar)
        }
        dismiss()
    }

    @objc private func previewVideo() {
        NSLog("Screenie: Thumbnail clicked")
        let url = archiveURL ?? clipboardURL
        guard let url else { return }
        NSLog("Screenie: Opening video: %@", url.path)
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

// Button subclass that accepts clicks even when window isn't key
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// View subclass that accepts clicks even when window isn't key
final class FirstMouseView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - GIF Exporter

enum GIFExporter {
    static func export(videoURL: URL, outputURL: URL, fps: Int = 12, width: Int = 480) async throws {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let naturalSize = try await track.load(.naturalSize)

        let scale = CGFloat(width) / naturalSize.width
        let height = Int(naturalSize.height * scale)

        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        reader.add(output)
        reader.startReading()

        // Sample every N frames to hit target fps
        let sourceFPS = try await track.load(.nominalFrameRate)
        let frameSkip = max(1, Int(sourceFPS) / fps)
        let frameDelay = 1.0 / Double(fps)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            Int(duration * Double(fps)) + 1,
            nil
        ) else {
            throw NSError(domain: "Screenie", code: 30, userInfo: [NSLocalizedDescriptionKey: "Failed to create GIF destination"])
        }

        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDelay
            ]
        ]

        let ciContext = CIContext()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var frameIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            frameIndex += 1
            guard frameIndex % frameSkip == 0 else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height), format: .BGRA8, colorSpace: colorSpace) else { continue }

            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Screenie", code: 31, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize GIF"])
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        NSLog("Screenie: GIF exported — %d bytes, %dx%d @ %dfps", fileSize, width, height, fps)
    }
}
