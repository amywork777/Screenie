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

    var onProgress: ((Double) -> Void)?

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

        // 1. Analyze (input events + screen change detection)
        let timeline = await ActivityAnalyzer.analyzeWithScreenChanges(
            events: events,
            videoURL: videoURL,
            duration: durationSecs
        )
        let timeMappings = SpeedMapper.map(segments: timeline)
        let clicks = events.filter { $0.type == .mouseClick }

        let hasSpeedChanges = timeMappings.contains(where: { $0.speed != 1.0 })

        NSLog("Screenie: %d segments, %d clicks — speed:%@",
              timeMappings.count, clicks.count,
              hasSpeedChanges ? "yes" : "no")

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

        // 3. Set up writer — HEVC for high quality output
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoProfileLevelKey: "HEVC_Main_AutoLevel" as CFString,
            ] as [String: Any],
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
        let estimatedFrames = max(Int(durationSecs * 60), 1)  // assume ~60fps source

        let ciContext = CIContext()

        // Read editing feature settings
        let useAutoZoom = Settings.shared.autoZoom
        let useAutoFollow = Settings.shared.autoFollow
        let useCursorBounce = Settings.shared.cursorBounce
        let useSpeedRamping = Settings.shared.speedRamping
        let useKeystrokeOverlay = Settings.shared.keystrokeOverlay
        let useCursorSmoothing = Settings.shared.cursorSmoothing

        // Precompute zoom + camera follow timeline
        let zoomTimeline = (useAutoZoom || useAutoFollow)
            ? buildZoomTimeline(clicks: useAutoZoom ? clicks : [], allEvents: useAutoFollow ? events : [], duration: durationSecs, screenSize: naturalSize)
            : []

        // Build cursor position track for rendering cursor overlay
        let cursorTrack = buildCursorTrack(from: events, smooth: useCursorSmoothing)

        // Pre-render cursor image (white arrow with black border)
        let cursorImage = renderCursorImage()

        // Build keystroke overlay timeline (isolated keypresses with labels)
        let keystrokeEvents = useKeystrokeOverlay ? buildKeystrokeTimeline(events: events) : []

        // Pre-render gradient background + rounded corner mask for styled output
        let useMonitorStyle = Settings.shared.monitorStyle
        let styleInset: CGFloat = useMonitorStyle ? 0.84 : 1.0
        let styleCornerRadius: CGFloat = useMonitorStyle ? 20.0 : 0.0
        let gradientBG = useMonitorStyle ? renderGradientWithWatermark(size: naturalSize) : nil
        let cornerMask = useMonitorStyle ? renderCornerMask(size: naturalSize, insetScale: styleInset, cornerRadius: styleCornerRadius) : nil
        let dropShadow = useMonitorStyle ? renderDropShadow(mask: cornerMask!, size: naturalSize) : nil
        let contactShadow = useMonitorStyle ? renderContactShadow(size: naturalSize, insetScale: styleInset) : nil
        let bezel = useMonitorStyle ? renderBezel(size: naturalSize, insetScale: styleInset, cornerRadius: styleCornerRadius) : nil
        let monitorStand = useMonitorStyle ? renderMonitorStand(size: naturalSize, insetScale: styleInset) : nil

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if baseTimestamp == nil {
                baseTimestamp = sourceTime
            }

            let relativeTime = (sourceTime - baseTimestamp!).seconds

            let outputTimeSecs: Double
            if hasSpeedChanges && useSpeedRamping {
                outputTimeSecs = sourceTimeToOutputTime(relativeTime, timeMappings: timeMappings)
            } else {
                outputTimeSecs = relativeTime
            }
            let outputTime = CMTime(seconds: outputTimeSecs, preferredTimescale: 600)

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // 1. Draw cursor with click bounce onto the frame
            let cursorPos = cursorPositionAt(time: relativeTime, track: cursorTrack)
            let cursorScale = useCursorBounce ? clickBounceScale(time: relativeTime, clicks: clicks) : 1.0
            let withCursor = drawCursor(
                on: pixelBuffer,
                cursorImage: cursorImage,
                position: cursorPos,
                screenSize: naturalSize,
                context: ciContext,
                adaptor: adaptor,
                scale: cursorScale
            )

            // 2. Apply zoom + camera follow
            let zState = zoomAt(time: relativeTime, timeline: zoomTimeline)
            let finalBuffer = applyZoom(
                to: withCursor,
                zoom: zState,
                size: naturalSize,
                context: ciContext,
                adaptor: adaptor
            ) ?? withCursor

            // 3. Apply gradient background + rounded corners (if monitor style enabled)
            let styledBuffer: CVPixelBuffer
            if useMonitorStyle {
                styledBuffer = applyStyleFrame(
                    to: finalBuffer,
                    gradient: gradientBG!,
                    shadow: dropShadow!,
                    contactShadow: contactShadow!,
                    mask: cornerMask!,
                    bezel: bezel!,
                    stand: monitorStand!,
                    insetScale: styleInset,
                    size: naturalSize,
                    context: ciContext,
                    adaptor: adaptor
                )
            } else {
                styledBuffer = finalBuffer
            }

            // 4. Composite keystroke overlay pill
            let outputBuffer = compositeKeystrokeOverlay(
                on: styledBuffer,
                time: relativeTime,
                keystrokes: keystrokeEvents,
                size: naturalSize,
                context: ciContext,
                adaptor: adaptor
            )

            // Wait for writer to be ready
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }

            adaptor.append(outputBuffer, withPresentationTime: outputTime)
            lastOutputTime = outputTime
            frameCount += 1
            if frameCount % 10 == 0 {
                let progress = min(Double(frameCount) / Double(estimatedFrames), 0.95)
                await MainActor.run { onProgress?(progress) }
            }
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

    /// Zoom + auto-follow camera: zooms in on clicks, pans to follow cursor with deadzone.
    /// Camera stays still while cursor is in center 60% of frame. Pans with spring physics when
    /// cursor exits the deadzone. Click zoom layers on top of the follow-pan.
    private func buildZoomTimeline(clicks: [LoggedEvent], allEvents: [LoggedEvent], duration: TimeInterval, screenSize: CGSize) -> [(time: TimeInterval, state: ZoomState)] {
        let maxZoom: CGFloat = 1.35
        let zoomInDuration = 0.6
        let zoomOutDuration = 1.0
        let holdAfterClick = 1.5

        var timeline: [(time: TimeInterval, state: ZoomState)] = []
        let fps = 30.0
        let step = 1.0 / fps
        var t = 0.0

        // Build sorted cursor positions for lookup
        let cursorSamples: [(time: TimeInterval, pos: CGPoint)] = allEvents.compactMap { event in
            guard let x = event.x, let y = event.y else { return nil }
            return (time: event.timestamp, pos: CGPoint(x: x, y: y))
        }.sorted { $0.time < $1.time }

        // Camera center — starts at screen center
        var camX: CGFloat = screenSize.width / 2
        var camY: CGFloat = screenSize.height / 2
        var velX: CGFloat = 0
        var velY: CGFloat = 0

        // Spring constants — softer for follow-pan, snappier for click-snap
        let followStiffness: CGFloat = 30
        let followDamping: CGFloat = 12
        let clickStiffness: CGFloat = 60
        let clickDamping: CGFloat = 16

        // Deadzone: cursor must exit this fraction of the viewport to trigger panning
        let deadzoneX: CGFloat = screenSize.width * 0.3   // 60% center = 30% margin each side
        let deadzoneY: CGFloat = screenSize.height * 0.3

        var currentZoom: CGFloat = 1.0

        while t <= duration {
            let dt = CGFloat(step)

            // Get cursor position at this time
            let cursorPos = interpolateCursor(time: t, samples: cursorSamples)

            // Find the most recent click
            let recentClick = clicks.last(where: { $0.timestamp <= t })
            let timeSinceLastClick = recentClick.map { t - $0.timestamp } ?? Double.infinity
            let isClickZooming = timeSinceLastClick < holdAfterClick

            // Target zoom
            let targetZoom: CGFloat = isClickZooming ? maxZoom : 1.0
            let tau: CGFloat = targetZoom > currentZoom
                ? CGFloat(zoomInDuration) / 3.0
                : CGFloat(zoomOutDuration) / 3.0
            let zoomAlpha = 1.0 - exp(-CGFloat(step) / tau)
            currentZoom += (targetZoom - currentZoom) * zoomAlpha

            // Determine pan target — click position takes priority, otherwise deadzone follow
            let targetX: CGFloat
            let targetY: CGFloat
            let stiffness: CGFloat
            let damping: CGFloat

            if isClickZooming, let click = recentClick, let cx = click.x, let cy = click.y {
                // Snap to click position
                targetX = cx
                targetY = cy
                stiffness = clickStiffness
                damping = clickDamping
            } else if let cursor = cursorPos {
                // Deadzone follow: only pan if cursor is outside the deadzone around camera center
                let offsetFromCamX = cursor.x - camX
                let offsetFromCamY = cursor.y - camY

                if abs(offsetFromCamX) > deadzoneX || abs(offsetFromCamY) > deadzoneY {
                    // Pan to bring cursor back to deadzone edge
                    targetX = cursor.x - deadzoneX * (offsetFromCamX > 0 ? 1 : -1)
                    targetY = cursor.y - deadzoneY * (offsetFromCamY > 0 ? 1 : -1)
                    stiffness = followStiffness
                    damping = followDamping
                } else {
                    // Inside deadzone — no panning force
                    targetX = camX
                    targetY = camY
                    stiffness = 0
                    damping = followDamping
                }
            } else {
                targetX = camX
                targetY = camY
                stiffness = 0
                damping = followDamping
            }

            // Spring physics
            let fx = stiffness * (targetX - camX) - damping * velX
            let fy = stiffness * (targetY - camY) - damping * velY
            velX += fx * dt
            velY += fy * dt
            camX += velX * dt
            camY += velY * dt

            // Clamp camera to screen bounds
            camX = max(screenSize.width * 0.25, min(camX, screenSize.width * 0.75))
            camY = max(screenSize.height * 0.25, min(camY, screenSize.height * 0.75))

            timeline.append((time: t, state: ZoomState(level: currentZoom, center: CGPoint(x: camX, y: camY))))
            t += step
        }

        return timeline
    }

    private func interpolateCursor(time: TimeInterval, samples: [(time: TimeInterval, pos: CGPoint)]) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        guard let idx = samples.lastIndex(where: { $0.time <= time }) else { return samples.first?.pos }
        if idx >= samples.count - 1 { return samples[idx].pos }
        let a = samples[idx]
        let b = samples[idx + 1]
        guard b.time > a.time else { return a.pos }
        let t = CGFloat((time - a.time) / (b.time - a.time))
        return CGPoint(x: a.pos.x + t * (b.pos.x - a.pos.x), y: a.pos.y + t * (b.pos.y - a.pos.y))
    }

    private func zoomAt(time: TimeInterval, timeline: [(time: TimeInterval, state: ZoomState)]) -> ZoomState {
        guard !timeline.isEmpty else { return ZoomState(level: 1.0, center: .zero) }
        // Binary search for the last entry <= time
        var lo = 0
        var hi = timeline.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if timeline[mid].time <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return timeline[lo].state
    }

    // MARK: - Cursor rendering (Screen Studio style)

    /// Build cursor track — raw positions sorted by time, optionally smoothed with exponential ease
    private func buildCursorTrack(from events: [LoggedEvent], smooth: Bool = true) -> [(time: TimeInterval, pos: CGPoint)] {
        var track: [(time: TimeInterval, pos: CGPoint)] = []
        for event in events {
            if let x = event.x, let y = event.y {
                track.append((time: event.timestamp, pos: CGPoint(x: x, y: y)))
            }
        }
        track.sort { $0.time < $1.time }

        // Exponential smoothing — removes jitter while keeping responsiveness
        guard smooth, track.count > 1 else { return track }
        let tau: TimeInterval = 0.15  // time constant in seconds
        var smoothed = track
        for i in 1..<smoothed.count {
            let dt = smoothed[i].time - smoothed[i - 1].time
            guard dt > 0 else { continue }
            let alpha = CGFloat(1.0 - exp(-dt / tau))
            smoothed[i].pos = CGPoint(
                x: smoothed[i - 1].pos.x + alpha * (smoothed[i].pos.x - smoothed[i - 1].pos.x),
                y: smoothed[i - 1].pos.y + alpha * (smoothed[i].pos.y - smoothed[i - 1].pos.y)
            )
        }
        return smoothed
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
    private var pillCache: [String: CIImage] = [:]

    /// Composite cursor onto a frame — scales up on click bounce
    private func drawCursor(
        on pixelBuffer: CVPixelBuffer,
        cursorImage: CIImage,
        position: CGPoint,
        screenSize: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        scale: CGFloat = 1.0
    ) -> CVPixelBuffer {
        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Scale cursor around hotspot for click bounce
        let scaledCursor: CIImage
        if abs(scale - 1.0) > 0.01 {
            // Scale around the hotspot point
            scaledCursor = cursorImage
                .transformed(by: CGAffineTransform(translationX: -cursorHotspot.x, y: -(cursorSize.height - cursorHotspot.y)))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: cursorHotspot.x, y: cursorSize.height - cursorHotspot.y))
        } else {
            scaledCursor = cursorImage
        }

        // Position cursor with hotspot at the cursor location
        let cursorX = position.x - cursorHotspot.x * scale
        let cursorY = position.y - (cursorSize.height - cursorHotspot.y) * scale

        let positioned = scaledCursor
            .transformed(by: CGAffineTransform(translationX: cursorX, y: cursorY))
        let composited = positioned.composited(over: baseImage)

        // Render to output buffer
        guard let pool = adaptor.pixelBufferPool else { return pixelBuffer }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return pixelBuffer }

        let renderRect = CGRect(origin: .zero, size: screenSize)
        context.render(composited, to: output, bounds: renderRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    /// Cursor bounce: squish down → pop up → gentle settle
    private func clickBounceScale(time: TimeInterval, clicks: [LoggedEvent]) -> CGFloat {
        let duration = 0.45
        var closestDt = duration

        for click in clicks {
            let dt = time - click.timestamp
            guard dt >= 0 && dt < duration else { continue }
            if dt < closestDt { closestDt = dt }
        }
        guard closestDt < duration else { return 1.0 }

        let t = closestDt

        // Phase 1 (0–0.04s): anticipation squish — cursor compresses like pressing a button
        if t < 0.04 {
            let p = CGFloat(t / 0.04)
            return 1.0 - 0.06 * sin(p * .pi)  // dips to ~0.94 and back
        }

        // Phase 2 (0.04s–end): underdamped spring — pops up to ~1.25, settles with one soft undershoot
        let st = CGFloat(t - 0.04)
        let amplitude: CGFloat = 0.25
        let frequency: CGFloat = 14.0   // ~2.2 Hz — one clean oscillation visible
        let damping: CGFloat = 7.0      // gentle decay
        return 1.0 + amplitude * sin(frequency * st) * exp(-damping * st)
    }

    // MARK: - Keystroke overlay

    private struct KeystrokeEvent {
        let timestamp: TimeInterval
        let label: String
    }

    /// Filter to isolated keypresses (shortcuts) with labels — same logic as zoom typing filter
    private func buildKeystrokeTimeline(events: [LoggedEvent]) -> [KeystrokeEvent] {
        let keyEvents = events.filter { $0.type == .keyPress }
        let keyTimes = keyEvents.map { $0.timestamp }.sorted()
        let window: TimeInterval = 0.5

        return keyEvents.compactMap { event in
            guard let label = event.keyLabel, !label.isEmpty else { return nil }
            // Only show keypresses with modifiers (shortcuts) — skip plain typing
            let hasModifier = label.contains("⌘") || label.contains("⌃") || label.contains("⌥")
            guard hasModifier else { return nil }
            // Also check it's isolated (not a burst)
            var count = 0
            for t in keyTimes {
                if abs(t - event.timestamp) <= window { count += 1 }
                if count >= 3 { break }
            }
            guard count < 3 else { return nil }
            return KeystrokeEvent(timestamp: event.timestamp, label: label)
        }
    }

    /// Composite keystroke pill overlay onto frame
    private func compositeKeystrokeOverlay(
        on pixelBuffer: CVPixelBuffer,
        time: TimeInterval,
        keystrokes: [KeystrokeEvent],
        size: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer {
        let holdDuration = 1.0
        let fadeIn = 0.15
        let fadeOut = 0.3

        // Find the most recent keystroke that should be visible
        guard let active = keystrokes.last(where: { time >= $0.timestamp && time < $0.timestamp + holdDuration + fadeOut }) else {
            return pixelBuffer
        }

        let dt = time - active.timestamp
        let opacity: CGFloat
        if dt < fadeIn {
            opacity = CGFloat(dt / fadeIn)
        } else if dt < holdDuration {
            opacity = 1.0
        } else {
            opacity = CGFloat(1.0 - (dt - holdDuration) / fadeOut)
        }
        guard opacity > 0.01 else { return pixelBuffer }

        // Render pill (cached at full opacity, faded per-frame)
        let basePill: CIImage
        if let cached = pillCache[active.label] {
            basePill = cached
        } else if let rendered = renderKeystrokePill(label: active.label) {
            pillCache[active.label] = rendered
            basePill = rendered
        } else {
            return pixelBuffer
        }
        let pillImage = basePill.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])

        // Position: bottom center, offset up from bottom edge
        let pillWidth = pillImage.extent.width
        let pillX = (size.width - pillWidth) / 2
        let pillY: CGFloat = size.height * 0.06  // 6% from bottom

        let baseImage = CIImage(cvPixelBuffer: pixelBuffer)
        let positioned = pillImage.transformed(by: CGAffineTransform(translationX: pillX, y: pillY))
        let composited = positioned.composited(over: baseImage)

        guard let pool = adaptor.pixelBufferPool else { return pixelBuffer }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return pixelBuffer }

        context.render(composited, to: output, bounds: CGRect(origin: .zero, size: size),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    private func renderKeystrokePill(label: String) -> CIImage? {
        let font = NSFont.systemFont(ofSize: 20, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let paddingH: CGFloat = 20
        let paddingV: CGFloat = 10
        let pillWidth = textSize.width + paddingH * 2
        let pillHeight = textSize.height + paddingV * 2
        let pillSize = NSSize(width: pillWidth, height: pillHeight)

        let image = NSImage(size: pillSize, flipped: false) { _ in
            NSColor(white: 0.1, alpha: 0.8).setFill()
            let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: pillSize),
                                    xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            path.fill()

            NSColor(white: 1.0, alpha: 0.2).setStroke()
            path.lineWidth = 1
            path.stroke()

            let textRect = NSRect(
                x: paddingH,
                y: paddingV - 1,
                width: textSize.width,
                height: textSize.height
            )
            (label as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }

        guard let tiff = image.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        return ci
    }

    // MARK: - Gradient background + rounded corners

    private func renderGradientBackground(size: CGSize) -> CIImage {
        let bg = Settings.shared.bgColor
        // Create a subtle gradient: user color at top-left, slightly warmer at bottom-right
        let filter = CIFilter(name: "CILinearGradient")!
        filter.setValue(CIVector(x: 0, y: size.height), forKey: "inputPoint0")
        filter.setValue(CIColor(red: bg.r, green: bg.g, blue: bg.b), forKey: "inputColor0")
        filter.setValue(CIVector(x: size.width, y: 0), forKey: "inputPoint1")
        filter.setValue(CIColor(red: min(bg.r + 0.1, 1.0), green: min(bg.g + 0.05, 1.0), blue: max(bg.b - 0.1, 0.0)), forKey: "inputColor1")
        return filter.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func renderGradientWithWatermark(size: CGSize) -> CIImage {
        let gradient = renderGradientBackground(size: size)

        // Load mascot (no background) from bundle
        guard let iconURL = Bundle.main.url(forResource: "screenie-mascot", withExtension: "png"),
              let iconImage = CIImage(contentsOf: iconURL) else {
            return gradient
        }

        // Scale icon with Lanczos for crisp result
        let iconHeight: CGFloat = 48
        let iconScale = iconHeight / iconImage.extent.height
        let scaledIcon = iconImage
            .applyingFilter("CILanczosScaleTransform", parameters: [
                "inputScale": iconScale,
                "inputAspectRatio": 1.0
            ])

        // Position: bottom-right corner, in the gradient margin area
        let margin: CGFloat = 16
        let iconX = size.width - scaledIcon.extent.width - margin
        let iconY = margin

        // Fade to 50% opacity
        let faded = scaledIcon
            .transformed(by: CGAffineTransform(translationX: iconX, y: iconY))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)
            ])

        return faded.composited(over: gradient)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func renderCornerMask(size: CGSize, insetScale: CGFloat, cornerRadius: CGFloat) -> CIImage {
        let insetW = size.width * insetScale
        let insetH = size.height * insetScale
        let insetX = (size.width - insetW) / 2
        let insetY = (size.height - insetH) / 2

        let nsImage = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: insetX, y: insetY, width: insetW, height: insetH),
                         xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }

        guard let tiff = nsImage.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return CIImage.empty() }
        return ci
    }

    private func renderBezel(size: CGSize, insetScale: CGFloat, cornerRadius: CGFloat) -> CIImage {
        let insetW = size.width * insetScale
        let insetH = size.height * insetScale
        let insetX = (size.width - insetW) / 2
        let insetY = (size.height - insetH) / 2
        let bw: CGFloat = 6  // thick bezel like a real monitor frame

        let nsImage = NSImage(size: size, flipped: false) { _ in
            // Light gray border matching the stand color — looks like a monitor chassis
            NSColor(white: 0.78, alpha: 1.0).setStroke()
            let outerRect = NSRect(x: insetX - bw / 2, y: insetY - bw / 2,
                                   width: insetW + bw, height: insetH + bw)
            let path = NSBezierPath(roundedRect: outerRect,
                                    xRadius: cornerRadius + bw / 2,
                                    yRadius: cornerRadius + bw / 2)
            path.lineWidth = bw
            path.stroke()
            return true
        }

        guard let tiff = nsImage.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return CIImage.empty() }
        return ci
    }

    private func renderContactShadow(size: CGSize, insetScale: CGFloat) -> CIImage {
        // Tight elliptical shadow directly below the monitor — like it's sitting on a surface
        let insetW = size.width * insetScale
        let centerX = size.width / 2
        let screenBottomY = (size.height - size.height * insetScale) / 2

        let shadowW = insetW * 0.5
        let shadowH: CGFloat = 10
        let shadowY = screenBottomY - 20  // just below the screen

        let nsImage = NSImage(size: size, flipped: false) { _ in
            NSColor(white: 0, alpha: 0.12).setFill()
            NSBezierPath(ovalIn: NSRect(
                x: centerX - shadowW / 2, y: shadowY,
                width: shadowW, height: shadowH
            )).fill()
            return true
        }

        guard let tiff = nsImage.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return CIImage.empty() }
        // Blur it for softness
        return ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8.0])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func renderDropShadow(mask: CIImage, size: CGSize) -> CIImage {
        // White rounded rect from mask → invert to get shadow shape → tint black → blur → offset down
        let shadowColor = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.25))
            .cropped(to: CGRect(origin: .zero, size: size))
        let shadowShape = mask.applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: shadowColor
        ])
        return shadowShape
            .transformed(by: CGAffineTransform(translationX: 0, y: -8))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24.0])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func renderMonitorStand(size: CGSize, insetScale: CGFloat) -> CIImage {
        let insetH = size.height * insetScale
        let centerX = size.width / 2
        let verticalShift = size.height * 0.015  // must match the shift in applyStyleFrame

        let nsImage = NSImage(size: size, flipped: true) { _ in
            let screenBottom = (size.height - insetH) / 2 - verticalShift  // shifted up in flipped coords

            // Neck — thin vertical bar
            let neckWidth: CGFloat = 6
            let neckHeight: CGFloat = 28
            let neckRect = NSRect(
                x: centerX - neckWidth / 2,
                y: screenBottom + insetH,
                width: neckWidth,
                height: neckHeight
            )
            NSColor(white: 0.78, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: neckRect, xRadius: neckWidth / 2, yRadius: neckWidth / 2).fill()

            // Base — wider rounded foot
            let baseWidth: CGFloat = 70
            let baseHeight: CGFloat = 8
            let baseY = screenBottom + insetH + neckHeight - 2
            let baseRect = NSRect(
                x: centerX - baseWidth / 2,
                y: baseY,
                width: baseWidth,
                height: baseHeight
            )
            NSColor(white: 0.75, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: baseRect, xRadius: baseHeight / 2, yRadius: baseHeight / 2).fill()

            // Subtle highlight on neck
            let highlightRect = NSRect(
                x: centerX - 1,
                y: screenBottom + insetH + 4,
                width: 2,
                height: neckHeight - 8
            )
            NSColor(white: 0.88, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 1, yRadius: 1).fill()

            return true
        }

        guard let tiff = nsImage.tiffRepresentation,
              let ci = CIImage(data: tiff) else { return CIImage.empty() }
        return ci
    }

    private func applyStyleFrame(
        to pixelBuffer: CVPixelBuffer,
        gradient: CIImage,
        shadow: CIImage,
        contactShadow: CIImage,
        mask: CIImage,
        bezel: CIImage,
        stand: CIImage,
        insetScale: CGFloat,
        size: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer {
        let content = CIImage(cvPixelBuffer: pixelBuffer)
        let shift = size.height * 0.015

        let offsetX = size.width * (1 - insetScale) / 2
        let offsetY = size.height * (1 - insetScale) / 2 + shift

        let scaled = content
            .transformed(by: CGAffineTransform(scaleX: insetScale, y: insetScale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        // Layer: gradient → stand → contact shadow → drop shadow → masked content → bezel
        let withStand = stand.composited(over: gradient)
        let withContact = contactShadow
            .transformed(by: CGAffineTransform(translationX: 0, y: shift))
            .composited(over: withStand)
        let withShadow = shadow
            .transformed(by: CGAffineTransform(translationX: 0, y: shift))
            .composited(over: withContact)

        let masked = scaled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: withShadow,
            kCIInputMaskImageKey: mask
                .transformed(by: CGAffineTransform(translationX: 0, y: shift))
        ])

        let result = bezel
            .transformed(by: CGAffineTransform(translationX: 0, y: shift))
            .composited(over: masked)

        guard let pool = adaptor.pixelBufferPool else { return pixelBuffer }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let output = outputBuffer else { return pixelBuffer }

        context.render(result, to: output, bounds: CGRect(origin: .zero, size: size),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
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
