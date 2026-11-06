import AppKit

/// Fades the frontmost app's menus (File, Edit...) out, keeping the Apple logo and app name, and
/// back in while the pointer is on the menu bar. macOS has no API to fade only part of the bar,
/// so a panel showing the matching slice of wallpaper covers the menus.
final class AppMenuFader: NSObject {
    private static let fadeDuration = 0.4
    private static let exitDelay = 0.3
    private static let relaunchReadDelay = 0.5
    private static let menuReadTimeout: Float = 0.2

    private var bars: [ScreenBar] = []
    private var isRevealed = false
    private var isMenuOpen = false
    private var exitMonitor: Any?

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(syncAndPlace), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncAndPlace), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(menuOpened), name: .init("com.apple.HIToolbox.beginMenuTrackingNotification"), object: nil)
        distributed.addObserver(self, selector: #selector(menuClosed), name: .init("com.apple.HIToolbox.endMenuTrackingNotification"), object: nil)

        syncAndPlace()
    }

    func settingsChanged() {
        syncAndPlace()
    }

    /// Reuses each screen's panels unless its wallpaper or geometry changed, since decoding the wallpaper is the one costly step.
    @objc private func syncAndPlace() {
        guard Settings.fadesAppMenus else { return removeBars() }
        bars = NSScreen.screens.compactMap { screen in
            let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen)
            if let existing = bars.first(where: { $0.matches(screen, wallpaper: wallpaper) }) { return existing }
            return ScreenBar(screen: screen, wallpaper: wallpaper) { [weak self] in self?.reveal() }
        }
        placeCovers()
    }

    @objc private func frontmostChanged() {
        syncAndPlace()
        // A freshly launched app can take a moment to publish its menus.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(placeCovers), object: nil)
        perform(#selector(placeCovers), with: nil, afterDelay: Self.relaunchReadDelay)
    }

    private func removeBars() {
        cancelCover()
        if let exitMonitor { NSEvent.removeMonitor(exitMonitor) }
        exitMonitor = nil
        isRevealed = false
        bars = []
    }

    @objc private func placeCovers() {
        guard !bars.isEmpty else { return }
        let menus = frontmostMenuSpan()
        let base = menus.flatMap { span in NSScreen.screens.first { $0.frame.minX...$0.frame.maxX ~= span.lowerBound } }
        for bar in bars {
            if let menus, let base {
                let offset = bar.screen.frame.minX - base.frame.minX
                bar.cover(from: menus.lowerBound + offset, to: menus.upperBound + offset)
            } else {
                bar.uncover()
            }
            bar.setCoverAlpha(isRevealed ? 0 : 1)
        }
    }

    /// The x range of the menus after the Apple logo and app name, or nil if there aren't any.
    private func frontmostMenuSpan() -> ClosedRange<CGFloat>? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.menuReadTimeout)
        guard let menuBar = element.value(kAXMenuBarAttribute) else { return nil }
        let items = (menuBar as! AXUIElement).children
        guard items.count > 2, let name = items[1].frame, let last = items[items.count - 1].frame, name.maxX < last.maxX else { return nil }
        return name.maxX...last.maxX
    }

    private func reveal() {
        cancelCover()
        guard !isRevealed, !bars.isEmpty else { return }
        isRevealed = true
        for bar in bars { bar.setHoverEnabled(false) }
        fade(to: 0)
        // Mouse moves only wake this app while the menus are showing.
        exitMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.pointerMoved()
        }
    }

    private func pointerMoved() {
        cancelCover()
        guard !isPointerOnBar else { return }
        perform(#selector(coverAgain), with: nil, afterDelay: Self.exitDelay)
    }

    @objc private func coverAgain() {
        guard isRevealed, !isMenuOpen, !isPointerOnBar else { return }
        isRevealed = false
        if let exitMonitor { NSEvent.removeMonitor(exitMonitor) }
        exitMonitor = nil
        for bar in bars { bar.setHoverEnabled(true) }
        placeCovers()
        fade(to: 1)
    }

    private func cancelCover() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(coverAgain), object: nil)
    }

    private var isPointerOnBar: Bool {
        let pointer = NSEvent.mouseLocation
        return bars.contains { $0.containsPointer(pointer) }
    }

    private func fade(to alpha: CGFloat) {
        // placeCovers already set the end state for hidden covers, so start from the opposite one.
        for bar in bars { bar.setCoverAlpha(1 - alpha) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for bar in bars { bar.animateCoverAlpha(alpha) }
        }
    }

    @objc private func menuOpened() {
        isMenuOpen = true
        reveal()
    }

    @objc private func menuClosed() {
        isMenuOpen = false
        pointerMoved()
    }
}

/// One screen's cover and hover panels.
private final class ScreenBar {
    /// The reported bar height runs past what's drawn, so a full-height cover would clip the window below.
    private static let coverBottomInset: CGFloat = 2

    let screen: NSScreen
    private let wallpaper: URL?
    private let barHeight: CGFloat
    private let coverPanel: NSPanel
    private let hoverPanel: NSPanel
    private let screenFrame: CGRect

    /// Returns nil when the screen has no visible bar, as with auto-hide or full screen.
    init?(screen: NSScreen, wallpaper: URL?, onHover: @escaping () -> Void) {
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        guard barHeight > 0, let wallpaper, let strip = Self.wallpaperStrip(screen: screen, url: wallpaper, height: barHeight - Self.coverBottomInset) else { return nil }
        self.screen = screen
        self.wallpaper = wallpaper
        self.barHeight = barHeight
        screenFrame = screen.frame

        let barRect = CGRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight, width: screen.frame.width, height: barHeight)

        coverPanel = Self.makePanel(frame: barRect, level: .statusBar)
        coverPanel.ignoresMouseEvents = true
        let content = NSView()
        content.wantsLayer = true
        content.layer?.contents = strip
        content.layer?.contentsGravity = .resize
        coverPanel.contentView = content

        hoverPanel = Self.makePanel(frame: barRect, level: NSWindow.Level(NSWindow.Level.statusBar.rawValue + 1))
        hoverPanel.isOpaque = false
        hoverPanel.backgroundColor = .clear
        hoverPanel.ignoresMouseEvents = false
        hoverPanel.contentView = HoverView(onEnter: onHover)
        hoverPanel.orderFrontRegardless()
    }

    deinit {
        coverPanel.close()
        hoverPanel.close()
    }

    func matches(_ screen: NSScreen, wallpaper: URL?) -> Bool {
        screen.frame == screenFrame && screen.frame.maxY - screen.visibleFrame.maxY == barHeight && wallpaper == self.wallpaper
    }

    func cover(from start: CGFloat, to end: CGFloat) {
        let x = min(start, screenFrame.maxX), maxX = min(end, screenFrame.maxX)
        let height = barHeight - Self.coverBottomInset
        coverPanel.setFrame(CGRect(x: x, y: screenFrame.maxY - height, width: maxX - x, height: height), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coverPanel.contentView?.layer?.contentsRect = CGRect(x: (x - screenFrame.minX) / screenFrame.width, y: 0, width: (maxX - x) / screenFrame.width, height: 1)
        CATransaction.commit()
        coverPanel.orderFrontRegardless()
    }

    func uncover() {
        coverPanel.orderOut(nil)
    }

    func setCoverAlpha(_ alpha: CGFloat) {
        coverPanel.alphaValue = alpha
    }

    func animateCoverAlpha(_ alpha: CGFloat) {
        coverPanel.animator().alphaValue = alpha
    }

    func setHoverEnabled(_ enabled: Bool) {
        hoverPanel.ignoresMouseEvents = !enabled
    }

    func containsPointer(_ point: CGPoint) -> Bool {
        point.y >= screenFrame.maxY - barHeight && point.y <= screenFrame.maxY && point.x >= screenFrame.minX && point.x <= screenFrame.maxX
    }

    private static func makePanel(frame: CGRect, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Without fullScreenAuxiliary the panels stay out of full-screen spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }

    /// The top of the wallpaper, aspect-filled to the screen and rendered once at full bar width.
    private static func wallpaperStrip(screen: NSScreen, url: URL, height stripPoints: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let scale = screen.backingScaleFactor
        let screenWidth = screen.frame.width * scale, screenHeight = screen.frame.height * scale, stripHeight = stripPoints * scale
        guard let context = CGContext(data: nil, width: Int(screenWidth), height: Int(stripHeight), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let fill = max(screenWidth / CGFloat(image.width), screenHeight / CGFloat(image.height))
        let width = CGFloat(image.width) * fill, height = CGFloat(image.height) * fill
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (screenWidth - width) / 2, y: stripHeight - (screenHeight + height) / 2, width: width, height: height))
        return context.makeImage()
    }
}

private final class HoverView: NSView {
    private let onEnter: () -> Void

    init(onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter()
    }
}
