import AppKit

/// A hidden item's picture from the menu bar, or its app's icon if it couldn't be captured.
struct BarIcon {
    let app: NSRunningApplication
    let image: NSImage
    /// Which of the app's items this is, left to right. Nil for an app's icon, which stands for all of them.
    var itemIndex: Int?
}

/// A small bar under the menu bar showing the hidden items. It holds nothing once closed.
final class SecondBar: NSObject {
    static let height: CGFloat = 28
    private static let padding: CGFloat = 8
    private static let gapBelowMenuBar: CGFloat = 4

    private let panel: NSPanel
    private let anchor: CGRect
    private let stack = NSStackView()
    private var icons: [BarIcon] = []
    private let onPick: (BarIcon) -> Void
    private let onDismiss: () -> Void
    private var outsideClickMonitor: Any?

    init(icons: [BarIcon], under anchor: CGRect, onPick: @escaping (BarIcon) -> Void, onDismiss: @escaping () -> Void) {
        self.anchor = anchor
        self.onPick = onPick
        self.onDismiss = onDismiss

        panel = NSPanel(barFrame: .zero, level: .statusBar, inFullScreen: true)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        super.init()

        stack.spacing = 0

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        panel.contentView = background
        show(icons)
        panel.orderFrontRegardless()

        // MenuBarAgent draws the divider, so its clicks reach this monitor. Leave those to the divider's
        // own toggle, or mouse-down would close the bar and mouse-up would reopen it.
        let divider = anchor.insetBy(dx: 0, dy: -1)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if !divider.contains(event.locationInWindow) { self?.onDismiss() }
        }
    }

    /// Pictures carry the bar's background, so they sit edge to edge to read as one strip.
    func show(_ icons: [BarIcon]) {
        self.icons = icons
        // Reusing the buttons means an update can't swallow a click in progress.
        if let buttons = stack.arrangedSubviews as? [NSButton], !icons.isEmpty, buttons.count == icons.count {
            for (button, icon) in zip(buttons, icons) {
                button.image = icon.image
                button.toolTip = icon.app.localizedName
            }
        } else {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let views = icons.isEmpty ? [NSTextField(labelWithString: "Nothing hidden")] : icons.indices.map(makeButton)
            views.forEach(stack.addArrangedSubview)
        }
        stack.edgeInsets = icons.isEmpty ? NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding) : NSEdgeInsetsZero
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)

        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.screens[0]
        let x = min(max(anchor.midX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        panel.setFrame(CGRect(x: x, y: screen.visibleFrame.maxY - size.height - Self.gapBelowMenuBar, width: size.width, height: size.height), display: true)
    }

    func close() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        panel.close()
    }

    private func makeButton(at index: Int) -> NSButton {
        let button = NSButton(image: icons[index].image, target: self, action: #selector(picked))
        button.tag = index
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.toolTip = icons[index].app.localizedName
        button.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height).isActive = true
        return button
    }

    @objc private func picked(_ sender: NSButton) {
        onPick(icons[sender.tag])
    }
}
