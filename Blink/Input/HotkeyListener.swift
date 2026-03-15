// Blink/Input/HotkeyListener.swift
import Foundation
import CoreGraphics

protocol HotkeyListenerDelegate: AnyObject {
    func hotkeyListenerDidRequestStart()
    func hotkeyListenerDidRequestStop()
}

final class HotkeyListener {
    weak var delegate: HotkeyListenerDelegate?

    private let state = InputState()
    private var holdTimer: DispatchWorkItem?
    private var doubleTapTimer: DispatchWorkItem?
    private var eventTap: CFMachPort?

    private let holdThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.4
    private let rightOptionKeyCode: UInt16 = 0x3D

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon!).takeUnretainedValue()
                listener.handleEvent(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        holdTimer?.cancel()
        doubleTapTimer?.cancel()
    }

    private func handleEvent(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == rightOptionKeyCode else { return }

        let flags = event.flags
        let isDown = flags.contains(.maskAlternate)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isDown {
                self.onKeyDown()
            } else {
                self.onKeyUp()
            }
        }
    }

    private func onKeyDown() {
        holdTimer?.cancel()

        let action = state.handleKeyDown()
        dispatchAction(action)

        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let action = self.state.handleHoldTimerFired()
            self.dispatchAction(action)
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
    }

    private func onKeyUp() {
        holdTimer?.cancel()

        let action = state.handleKeyUp()
        dispatchAction(action)

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
            delegate?.hotkeyListenerDidRequestStart()
        case .stopRecording:
            delegate?.hotkeyListenerDidRequestStop()
        case nil:
            break
        }
    }
}
