import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyListener = HotkeyListener()
    private let storage = StorageManager()
    private lazy var menuBar = MenuBarController(storage: storage)
    private let recordingIndicator = RecordingIndicator()
    private var previewHUD: PreviewHUD?
    private var session: RecordingSession?
    private var onboardingWindow: OnboardingWindow?
    private let settings = Settings.shared

    private let startSound = NSSound(named: "Tink")
    private let stopSound = NSSound(named: "Pop")

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.delegate = self
        menuBar.setup()

        updateLoginItem()

        if !settings.hasCompletedOnboarding {
            showOnboarding()
        } else {
            startListening()
        }
    }

    private func showOnboarding() {
        let window = OnboardingWindow { [weak self] in
            self?.startListening()
            self?.onboardingWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func startListening() {
        hotkeyListener.delegate = self
        let success = hotkeyListener.start()
        if !success {
            NSLog("Blink: Accessibility permission required for hotkey")
        }
        menuBar.setTooltip("Hold Right Option to record")
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

        let newSession = RecordingSession(storage: storage)
        session = newSession

        Task {
            do {
                try await newSession.start(
                    captureAudio: settings.captureAudio,
                    captureMicrophone: settings.captureMicrophone
                )
            } catch {
                NSLog("Blink: Recording failed: \(error)")
                recordingIndicator.hide()
                menuBar.showRecordingState(false)
                session = nil
            }
        }
    }

    private func stopRecording() {
        guard let currentSession = session else { return }
        stopSound?.play()
        recordingIndicator.hide()
        menuBar.showRecordingState(false)

        recordingIndicator.showProcessing()

        session = nil

        Task {
            guard let result = await currentSession.stop() else { return }

            let compositor = Compositor(storage: storage)
            do {
                let output = try await compositor.process(result: result)

                await MainActor.run {
                    recordingIndicator.hide()
                    showPreview(output: output)
                    menuBar.refreshMenu()
                }

                storage.cleanupSession(dir: result.sessionDir)
            } catch {
                NSLog("Blink: Processing failed: \(error)")
                await MainActor.run { recordingIndicator.hide() }
            }
        }
    }

    private func showPreview(output: CompositorOutput) {
        let hud = PreviewHUD()
        hud.hudDelegate = self
        hud.show(
            clipboardURL: output.clipboardURL,
            archiveURL: output.archiveURL,
            duration: output.duration
        )
        previewHUD = hud
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
