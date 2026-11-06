import AppKit

/// A small bar under the menu bar with one icon per hidden app. It holds nothing once closed.
final class SecondBar: NSObject {
    private static let iconSize: CGFloat = 20
    private static let padding: CGFloat = 8
    private static let gapBelowMenuBar: CGFloat = 4

    private let panel: NSPanel
    private let apps: [NSRunningApplication]
    private let onPick: (NSRunningApplication) -> Void
    private let onDismiss: () -> Void
    private var outsideClickMonitor: Any?

    init(apps: [NSRunningApplication], under anchor: CGRect, onPick: @escaping (NSRunningApplication) -> Void, onDismiss: @escaping () -> Void) {
        self.apps = apps
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

        let stack = NSStackView(views: apps.isEmpty ? [NSTextField(labelWithString: "Nothing hidden")] : apps.indices.map(makeButton))
        stack.spacing = Self.padding
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.iconSize / 2
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
        let icon = apps[index].icon ?? NSImage()
        icon.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        let button = NSButton(image: icon, target: self, action: #selector(picked))
        button.tag = index
        button.isBordered = false
        button.toolTip = apps[index].localizedName
        return button
    }

    @objc private func picked(_ sender: NSButton) {
        onPick(apps[sender.tag])
    }
}
