import AppKit

/// Hidden items drawn on the bar, under covers. They can't be clicked until they've settled.
private struct BarLift {
    let covers: [NSPanel]
    let shownAt = Date()
}

/// Owns the divider and decides what's hidden. Apps with an item left of the divider are hidden.
/// Hiding is per app, so an app with items on both sides stays visible.
final class Hider: NSObject {
    private static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
    private static let launchSettleDelay = 0.5
    private static let peekPollInterval = 0.05
    private static let peekPollAttempts = 40
    /// How often auto-hide checks back while the icons are still in use.
    private static let autoHideRecheck = 0.5
    /// How long the bar takes to redraw after the allow-list changes, measured on macOS 27.
    private static let showSettleDelay = 0.8
    private static let hideSettleDelay = 0.6
    private static let iconUpdateInterval = 1.0

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var hidden = Settings.hiddenBundleIDs
    private var isCollapsed = false
    private let restriction = MenuBarRestriction()
    private var failure: String?
    private var secondBar: SecondBar?
    /// An app shown temporarily from the second bar, so its menu can open.
    private var peeked: NSRunningApplication?
    private var peekEndMonitor: Any?
    private var isMenuOpen = false
    /// The hidden items as last photographed, so the second bar can open without waiting for a new capture.
    private var capturedIcons: [BarIcon] = []
    /// The apps the last capture looked at, so an app with nothing captured can be told from one it didn't check.
    private var checkedApps = Set<pid_t>()
    private var iconUpdates: Task<Void, Never>?
    /// Set while nothing is restricted so the hidden items are drawn, with covers hiding them.
    private var lift: BarLift?
    private var secondBarDisplay: CGRect?

    var onOpenSettings: (() -> Void)?

    func start() {
        item.autosaveName = "peekaboo.divider"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(menuOpened), name: .init("com.apple.HIToolbox.beginMenuTrackingNotification"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(menuClosed), name: .init("com.apple.HIToolbox.endMenuTrackingNotification"), object: nil)

        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        PKBAllowCursorHidingInBackground()
        isCollapsed = !hidden.isEmpty
        applyRestriction()
        updateIcon()
        if isCollapsed && Settings.revealMode == .secondBar { startIconUpdates(once: true) }
    }

    func settingsChanged() {
        item.isVisible = true
        closeSecondBar()
        updateIcon()
    }

    /// Reads which side of the divider each app is on, then hides the left side. Only valid
    /// while nothing is restricted, because hidden items don't report positions.
    private func collapse() {
        cancelAutoHide()
        endPeek()
        guard AXIsProcessTrusted() else { return fail("Accessibility permission is needed") }
        let items = MenuBarAgent.items()
        guard let divider = items.first(where: { $0.owner == getpid() }) else { return fail("Couldn't read the menu bar") }

        var left = Set<String>(), right = Set<String>()
        for item in items where item.owner != getpid() {
            guard let bundleID = NSRunningApplication(processIdentifier: item.owner)?.bundleIdentifier,
                  !Self.systemOwners.contains(bundleID) else { continue }
            if item.frame.minX < divider.frame.minX { left.insert(bundleID) } else { right.insert(bundleID) }
        }
        // Keep apps that aren't running, so they stay hidden when they next launch.
        hidden = hidden.subtracting(left.union(right)).union(left.subtracting(right))
        Settings.hiddenBundleIDs = hidden

        failure = nil
        isCollapsed = true
        applyRestriction()
        updateIcon()
    }

    @objc private func expand() {
        cancelAutoHide()
        closeSecondBar()
        endPeek()
        isCollapsed = false
        applyRestriction()
        updateIcon()
    }

    /// Allowing everything except the hidden set means a new app is visible by default.
    @objc private func applyRestriction() {
        guard isCollapsed, !hidden.isEmpty, lift == nil else { return restriction.end() }

        // The divider must never hide, or the user has no way back. macOS also drops the items of
        // apps outside /Applications while restricted, so peekaboo has to be installed there.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let allowed = running.filter { !hidden.contains($0) || $0 == peeked?.bundleIdentifier } + [Bundle.main.bundleIdentifier ?? ""]
        restriction.allow(only: allowed) { [weak self] reason in
            self?.isCollapsed = false
            self?.updateIcon()
            self?.fail(reason)
        }
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
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyRestriction), object: nil)
        perform(#selector(applyRestriction), with: nil, afterDelay: Self.launchSettleDelay)
    }

    private func toggleSecondBar() {
        guard secondBar == nil else { return closeSecondBar() }
        endPeek()
        secondBar = SecondBar(icons: BarIcon.all(captured: capturedIcons, checked: checkedApps, apps: hiddenApps()), under: item.button?.window?.frame ?? .zero, onPick: { [weak self] in self?.peek($0) }, onDismiss: { [weak self] in self?.closeSecondBar() })
        updateIcon()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        startIconUpdates(once: false)
    }

    private func closeSecondBar() {
        cancelAutoHide()
        iconUpdates?.cancel()
        secondBar?.close()
        secondBar = nil
        updateIcon()
    }

    private func hiddenApps() -> [NSRunningApplication] {
        hidden.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
    }

    private func startIconUpdates(once: Bool) {
        guard CGPreflightScreenCaptureAccess(), !hiddenApps().isEmpty else { return }
        iconUpdates?.cancel()
        let previous = iconUpdates
        iconUpdates = Task {
            await previous?.value
            await updateIcons(once: once)
        }
    }

    /// macOS only draws allowed items, so this lifts the restriction and reads the hidden items off
    /// the bar until cancelled. They appear left of the divider without moving anything else, so
    /// only that stretch needs covering, and the divider stays real and clickable.
    private func updateIcons(once: Bool) async {
        guard !Task.isCancelled else { return }
        let anchor = item.button?.window?.frame ?? .zero
        do {
            var panels: [NSPanel] = []
            for camera in try await BarCamera.all(hidingOwnWindows: false) {
                guard let divider = MenuBarAgent.items(onDisplay: camera.displayFrame).first(where: { $0.owner == getpid() }) else { continue }
                let cover = try await camera.picture().cover(leftOf: divider.frame.minX) { [weak self] in
                    self?.closeSecondBar()
                    self?.endPeek()
                }
                if let cover { panels.append(cover) }
                if camera.screen.frame.contains(anchor.origin) { secondBarDisplay = camera.displayFrame }
            }
            guard !Task.isCancelled else { return panels.forEach { $0.close() } }
            lift = BarLift(covers: panels)
            applyRestriction()

            try? await Task.sleep(for: .seconds(Self.showSettleDelay))
            // An inactive display draws its items dimmed, so read the one that was clicked.
            if let camera = try await BarCamera.all(hidingOwnWindows: true).first(where: { $0.screen.frame.contains(anchor.origin) }) {
                while !Task.isCancelled {
                    let apps = hiddenApps()
                    if let icons = try await camera.icons(of: apps), !Task.isCancelled {
                        capturedIcons = icons
                        checkedApps = Set(apps.map(\.processIdentifier))
                        secondBar?.show(BarIcon.all(captured: icons, checked: checkedApps, apps: hiddenApps()))
                    }
                    if once { break }
                    try? await Task.sleep(for: .seconds(Self.iconUpdateInterval))
                }
            }
        } catch {
            fail("Couldn't capture the menu bar: \(error.localizedDescription)")
        }
        // A picked item stays drawn until its menu closes.
        if peeked == nil { restoreBar() }
    }

    private func restoreBar() {
        guard let lift else { return }
        self.lift = nil
        applyRestriction()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideSettleDelay) { lift.covers.forEach { $0.close() } }
    }

    /// Opens a hidden item's menu. The item is already on the bar if the bar is lifted, otherwise its
    /// app has to be allowed first.
    private func peek(_ icon: BarIcon) {
        peeked = icon.app
        closeSecondBar()
        // An app's icon usually means macOS folded the item away for lack of room. Showing that app
        // alone with the visible ones gives it room.
        if icon.itemIndex == nil, lift != nil {
            restoreBar()
        } else if lift == nil {
            applyRestriction()
        }
        clickWhenVisible(icon, shownAt: lift?.shownAt ?? Date(), attemptsLeft: Self.peekPollAttempts)
        peekEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // A click on the bar may be on the peeked item, so only a click elsewhere ends the peek.
            // This reads the event's location because the pointer has left a posted click's by now.
            if !Self.isOnMenuBar(event.locationInWindow) { self?.endPeek() }
        }
    }

    /// An app's icon stands for all its items, so it only clicks when the app has just one. With
    /// several, they stay up for the user to click.
    private func clickWhenVisible(_ icon: BarIcon, shownAt: Date, attemptsLeft: Int) {
        guard peeked == icon.app, attemptsLeft > 0 else { return }
        let items = MenuBarAgent.items(onDisplay: secondBarDisplay).filter { $0.owner == icon.app.processIdentifier && !$0.isOverflowed }
        let index = icon.itemIndex ?? 0
        guard items.indices.contains(index), -shownAt.timeIntervalSinceNow >= Self.showSettleDelay else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekPollInterval) { [weak self] in
                self?.clickWhenVisible(icon, shownAt: shownAt, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        if icon.itemIndex != nil || items.count == 1 {
            PointerClick.post(at: CGPoint(x: items[index].frame.midX, y: items[index].frame.midY), through: lift?.covers ?? [])
        }
    }

    @objc private func endPeek() {
        if let peekEndMonitor { NSEvent.removeMonitor(peekEndMonitor) }
        peekEndMonitor = nil
        guard peeked != nil else { return }
        peeked = nil
        if lift != nil { restoreBar() } else { applyRestriction() }
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            if isCollapsed && Settings.revealMode == .secondBar {
                toggleSecondBar()
            } else if isCollapsed {
                expand()
            } else {
                collapse()
            }
            // Only a click reveals for auto-hide. Arrange Icons leaves the icons up while they're moved.
            return scheduleAutoHide()
        }
        let menu = NSMenu()
        if let failure {
            menu.addItem(withTitle: failure, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        if isCollapsed {
            menu.addItem(withTitle: "Arrange Icons", action: #selector(expand), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit peekaboo", action: #selector(NSApplication.terminate), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func scheduleAutoHide(after delay: Double = Settings.autoHideDelay) {
        cancelAutoHide()
        guard Settings.autoHidesIcons, secondBar != nil || !isCollapsed else { return }
        perform(#selector(autoHide), with: nil, afterDelay: delay)
    }

    private func cancelAutoHide() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoHide), object: nil)
    }

    /// Waits while the icons are in use: a menu open, an item picked, or the pointer on the bar or the second bar.
    @objc private func autoHide() {
        let pointer = NSEvent.mouseLocation
        if isMenuOpen || peeked != nil || Self.isOnMenuBar(pointer) || secondBar?.contains(pointer) == true {
            return scheduleAutoHide(after: Self.autoHideRecheck)
        }
        if secondBar != nil { closeSecondBar() } else if !isCollapsed { collapse() }
    }

    @objc private func menuOpened() {
        isMenuOpen = true
    }

    @objc private func menuClosed() {
        isMenuOpen = false
        endPeek()
    }

    private static func isOnMenuBar(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.maxY <= point.y && $0.frame.minX...$0.frame.maxX ~= point.x }
    }

    private func updateIcon() {
        let state: DividerState = secondBar != nil ? .secondBarOpen : isCollapsed ? .collapsed : .expanded
        let symbol = Settings.glyph.symbol(for: state)
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "peekaboo divider")
    }
}
