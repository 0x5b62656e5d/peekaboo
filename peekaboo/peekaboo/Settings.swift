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

/// The settings window, laid out like System Settings. Built on open and released on close, so it costs
/// nothing the rest of the time.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 400
    private static let margin: CGFloat = 20
    private static let rowInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    private static let rowHeight: CGFloat = 40

    private let window: NSWindow
    private let onChange: () -> Void
    private let onClose: () -> Void
    private let glyphPicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let menusSwitch = NSSwitch()
    private let loginSwitch = NSSwitch()

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
        menusSwitch.state = Settings.hidesAppMenus ? .on : .off
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menusSwitch.controlSize = .small
        loginSwitch.controlSize = .small
        for (control, action) in [(glyphPicker, #selector(glyphChanged)), (modePicker, #selector(modeChanged)),
                                  (menusSwitch, #selector(menusToggled)), (loginSwitch, #selector(loginToggled))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }

        let group = Self.group([
            Self.row("Divider icon", glyphPicker),
            Self.row("Show hidden icons", modePicker),
            Self.row("Hide app menus until hovered", menusSwitch),
            Self.row("Launch at login", loginSwitch),
        ])
        let hint = NSTextField(wrappingLabelWithString: "⌘-drag menu bar icons left of the divider to hide them, or right of it to keep them visible. Apple's own icons always stay visible, and an app's icons hide together.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let content = NSStackView(views: [group, hint])
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        // Without a fixed width the stack drops its side margins and fits the window to the group.
        content.widthAnchor.constraint(equalToConstant: Self.width + Self.margin * 2).isActive = true
        group.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        hint.widthAnchor.constraint(equalTo: group.widthAnchor, constant: -Self.rowInsets.left * 2).isActive = true
        window.contentView = content
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Otherwise the first picker opens with a focus ring, as if it had been clicked.
        window.makeFirstResponder(nil)
    }

    /// A label on the left and its control on the right.
    private static func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let row = NSStackView(views: [label, control])
        row.distribution = .equalSpacing
        row.edgeInsets = rowInsets
        row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        return row
    }

    /// Rows on a rounded background, with separators between them.
    private static func group(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        for row in rows {
            if !stack.arrangedSubviews.isEmpty {
                let separator = NSBox()
                separator.boxType = .separator
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -rowInsets.left * 2).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 10
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = .zero
        box.contentView = stack
        return box
    }

    @objc private func glyphChanged() {
        Settings.glyph = DividerGlyph.allCases[glyphPicker.indexOfSelectedItem]
        onChange()
    }

    @objc private func modeChanged() {
        Settings.revealMode = RevealMode.allCases[modePicker.indexOfSelectedItem]
        onChange()
    }

    @objc private func menusToggled() {
        Settings.hidesAppMenus = menusSwitch.state == .on
    }

    @objc private func loginToggled() {
        do {
            if loginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
