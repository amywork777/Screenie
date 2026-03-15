// Blink/Processing/SimpleEditor.swift
// Simplified auto-editor: speed ramps idle sections, keeps active at 1x
import Foundation
import AVFoundation

final class SimpleEditor {

    struct Output {
        let url: URL
        let originalDuration: Double
        let editedDuration: Double
    }

    /// Process a raw recording: analyze events, speed ramp idle sections, export
    func process(videoURL: URL, events: [LoggedEvent], outputURL: URL) async throws -> Output {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSecs = duration.seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let sourceVideoTrack = videoTracks.first else {
            throw NSError(domain: "Blink", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }

        NSLog("Blink: Processing %.1fs video with %d events", durationSecs, events.count)

        // 1. Analyze activity
        let timeline = ActivityAnalyzer.analyze(events: events, duration: durationSecs)
        let timeMappings = SpeedMapper.map(segments: timeline)

        NSLog("Blink: %d segments: %d active, %d idle, %d click",
              timeMappings.count,
              timeMappings.filter({ $0.speed == 1.0 }).count,
              timeMappings.filter({ $0.speed > 1.0 }).count,
              timeMappings.filter({ $0.speed < 1.0 }).count)

        // If no idle segments found, just copy the file directly
        let hasSpeedChanges = timeMappings.contains(where: { $0.speed != 1.0 })
        if !hasSpeedChanges {
            NSLog("Blink: No speed changes needed, copying raw file")
            try FileManager.default.copyItem(at: videoURL, to: outputURL)
            return Output(url: outputURL, originalDuration: durationSecs, editedDuration: durationSecs)
        }

        // 2. Build composition with speed changes (video only)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "Blink", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create composition track"])
        }

        // Get the video's actual start time
        let assetStartTime = CMTime.zero // After writing, timestamps should be normalized

        var insertTime = CMTime.zero
        for mapping in timeMappings {
            let segStart = CMTime(seconds: mapping.sourceStart, preferredTimescale: 600)
            let segEnd = CMTime(seconds: mapping.sourceEnd, preferredTimescale: 600)
            let segRange = CMTimeRange(start: assetStartTime + segStart, duration: segEnd - segStart)

            do {
                try compositionTrack.insertTimeRange(segRange, of: sourceVideoTrack, at: insertTime)

                // Scale this segment's duration if speed != 1x
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
                NSLog("Blink: Failed to insert segment %.1f-%.1f: %@", mapping.sourceStart, mapping.sourceEnd, error.localizedDescription)
            }
        }

        let editedDuration = insertTime.seconds
        NSLog("Blink: Composition built: %.1fs → %.1fs", durationSecs, editedDuration)

        // 3. Export
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw NSError(domain: "Blink", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        NSLog("Blink: Exporting...")
        await exportSession.export()

        if let error = exportSession.error {
            NSLog("Blink: Export failed: %@", error.localizedDescription)
            throw error
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        NSLog("Blink: Export done! %d bytes at %@", fileSize, outputURL.path)

        return Output(url: outputURL, originalDuration: durationSecs, editedDuration: editedDuration)
    }
}
