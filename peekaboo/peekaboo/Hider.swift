import AppKit

/// Owns the divider and decides what's hidden. Apps with an item left of the divider are hidden.
/// Hiding is per app, so an app with items on both sides stays visible.
final class Hider: NSObject {
    private static let hiddenKey = "hiddenBundleIDs"
    private static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
    private static let launchSettleDelay = 0.5

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    private var isCollapsed = false
    private var token: Any?
    private var failure: String?
    private var generation = 0

    func start() {
        item.autosaveName = "peekaboo.divider"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        isCollapsed = !hidden.isEmpty
        applyRestriction()
        updateIcon()
    }

    /// Reads which side of the divider each app is on, then hides the left side. Only valid
    /// while nothing is restricted, because hidden items don't report positions.
    private func collapse() {
        guard AXIsProcessTrusted() else { return fail("Accessibility permission is needed") }
        let items = MenuBarAgent.items()
        guard let divider = items.first(where: { $0.owner == getpid() }) else { return fail("Couldn't read the menu bar") }

        var left = Set<String>(), right = Set<String>()
        for item in items where item.owner != getpid() {
            guard let bundleID = NSRunningApplication(processIdentifier: item.owner)?.bundleIdentifier,
                  !Self.systemOwners.contains(bundleID) else { continue }
            if item.x < divider.x { left.insert(bundleID) } else { right.insert(bundleID) }
        }
        // Keep apps that aren't running, so they stay hidden when they next launch.
        hidden = hidden.subtracting(left.union(right)).union(left.subtracting(right))
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenKey)

        failure = nil
        isCollapsed = true
        applyRestriction()
        updateIcon()
    }

    private func expand() {
        isCollapsed = false
        applyRestriction()
        updateIcon()
    }

    /// Allowing everything except the hidden set means a new app is visible by default. The new
    /// restriction starts before the old one ends so the bar doesn't flash.
    private func applyRestriction() {
        generation += 1
        let generation = generation
        guard isCollapsed, !hidden.isEmpty else { return replaceToken(with: nil) }

        // The divider must never hide, or the user has no way back. macOS also drops the items of
        // apps outside /Applications while restricted, so peekaboo has to be installed there.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let allowed = running.filter { !hidden.contains($0) } + [Bundle.main.bundleIdentifier ?? ""]
        PKBMenuBarRestrictionBegin(allowed) { [weak self] token, error in
            guard let self, generation == self.generation else {
                if let token { PKBMenuBarRestrictionEnd(token) }
                return
            }
            guard let token else {
                self.replaceToken(with: nil)
                self.isCollapsed = false
                self.updateIcon()
                return self.fail(error?.localizedDescription ?? "Hiding failed")
            }
            self.replaceToken(with: token)
        }
    }

    private func replaceToken(with new: Any?) {
        if let token { PKBMenuBarRestrictionEnd(token) }
        token = new
    }

    private func fail(_ reason: String) {
        NSLog("peekaboo: %@", reason)
        failure = reason
    }

    @objc private func appLaunched(_ note: Notification) {
        guard isCollapsed,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, !hidden.contains(bundleID) else { return }
        // Apps often launch in bursts, so coalesce the re-apply.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reapply), object: nil)
        perform(#selector(reapply), with: nil, afterDelay: Self.launchSettleDelay)
    }

    @objc private func reapply() {
        applyRestriction()
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            return isCollapsed ? expand() : collapse()
        }
        let menu = NSMenu()
        if let failure {
            menu.addItem(withTitle: failure, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Quit peekaboo", action: #selector(NSApplication.terminate), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func updateIcon() {
        let symbol = isCollapsed ? "chevron.left" : "chevron.right"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "peekaboo divider")
    }
}
