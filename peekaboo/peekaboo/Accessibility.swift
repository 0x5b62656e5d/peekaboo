import AppKit

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    var children: [AXUIElement] {
        value(kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Position and size in global coordinates with a top-left origin.
    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute) else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &rect.origin)
        AXValueGetValue(size as! AXValue, .cgSize, &rect.size)
        return rect
    }
}

struct BarItem {
    let owner: pid_t
    let frame: CGRect
}

enum MenuBarAgent {
    private static let timeout: Float = 0.5

    /// Every item on a display's bar, left to right, or the main display's by default, which has the same items.
    /// MenuBarAgent's window holds them all, each wrapping an element from its owning process, so
    /// one read here replaces a walk over every running app.
    static func items(onDisplay display: CGRect? = nil) -> [BarItem] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)
        let windows = app.value(kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { window in
            guard let display else { return true }
            return window.frame.map { display.contains($0.origin) } ?? false
        }) else { return [] }
        return window.children.compactMap { group in
            guard let frame = group.frame, let button = group.children.first else { return nil }
            var owner: pid_t = 0
            AXUIElementGetPid(button, &owner)
            return BarItem(owner: owner, frame: frame)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }
}
