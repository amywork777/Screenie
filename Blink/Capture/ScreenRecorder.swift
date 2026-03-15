// Blink/Capture/ScreenRecorder.swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreVideo

final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var outputURL: URL?
    private var frameCount = 0
    private var firstTimestamp: CMTime?
    private var lastTimestamp = CMTime.invalid

    func start(outputURL: URL, captureAudio: Bool, captureMicrophone: Bool) async throws {
        self.outputURL = outputURL
        frameCount = 0
        firstTimestamp = nil
        lastTimestamp = .invalid

        let content = try await SCShareableContent.current
        let mouseLocation = NSEvent.mouseLocation
        let display = content.displays.first { display in
            let frame = CGRect(x: display.frame.origin.x,
                               y: display.frame.origin.y,
                               width: CGFloat(display.width),
                               height: CGFloat(display.height))
            return frame.contains(mouseLocation)
        } ?? content.displays.first!

        let w = display.width
        let h = display.height
        NSLog("Blink: Capturing display %dx%d", w, h)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.capturesAudio = false
        // Request BGRA pixel format for compatibility
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writerInput = input

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ]
        )
        pixelBufferAdaptor = adaptor

        assetWriter = writer
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        self.stream = stream
        try await stream.startCapture()
        isRecording = true
        NSLog("Blink: Capture started (HEVC, pixel buffer adaptor)")
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        NSLog("Blink: Stopping capture, %d frames written", frameCount)

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        writerInput?.markAsFinished()

        if let writer = assetWriter, writer.status == .writing {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    NSLog("Blink: Writer finished, status=%d", writer.status.rawValue)
                    continuation.resume()
                }
            }
        } else if let writer = assetWriter {
            NSLog("Blink: Writer status=%d, error=%@", writer.status.rawValue, writer.error?.localizedDescription ?? "none")
        }

        if let url = outputURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            NSLog("Blink: File: %d bytes at %@", size, url.path)
            if size == 0 { return nil }
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
        guard let adaptor = pixelBufferAdaptor, let input = writerInput else { return }

        // Get pixel buffer from sample buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstTimestamp == nil {
            firstTimestamp = originalTimestamp
            NSLog("Blink: First frame at %.3f", originalTimestamp.seconds)
        }

        // Normalize timestamp to start at zero
        let normalized = originalTimestamp - firstTimestamp!

        // Skip out-of-order or duplicate frames
        if lastTimestamp.isValid && normalized <= lastTimestamp {
            return
        }
        lastTimestamp = normalized

        // Write pixel buffer through adaptor
        if input.isReadyForMoreMediaData {
            let success = adaptor.append(pixelBuffer, withPresentationTime: normalized)
            if success {
                frameCount += 1
            } else {
                NSLog("Blink: Frame append failed at %.3f, writer status=%d", normalized.seconds, writer.status.rawValue)
            }
        }
    }
}
