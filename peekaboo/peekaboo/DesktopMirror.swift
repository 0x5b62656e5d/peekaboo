import AppKit

/// Feeds covers what's behind each menu bar while a live wallpaper app, like Canapé, is drawing there.
/// These apps never change the wallpaper file and can animate constantly. Captures only run while such
/// a window exists, so a static wallpaper costs next to nothing.
final class DesktopMirror {
    static let shared = DesktopMirror()

    private static let checkInterval = 3.0
    /// Canapé drifts about 1/255 per 100ms at most, so steps this far apart don't show.
    private static let frameInterval = 0.2
    private static let menuBarWindowName = "Menubar"

    private struct Observer {
        weak var owner: AnyObject?
        let screen: NSScreen
        let onFrame: (CGImage?) -> Void
    }

    private var observers: [Observer] = []
    private var checkTimer: Timer?
    private var frameTimer: Timer?

    /// `onFrame` gets each new picture of the screen's bar background, or nil when captures stop, until `owner` goes away.
    func observe(_ screen: NSScreen, owner: AnyObject, onFrame: @escaping (CGImage?) -> Void) {
        observers.append(Observer(owner: owner, screen: screen, onFrame: onFrame))
        if checkTimer == nil {
            checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
            checkTimer?.tolerance = Self.checkInterval / 2
        }
        check()
    }

    private func check() {
        observers.removeAll { $0.owner == nil }
        if observers.isEmpty {
            checkTimer?.invalidate()
            checkTimer = nil
        }
        guard !observers.isEmpty, Self.hasLiveWallpaper(), CGPreflightScreenCaptureAccess() else { return stop() }
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in self?.captureFrames() }
        captureFrames()
    }

    private func stop() {
        guard frameTimer != nil else { return }
        frameTimer?.invalidate()
        frameTimer = nil
        observers.forEach { $0.onFrame(nil) }
    }

    /// macOS's own wallpaper sits below the desktop level, so anything from there up to the icons is an app's.
    private static func hasLiveWallpaper() -> Bool {
        let levels = CGWindowLevelForKey(.desktopWindow)..<CGWindowLevelForKey(.desktopIconWindow)
        return onScreenWindows().contains { ($0[kCGWindowLayer] as? Int32).map(levels.contains) ?? false }
    }

    private static func onScreenWindows() -> [[CFString: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] ?? []
    }

    private func captureFrames() {
        observers.removeAll { $0.owner == nil }
        let windows = Self.onScreenWindows()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for screen in NSScreen.screens where observers.contains(where: { $0.screen.displayID == screen.displayID }) {
            guard let image = Self.barBackground(of: screen, among: windows) else { continue }
            for observer in observers where observer.screen.displayID == screen.displayID { observer.onFrame(image) }
        }
        CATransaction.commit()
    }

    /// Everything under the bar's own window, which leaves out its text and icons but keeps the shadows
    /// windows cast onto it. ScreenCaptureKit drops those, so a cover made from it shows as a lighter band.
    private static func barBackground(of screen: NSScreen, among windows: [[CFString: Any]]) -> CGImage? {
        let origin = CGPoint(x: screen.frame.minX, y: NSScreen.screens[0].frame.maxY - screen.frame.maxY)
        let bar = windows.first { window in
            guard window[kCGWindowName] as? String == menuBarWindowName,
                  let bounds = (window[kCGWindowBounds] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return false }
            return bounds.origin == origin
        }
        guard let id = bar?[kCGWindowNumber] as? CGWindowID else { return nil }
        let rect = CGRect(origin: origin, size: CGSize(width: screen.frame.width, height: screen.menuBarHeight - NSScreen.menuBarCoverInset))
        return PKBCreateImageBelowWindow(rect, id)
    }
}
