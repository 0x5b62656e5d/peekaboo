import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hider = Hider()
    private var settingsWindow: SettingsWindow?

    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        hider.onOpenSettings = { [weak self] in self?.showSettings() }
        let isFirstLaunch = Settings.isFirstLaunch()
        Settings.adoptMenuHiding(isFirstLaunch: isFirstLaunch)
        hider.start()
        if isFirstLaunch { showSettings() }
    }

    /// Opening the app again is the way back if the divider ever goes missing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hider.settingsChanged()
        showSettings()
        return false
    }

    @objc private func showSettings() {
        openSettings(.general)
    }

    @objc private func showAbout() {
        openSettings(.about)
    }

    private func openSettings(_ tab: SettingsWindow.Tab) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(onChange: { [weak self] in
                self?.hider.settingsChanged()
            }, onClose: { [weak self] in
                self?.settingsWindow = nil
            })
        }
        settingsWindow?.show(tab)
    }

    /// Shown while a peekaboo window is in front. There's no Dock icon, so it's the only place for these.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "peekaboo")
        appMenu.addItem(withTitle: "About peekaboo", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide peekaboo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit peekaboo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Reset All Permissions…", action: #selector(resetPermissions), keyEquivalent: "")
        NSApp.helpMenu = helpMenu

        let menu = NSMenu()
        for submenu in [appMenu, helpMenu] {
            menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return menu
    }

    /// Clears peekaboo's Accessibility and Screen Recording grants, then reopens it so macOS asks again.
    @objc private func resetPermissions() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Reset all permissions?"
        alert.informativeText = "peekaboo will forget its Accessibility and Screen Recording access, then reopen so you can grant them again."
        alert.addButton(withTitle: "Reset and Reopen")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let bundleID = Bundle.main.bundleIdentifier else { return }

        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "All", bundleID]
        do {
            try reset.run()
            reset.waitUntilExit()
            guard reset.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        Self.relaunch()
    }

    /// Quits and opens whatever is at this app's path. The new copy starts once this one has quit, so it
    /// doesn't inherit anything from it.
    static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }
}
