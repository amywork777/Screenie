// Blink/Processing/SimpleEditor.swift
// Auto-editor: speed ramps idle sections + auto-zooms on clicks
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
        NSLog("Blink: Processing %.1fs video (%dx%d) with %d events",
              durationSecs, Int(naturalSize.width), Int(naturalSize.height), events.count)

        // 1. Analyze activity
        let timeline = ActivityAnalyzer.analyze(events: events, duration: durationSecs)
        let timeMappings = SpeedMapper.map(segments: timeline)

        let hasSpeedChanges = timeMappings.contains(where: { $0.speed != 1.0 })
        let clicks = events.filter { $0.type == .mouseClick }
        let hasZoom = !clicks.isEmpty

        NSLog("Blink: %d segments, %d clicks — speed:%@ zoom:%@",
              timeMappings.count, clicks.count,
              hasSpeedChanges ? "yes" : "no",
              hasZoom ? "yes" : "no")

        // If nothing to edit, just copy
        if !hasSpeedChanges && !hasZoom {
            NSLog("Blink: No edits needed, copying raw file")
            try FileManager.default.copyItem(at: videoURL, to: outputURL)
            return Output(url: outputURL, originalDuration: durationSecs, editedDuration: durationSecs)
        }

        // 2. Build composition
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "Blink", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }

        if hasSpeedChanges {
            // Insert segments with speed changes
            var insertTime = CMTime.zero
            for mapping in timeMappings {
                let segStart = CMTime(seconds: mapping.sourceStart, preferredTimescale: 600)
                let segEnd = CMTime(seconds: mapping.sourceEnd, preferredTimescale: 600)
                let segRange = CMTimeRange(start: segStart, duration: segEnd - segStart)

                do {
                    try compositionTrack.insertTimeRange(segRange, of: sourceVideoTrack, at: insertTime)

                    if mapping.speed != 1.0 {
                        let originalDuration = segEnd - segStart
                        let scaledDuration = CMTime(seconds: mapping.outputDuration, preferredTimescale: 600)
                        let rangeToScale = CMTimeRange(start: insertTime, duration: originalDuration)
                        compositionTrack.scaleTimeRange(rangeToScale, toDuration: scaledDuration)
                        insertTime = insertTime + scaledDuration
                    } else {
                        insertTime = insertTime + (segEnd - segStart)
                    }
                } catch {
                    NSLog("Blink: Segment insert failed: %@", error.localizedDescription)
                }
            }
            NSLog("Blink: Speed ramp: %.1fs → %.1fs", durationSecs, insertTime.seconds)
        } else {
            // No speed changes — insert entire video
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            try compositionTrack.insertTimeRange(fullRange, of: sourceVideoTrack, at: .zero)
        }

        // 3. Build zoom video composition (if clicks exist)
        var videoComposition: AVVideoComposition? = nil
        if hasZoom {
            videoComposition = buildZoomComposition(
                compositionTrack: compositionTrack,
                clicks: clicks,
                timeMappings: hasSpeedChanges ? timeMappings : [],
                naturalSize: naturalSize,
                outputDuration: composition.duration
            )
            NSLog("Blink: Zoom composition built with %d click points", clicks.count)
        }

        // 4. Export
        let editedDuration = composition.duration.seconds

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "Blink", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition

        NSLog("Blink: Exporting...")
        await exportSession.export()

        if let error = exportSession.error {
            NSLog("Blink: Export failed: %@", error.localizedDescription)
            throw error
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        NSLog("Blink: Export done! %d bytes", fileSize)

        return Output(url: outputURL, originalDuration: durationSecs, editedDuration: editedDuration)
    }

    // MARK: - Zoom

    private func buildZoomComposition(
        compositionTrack: AVCompositionTrack,
        clicks: [LoggedEvent],
        timeMappings: [TimeMapping],
        naturalSize: CGSize,
        outputDuration: CMTime
    ) -> AVVideoComposition {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: outputDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)

        // Start at identity (full screen)
        layerInstruction.setTransform(.identity, at: .zero)

        for click in clicks {
            guard let x = click.x, let y = click.y else { continue }

            // Map source time to output time (accounting for speed changes)
            let outputTime = sourceTimeToOutputTime(click.timestamp, timeMappings: timeMappings)

            let zoomLevel: CGFloat = 1.5
            let cropW = naturalSize.width / zoomLevel
            let cropH = naturalSize.height / zoomLevel

            // Center crop on click, clamped to screen bounds
            var cropX = x - cropW / 2
            var cropY = y - cropH / 2
            cropX = max(0, min(cropX, naturalSize.width - cropW))
            cropY = max(0, min(cropY, naturalSize.height - cropH))

            let scaleX = naturalSize.width / cropW
            let scaleY = naturalSize.height / cropH

            // Zoom in at click time
            let zoomIn = CGAffineTransform(translationX: -cropX * scaleX, y: -cropY * scaleY)
                .scaledBy(x: scaleX, y: scaleY)
            let zoomInTime = CMTime(seconds: outputTime, preferredTimescale: 600)
            layerInstruction.setTransform(zoomIn, at: zoomInTime)

            // Zoom out 1.5s later
            let zoomOutTime = CMTime(seconds: outputTime + 1.5, preferredTimescale: 600)
            if zoomOutTime < outputDuration {
                layerInstruction.setTransform(.identity, at: zoomOutTime)
            }
        }

        instruction.layerInstructions = [layerInstruction]

        let videoComp = AVMutableVideoComposition()
        videoComp.instructions = [instruction]
        videoComp.renderSize = naturalSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        return videoComp
    }

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
