// Blink/Capture/RecordingSession.swift
import Foundation

final class RecordingSession {
    private let recorder = ScreenRecorder()
    private let eventLogger = EventLogger()
    private let storage: StorageManager
    private var sessionDir: URL?

    init(storage: StorageManager) {
        self.storage = storage
    }

    struct Result {
        let videoURL: URL
        let events: [LoggedEvent]
        let sessionDir: URL
    }

    func start(captureAudio: Bool, captureMicrophone: Bool) async throws {
        let dir = storage.newSessionDir()
        sessionDir = dir
        let videoURL = dir.appendingPathComponent("raw.mov")

        eventLogger.start()
        try await recorder.start(outputURL: videoURL, captureAudio: captureAudio, captureMicrophone: captureMicrophone)
    }

    func stop() async -> Result? {
        let events = eventLogger.stop()
        guard let videoURL = await recorder.stop(),
              let dir = sessionDir else { return nil }

        let eventLogURL = dir.appendingPathComponent("events.jsonl")
        try? eventLogger.writeToFile(at: eventLogURL)

        return Result(videoURL: videoURL, events: events, sessionDir: dir)
    }
}
