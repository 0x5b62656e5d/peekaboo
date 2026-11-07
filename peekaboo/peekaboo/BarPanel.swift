import AppKit

extension NSScreen {
    /// The reported bar height runs past what's drawn, so a full-height cover would clip the window below.
    static let menuBarCoverInset: CGFloat = 2

    var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}

extension NSPanel {
    /// A borderless panel for drawing on or near the menu bar. It never activates peekaboo and stays up until closed.
    convenience init(barFrame frame: CGRect, level: NSWindow.Level, inFullScreen: Bool) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if inFullScreen { collectionBehavior.insert(.fullScreenAuxiliary) }
    }
}
