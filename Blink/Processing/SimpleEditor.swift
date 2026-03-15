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
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSecs = duration.seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

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

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if baseTimestamp == nil {
                baseTimestamp = sourceTime
            }

            // Relative time from start of recording
            let relativeTime = (sourceTime - baseTimestamp!).seconds

            // Map to output time based on speed
            let outputTimeSecs: Double
            if hasSpeedChanges {
                outputTimeSecs = sourceTimeToOutputTime(relativeTime, timeMappings: timeMappings)
            } else {
                outputTimeSecs = relativeTime
            }
            let outputTime = CMTime(seconds: outputTimeSecs, preferredTimescale: 600)

            // Get pixel buffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // Apply zoom if needed
            let finalBuffer: CVPixelBuffer
            if hasZoom {
                let zState = zoomAt(time: relativeTime, timeline: zoomTimeline)
                finalBuffer = applyZoom(
                    to: pixelBuffer,
                    zoom: zState,
                    size: naturalSize,
                    context: ciContext,
                    adaptor: adaptor
                ) ?? pixelBuffer
            } else {
                finalBuffer = pixelBuffer
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
        guard zoom.level > 1.01 else { return nil } // No zoom needed

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Crop to zoomed region
        let cropW = size.width / zoom.level
        let cropH = size.height / zoom.level
        var cropX = zoom.center.x - cropW / 2
        var cropY = zoom.center.y - cropH / 2
        cropX = max(0, min(cropX, size.width - cropW))
        cropY = max(0, min(cropY, size.height - cropH))

        // CIImage has flipped Y
        let flippedY = size.height - cropY - cropH

        let cropped = inputImage.cropped(to: CGRect(x: cropX, y: flippedY, width: cropW, height: cropH))

        // Scale back to full size
        let scaleX = size.width / cropW
        let scaleY = size.height / cropH
        let scaled = cropped
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -flippedY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Render to a new pixel buffer
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

    /// Precompute zoom keyframes for the entire recording so we can smoothly
    /// interpolate between them (both zoom level AND center position).
    private func buildZoomTimeline(clicks: [LoggedEvent], allEvents: [LoggedEvent], duration: TimeInterval) -> [(time: TimeInterval, state: ZoomState)] {
        let maxZoom: CGFloat = 1.5
        let fadeIn = 0.3
        let fadeOut = 0.5
        let holdAfterLastClick = 1.0

        guard !clicks.isEmpty else { return [] }

        // Build a dense timeline at 30fps
        var timeline: [(time: TimeInterval, state: ZoomState)] = []
        let step = 1.0 / 30.0
        var t = 0.0

        // Track current smooth center using exponential smoothing
        var smoothCenter = CGPoint(x: clicks[0].x ?? 0, y: clicks[0].y ?? 0)
        let smoothing: CGFloat = 0.15 // lower = smoother panning

        while t <= duration {
            // Find the most recent click before or at this time
            let recentClick = clicks.last(where: { $0.timestamp <= t })
            // Find the next click after this time
            let nextClick = clicks.first(where: { $0.timestamp > t })
            // Time since last click
            let timeSinceLast = recentClick.map { t - $0.timestamp } ?? Double.infinity
            // Time until next click
            let timeUntilNext = nextClick.map { $0.timestamp - t } ?? Double.infinity

            // Determine target center (most recent click position)
            if let click = recentClick, let x = click.x, let y = click.y {
                let target = CGPoint(x: x, y: y)
                // Smooth pan toward target
                smoothCenter.x += (target.x - smoothCenter.x) * smoothing
                smoothCenter.y += (target.y - smoothCenter.y) * smoothing
            }

            // Determine zoom level
            let zoom: CGFloat
            let firstClickTime = clicks[0].timestamp
            let lastClickTime = clicks.last!.timestamp

            if t < firstClickTime {
                // Before first click — ease in as we approach
                if firstClickTime - t < fadeIn {
                    let progress = CGFloat((fadeIn - (firstClickTime - t)) / fadeIn)
                    zoom = 1.0 + (maxZoom - 1.0) * smoothstep(progress)
                } else {
                    zoom = 1.0
                }
            } else if t > lastClickTime + holdAfterLastClick {
                // After last click + hold — ease out
                let elapsed = t - (lastClickTime + holdAfterLastClick)
                if elapsed < fadeOut {
                    let progress = CGFloat(elapsed / fadeOut)
                    zoom = maxZoom - (maxZoom - 1.0) * smoothstep(progress)
                } else {
                    zoom = 1.0
                }
            } else {
                // During clicks — stay zoomed
                zoom = maxZoom
            }

            timeline.append((time: t, state: ZoomState(level: zoom, center: smoothCenter)))
            t += step
        }

        return timeline
    }

    private func zoomAt(time: TimeInterval, timeline: [(time: TimeInterval, state: ZoomState)]) -> ZoomState {
        guard !timeline.isEmpty else { return ZoomState(level: 1.0, center: .zero) }

        // Binary search for closest frame
        let idx = timeline.lastIndex(where: { $0.time <= time }) ?? 0
        return timeline[idx].state
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
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
