import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hider = Hider()
    private let fader = AppMenuFader()
    private var settingsWindow: SettingsWindow?

    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hider.onOpenSettings = { [weak self] in self?.showSettings() }
        fader.isPeeking = { [hider] in hider.isPeeking }
        hider.start()
        fader.start()
        if Settings.isFirstLaunch() { showSettings() }
    }

    /// Opening the app again is the way back if the divider ever goes missing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hider.settingsChanged()
        showSettings()
        return false
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(onChange: { [weak self] in
                self?.hider.settingsChanged()
                self?.fader.settingsChanged()
            }, onClose: { [weak self] in
                self?.settingsWindow = nil
            })
        }
        settingsWindow?.show()
    }
}
