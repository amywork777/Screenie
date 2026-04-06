import AppKit
import AVFoundation
import ServiceManagement
import UserNotifications

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
    private let floatingIndicator = FloatingIndicator()
    private var previewHUD: PreviewHUD?
    private var session: RecordingSession?
    private var mainWindow: MainWindow?
    private let settings = Settings.shared
    private let sounds = SoundEffects.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Screenie: applicationDidFinishLaunching")

        // App icon comes from Screenie.icns in the bundle — no runtime generation needed

        menuBar.delegate = self
        menuBar.setup()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !settings.hasCompletedOnboarding {
            // First launch — show guided onboarding
            NSLog("Screenie: Showing onboarding")
            showOnboarding()
        } else {
            // Already set up — go straight to main window
            showMainWindow()
            startListening()
        }
    }

    private func showOnboarding() {
        let window = OnboardingWindow { [weak self] in
            guard let self else { return }
            NSLog("Screenie: Onboarding complete")
            self.showMainWindow()
            self.startListening()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        onboardingWindow = window
    }

    private var onboardingWindow: OnboardingWindow?

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
            NSLog("Screenie: Hotkey listener started — double-tap Right Control to record!")
            mainWindow?.updateHotkeyStatus(granted: true)
        } else {
            NSLog("Screenie: Accessibility permission required")
            mainWindow?.updateHotkeyStatus(granted: false)
        }
        menuBar.setTooltip("Double-tap Right Control to record")

        // Re-check accessibility every 2 seconds until granted
        if !success {
            retryHotkeyListener()
        }
    }

    private var retryCount = 0

    private func retryHotkeyListener() {
        retryCount += 1
        // Stop retrying after 30 attempts (60 seconds)
        guard retryCount < 30 else {
            NSLog("Screenie: Gave up retrying accessibility — user can restart app after granting")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let success = self.hotkeyListener.start()
            if success {
                NSLog("Screenie: Hotkey listener started after permission grant!")
                self.mainWindow?.updateHotkeyStatus(granted: true)
                self.mainWindow?.updateRecordingStatus(false)
                self.retryCount = 0
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
                NSLog("Screenie: Login item update failed: \(error)")
            }
        }
    }

    private func startRecording() {
        guard session == nil else { return }
        sounds.playStart()
        recordingIndicator.show()
        floatingIndicator.show()
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
                NSLog("Screenie: Recording started!")
            } catch {
                NSLog("Screenie: Recording failed: \(error)")
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
        sounds.playStop()
        recordingIndicator.hide()
        menuBar.showRecordingState(false)
        mainWindow?.updateRecordingStatus(false)

        // Switch floating indicator to processing mode
        floatingIndicator.showProcessing()

        session = nil

        Task {
            guard let result = await currentSession.stop() else {
                NSLog("Screenie: Recording session returned nil")
                await MainActor.run { floatingIndicator.hide() }
                return
            }

            NSLog("Screenie: Recording done — %d events, video at %@", result.events.count, result.videoURL.path)

            let archiveURL = storage.archivePath()
            let editor = SimpleEditor()
            editor.onProgress = { [weak self] progress in
                self?.floatingIndicator.updateProgress(progress)
            }

            do {
                let output = try await editor.process(
                    videoURL: result.videoURL,
                    micAudioURL: result.micAudioURL,
                    events: result.events,
                    outputURL: archiveURL
                )
                NSLog("Screenie: Auto-edit complete: %.1fs → %.1fs", output.originalDuration, output.editedDuration)

                await MainActor.run {
                    floatingIndicator.hide()
                    copyFileToClipboard(archiveURL)
                    menuBar.refreshMenu()

                    let hud = PreviewHUD()
                    hud.hudDelegate = self
                    hud.show(
                        clipboardURL: archiveURL,
                        archiveURL: archiveURL,
                        duration: output.editedDuration,
                        originalDuration: output.originalDuration
                    )
                    previewHUD = hud

                    sendCompletionNotification(duration: output.editedDuration)
                }
            } catch {
                NSLog("Screenie: Auto-edit failed: %@, saving raw instead", "\(error)")
                // Fallback: save raw recording (only if it's a valid file)
                let rawSize = (try? FileManager.default.attributesOfItem(atPath: result.videoURL.path)[.size] as? Int) ?? 0
                if rawSize > 1000 {
                    try? FileManager.default.copyItem(at: result.videoURL, to: archiveURL)
                } else {
                    NSLog("Screenie: Raw file too small (%d bytes), not saving", rawSize)
                    storage.cleanupSession(dir: result.sessionDir)
                    return
                }
                await MainActor.run {
                    floatingIndicator.hide()
                    copyFileToClipboard(archiveURL)
                    menuBar.refreshMenu()

                    let hud = PreviewHUD()
                    hud.hudDelegate = self
                    hud.show(clipboardURL: archiveURL, archiveURL: archiveURL, duration: 0, originalDuration: 0)
                    previewHUD = hud
                }
            }

            // Clean up temp files
            storage.cleanupSession(dir: result.sessionDir)
        }
    }

    private func sendCompletionNotification(duration: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Recording ready"
        content.body = String(format: "%.0fs video copied to clipboard", duration)
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func copyFileToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        NSLog("Screenie: File copied to clipboard")
    }

    private func showSavedNotification(url: URL, original: Double, edited: Double) {
        let alert = NSAlert()
        alert.messageText = "Recording Saved"
        if original > 0 && edited > 0 && edited < original {
            alert.informativeText = String(format: "%@ — %.1fs → %.1fs (%.0f%% shorter)",
                                           url.lastPathComponent, original, edited,
                                           (1.0 - edited / original) * 100)
        } else {
            alert.informativeText = url.lastPathComponent
        }
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
