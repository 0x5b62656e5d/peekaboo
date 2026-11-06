import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hider = Hider()
    private let fader = AppMenuFader()

    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hider.start()
        fader.start()
    }
}
