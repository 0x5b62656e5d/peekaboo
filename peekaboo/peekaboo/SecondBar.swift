import AppKit

/// A hidden item's picture from the menu bar, or its app's icon if it couldn't be captured.
struct BarIcon {
    let app: NSRunningApplication
    let image: NSImage
}

/// A small bar under the menu bar showing the hidden items. It holds nothing once closed.
final class SecondBar: NSObject {
    static let height: CGFloat = 28
    private static let padding: CGFloat = 8
    private static let gapBelowMenuBar: CGFloat = 4

    private let panel: NSPanel
    private let icons: [BarIcon]
    private let onPick: (NSRunningApplication) -> Void
    private let onDismiss: () -> Void
    private var outsideClickMonitor: Any?

    init(icons: [BarIcon], under anchor: CGRect, onPick: @escaping (NSRunningApplication) -> Void, onDismiss: @escaping () -> Void) {
        self.icons = icons
        self.onPick = onPick
        self.onDismiss = onDismiss

        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        super.init()

        // Pictures carry the bar's background, so they sit edge to edge to read as one strip.
        let stack = NSStackView(views: icons.isEmpty ? [NSTextField(labelWithString: "Nothing hidden")] : icons.indices.map(makeButton))
        stack.spacing = 0
        stack.edgeInsets = icons.isEmpty ? NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding) : NSEdgeInsetsZero

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.height / 2
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
        panel.contentView = background

        // Centered under the divider, kept on its screen.
        let size = stack.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.screens[0]
        let x = min(max(anchor.midX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        panel.setFrame(CGRect(x: x, y: screen.visibleFrame.maxY - size.height - Self.gapBelowMenuBar, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        // MenuBarAgent draws the divider, so its clicks reach this monitor. Leave those to the divider's
        // own toggle, or mouse-down would close the bar and mouse-up would reopen it.
        let divider = anchor.insetBy(dx: 0, dy: -1)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if !divider.contains(NSEvent.mouseLocation) { self?.onDismiss() }
        }
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
        onPick(icons[sender.tag].app)
    }
}
