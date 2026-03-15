import Foundation

enum InputPhase: Equatable {
    case idle
    case pressed
    case holdRecording
    case awaitSecondTap
    case secondPressed
    case toggleRecording
    case toggleStopPressed
    case toggleStopAwait
    case toggleStopSecond
}

enum InputAction: Equatable {
    case startRecording
    case stopRecording
}

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
        case .holdRecording:
            current = .idle
            return .stopRecording
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

    func handleHoldTimerFired() -> InputAction? {
        guard current == .pressed else { return nil }
        current = .holdRecording
        return .startRecording
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
