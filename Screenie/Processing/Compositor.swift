import Foundation
import AVFoundation
import CoreImage

struct CompositorOutput {
    let clipboardURL: URL
    let archiveURL: URL
    let duration: TimeInterval
}

final class Compositor {
    private let storage: StorageManager

    init(storage: StorageManager) {
        self.storage = storage
    }

    func process(result: RecordingSession.Result) async throws -> CompositorOutput {
        let asset = AVURLAsset(url: result.videoURL)
        let duration = try await asset.load(.duration).seconds
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first!
        let naturalSize = try await videoTrack.load(.naturalSize)

        // 1. Analyze activity
        let timeline = ActivityAnalyzer.analyze(events: result.events, duration: duration)

        // 2. Map speeds
        let timeMappings = SpeedMapper.map(segments: timeline)

        // 3. Generate zoom frames
        let zoomFrames = ZoomEngine.generateFrames(
            events: result.events,
            screenSize: naturalSize,
            timeMappings: timeMappings,
            duration: duration
        )

        // 4. Build composition with speed changes
        let composition = AVMutableComposition()
        let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!

        var insertTime = CMTime.zero
        for mapping in timeMappings {
            let sourceStart = CMTime(seconds: mapping.sourceStart, preferredTimescale: 600)
            let sourceEnd = CMTime(seconds: mapping.sourceEnd, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: sourceStart, end: sourceEnd)

            try videoCompositionTrack.insertTimeRange(sourceRange, of: videoTrack, at: insertTime)

            let segmentDuration = sourceEnd - sourceStart
            let scaledDuration = CMTime(seconds: mapping.outputDuration, preferredTimescale: 600)
            let insertRange = CMTimeRange(start: insertTime, duration: segmentDuration)
            videoCompositionTrack.scaleTimeRange(insertRange, toDuration: scaledDuration)

            insertTime = insertTime + scaledDuration
        }

        // Handle audio track if present
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let audioCompTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )!

            var audioInsert = CMTime.zero
            for mapping in timeMappings {
                let sourceStart = CMTime(seconds: mapping.sourceStart, preferredTimescale: 600)
                let sourceEnd = CMTime(seconds: mapping.sourceEnd, preferredTimescale: 600)
                let sourceRange = CMTimeRange(start: sourceStart, end: sourceEnd)

                try audioCompTrack.insertTimeRange(sourceRange, of: audioTrack, at: audioInsert)

                let segmentDuration = sourceEnd - sourceStart
                let scaledDuration = CMTime(seconds: mapping.outputDuration, preferredTimescale: 600)
                let insertRange = CMTimeRange(start: audioInsert, duration: segmentDuration)
                audioCompTrack.scaleTimeRange(insertRange, toDuration: scaledDuration)

                audioInsert = audioInsert + scaledDuration
            }
        }

        // 5. Build video composition for zoom
        let videoComposition = buildZoomComposition(
            composition: composition,
            zoomFrames: zoomFrames,
            timeMappings: timeMappings,
            naturalSize: naturalSize
        )

        // 6. Build audio mix to fade fast segments
        let audioMix = buildAudioMix(
            composition: composition,
            timeMappings: timeMappings
        )

        // 7. Dual export — clipboard first, archive in background
        let sessionDir = result.sessionDir
        let clipboardURL = sessionDir.appendingPathComponent("clipboard.mp4")
        let archiveURL = storage.archivePath()

        let outputDuration = timeMappings.reduce(0.0) { $0 + $1.outputDuration }

        let output = CompositorOutput(
            clipboardURL: clipboardURL,
            archiveURL: archiveURL,
            duration: outputDuration
        )

        // Clipboard export (fast, compressed) — awaited
        try await export(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            outputURL: clipboardURL,
            preset: AVAssetExportPreset1920x1080,
            fileType: .mp4
        )

        // Archive export runs in background
        Task.detached { [self] in
            try? await self.export(
                composition: composition,
                videoComposition: videoComposition,
                audioMix: audioMix,
                outputURL: archiveURL,
                preset: AVAssetExportPresetHEVCHighestQuality,
                fileType: .mp4
            )
        }

        return output
    }

    private func export(
        composition: AVComposition,
        videoComposition: AVVideoComposition?,
        audioMix: AVAudioMix?,
        outputURL: URL,
        preset: String,
        fileType: AVFileType
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw NSError(domain: "Screenie", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
        }
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.videoComposition = videoComposition
        session.audioMix = audioMix

        await session.export()

        if let error = session.error {
            throw error
        }
    }

    private func buildZoomComposition(
        composition: AVComposition,
        zoomFrames: [ZoomFrame],
        timeMappings: [TimeMapping],
        naturalSize: CGSize
    ) -> AVVideoComposition? {
        guard zoomFrames.contains(where: { $0.zoomLevel > 1.0 }) else { return nil }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        if let track = composition.tracks(withMediaType: .video).first {
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

            var wasZoomed = false
            for frame in zoomFrames {
                let outputTime = sourceTimeToOutputTime(
                    sourceTime: frame.timestamp,
                    timeMappings: timeMappings
                )
                let time = CMTime(seconds: outputTime, preferredTimescale: 600)

                if frame.zoomLevel > 1.0 {
                    let scaleX = naturalSize.width / frame.cropRect.width
                    let scaleY = naturalSize.height / frame.cropRect.height
                    let translateX = -frame.cropRect.origin.x * scaleX
                    let translateY = -frame.cropRect.origin.y * scaleY

                    var transform = CGAffineTransform.identity
                    transform = transform.scaledBy(x: scaleX, y: scaleY)
                    transform = transform.translatedBy(x: translateX / scaleX, y: translateY / scaleY)

                    layerInstruction.setTransform(transform, at: time)
                    wasZoomed = true
                } else if wasZoomed {
                    // Reset to identity so the video doesn't stay stuck zoomed in
                    layerInstruction.setTransform(.identity, at: time)
                    wasZoomed = false
                }
            }

            instruction.layerInstructions = [layerInstruction]
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.instructions = [instruction]
        videoComp.renderSize = naturalSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)

        return videoComp
    }

    private func buildAudioMix(
        composition: AVComposition,
        timeMappings: [TimeMapping]
    ) -> AVAudioMix? {
        guard let audioTrack = composition.tracks(withMediaType: .audio).first else { return nil }

        let params = AVMutableAudioMixInputParameters(track: audioTrack)

        var outputTime = 0.0
        for mapping in timeMappings {
            let volume: Float = mapping.speed > 2.0 ? 0.0 : 1.0
            let time = CMTime(seconds: outputTime, preferredTimescale: 600)
            params.setVolume(volume, at: time)
            outputTime += mapping.outputDuration
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    func sourceTimeToOutputTime(
        sourceTime: TimeInterval,
        timeMappings: [TimeMapping]
    ) -> TimeInterval {
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
