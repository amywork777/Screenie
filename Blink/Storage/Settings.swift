import Foundation

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    enum Key: String {
        case captureAudio = "blink.captureAudio"
        case captureMicrophone = "blink.captureMicrophone"
        case saveFolderPath = "blink.saveFolderPath"
        case autoStart = "blink.autoStart"
        case hasCompletedOnboarding = "blink.hasCompletedOnboarding"
    }

    var captureAudio: Bool {
        get { defaults.bool(forKey: Key.captureAudio.rawValue) }
        set { defaults.set(newValue, forKey: Key.captureAudio.rawValue) }
    }

    var captureMicrophone: Bool {
        get { defaults.bool(forKey: Key.captureMicrophone.rawValue) }
        set { defaults.set(newValue, forKey: Key.captureMicrophone.rawValue) }
    }

    var autoStart: Bool {
        get { defaults.object(forKey: Key.autoStart.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoStart.rawValue) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding.rawValue) }
    }
}
