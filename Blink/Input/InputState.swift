import Foundation

enum InputPhase: Equatable {
    case idle
    case pressed              // first tap down
    case awaitSecondTap       // first tap released, waiting for second
    case secondPressed        // second tap down
    case toggleRecording      // recording active
    case toggleStopPressed    // first tap of stop double-tap
    case toggleStopAwait      // first tap released, waiting for second stop tap
    case toggleStopSecond     // second tap of stop down
}

enum InputAction: Equatable {
    case startRecording
    case stopRecording
}

/// Double-tap only state machine.
/// Double-tap Right Option to start recording, double-tap again to stop.
/// No hold mode — holding Option interferes with typing.
final class InputState {
    private(set) var current: InputPhase = .idle

    func handleKeyDown() -> InputAction? {
        switch current {
        case .idle:
            current = .pressed
            return nil
        case .awaitSecondTap:
            current = .secondPressed
            return nil
        case .toggleRecording:
            current = .toggleStopPressed
            return nil
        case .toggleStopAwait:
            current = .toggleStopSecond
            return nil
        default:
            return nil
        }
    }

    func handleKeyUp() -> InputAction? {
        switch current {
        case .pressed:
            current = .awaitSecondTap
            return nil
        case .secondPressed:
            current = .toggleRecording
            return .startRecording
        case .toggleStopPressed:
            current = .toggleStopAwait
            return nil
        case .toggleStopSecond:
            current = .idle
            return .stopRecording
        default:
            return nil
        }
    }

    func handleDoubleTapTimerFired() -> InputAction? {
        switch current {
        case .awaitSecondTap:
            current = .idle
            return nil
        case .toggleStopAwait:
            current = .toggleRecording
            return nil
        default:
            return nil
        }
    }
}
