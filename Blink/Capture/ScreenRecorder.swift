// Blink/Capture/ScreenRecorder.swift
import Foundation
import ScreenCaptureKit
import AVFoundation

final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var isRecording = false
    private var outputURL: URL?
    private var frameCount = 0
    private var firstTimestamp: CMTime?
    private var lastNormalizedTimestamp = CMTime.invalid

    func start(outputURL: URL, captureAudio: Bool, captureMicrophone: Bool) async throws {
        self.outputURL = outputURL
        frameCount = 0
        firstTimestamp = nil
        lastNormalizedTimestamp = .invalid

        let content = try await SCShareableContent.current
        let mouseLocation = NSEvent.mouseLocation
        let display = content.displays.first { display in
            let frame = CGRect(x: display.frame.origin.x,
                               y: display.frame.origin.y,
                               width: CGFloat(display.width),
                               height: CGFloat(display.height))
            return frame.contains(mouseLocation)
        } ?? content.displays.first!

        NSLog("Blink: Capturing display %dx%d", display.width, display.height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        // No audio — simplifies recording and prevents corruption
        config.capturesAudio = false

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.width,
            AVVideoHeightKey: display.height,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        writer.add(vInput)
        videoInput = vInput

        assetWriter = writer
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        self.stream = stream
        try await stream.startCapture()
        isRecording = true
        NSLog("Blink: SCStream capture started")
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        NSLog("Blink: Stopping capture, %d frames written", frameCount)

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        videoInput?.markAsFinished()

        if let writer = assetWriter, writer.status == .writing {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    NSLog("Blink: AVAssetWriter finished, status=%d", writer.status.rawValue)
                    continuation.resume()
                }
            }
        } else if let writer = assetWriter {
            NSLog("Blink: AVAssetWriter status=%d, error=%@", writer.status.rawValue, writer.error?.localizedDescription ?? "none")
        }

        if let url = outputURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            NSLog("Blink: Output file size: %d bytes at %@", size, url.path)
            if size == 0 {
                return nil
            }
        }

        return outputURL
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Blink: SCStream error: \(error.localizedDescription)")
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }

        let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Record first timestamp as the base offset
        if firstTimestamp == nil {
            firstTimestamp = originalTimestamp
            NSLog("Blink: First frame at %.3f", originalTimestamp.seconds)
        }

        // Normalize to zero-based timestamp
        let normalized = originalTimestamp - firstTimestamp!

        // Skip out-of-order frames
        if lastNormalizedTimestamp.isValid && normalized <= lastNormalizedTimestamp {
            return
        }
        lastNormalizedTimestamp = normalized

        // Create a copy of the sample buffer with the normalized timestamp
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: normalized,
            decodeTimeStamp: .invalid
        )

        var newBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newBuffer
        )

        guard status == noErr, let buffer = newBuffer else { return }

        if let videoInput, videoInput.isReadyForMoreMediaData {
            videoInput.append(buffer)
            frameCount += 1
        }
    }
}
