// Blink/Capture/ScreenRecorder.swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreVideo

final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecording = false
    private var outputURL: URL?
    private var frameCount = 0
    private var audioSampleCount = 0
    private var firstVideoTimestamp: CMTime?
    private var firstAudioTimestamp: CMTime?
    private var lastVideoTimestamp = CMTime.invalid

    func start(outputURL: URL, captureAudio: Bool, captureMicrophone: Bool) async throws {
        self.outputURL = outputURL
        frameCount = 0
        audioSampleCount = 0
        firstVideoTimestamp = nil
        firstAudioTimestamp = nil
        lastVideoTimestamp = .invalid

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
        NSLog("Blink: Capturing display %dx%d, audio=%d", w, h, captureAudio ? 1 : 0)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = captureAudio
        if captureAudio {
            config.sampleRate = 48000
            config.channelCount = 2
        }

        // Remove existing file if present (prevents -12412 error)
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
            ] as [String: Any],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        writer.add(vInput)
        videoWriterInput = vInput

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ]
        )
        pixelBufferAdaptor = adaptor

        // Audio input (AAC encoding, accepts raw PCM from ScreenCaptureKit)
        if captureAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)
            audioWriterInput = aInput
        }

        assetWriter = writer
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }
        self.stream = stream
        try await stream.startCapture()
        isRecording = true
        NSLog("Blink: Capture started (HEVC + %@)", captureAudio ? "AAC audio" : "no audio")
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        NSLog("Blink: Stopping — %d video frames, %d audio samples", frameCount, audioSampleCount)

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

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
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }

        let originalTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch type {
        case .screen:
            handleVideoSample(sampleBuffer, timestamp: originalTimestamp)
        case .audio:
            handleAudioSample(sampleBuffer, timestamp: originalTimestamp)
        @unknown default:
            break
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        guard let adaptor = pixelBufferAdaptor, let input = videoWriterInput else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if firstVideoTimestamp == nil {
            firstVideoTimestamp = timestamp
            NSLog("Blink: First video frame at %.3f", timestamp.seconds)
        }

        let normalized = timestamp - firstVideoTimestamp!

        // Skip out-of-order frames
        if lastVideoTimestamp.isValid && normalized <= lastVideoTimestamp { return }
        lastVideoTimestamp = normalized

        if input.isReadyForMoreMediaData {
            if adaptor.append(pixelBuffer, withPresentationTime: normalized) {
                frameCount += 1
            }
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer, timestamp: CMTime) {
        guard let input = audioWriterInput else { return }

        if firstAudioTimestamp == nil {
            firstAudioTimestamp = timestamp
            NSLog("Blink: First audio sample at %.3f", timestamp.seconds)
        }

        // Normalize audio timestamp relative to first audio sample
        let normalized = timestamp - firstAudioTimestamp!

        // Create retimed audio sample buffer
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: normalized,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &retimed
        )

        guard let audioBuffer = retimed else { return }

        if input.isReadyForMoreMediaData {
            input.append(audioBuffer)
            audioSampleCount += 1
        }
    }
}
