import AppKit
import AVFoundation
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let hotkeyListener = HotkeyListener()
    private let storage = StorageManager()
    private lazy var menuBar = MenuBarController(storage: storage)
    private let recordingIndicator = RecordingIndicator()
    private var previewHUD: PreviewHUD?
    private var session: RecordingSession?
    private var mainWindow: MainWindow?
    private let settings = Settings.shared

    private let startSound = NSSound(named: "Tink")
    private let stopSound = NSSound(named: "Pop")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Blink: applicationDidFinishLaunching")

        menuBar.delegate = self
        menuBar.setup()

        // Always show the main window on launch
        showMainWindow()

        // Start hotkey listener
        startListening()

        settings.hasCompletedOnboarding = true
    }

    private func showMainWindow() {
        let window = MainWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mainWindow = window
    }

    private func startListening() {
        hotkeyListener.delegate = self
        let success = hotkeyListener.start()
        if success {
            NSLog("Blink: Hotkey listener started — hold Right Option to record!")
            mainWindow?.updateHotkeyStatus(granted: true)
        } else {
            NSLog("Blink: Accessibility permission required")
            mainWindow?.updateHotkeyStatus(granted: false)
        }
        menuBar.setTooltip("Hold Right Option to record")

        // Re-check accessibility every 2 seconds until granted
        if !success {
            retryHotkeyListener()
        }
    }

    private func retryHotkeyListener() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let success = self.hotkeyListener.start()
            if success {
                NSLog("Blink: Hotkey listener started after permission grant!")
                self.mainWindow?.updateHotkeyStatus(granted: true)
                self.mainWindow?.updateRecordingStatus(false)
            } else {
                self.retryHotkeyListener()
            }
        }
    }

    func updateLoginItem() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if settings.autoStart {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                NSLog("Blink: Login item update failed: \(error)")
            }
        }
    }

    private func startRecording() {
        guard session == nil else { return }
        startSound?.play()
        recordingIndicator.show()
        menuBar.showRecordingState(true)
        mainWindow?.updateRecordingStatus(true)

        let newSession = RecordingSession(storage: storage)
        session = newSession

        Task {
            do {
                try await newSession.start(
                    captureAudio: settings.captureAudio,
                    captureMicrophone: settings.captureMicrophone
                )
                NSLog("Blink: Recording started!")
            } catch {
                NSLog("Blink: Recording failed: \(error)")
                await MainActor.run {
                    recordingIndicator.hide()
                    menuBar.showRecordingState(false)
                    mainWindow?.updateRecordingStatus(false)
                    session = nil
                }
            }
        }
    }

    private func stopRecording() {
        guard let currentSession = session else { return }
        stopSound?.play()
        recordingIndicator.hide()
        menuBar.showRecordingState(false)
        mainWindow?.updateRecordingStatus(false)

        session = nil

        Task {
            guard let result = await currentSession.stop() else {
                NSLog("Blink: Recording session returned nil")
                return
            }

            NSLog("Blink: Recording done — %d events, video at %@", result.events.count, result.videoURL.path)

            // Copy raw recording to archive folder directly (skip processing for now)
            let archiveURL = storage.archivePath()
            do {
                try FileManager.default.copyItem(at: result.videoURL, to: archiveURL)
                NSLog("Blink: Saved to %@", archiveURL.path)
            } catch {
                NSLog("Blink: Failed to copy to archive: %@", error.localizedDescription)
            }

            // Copy to clipboard as a file
            await MainActor.run {
                copyFileToClipboard(archiveURL)
                menuBar.refreshMenu()

                // Show notification
                showSavedNotification(url: archiveURL)
            }

            // Clean up temp files
            storage.cleanupSession(dir: result.sessionDir)
        }
    }

    private func copyFileToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        NSLog("Blink: File copied to clipboard")
    }

    private func showSavedNotification(url: URL) {
        // Show a small alert with the file path and an Open button
        let alert = NSAlert()
        alert.messageText = "Recording Saved"
        alert.informativeText = url.lastPathComponent
        alert.addButton(withTitle: "Open in Finder")
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // Re-open window when dock icon clicked
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }
}

extension AppDelegate: HotkeyListenerDelegate {
    func hotkeyListenerDidRequestStart() {
        startRecording()
    }

    func hotkeyListenerDidRequestStop() {
        stopRecording()
    }
}

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidSelectRecording(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    func menuBarDidSelectQuit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: PreviewHUDDelegate {
    func previewHUDDidDiscard(clipboardURL: URL, archiveURL: URL) {
        try? FileManager.default.removeItem(at: clipboardURL)
        try? FileManager.default.removeItem(at: archiveURL)
    }
}
