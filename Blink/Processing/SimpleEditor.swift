// Blink/Processing/SimpleEditor.swift
// Auto-editor: speed ramps idle sections + smooth auto-zoom on clicks
// Uses AVAssetReader/Writer for reliable frame-level timing control
import Foundation
import AVFoundation
import CoreImage
import AppKit

final class SimpleEditor {

    struct Output {
        let url: URL
        let originalDuration: Double
        let editedDuration: Double
    }

    func process(videoURL: URL, micAudioURL: URL? = nil, events: [LoggedEvent], outputURL: URL) async throws -> Output {
        let asset = AVURLAsset(url: videoURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        // Try loading duration — if it fails, estimate from events
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            NSLog("Blink: Could not load duration, estimating from events")
            let maxEventTime = events.map(\.timestamp).max() ?? 5.0
            duration = CMTime(seconds: maxEventTime + 0.5, preferredTimescale: 600)
        }
        let durationSecs = duration.seconds

        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            NSLog("Blink: Could not load video tracks: %@", error.localizedDescription)
            throw error
        }

        guard let sourceVideoTrack = videoTracks.first else {
            throw NSError(domain: "Blink", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let width = Int(naturalSize.width)
        let height = Int(naturalSize.height)
        NSLog("Blink: Processing %.1fs video (%dx%d) with %d events", durationSecs, width, height, events.count)

        // 1. Analyze
        let timeline = ActivityAnalyzer.analyze(events: events, duration: durationSecs)
        let timeMappings = SpeedMapper.map(segments: timeline)
        let clicks = events.filter { $0.type == .mouseClick }

        let hasSpeedChanges = timeMappings.contains(where: { $0.speed != 1.0 })
        let hasZoom = !clicks.isEmpty

        NSLog("Blink: %d segments, %d clicks — speed:%@ zoom:%@",
              timeMappings.count, clicks.count,
              hasSpeedChanges ? "yes" : "no", hasZoom ? "yes" : "no")

        if !hasSpeedChanges && !hasZoom {
            NSLog("Blink: No edits needed, copying raw")
            try FileManager.default.copyItem(at: videoURL, to: outputURL)
            return Output(url: outputURL, originalDuration: durationSecs, editedDuration: durationSecs)
        }

        // 2. Set up reader (video)
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: readerSettings)
        reader.add(readerOutput)

        // Audio: skip processing for now (retiming causes hangs)
        // Raw recording has audio — it's preserved when "no edits needed" copies the file
        NSLog("Blink: Audio processing skipped (video-only edit)")

        // 3. Set up writer — output is larger to fit background + padding
        let padding: CGFloat = 60  // padding around the screen recording
        let cornerRadius: CGFloat = 16
        // Round up to multiple of 16 for H.264 compatibility
        let rawW = Int(CGFloat(width) + padding * 2)
        let rawH = Int(CGFloat(height) + padding * 2)
        let outputW = (rawW + 15) / 16 * 16
        let outputH = (rawH + 15) / 16 * 16

        // Pre-render the background gradient (only once)
        let backgroundImage = renderBackground(width: outputW, height: outputH)
        // Pre-render the shadow
        let shadowImage = renderShadow(
            contentSize: CGSize(width: width, height: height),
            padding: padding,
            cornerRadius: cornerRadius,
            canvasSize: CGSize(width: outputW, height: outputH)
        )

        NSLog("Blink: Output with background: %dx%d (padding=%.0f)", outputW, outputH, padding)

        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputW,
            AVVideoHeightKey: outputH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputW,
                kCVPixelBufferHeightKey as String: outputH,
            ]
        )
        writer.add(writerInput)

        // No audio writer — video only for edited output

        // 4. Process frames
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Get the first frame's timestamp as base offset
        var baseTimestamp: CMTime?
        var frameCount = 0
        var lastOutputTime = CMTime.zero

        let ciContext = CIContext()

        // Precompute zoom timeline for smooth panning
        let zoomTimeline = hasZoom ? buildZoomTimeline(clicks: clicks, allEvents: events, duration: durationSecs) : []

        // Build cursor position track for rendering cursor overlay
        let cursorTrack = buildCursorTrack(from: events)

        // Pre-render cursor image (white arrow with black border)
        let cursorImage = renderCursorImage()

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if baseTimestamp == nil {
                baseTimestamp = sourceTime
            }

            let relativeTime = (sourceTime - baseTimestamp!).seconds

            let outputTimeSecs: Double
            if hasSpeedChanges {
                outputTimeSecs = sourceTimeToOutputTime(relativeTime, timeMappings: timeMappings)
            } else {
                outputTimeSecs = relativeTime
            }
            let outputTime = CMTime(seconds: outputTimeSecs, preferredTimescale: 600)

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // 1. Draw cursor + click highlight onto the frame
            let cursorPos = cursorPositionAt(time: relativeTime, track: cursorTrack)
            let highlight = clickHighlightAt(time: relativeTime, clicks: clicks)
            let withCursor = drawCursor(
                on: pixelBuffer,
                cursorImage: cursorImage,
                position: cursorPos,
                screenSize: naturalSize,
                context: ciContext,
                adaptor: adaptor,
                clickHighlight: highlight
            )

            // 2. Apply zoom if needed
            let finalBuffer: CVPixelBuffer
            if hasZoom {
                let zState = zoomAt(time: relativeTime, timeline: zoomTimeline)
                finalBuffer = applyZoom(
                    to: withCursor,
                    zoom: zState,
                    size: naturalSize,
                    context: ciContext,
                    adaptor: adaptor
                ) ?? withCursor
            } else {
                finalBuffer = withCursor
            }

            // 3. Composite onto background with rounded corners + shadow
            let composited = compositeOnBackground(
                frame: finalBuffer,
                background: backgroundImage,
                shadow: shadowImage,
                padding: padding,
                cornerRadius: cornerRadius,
                contentSize: naturalSize,
                canvasSize: CGSize(width: outputW, height: outputH),
                context: ciContext,
                adaptor: adaptor
            )

            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            adaptor.append(composited, withPresentationTime: outputTime)
            lastOutputTime = outputTime
            frameCount += 1
        }

        writerInput.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }

        reader.cancelReading()

        let editedDuration = lastOutputTime.seconds
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        NSLog("Blink: Video done! %d frames, %.1fs → %.1fs, %d bytes", frameCount, durationSecs, editedDuration, fileSize)

        // 5. Merge audio from raw recording into the edited video
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let rawAudioTrack = audioTracks.first {
            NSLog("Blink: Merging audio track...")
            let finalURL = outputURL.deletingLastPathComponent().appendingPathComponent("final.mp4")
            do {
                try await mergeAudioIntoVideo(
                    videoURL: outputURL,
                    rawAudioTrack: rawAudioTrack,
                    micAudioURL: micAudioURL,
                    timeMappings: hasSpeedChanges ? timeMappings : [],
                    outputURL: finalURL
                )
                // Replace video-only file with merged file
                try FileManager.default.removeItem(at: outputURL)
                try FileManager.default.moveItem(at: finalURL, to: outputURL)
                let finalSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
                NSLog("Blink: Audio merged! Final: %d bytes", finalSize)
            } catch {
                NSLog("Blink: Audio merge failed: %@, keeping video-only", error.localizedDescription)
            }
        }

        return Output(url: outputURL, originalDuration: durationSecs, editedDuration: editedDuration)
    }

    // MARK: - Zoom

    private func applyZoom(
        to pixelBuffer: CVPixelBuffer,
        zoom: ZoomState,
        size: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard zoom.level > 1.02 else { return nil } // No zoom needed

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Convert cursor center from Cocoa coords (Y=0 bottom) to pixel buffer coords (Y=0 top)
        // Then to CIImage coords (Y=0 bottom) — so the two flips cancel out for X,
        // but Y needs: pixelBufferY = screenHeight - cocoaY, then ciImageY = screenHeight - pixelBufferY = cocoaY
        // So we can use zoom.center directly in CIImage space!
        let centerX = zoom.center.x
        let centerY = zoom.center.y  // Cocoa Y ≈ CIImage Y

        let cropW = size.width / zoom.level
        let cropH = size.height / zoom.level
        var cropX = centerX - cropW / 2
        var cropY = centerY - cropH / 2

        // Clamp to image bounds
        cropX = max(0, min(cropX, size.width - cropW))
        cropY = max(0, min(cropY, size.height - cropH))

        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)

        // Crop, translate to origin, scale to full size
        let cropped = inputImage.cropped(to: cropRect)
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: size.width / cropW, y: size.height / cropH))

        // Render to output buffer
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return nil }

        context.render(scaled, to: output)
        return output
    }

    private struct ZoomState {
        let level: CGFloat
        let center: CGPoint
    }

    /// Click-only zoom: zooms in on each click, smoothly pans between click positions,
    /// zooms out when no recent clicks. No mouse-follow — only reacts to clicks.
    private func buildZoomTimeline(clicks: [LoggedEvent], allEvents: [LoggedEvent], duration: TimeInterval) -> [(time: TimeInterval, state: ZoomState)] {
        let maxZoom: CGFloat = 1.35
        let zoomInDuration = 0.6
        let zoomOutDuration = 1.0
        let holdAfterClick = 1.5  // stay zoomed this long after each click

        guard !clicks.isEmpty else { return [] }

        var timeline: [(time: TimeInterval, state: ZoomState)] = []
        let fps = 30.0
        let step = 1.0 / fps
        var t = 0.0

        // Spring physics for camera center (pans between click positions)
        let firstClick = clicks[0]
        var camX: CGFloat = firstClick.x ?? 0
        var camY: CGFloat = firstClick.y ?? 0
        var velX: CGFloat = 0
        var velY: CGFloat = 0
        let stiffness: CGFloat = 60
        let damping: CGFloat = 16

        var currentZoom: CGFloat = 1.0

        while t <= duration {
            // Find the most recent click
            let recentClick = clicks.last(where: { $0.timestamp <= t })
            let timeSinceLastClick = recentClick.map { t - $0.timestamp } ?? Double.infinity

            // Target zoom: zoomed in if a click happened recently
            let targetZoom: CGFloat = timeSinceLastClick < holdAfterClick ? maxZoom : 1.0

            // Smooth zoom easing
            let tau: CGFloat = targetZoom > currentZoom
                ? CGFloat(zoomInDuration) / 3.0
                : CGFloat(zoomOutDuration) / 3.0
            let alpha = 1.0 - exp(-CGFloat(step) / tau)
            currentZoom += (targetZoom - currentZoom) * alpha

            // Spring physics: pan camera toward most recent click position
            if let click = recentClick, let cx = click.x, let cy = click.y {
                let dt = CGFloat(step)
                let dx = cx - camX
                let dy = cy - camY
                let fx = stiffness * dx - damping * velX
                let fy = stiffness * dy - damping * velY
                velX += fx * dt
                velY += fy * dt
                camX += velX * dt
                camY += velY * dt
            }

            timeline.append((time: t, state: ZoomState(level: currentZoom, center: CGPoint(x: camX, y: camY))))
            t += step
        }

        return timeline
    }

    private func zoomAt(time: TimeInterval, timeline: [(time: TimeInterval, state: ZoomState)]) -> ZoomState {
        guard !timeline.isEmpty else { return ZoomState(level: 1.0, center: .zero) }
        let idx = timeline.lastIndex(where: { $0.time <= time }) ?? 0
        return timeline[idx].state
    }

    // MARK: - Cursor rendering (Screen Studio style)

    /// Build smoothed cursor track — reconstructs path with cubic interpolation
    /// instead of using raw jittery mouse positions
    private func buildCursorTrack(from events: [LoggedEvent]) -> [(time: TimeInterval, pos: CGPoint)] {
        var raw: [(time: TimeInterval, pos: CGPoint)] = []
        for event in events {
            if let x = event.x, let y = event.y {
                raw.append((time: event.timestamp, pos: CGPoint(x: x, y: y)))
            }
        }
        raw.sort { $0.time < $1.time }
        guard raw.count >= 2 else { return raw }

        // Resample at 60fps with cubic interpolation for smooth paths
        var smoothed: [(time: TimeInterval, pos: CGPoint)] = []
        let step = 1.0 / 60.0
        var t = raw[0].time

        while t <= (raw.last?.time ?? 0) {
            let pos = interpolatedPosition(at: t, track: raw)
            smoothed.append((time: t, pos: pos))
            t += step
        }

        return smoothed
    }

    /// Cubic Hermite interpolation between track points for smooth cursor movement
    private func interpolatedPosition(at time: TimeInterval, track: [(time: TimeInterval, pos: CGPoint)]) -> CGPoint {
        // Find surrounding points
        var i1 = 0
        for i in 0..<track.count {
            if track[i].time > time { break }
            i1 = i
        }
        let i2 = min(i1 + 1, track.count - 1)

        if i1 == i2 { return track[i1].pos }

        let t1 = track[i1].time
        let t2 = track[i2].time
        let progress = (time - t1) / (t2 - t1)

        // Smoothstep for natural easing between points
        let t = progress * progress * (3.0 - 2.0 * progress)

        let x = track[i1].pos.x + CGFloat(t) * (track[i2].pos.x - track[i1].pos.x)
        let y = track[i1].pos.y + CGFloat(t) * (track[i2].pos.y - track[i1].pos.y)
        return CGPoint(x: x, y: y)
    }

    private func cursorPositionAt(time: TimeInterval, track: [(time: TimeInterval, pos: CGPoint)]) -> CGPoint {
        guard !track.isEmpty else { return .zero }
        // Find closest entry
        if let entry = track.last(where: { $0.time <= time }) {
            return entry.pos
        }
        return track[0].pos
    }

    /// Get the real macOS arrow cursor as a CIImage (scaled up for visibility)
    private func renderCursorImage() -> CIImage {
        let cursor = NSCursor.arrow
        let cursorImage = cursor.image
        let hotspot = cursor.hotSpot

        // Scale cursor up for better visibility in recordings (like Screen Studio)
        let scale: CGFloat = 1.5
        let scaledSize = NSSize(
            width: cursorImage.size.width * scale,
            height: cursorImage.size.height * scale
        )

        let rendered = NSImage(size: scaledSize, flipped: false) { rect in
            cursorImage.draw(in: rect)
            return true
        }

        guard let tiffData = rendered.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return CIImage.empty()
        }

        // Store hotspot offset for positioning (scaled)
        cursorHotspot = CGPoint(x: hotspot.x * scale, y: hotspot.y * scale)
        cursorSize = scaledSize

        return ciImage
    }

    private var cursorHotspot = CGPoint.zero
    private var cursorSize = NSSize.zero

    /// Composite cursor + optional click highlight onto a frame
    private func drawCursor(
        on pixelBuffer: CVPixelBuffer,
        cursorImage: CIImage,
        position: CGPoint,
        screenSize: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        clickHighlight: CIImage? = nil
    ) -> CVPixelBuffer {
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Position cursor with hotspot at the cursor location
        // CIImage Y = Cocoa Y (both bottom-up)
        let cursorX = position.x - cursorHotspot.x
        let cursorY = position.y - (cursorSize.height - cursorHotspot.y)

        var composited = baseImage

        // Draw click highlight first (behind cursor)
        if let highlight = clickHighlight {
            let highlightPos = highlight
                .transformed(by: CGAffineTransform(translationX: position.x - 20, y: position.y - 20))
            composited = highlightPos.composited(over: composited)
        }

        // Draw cursor on top
        let positioned = cursorImage
            .transformed(by: CGAffineTransform(translationX: cursorX, y: cursorY))
        composited = positioned.composited(over: composited)

        // Render to output buffer
        guard let pool = adaptor.pixelBufferPool else { return pixelBuffer }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return pixelBuffer }

        let renderRect = CGRect(origin: .zero, size: screenSize)
        context.render(composited, to: output, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    /// Render a click highlight ring (expanding circle that fades)
    private func clickHighlightAt(time: TimeInterval, clicks: [LoggedEvent]) -> CIImage? {
        for click in clicks {
            let dt = time - click.timestamp
            guard dt >= 0 && dt < 0.2 else { continue } // 0.2s — snappy

            let progress = CGFloat(dt / 0.2)
            let radius = 6 + progress * 16   // quick expanding ring
            let opacity = 1.0 - progress      // fast fade
            let size = CGFloat(40)

            let highlight = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSColor(white: 1.0, alpha: opacity * 0.6).setStroke()
                let circle = NSBezierPath(
                    ovalIn: NSRect(
                        x: size / 2 - radius,
                        y: size / 2 - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                circle.lineWidth = 2.5
                circle.stroke()
                return true
            }

            guard let tiffData = highlight.tiffRepresentation,
                  let ciImage = CIImage(data: tiffData) else { continue }
            return ciImage
        }
        return nil
    }

    // MARK: - Background compositing

    /// Render a gradient background (dark, modern — like Screen Studio)
    private func renderBackground(width: Int, height: Int) -> CIImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            // Deep blue-purple gradient
            let gradient = NSGradient(colors: [
                NSColor(red: 0.08, green: 0.06, blue: 0.18, alpha: 1),  // deep indigo
                NSColor(red: 0.15, green: 0.08, blue: 0.25, alpha: 1),  // purple
                NSColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 1),  // blue-grey
            ], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)
            gradient?.draw(in: rect, angle: -35)

            // Subtle noise texture
            for _ in 0..<(width * height / 80) {
                let x = CGFloat.random(in: 0..<CGFloat(width))
                let y = CGFloat.random(in: 0..<CGFloat(height))
                NSColor(white: 1.0, alpha: CGFloat.random(in: 0.01...0.03)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1, height: 1)).fill()
            }
            return true
        }

        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else {
            return CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ci
    }

    /// Render a soft shadow beneath the content area
    private func renderShadow(contentSize: CGSize, padding: CGFloat, cornerRadius: CGFloat, canvasSize: CGSize) -> CIImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let shadowRect = NSRect(
                x: padding - 4, y: padding - 8,
                width: contentSize.width + 8, height: contentSize.height + 8
            )
            let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: cornerRadius + 2, yRadius: cornerRadius + 2)

            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -8)

            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.setFill()
            shadowPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            // Clear the inner rect so only shadow shows
            NSColor.clear.setFill()
            NSBezierPath(roundedRect: NSRect(
                x: padding, y: padding,
                width: contentSize.width, height: contentSize.height
            ), xRadius: cornerRadius, yRadius: cornerRadius).fill()
            // Note: shadow-only effect — the frame itself goes on top in compositing

            return true
        }

        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else {
            return CIImage.empty()
        }
        return ci
    }

    /// Composite a video frame onto the background with rounded corners and shadow
    private func compositeOnBackground(
        frame: CVPixelBuffer,
        background: CIImage,
        shadow: CIImage,
        padding: CGFloat,
        cornerRadius: CGFloat,
        contentSize: CGSize,
        canvasSize: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer {
        let frameImage = CIImage(cvPixelBuffer: frame)

        // Apply rounded corners via a mask
        let maskRect = CGRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        let maskImage = NSImage(size: contentSize, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }

        let mask: CIImage
        if let tiff = maskImage.tiffRepresentation, let ci = CIImage(data: tiff) {
            mask = ci
        } else {
            mask = CIImage(color: .white).cropped(to: maskRect)
        }

        // Apply mask (rounded corners)
        let rounded = frameImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: mask,
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: maskRect)
        ])

        // Position frame on canvas (centered with padding)
        let positioned = rounded.transformed(by: CGAffineTransform(translationX: padding, y: padding))

        // Stack: background → shadow → frame
        let withShadow = shadow.composited(over: background)
        let final_ = positioned.composited(over: withShadow)

        // Render to output buffer
        guard let pool = adaptor.pixelBufferPool else { return frame }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return frame }

        let renderRect = CGRect(origin: .zero, size: canvasSize)
        context.render(final_, to: output, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    // MARK: - Audio merge

    /// Merge audio from the raw recording into the edited video using AVMutableComposition
    private func mergeAudioIntoVideo(
        videoURL: URL,
        rawAudioTrack: AVAssetTrack,
        micAudioURL: URL? = nil,
        timeMappings: [TimeMapping],
        outputURL: URL
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { return }

        let composition = AVMutableComposition()

        // Add video track (copy from edited file as-is)
        let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
        let videoDuration = try await videoAsset.load(.duration)
        try compVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )

        // Add audio track from raw recording
        let compAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)!

        if timeMappings.isEmpty {
            // No speed changes — insert audio up to video duration
            let rawDuration = try await rawAudioTrack.asset!.load(.duration)
            let insertDuration = min(rawDuration, videoDuration)
            try compAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: rawAudioTrack,
                at: .zero
            )
        } else {
            // With speed changes — insert audio segments matching video speed
            var insertTime = CMTime.zero
            for mapping in timeMappings {
                let segStart = CMTime(seconds: mapping.sourceStart, preferredTimescale: 600)
                let segEnd = CMTime(seconds: mapping.sourceEnd, preferredTimescale: 600)
                let segDuration = segEnd - segStart
                let scaledDuration = CMTime(seconds: mapping.outputDuration, preferredTimescale: 600)

                do {
                    try compAudioTrack.insertTimeRange(
                        CMTimeRange(start: segStart, duration: segDuration),
                        of: rawAudioTrack,
                        at: insertTime
                    )
                    // Scale audio to match video speed
                    if mapping.speed != 1.0 {
                        compAudioTrack.scaleTimeRange(
                            CMTimeRange(start: insertTime, duration: segDuration),
                            toDuration: scaledDuration
                        )
                    }
                    insertTime = insertTime + scaledDuration
                } catch {
                    NSLog("Blink: Audio segment failed: %@", error.localizedDescription)
                }
            }
        }

        // Add mic audio track if available
        if let micURL = micAudioURL {
            let micAsset = AVURLAsset(url: micURL)
            if let micTrack = try? await micAsset.loadTracks(withMediaType: .audio).first {
                let micDuration = try await micAsset.load(.duration)
                let compMicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3)!
                let insertDuration = min(micDuration, videoDuration)
                try? compMicTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: insertDuration),
                    of: micTrack,
                    at: .zero
                )
                NSLog("Blink: Mic audio track added (%.1fs)", insertDuration.seconds)
            }
        }

        // Export merged composition
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Blink", code: 10, userInfo: [NSLocalizedDescriptionKey: "Export session failed"])
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4

        await session.export()
        if let error = session.error { throw error }
    }

    // MARK: - Speed mapping

    private func sourceTimeToOutputTime(_ sourceTime: TimeInterval, timeMappings: [TimeMapping]) -> TimeInterval {
        guard !timeMappings.isEmpty else { return sourceTime }

        var outputTime = 0.0
        for mapping in timeMappings {
            if sourceTime <= mapping.sourceStart {
                return outputTime
            } else if sourceTime <= mapping.sourceEnd {
                let elapsed = sourceTime - mapping.sourceStart
                return outputTime + elapsed / mapping.speed
            }
            outputTime += mapping.outputDuration
        }
        return outputTime
    }
}
