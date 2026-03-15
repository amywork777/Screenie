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
                finalBuffer = applyZoom(
                    to: pixelBuffer,
                    at: relativeTime,
                    clicks: clicks,
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
        at time: TimeInterval,
        clicks: [LoggedEvent],
        size: CGSize,
        context: CIContext,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        let zoom = zoomAt(time: time, clicks: clicks)
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

    private func zoomAt(time: TimeInterval, clicks: [LoggedEvent]) -> ZoomState {
        let maxZoom: CGFloat = 1.5
        let transitionIn = 0.3
        let hold = 1.2
        let transitionOut = 0.3

        var bestZoom: CGFloat = 1.0
        var bestCenter = CGPoint.zero

        for click in clicks {
            guard let x = click.x, let y = click.y else { continue }
            let dt = time - click.timestamp

            let zoom: CGFloat
            if dt < 0 {
                // Before click
                continue
            } else if dt < transitionIn {
                // Easing in
                let t = CGFloat(dt / transitionIn)
                let eased = t * t * (3 - 2 * t) // smoothstep
                zoom = 1.0 + (maxZoom - 1.0) * eased
            } else if dt < transitionIn + hold {
                // Holding
                zoom = maxZoom
            } else if dt < transitionIn + hold + transitionOut {
                // Easing out
                let t = CGFloat((dt - transitionIn - hold) / transitionOut)
                let eased = t * t * (3 - 2 * t)
                zoom = maxZoom - (maxZoom - 1.0) * eased
            } else {
                continue
            }

            if zoom > bestZoom {
                bestZoom = zoom
                bestCenter = CGPoint(x: x, y: y)
            }
        }

        return ZoomState(level: bestZoom, center: bestCenter)
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
