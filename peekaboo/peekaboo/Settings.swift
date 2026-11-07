import AppKit
import ServiceManagement

enum RevealMode: String, CaseIterable {
    case inline, secondBar

    var title: String {
        switch self {
        case .inline: "In the menu bar"
        case .secondBar: "In a second bar"
        }
    }
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

    /// A system setting, so it stays after peekaboo quits.
    static var hidesAppMenus: Bool {
        get { CFPreferencesCopyValue(menusOnHoverKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool ?? false }
        set {
            CFPreferencesSetValue(menusOnHoverKey, newValue as CFBoolean, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }

    /// peekaboo used to fade the menus itself, on by default. This carries that choice over to macOS's setting once.
    static func adoptMenuHiding(isFirstLaunch: Bool) {
        if defaults.object(forKey: "fadesAppMenus") as? Bool ?? isFirstLaunch { hidesAppMenus = true }
        defaults.removeObject(forKey: "fadesAppMenus")
    }

    static var hiddenBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "hiddenBundleIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "hiddenBundleIDs") }
    }

    static func isFirstLaunch() -> Bool {
        defer { defaults.set(true, forKey: "hasLaunched") }
        return !defaults.bool(forKey: "hasLaunched")
    }
}

/// The settings window. Built on open and released on close, so it costs nothing the rest of the time.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onChange: () -> Void
    private let onClose: () -> Void
    private let glyphPicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let menusToggle = NSButton(checkboxWithTitle: "Hide app menus until hovered", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)

    init(onChange: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onChange = onChange
        self.onClose = onClose
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "peekaboo"
        super.init()
        window.delegate = self

        glyphPicker.addItems(withTitles: DividerGlyph.allCases.map(\.title))
        glyphPicker.selectItem(at: DividerGlyph.allCases.firstIndex(of: Settings.glyph) ?? 0)
        modePicker.addItems(withTitles: RevealMode.allCases.map(\.title))
        modePicker.selectItem(at: RevealMode.allCases.firstIndex(of: Settings.revealMode) ?? 0)
        menusToggle.state = Settings.hidesAppMenus ? .on : .off
        loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for control in [glyphPicker, modePicker, menusToggle] {
            control.target = self
            control.action = #selector(controlChanged)
        }
        loginToggle.target = self
        loginToggle.action = #selector(loginToggled)

        let hint = NSTextField(wrappingLabelWithString: "⌘-drag menu bar icons to the left of the divider to hide them, or to the right to keep them visible. Apple's own icons always stay visible, and an app's icons hide together.")
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 340

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Divider icon:"), glyphPicker],
            [NSTextField(labelWithString: "Show hidden icons:"), modePicker],
        ])
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [grid, menusToggle, loginToggle, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func controlChanged() {
        Settings.glyph = DividerGlyph.allCases[glyphPicker.indexOfSelectedItem]
        Settings.revealMode = RevealMode.allCases[modePicker.indexOfSelectedItem]
        Settings.hidesAppMenus = menusToggle.state == .on
        onChange()
    }

    @objc private func loginToggled() {
        do {
            if loginToggle.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
