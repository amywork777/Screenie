import Foundation

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    enum Key: String {
        case captureAudio = "screenie.captureAudio"
        case captureMicrophone = "screenie.captureMicrophone"
        case saveFolderPath = "screenie.saveFolderPath"
        case autoStart = "screenie.autoStart"
        case hasCompletedOnboarding = "screenie.hasCompletedOnboarding"
        case monitorStyle = "screenie.monitorStyle"
        case bgColorR = "screenie.bgColorR"
        case bgColorG = "screenie.bgColorG"
        case bgColorB = "screenie.bgColorB"
        case autoZoom = "screenie.autoZoom"
        case autoFollow = "screenie.autoFollow"
        case cursorBounce = "screenie.cursorBounce"
        case speedRamping = "screenie.speedRamping"
        case keystrokeOverlay = "screenie.keystrokeOverlay"
        case cursorSmoothing = "screenie.cursorSmoothing"
    }

    var captureAudio: Bool {
        get { defaults.object(forKey: Key.captureAudio.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.captureAudio.rawValue) }
    }

    var captureMicrophone: Bool {
        get { defaults.object(forKey: Key.captureMicrophone.rawValue) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.captureMicrophone.rawValue) }
    }

    var autoStart: Bool {
        get { defaults.object(forKey: Key.autoStart.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoStart.rawValue) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.object(forKey: Key.hasCompletedOnboarding.rawValue) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding.rawValue) }
    }

    var monitorStyle: Bool {
        get { defaults.object(forKey: Key.monitorStyle.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.monitorStyle.rawValue) }
    }

    var autoZoom: Bool {
        get { defaults.object(forKey: Key.autoZoom.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoZoom.rawValue) }
    }

    var autoFollow: Bool {
        get { defaults.object(forKey: Key.autoFollow.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoFollow.rawValue) }
    }

    var cursorBounce: Bool {
        get { defaults.object(forKey: Key.cursorBounce.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.cursorBounce.rawValue) }
    }

    var speedRamping: Bool {
        get { defaults.object(forKey: Key.speedRamping.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.speedRamping.rawValue) }
    }

    var keystrokeOverlay: Bool {
        get { defaults.object(forKey: Key.keystrokeOverlay.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.keystrokeOverlay.rawValue) }
    }

    var cursorSmoothing: Bool {
        get { defaults.object(forKey: Key.cursorSmoothing.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.cursorSmoothing.rawValue) }
    }

    /// Background gradient start color (defaults to soft lavender)
    var bgColor: (r: Double, g: Double, b: Double) {
        get {
            let r = defaults.object(forKey: Key.bgColorR.rawValue) as? Double ?? 0.85
            let g = defaults.object(forKey: Key.bgColorG.rawValue) as? Double ?? 0.65
            let b = defaults.object(forKey: Key.bgColorB.rawValue) as? Double ?? 0.90
            return (r, g, b)
        }
        set {
            defaults.set(newValue.r, forKey: Key.bgColorR.rawValue)
            defaults.set(newValue.g, forKey: Key.bgColorG.rawValue)
            defaults.set(newValue.b, forKey: Key.bgColorB.rawValue)
        }
    }
}
