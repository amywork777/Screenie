// Blink/Processing/SimpleEditor.swift
// Auto-editor: speed ramps idle sections + smooth auto-zoom on clicks
// Uses AVAssetReader/Writer for reliable frame-level timing control
import Foundation
import AVFoundation
import CoreImage

final class SimpleEditor {

    struct Output {
        let url: URL
        let originalDuration: Double
        let editedDuration: Double
    }

    func process(videoURL: URL, events: [LoggedEvent], outputURL: URL) async throws -> Output {
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

        // 2. Set up reader
        let reader = try AVAssetReader(asset: asset)
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: readerSettings)
        reader.add(readerOutput)

        // 3. Set up writer
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(writerInput)

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

            // 1. Draw cursor onto the frame
            let cursorPos = cursorPositionAt(time: relativeTime, track: cursorTrack)
            let withCursor = drawCursor(
                on: pixelBuffer,
                cursorImage: cursorImage,
                position: cursorPos,
                screenSize: naturalSize,
                context: ciContext,
                adaptor: adaptor
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

            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            adaptor.append(finalBuffer, withPresentationTime: outputTime)
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
        NSLog("Blink: Done! %d frames, %.1fs → %.1fs, %d bytes", frameCount, durationSecs, editedDuration, fileSize)

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

    /// Screen Studio-style zoom: follows cursor continuously with spring physics.
    /// Zooms in when activity starts, smoothly pans to follow mouse, zooms out during idle.
    private func buildZoomTimeline(clicks: [LoggedEvent], allEvents: [LoggedEvent], duration: TimeInterval) -> [(time: TimeInterval, state: ZoomState)] {
        let maxZoom: CGFloat = 1.35  // subtle — Screen Studio doesn't zoom too aggressively
        let zoomInDuration = 0.8    // slow, cinematic zoom in
        let zoomOutDuration = 1.2   // very slow zoom out for buttery feel
        let idleBeforeZoomOut = 2.0 // stay zoomed a while after last activity

        // Build cursor position track from ALL events (moves + clicks)
        var cursorTrack: [(time: TimeInterval, pos: CGPoint)] = []
        for event in allEvents {
            if let x = event.x, let y = event.y {
                cursorTrack.append((time: event.timestamp, pos: CGPoint(x: x, y: y)))
            }
        }
        guard !cursorTrack.isEmpty else { return [] }
        cursorTrack.sort { $0.time < $1.time }

        // Find active periods (any mouse/keyboard activity)
        let activityEvents = allEvents.filter { $0.type == .mouseClick || $0.type == .mouseMove || $0.type == .keyPress }
        guard !activityEvents.isEmpty else { return [] }

        let firstActivity = activityEvents.first!.timestamp
        let lastActivity = activityEvents.last!.timestamp

        // Build dense timeline at 30fps
        var timeline: [(time: TimeInterval, state: ZoomState)] = []
        let fps = 30.0
        let step = 1.0 / fps
        var t = 0.0

        // Spring physics state for camera center
        var camX: CGFloat = cursorTrack[0].pos.x
        var camY: CGFloat = cursorTrack[0].pos.y
        var velX: CGFloat = 0
        var velY: CGFloat = 0

        // Spring constants — tuned for buttery Screen Studio feel
        // Lower stiffness = slower, more cinematic following
        // Damping ratio ~1.0 = critically damped (no bounce, just smooth settling)
        let stiffness: CGFloat = 60    // gentle pull toward cursor
        let damping: CGFloat = 16      // critically damped (2 * sqrt(60) ≈ 15.5)

        // Current zoom level with smooth interpolation
        var currentZoom: CGFloat = 1.0

        while t <= duration {
            // Find cursor position at this time (most recent known position)
            let cursorPos: CGPoint
            if let latest = cursorTrack.last(where: { $0.time <= t }) {
                cursorPos = latest.pos
            } else {
                cursorPos = CGPoint(x: camX, y: camY)
            }

            // Determine target zoom level
            let targetZoom: CGFloat
            if t < firstActivity {
                targetZoom = 1.0
            } else if t > lastActivity + idleBeforeZoomOut {
                targetZoom = 1.0
            } else {
                // Check if there's been recent activity (within idleBeforeZoomOut)
                let recentActivity = activityEvents.contains(where: {
                    $0.timestamp <= t && t - $0.timestamp < idleBeforeZoomOut
                })
                targetZoom = recentActivity ? maxZoom : 1.0
            }

            // Exponential ease toward target zoom — never linear, always smooth
            let tau: CGFloat  // time constant (lower = faster)
            if targetZoom > currentZoom {
                tau = CGFloat(zoomInDuration) / 3.0
            } else {
                tau = CGFloat(zoomOutDuration) / 3.0
            }
            let alpha = 1.0 - exp(-CGFloat(step) / tau)
            currentZoom += (targetZoom - currentZoom) * alpha

            // Spring physics for camera position (only when zoomed in)
            if currentZoom > 1.05 {
                let dt = CGFloat(step)

                // Spring force toward cursor
                let dx = cursorPos.x - camX
                let dy = cursorPos.y - camY
                let forceX = stiffness * dx - damping * velX
                let forceY = stiffness * dy - damping * velY

                velX += forceX * dt
                velY += forceY * dt
                camX += velX * dt
                camY += velY * dt
            } else {
                // When zoomed out, snap to cursor (no lag needed)
                camX = cursorPos.x
                camY = cursorPos.y
                velX = 0
                velY = 0
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

    // MARK: - Cursor rendering

    private func buildCursorTrack(from events: [LoggedEvent]) -> [(time: TimeInterval, pos: CGPoint)] {
        var track: [(time: TimeInterval, pos: CGPoint)] = []
        for event in events {
            if let x = event.x, let y = event.y {
                track.append((time: event.timestamp, pos: CGPoint(x: x, y: y)))
            }
        }
        return track.sorted { $0.time < $1.time }
    }

    private func cursorPositionAt(time: TimeInterval, track: [(time: TimeInterval, pos: CGPoint)]) -> CGPoint {
        guard !track.isEmpty else { return .zero }
        if let entry = track.last(where: { $0.time <= time }) {
            return entry.pos
        }
        return track[0].pos
    }

    /// Renders a macOS-style cursor arrow as a CIImage
    private func renderCursorImage() -> CIImage {
        let size = NSSize(width: 24, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            // Arrow cursor shape
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 26))    // top-left (tip)
            path.line(to: NSPoint(x: 2, y: 2))      // bottom-left
            path.line(to: NSPoint(x: 9, y: 9))      // inner right
            path.line(to: NSPoint(x: 15, y: 2))     // bottom-right arm
            path.line(to: NSPoint(x: 18, y: 5))     // outer right arm
            path.line(to: NSPoint(x: 12, y: 12))    // inner junction
            path.line(to: NSPoint(x: 20, y: 12))    // right arm
            path.close()

            // Black border
            NSColor.black.setStroke()
            path.lineWidth = 2.0
            path.stroke()

            // White fill
            NSColor.white.setFill()
            path.fill()

            return true
        }

        // Convert to CIImage
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return CIImage.empty()
        }
        return ciImage
    }

    /// Draws cursor onto a pixel buffer, returns a new buffer with the cursor composited
    private func drawCursor(
        on pixelBuffer: CVPixelBuffer,
        cursorImage: CIImage,
        position: CGPoint,
        screenSize: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer {
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Convert Cocoa coords (Y from bottom) to CIImage coords (also Y from bottom)
        // Position the cursor with its tip at the cursor location
        let cursorX = position.x
        let cursorY = position.y - 28  // offset so tip is at position

        let positioned = cursorImage
            .transformed(by: CGAffineTransform(translationX: cursorX, y: cursorY))

        let composited = positioned.composited(over: baseImage)

        // Render to new buffer
        guard let pool = adaptor.pixelBufferPool else { return pixelBuffer }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return pixelBuffer }

        let renderRect = CGRect(origin: .zero, size: screenSize)
        context.render(composited, to: output, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
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
