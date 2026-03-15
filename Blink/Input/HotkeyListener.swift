// Blink/Input/HotkeyListener.swift
import Foundation
import AppKit
import ApplicationServices

protocol HotkeyListenerDelegate: AnyObject {
    func hotkeyListenerDidRequestStart()
    func hotkeyListenerDidRequestStop()
}

final class HotkeyListener {
    weak var delegate: HotkeyListenerDelegate?

    private let state = InputState()
    private var doubleTapTimer: DispatchWorkItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private let doubleTapWindow: TimeInterval = 0.35
    private let rightOptionKeyCode: UInt16 = 61 // 0x3D

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func start() -> Bool {
        if !HotkeyListener.isAccessibilityGranted {
            NSLog("Blink: Accessibility not granted, prompting...")
            HotkeyListener.promptAccessibility()
            return false
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        NSLog("Blink: Event monitors installed (double-tap Right Option to record)")
        return globalMonitor != nil
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        doubleTapTimer?.cancel()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        guard keyCode == rightOptionKeyCode else { return }

        let isDown = event.modifierFlags.contains(.option)

        if isDown {
            onKeyDown()
        } else {
            onKeyUp()
        }
    }

    private func onKeyDown() {
        let action = state.handleKeyDown()
        dispatchAction(action)
    }

    private func onKeyUp() {
        let action = state.handleKeyUp()
        dispatchAction(action)

        // Start double-tap timeout
        doubleTapTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            _ = self.state.handleDoubleTapTimerFired()
        }
        doubleTapTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: timer)
    }

    private func dispatchAction(_ action: InputAction?) {
        switch action {
        case .startRecording:
            NSLog("Blink: >>> START RECORDING <<<")
            delegate?.hotkeyListenerDidRequestStart()
        case .stopRecording:
            NSLog("Blink: >>> STOP RECORDING <<<")
            delegate?.hotkeyListenerDidRequestStop()
        case nil:
            break
        }
    }
}
