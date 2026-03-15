// Blink/Capture/ScreenRecorder.swift
import Foundation
import ScreenCaptureKit
import AVFoundation

final class ScreenRecorder: NSObject {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isRecording = false
    private var sessionStarted = false
    private var outputURL: URL?
    private var frameCount = 0
    private var lastVideoTimestamp = CMTime.invalid
    private var lastAudioTimestamp = CMTime.invalid

    func start(outputURL: URL, captureAudio: Bool, captureMicrophone: Bool) async throws {
        self.outputURL = outputURL
        sessionStarted = false
        frameCount = 0
        lastVideoTimestamp = .invalid
        lastAudioTimestamp = .invalid

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
        config.capturesAudio = captureAudio

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
            audioInput = aInput
        }

        assetWriter = writer
        writer.startWriting()
        // Don't start session yet — we'll start it with the first sample buffer's timestamp

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }
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
        audioInput?.markAsFinished()

        if let writer = assetWriter, writer.status == .writing {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    NSLog("Blink: AVAssetWriter finished, status=%d", writer.status.rawValue)
                    continuation.resume()
                }
            }
        }

        // Verify the file was actually written
        if let url = outputURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            NSLog("Blink: Output file size: %d bytes at %@", size, url.path)
            if size == 0 {
                NSLog("Blink: WARNING — output file is empty!")
                return nil
            }
        }

        return outputURL
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Blink: SCStream stopped with error: \(error.localizedDescription)")
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let writer = assetWriter, writer.status == .writing else { return }

        // Start session with first sample buffer's timestamp
        if !sessionStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
            NSLog("Blink: Session started at timestamp %.3f", timestamp.seconds)
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch type {
        case .screen:
            // Skip out-of-order frames
            if lastVideoTimestamp.isValid && timestamp <= lastVideoTimestamp {
                return
            }
            lastVideoTimestamp = timestamp
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
                frameCount += 1
            }
        case .audio:
            if lastAudioTimestamp.isValid && timestamp <= lastAudioTimestamp {
                return
            }
            lastAudioTimestamp = timestamp
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }
}
