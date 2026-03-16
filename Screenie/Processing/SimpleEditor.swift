// Screenie/Processing/SimpleEditor.swift
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
            NSLog("Screenie: Could not load duration, estimating from events")
            let maxEventTime = events.map(\.timestamp).max() ?? 5.0
            duration = CMTime(seconds: maxEventTime + 0.5, preferredTimescale: 600)
        }
        let durationSecs = duration.seconds

        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            NSLog("Screenie: Could not load video tracks: %@", error.localizedDescription)
            throw error
        }

        guard let sourceVideoTrack = videoTracks.first else {
            throw NSError(domain: "Screenie", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let width = Int(naturalSize.width)
        let height = Int(naturalSize.height)
        NSLog("Screenie: Processing %.1fs video (%dx%d) with %d events", durationSecs, width, height, events.count)

        // 1. Analyze
        let timeline = ActivityAnalyzer.analyze(events: events, duration: durationSecs)
        let timeMappings = SpeedMapper.map(segments: timeline)
        let clicks = events.filter { $0.type == .mouseClick }

        let hasSpeedChanges = timeMappings.contains(where: { $0.speed != 1.0 })
        let hasZoom = !clicks.isEmpty

        NSLog("Screenie: %d segments, %d clicks — speed:%@ zoom:%@",
              timeMappings.count, clicks.count,
              hasSpeedChanges ? "yes" : "no", hasZoom ? "yes" : "no")

        if !hasSpeedChanges && !hasZoom {
            NSLog("Screenie: No edits needed, copying raw")
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
        NSLog("Screenie: Audio processing skipped (video-only edit)")

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
        NSLog("Screenie: Video done! %d frames, %.1fs → %.1fs, %d bytes", frameCount, durationSecs, editedDuration, fileSize)

        // 5. Merge audio from raw recording into edited video
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let rawAudioTrack = audioTracks.first {
            NSLog("Screenie: Merging audio into edited video...")
            let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent("with_audio.mp4")
            do {
                let editedAsset = AVURLAsset(url: outputURL)
                let editedVideoTracks = try await editedAsset.loadTracks(withMediaType: .video)
                guard let editedVideoTrack = editedVideoTracks.first else { throw NSError(domain: "Screenie", code: 20) }

                let composition = AVMutableComposition()
                let editedDur = try await editedAsset.load(.duration)

                // Add edited video track
                let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1)!
                try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: editedDur), of: editedVideoTrack, at: .zero)

                // Add raw audio track (trimmed to edited video duration)
                let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)!
                let audioDur = min(try await rawAudioTrack.asset!.load(.duration), editedDur)
                try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDur), of: rawAudioTrack, at: .zero)

                // Export merged
                guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    throw NSError(domain: "Screenie", code: 21)
                }
                session.outputURL = tempURL
                session.outputFileType = .mp4
                await session.export()

                if session.status == .completed {
                    try FileManager.default.removeItem(at: outputURL)
                    try FileManager.default.moveItem(at: tempURL, to: outputURL)
                    NSLog("Screenie: Audio merged!")
                } else {
                    NSLog("Screenie: Audio merge failed: %@", session.error?.localizedDescription ?? "unknown")
                    try? FileManager.default.removeItem(at: tempURL)
                }
            } catch {
                NSLog("Screenie: Audio merge error: %@, keeping video-only", error.localizedDescription)
                try? FileManager.default.removeItem(at: tempURL)
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

    /// Build cursor track — raw positions sorted by time, no resampling
    private func buildCursorTrack(from events: [LoggedEvent]) -> [(time: TimeInterval, pos: CGPoint)] {
        var track: [(time: TimeInterval, pos: CGPoint)] = []
        for event in events {
            if let x = event.x, let y = event.y {
                track.append((time: event.timestamp, pos: CGPoint(x: x, y: y)))
            }
        }
        track.sort { $0.time < $1.time }
        return track
    }

    /// Get cursor position at a given time — linear interpolation between raw samples
    private func cursorPositionAt(time: TimeInterval, track: [(time: TimeInterval, pos: CGPoint)]) -> CGPoint {
        guard !track.isEmpty else { return .zero }

        // Binary search for the two surrounding samples
        var lo = 0
        var hi = track.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if track[mid].time <= time {
                lo = mid
            } else {
                hi = mid
            }
        }

        let before = track[lo]
        let after = track[hi]

        // Exact match or before first sample
        if time <= before.time { return before.pos }
        if time >= after.time { return after.pos }
        if before.time == after.time { return before.pos }

        // Linear interpolation — zero lag, no smoothing delay
        let t = CGFloat((time - before.time) / (after.time - before.time))
        return CGPoint(
            x: before.pos.x + t * (after.pos.x - before.pos.x),
            y: before.pos.y + t * (after.pos.y - before.pos.y)
        )
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
