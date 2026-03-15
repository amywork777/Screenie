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
    private var outputURL: URL?

    func start(outputURL: URL, captureAudio: Bool, captureMicrophone: Bool) async throws {
        self.outputURL = outputURL

        let content = try await SCShareableContent.current
        let mouseLocation = NSEvent.mouseLocation
        let display = content.displays.first { display in
            let frame = CGRect(x: display.frame.origin.x,
                               y: display.frame.origin.y,
                               width: CGFloat(display.width),
                               height: CGFloat(display.height))
            return frame.contains(mouseLocation)
        } ?? content.displays.first!

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = captureAudio

        if captureMicrophone {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

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
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)
            audioInput = aInput
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
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            assetWriter?.finishWriting {
                continuation.resume()
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

        switch type {
        case .screen:
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sampleBuffer)
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }
}
