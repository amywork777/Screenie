// Blink/App/AppDelegate.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeyListener = HotkeyListener()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyListener.delegate = self
        let success = hotkeyListener.start()
        if !success {
            NSLog("Blink: Failed to start hotkey listener — check Accessibility permission")
        } else {
            NSLog("Blink: Hotkey listener started — hold or double-tap Right Option to record")
        }
    }
}

extension AppDelegate: HotkeyListenerDelegate {
    func hotkeyListenerDidRequestStart() {
        NSLog("Blink: Recording START requested")
    }

    func hotkeyListenerDidRequestStop() {
        NSLog("Blink: Recording STOP requested")
    }
}
