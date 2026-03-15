// Blink/App/AppDelegate.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyListener = HotkeyListener()
    private let storage = StorageManager()
    private var session: RecordingSession?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyListener.delegate = self
        let success = hotkeyListener.start()
        NSLog("Blink: Hotkey listener \(success ? "started" : "FAILED")")
    }
}

extension AppDelegate: HotkeyListenerDelegate {
    func hotkeyListenerDidRequestStart() {
        NSLog("Blink: Starting recording...")
        let session = RecordingSession(storage: storage)
        self.session = session
        Task {
            do {
                try await session.start(captureAudio: false, captureMicrophone: false)
                NSLog("Blink: Recording started")
            } catch {
                NSLog("Blink: Failed to start recording: \(error)")
            }
        }
    }

    func hotkeyListenerDidRequestStop() {
        NSLog("Blink: Stopping recording...")
        guard let session else { return }
        Task {
            if let result = await session.stop() {
                NSLog("Blink: Recording saved to \(result.videoURL.path)")
                NSLog("Blink: Captured \(result.events.count) events")
            }
            self.session = nil
        }
    }
}
