import AppKit

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success ? value : nil
    }

    var children: [AXUIElement] {
        value(kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Position and size in global coordinates with a top-left origin. Only x is used, which is the same in AppKit's.
    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute) else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &rect.origin)
        AXValueGetValue(size as! AXValue, .cgSize, &rect.size)
        return rect
    }
}

/// A status item as MenuBarAgent lays it out.
struct BarItem {
    let element: AXUIElement
    let owner: pid_t
    let x: CGFloat
}

enum MenuBarAgent {
    private static let timeout: Float = 0.5

    /// Every item on the bar. MenuBarAgent's window holds them all, each wrapping an element from
    /// its owning process, so one read here replaces a walk over every running app.
    static func items() -> [BarItem] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = (app.value(kAXWindowsAttribute) as? [AXUIElement])?.first else { return [] }
        return window.children.compactMap { group in
            guard let frame = group.frame, let child = group.children.first else { return nil }
            var owner: pid_t = 0
            AXUIElementGetPid(child, &owner)
            return BarItem(element: group, owner: owner, x: frame.minX)
        }
    }
}
