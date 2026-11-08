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

/// The settings window, with General and About tabs laid out like System Settings. Built on open and
/// released on close, so it costs nothing the rest of the time.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 400
    private static let margin: CGFloat = 20
    private static let rowInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    private static let rowHeight: CGFloat = 40
    private static let aboutIconSize: CGFloat = 96
    private static let maxAutoHideDelay = 10.0
    private static let autoHideDelayStep = 0.5

    enum Tab: Int { case general, about }

    private let window: NSWindow
    private let tabs = FittingTabViewController()
    private let onChange: () -> Void
    private let onClose: () -> Void
    private let loginSwitch = NSSwitch()
    private let menusSwitch = NSSwitch()
    private let glyphPicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let autoHideSwitch = NSSwitch()
    private let delaySlider = NSSlider()
    private let delayLabel = NSTextField(labelWithString: "")
    private lazy var delayRow = Self.row("Hide after", Self.stack([delaySlider, delayLabel]))

    init(onChange: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onChange = onChange
        self.onClose = onClose
        tabs.tabStyle = .toolbar
        window = CloseableWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menusSwitch.state = Settings.hidesAppMenus ? .on : .off
        loginSwitch.controlSize = .small
        menusSwitch.controlSize = .small
        glyphPicker.addItems(withTitles: DividerGlyph.allCases.map(\.title))
        glyphPicker.selectItem(at: DividerGlyph.allCases.firstIndex(of: Settings.glyph) ?? 0)
        modePicker.addItems(withTitles: RevealMode.allCases.map(\.title))
        modePicker.selectItem(at: RevealMode.allCases.firstIndex(of: Settings.revealMode) ?? 0)
        autoHideSwitch.state = Settings.autoHidesIcons ? .on : .off
        autoHideSwitch.controlSize = .small
        delaySlider.minValue = 0
        delaySlider.maxValue = Self.maxAutoHideDelay
        delaySlider.numberOfTickMarks = Int(Self.maxAutoHideDelay / Self.autoHideDelayStep) + 1
        delaySlider.allowsTickMarkValuesOnly = true
        delaySlider.tickMarkPosition = .below
        delaySlider.controlSize = .small
        delaySlider.doubleValue = Settings.autoHideDelay
        delaySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        delayLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        delayLabel.textColor = .secondaryLabelColor
        showDelay()
        for (control, action) in [(loginSwitch, #selector(loginToggled)), (menusSwitch, #selector(menusToggled)),
                                  (glyphPicker, #selector(glyphChanged)), (modePicker, #selector(modeChanged)),
                                  (autoHideSwitch, #selector(autoHideToggled)), (delaySlider, #selector(delayChanged))] as [(NSControl, Selector)] {
            control.target = self
            control.action = action
        }

        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", view: makeGeneral()))
        tabs.addTabViewItem(Self.tab("About", symbol: "info.circle", view: Self.makeAbout()))
        window.center()
    }

    func show(_ tab: Tab = .general) {
        tabs.selectedTabViewItemIndex = tab.rawValue
        // An app without a Dock icon never takes over the menu bar, so it becomes a regular app while this is open.
        NSApp.setActivationPolicy(.regular)
        // The polite activate() gets turned down when another app is in front, which leaves the menu bar
        // showing that app. Settings is always opened on purpose, so it takes focus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Otherwise the first control opens with a focus ring, as if it had been clicked.
        window.makeFirstResponder(nil)
    }

    private func makeGeneral() -> NSView {
        let group = Self.group([
            Self.row("Launch at login", loginSwitch),
            Self.row("Hide app menus until hovered", menusSwitch),
            Self.row("Divider icon", glyphPicker),
            Self.row("Show hidden icons", modePicker),
            Self.stack([Self.row("Hide icons automatically", autoHideSwitch), delayRow], vertical: true),
        ])
        delayRow.isHidden = !Settings.autoHidesIcons
        let hint = NSTextField(wrappingLabelWithString: "⌘-drag menu bar icons left of the divider to hide them, or right of it to keep them visible. Apple's own icons always stay visible, and an app's icons hide together.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        let page = Self.page([group, hint], alignment: .leading)
        group.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        hint.widthAnchor.constraint(equalTo: group.widthAnchor, constant: -Self.rowInsets.left * 2).isActive = true
        return page
    }

    /// The app's icon, name and version as x.y.z (build).
    private static func makeAbout() -> NSView {
        // NSApp.applicationIconImage can hold on to a stale placeholder, so ask for the icon Finder shows.
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: aboutIconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: aboutIconSize).isActive = true
        let name = NSTextField(labelWithString: "peekaboo")
        name.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        let info = Bundle.main.infoDictionary
        let version = NSTextField(labelWithString: "Version \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        version.textColor = .secondaryLabelColor
        version.isSelectable = true
        return page([icon, name, version], alignment: .centerX)
    }

    /// A tab's content: views stacked down the page, inside the window's margins.
    private static func page(_ views: [NSView], alignment: NSLayoutConstraint.Attribute) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        // Without a fixed width the stack drops its side margins and fits the window to its content.
        stack.widthAnchor.constraint(equalToConstant: width + margin * 2).isActive = true
        return stack
    }

    private static func tab(_ label: String, symbol: String, view: NSView) -> NSTabViewItem {
        let controller = NSViewController()
        controller.title = label
        controller.view = view
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    private static func stack(_ views: [NSView], vertical: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = vertical ? 0 : 8
        if vertical { views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true } }
        return stack
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

    @objc private func autoHideToggled() {
        Settings.autoHidesIcons = autoHideSwitch.state == .on
        delayRow.isHidden = autoHideSwitch.state == .off
        tabs.fitWindow()
    }

    @objc private func delayChanged() {
        Settings.autoHideDelay = delaySlider.doubleValue
        showDelay()
    }

    private func showDelay() {
        delayLabel.stringValue = String(format: "%.1fs", delaySlider.doubleValue)
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
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }
}

/// Closes on ⌘W. peekaboo has no File or Window menu to hold a Close item.
private final class CloseableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" else {
            return super.performKeyEquivalent(with: event)
        }
        performClose(nil)
        return true
    }
}

/// Fits the window to each tab, keeping its top edge in place. The stock controller leaves the window at its
/// default size.
private final class FittingTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow()
    }

    func fitWindow() {
        guard let content = tabView.selectedTabViewItem?.view, let window = content.window else { return }
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: content.fittingSize)).size
        window.setFrame(CGRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height),
                        display: true, animate: window.isVisible)
    }
}
