import SwiftUI

/// Настройки приложения. Хранятся в памяти телефона.
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var voiceOn: Bool { didSet { d.set(voiceOn, forKey: "voiceOn") } }
    @Published var deadReckoning: Bool { didSet { d.set(deadReckoning, forKey: "deadReckoning") } }
    @Published var rotateMap: Bool { didSet { d.set(rotateMap, forKey: "rotateMap") } }
    @Published var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake") } }
    @Published var showStreetNames: Bool { didSet { d.set(showStreetNames, forKey: "showStreetNames") } }
    @Published var showGPSPanel: Bool { didSet { d.set(showGPSPanel, forKey: "showGPSPanel") } }
    @Published var saveLog: Bool { didSet { d.set(saveLog, forKey: "saveLog") } }
    /// "auto", "light" или "dark"
    @Published var appearance: String { didSet { d.set(appearance, forKey: "appearance") } }

    init() {
        d.register(defaults: [
            "voiceOn": true,
            "deadReckoning": true,
            "rotateMap": true,
            "keepAwake": true,
            "showStreetNames": true,
            "showGPSPanel": false,
            "saveLog": true,
            "appearance": "auto"
        ])
        voiceOn = d.bool(forKey: "voiceOn")
        deadReckoning = d.bool(forKey: "deadReckoning")
        rotateMap = d.bool(forKey: "rotateMap")
        keepAwake = d.bool(forKey: "keepAwake")
        showStreetNames = d.bool(forKey: "showStreetNames")
        showGPSPanel = d.bool(forKey: "showGPSPanel")
        saveLog = d.bool(forKey: "saveLog")
        appearance = d.string(forKey: "appearance") ?? "auto"
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
