import Foundation

enum RevealMode: String {
    case inline, secondBar
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var revealMode: RevealMode {
        get { RevealMode(rawValue: defaults.string(forKey: "revealMode") ?? "") ?? .inline }
        set { defaults.set(newValue.rawValue, forKey: "revealMode") }
    }
}
