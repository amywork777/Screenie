// Screenie/Capture/RecordingSession.swift
import Foundation

final class RecordingSession {
    private let recorder = ScreenRecorder()
    private let micRecorder = MicRecorder()
    private let eventLogger = EventLogger()
    private let storage: StorageManager
    private var sessionDir: URL?

    init(storage: StorageManager) {
        self.storage = storage
    }

    struct Result {
        let videoURL: URL
        let micAudioURL: URL?  // separate mic track, nil if mic not enabled
        let events: [LoggedEvent]
        let sessionDir: URL
    }

    func start(captureAudio: Bool, captureMicrophone: Bool) async throws {
        let dir = storage.newSessionDir()
        sessionDir = dir
        let videoURL = dir.appendingPathComponent("raw.mov")

        // Start recorder first — ScreenCaptureKit takes time to initialize
        // Then start event logger so clocks are synced with first video frame
        try await recorder.start(outputURL: videoURL, captureAudio: captureAudio, captureMicrophone: captureMicrophone)
        eventLogger.start()

        // Start mic recording separately
        if captureMicrophone {
            let micURL = dir.appendingPathComponent("mic.m4a")
            try? micRecorder.start(outputURL: micURL)
        }
    }

    func stop() async -> Result? {
        let events = eventLogger.stop()
        let micURL = await micRecorder.stop()
        guard let videoURL = await recorder.stop(),
              let dir = sessionDir else { return nil }

        let eventLogURL = dir.appendingPathComponent("events.jsonl")
        try? eventLogger.writeToFile(at: eventLogURL)

        return Result(videoURL: videoURL, micAudioURL: micURL, events: events, sessionDir: dir)
    }
}
