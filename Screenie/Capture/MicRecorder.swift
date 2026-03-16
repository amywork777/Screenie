// Screenie/Capture/MicRecorder.swift
// Records microphone audio to a separate .m4a file
import AVFoundation

final class MicRecorder: NSObject {
    private var captureSession: AVCaptureSession?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var isRecording = false
    private var outputURL: URL?
    private var firstTimestamp: CMTime?
    private var sampleCount = 0

    func start(outputURL: URL) throws {
        self.outputURL = outputURL
        firstTimestamp = nil
        sampleCount = 0

        // Request mic permission
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            NSLog("Screenie: Mic permission requested")
            return
        }
        guard status == .authorized else {
            NSLog("Screenie: Mic permission not granted (status=%d)", status.rawValue)
            return
        }

        // Set up capture session
        let session = AVCaptureSession()
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            NSLog("Screenie: No microphone found")
            return
        }

        let micInput = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(micInput) else { return }
        session.addInput(micInput)

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: .global(qos: .userInteractive))
        guard session.canAddOutput(audioOutput) else { return }
        session.addOutput(audioOutput)

        // Set up writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        self.assetWriter = writer
        self.writerInput = input
        self.captureSession = session

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        session.startRunning()
        isRecording = true
        NSLog("Screenie: Mic recording started")
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        captureSession?.stopRunning()
        captureSession = nil

        writerInput?.markAsFinished()

        if let writer = assetWriter, writer.status == .writing {
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
        }

        NSLog("Screenie: Mic recording stopped — %d samples", sampleCount)
        return sampleCount > 0 ? outputURL : nil
    }
}

extension MicRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter, writer.status == .writing else { return }
        guard let input = writerInput, input.isReadyForMoreMediaData else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if firstTimestamp == nil {
            firstTimestamp = timestamp
            NSLog("Screenie: First mic sample at %.3f", timestamp.seconds)
        }

        // Normalize timestamp
        let normalized = timestamp - firstTimestamp!

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: normalized,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleBufferOut: &retimed
        )

        if let buf = retimed {
            input.append(buf)
            sampleCount += 1
        }
    }
}
