import AppKit

enum RevealMode: String, CaseIterable {
    case inline, secondBar

    var title: String {
        switch self {
        case .inline: "In the menu bar"
        case .secondBar: "In a second bar"
        }
    }
}

/// Apple's items that can hide along with the rest. The raw values are macOS's own numbers for them.
enum SystemItem: Int {
    case clock = 2
    case controlCenter = 8
}

enum DividerState {
    case collapsed, expanded, secondBarOpen
}

enum DividerGlyph: String, CaseIterable {
    case chevron, dot, diamond, line

    var title: String { rawValue.capitalized }

    func symbol(for state: DividerState) -> String {
        switch (self, state) {
        case (.chevron, .collapsed): "chevron.left"
        case (.chevron, .expanded): "chevron.right"
        case (.chevron, .secondBarOpen): "chevron.down"
        case (.dot, .collapsed): "circle.fill"
        case (.dot, _): "circle"
        case (.diamond, .collapsed): "diamond.fill"
        case (.diamond, _): "diamond"
        case (.line, _): "poweron"
        }
    }

    /// Filled shapes at the default size look heavy next to the bar's other icons.
    var configuration: NSImage.SymbolConfiguration? {
        switch self {
        case .dot, .diamond: NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        case .chevron, .line: nil
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard
    /// macOS 27's own "show app menus only on hover". Apple doesn't document it.
    private static let menusOnHoverKey = "MenuBarShowMenuItemsOnHover" as CFString

    static var revealMode: RevealMode {
        get { RevealMode(rawValue: defaults.string(forKey: "revealMode") ?? "") ?? .inline }
        set { defaults.set(newValue.rawValue, forKey: "revealMode") }
    }

    static var glyph: DividerGlyph {
        get { DividerGlyph(rawValue: defaults.string(forKey: "glyph") ?? "") ?? .chevron }
        set { defaults.set(newValue.rawValue, forKey: "glyph") }
    }

    /// peekaboo's own copy of the choice. macOS's setting only follows it while peekaboo runs.
    static var hidesAppMenus: Bool {
        get { defaults.bool(forKey: "hidesAppMenus") }
        set {
            defaults.set(newValue, forKey: "hidesAppMenus")
            menusOnHover = newValue
            if newValue { _ = menusOffOnExit }
        }
    }

    private static var menusOnHover: Bool {
        get { CFPreferencesCopyValue(menusOnHoverKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false }
        set {
            CFPreferencesSetValue(menusOnHoverKey, newValue as CFBoolean, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    /// Turns macOS's setting off once peekaboo exits, even on a force quit or crash: the kernel
    /// closes peekaboo's end of the pipe however it dies, and that ends the shell's read.
    private static let menusOffOnExit: Process = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "read _; /usr/bin/defaults write -g \(menusOnHoverKey) -bool false"]
        process.standardInput = Pipe()
        try? process.run()
        return process
    }()

    /// Earlier versions kept the choice as fadesAppMenus, then only in macOS's setting.
    static func adoptMenuHiding(isFirstLaunch: Bool) {
        let saved = defaults.object(forKey: "hidesAppMenus") ?? defaults.object(forKey: "fadesAppMenus")
        defaults.removeObject(forKey: "fadesAppMenus")
        let hides = saved as? Bool ?? (menusOnHover || isFirstLaunch)
        defaults.set(hides, forKey: "hidesAppMenus")
        if hides { hidesAppMenus = true }
    }

    static var hiddenBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenBundleIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "hiddenBundleIDs") }
    }

    static var hiddenSystemItems: Set<SystemItem> {
        get { Set((defaults.array(forKey: "hiddenSystemItems") as? [Int] ?? []).compactMap(SystemItem.init)) }
        set { defaults.set(newValue.map(\.rawValue), forKey: "hiddenSystemItems") }
    }

    static var autoHidesIcons: Bool {
        get { defaults.bool(forKey: "autoHidesIcons") }
        set { defaults.set(newValue, forKey: "autoHidesIcons") }
    }

    /// Seconds after revealing icons before they hide again.
    static var autoHideDelay: Double {
        get { defaults.object(forKey: "autoHideDelay") as? Double ?? 5 }
        set { defaults.set(newValue, forKey: "autoHideDelay") }
    }

    static func isFirstLaunch() -> Bool {
        defer { defaults.set(true, forKey: "hasLaunched") }
        return !defaults.bool(forKey: "hasLaunched")
    }
}
