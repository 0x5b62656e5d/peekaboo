import AppKit

/// Owns the divider and decides what's hidden. Apps with an item left of the divider are hidden.
/// Hiding is per app, so an app with items on both sides stays visible.
final class Hider: NSObject {
    private static let hiddenKey = "hiddenBundleIDs"
    private static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
    private static let launchSettleDelay = 0.5
    private static let peekPollInterval = 0.05
    private static let peekPollAttempts = 40
    /// How long the bar takes to redraw after the allow-list changes, measured on macOS 27.
    private static let showSettleDelay = 0.8
    private static let hideSettleDelay = 0.6
    private static let iconUpdateInterval = 1.0
    private static let fallbackIconSize: CGFloat = 20

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    private var isCollapsed = false
    private var token: Any?
    private var failure: String?
    private var generation = 0
    private var secondBar: SecondBar?
    /// An app shown temporarily from the second bar, so its menu can open.
    private var peeked: NSRunningApplication?
    private var peekEndMonitor: Any?
    /// The hidden items as last photographed, so the second bar can open without waiting for a new capture.
    private var capturedIcons: [BarIcon] = []
    private var iconUpdates: Task<Void, Never>?
    /// Set while nothing is restricted so the hidden items are drawn, with `covers` hiding them.
    private var isShowingHidden = false
    private var covers: [NSPanel] = []
    /// The display the second bar was opened on.
    private var barDisplay: CGRect?

    var onOpenSettings: (() -> Void)?
    var isPeeking: Bool { peeked != nil }

    func start() {
        item.autosaveName = "peekaboo.divider"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(endPeek), name: .init("com.apple.HIToolbox.endMenuTrackingNotification"), object: nil)

        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        isCollapsed = !hidden.isEmpty
        applyRestriction()
        updateIcon()
        if isCollapsed && Settings.revealMode == .secondBar { startIconUpdates(once: true) }
    }

    /// Reads which side of the divider each app is on, then hides the left side. Only valid
    /// while nothing is restricted, because hidden items don't report positions.
    func settingsChanged() {
        item.isVisible = true
        closeSecondBar()
        updateIcon()
    }

    private func collapse() {
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
        UserDefaults.standard.set(Array(hidden), forKey: Self.hiddenKey)

        failure = nil
        isCollapsed = true
        applyRestriction()
        updateIcon()
    }

    private func expand() {
        closeSecondBar()
        endPeek()
        isCollapsed = false
        applyRestriction()
        updateIcon()
    }

    /// Allowing everything except the hidden set means a new app is visible by default. The new
    /// restriction starts before the old one ends so the bar doesn't flash.
    private func applyRestriction() {
        generation += 1
        let generation = generation
        guard isCollapsed, !hidden.isEmpty, !isShowingHidden else { return replaceToken(with: nil) }

        // The divider must never hide, or the user has no way back. macOS also drops the items of
        // apps outside /Applications while restricted, so peekaboo has to be installed there.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let allowed = running.filter { !hidden.contains($0) || $0 == peeked?.bundleIdentifier } + [Bundle.main.bundleIdentifier ?? ""]
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

    private func toggleSecondBar() {
        guard secondBar == nil else { return closeSecondBar() }
        endPeek()
        secondBar = SecondBar(icons: currentIcons(), under: item.button?.window?.frame ?? .zero, onPick: { [weak self] in self?.peek($0) }, onDismiss: { [weak self] in self?.closeSecondBar() })
        updateIcon()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        startIconUpdates(once: false)
    }

    private func closeSecondBar() {
        iconUpdates?.cancel()
        secondBar?.close()
        secondBar = nil
        updateIcon()
    }

    /// The latest pictures of the hidden items, with the app's icon for any app without one.
    private func currentIcons() -> [BarIcon] {
        let apps = hiddenApps()
        var icons = capturedIcons.filter { icon in apps.contains { $0.processIdentifier == icon.app.processIdentifier } }
        for app in apps where !icons.contains(where: { $0.app.processIdentifier == app.processIdentifier }) {
            let image = app.icon ?? NSImage()
            image.size = NSSize(width: Self.fallbackIconSize, height: Self.fallbackIconSize)
            icons.append(BarIcon(app: app, image: image))
        }
        return icons
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
                if camera.screen.frame.contains(anchor.origin) { barDisplay = camera.displayFrame }
            }
            guard !Task.isCancelled else { return panels.forEach { $0.close() } }
            covers = panels
            isShowingHidden = true
            applyRestriction()

            try? await Task.sleep(nanoseconds: UInt64(Self.showSettleDelay * 1_000_000_000))
            // An inactive display draws its items dimmed, so read the one that was clicked.
            if let camera = try await BarCamera.all(hidingOwnWindows: true).first(where: { $0.screen.frame.contains(anchor.origin) }) {
                while !Task.isCancelled {
                    try await readIcons(with: camera)
                    if once { break }
                    try? await Task.sleep(nanoseconds: UInt64(Self.iconUpdateInterval * 1_000_000_000))
                }
            }
        } catch {
            fail("Couldn't capture the menu bar: \(error.localizedDescription)")
        }
        // A picked item stays drawn until its menu closes.
        if peeked == nil { restoreBar() }
    }

    private func readIcons(with camera: BarCamera) async throws {
        let picture = try await camera.picture()
        let items = MenuBarAgent.items(onDisplay: camera.displayFrame).sorted { $0.frame.minX < $1.frame.minX }
        guard !Task.isCancelled, !items.isEmpty else { return }
        let apps = hiddenApps()
        var itemCounts: [pid_t: Int] = [:]
        capturedIcons = items.compactMap { item in
            guard let app = apps.first(where: { $0.processIdentifier == item.owner }),
                  let image = picture.icon(at: item.frame, height: SecondBar.height) else { return nil }
            let index = itemCounts[item.owner, default: 0]
            itemCounts[item.owner] = index + 1
            return BarIcon(app: app, image: image, itemIndex: index)
        }
        secondBar?.show(currentIcons())
    }

    private func restoreBar() {
        guard isShowingHidden else { return }
        isShowingHidden = false
        applyRestriction()
        let panels = covers
        covers = []
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideSettleDelay) { panels.forEach { $0.close() } }
    }

    /// Opens a hidden item's menu. The item is already on the bar if the bar is lifted, otherwise its
    /// app has to be allowed first.
    private func peek(_ icon: BarIcon) {
        peeked = icon.app
        closeSecondBar()
        if !isShowingHidden { applyRestriction() }
        pressWhenVisible(icon, attemptsLeft: Self.peekPollAttempts)
        peekEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click on the bar may be on the peeked item, so only a click elsewhere ends the peek.
            let pointer = NSEvent.mouseLocation
            if !NSScreen.screens.contains(where: { $0.visibleFrame.maxY <= pointer.y && $0.frame.minX...$0.frame.maxX ~= pointer.x }) {
                self?.endPeek()
            }
        }
    }

    /// An app's icon stands for all its items, so it only presses when the app has just one. With
    /// several, they stay up for the user to click.
    private func pressWhenVisible(_ icon: BarIcon, attemptsLeft: Int) {
        guard peeked == icon.app, attemptsLeft > 0 else { return }
        let items = MenuBarAgent.items(onDisplay: barDisplay).filter { $0.owner == icon.app.processIdentifier }.sorted { $0.frame.minX < $1.frame.minX }
        let index = icon.itemIndex ?? 0
        guard items.indices.contains(index) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekPollInterval) { [weak self] in
                self?.pressWhenVisible(icon, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        if icon.itemIndex != nil || items.count == 1 {
            AXUIElementPerformAction(items[index].button, kAXPressAction as CFString)
        }
    }

    @objc private func endPeek() {
        if let peekEndMonitor { NSEvent.removeMonitor(peekEndMonitor) }
        peekEndMonitor = nil
        guard peeked != nil else { return }
        peeked = nil
        if isShowingHidden { restoreBar() } else { applyRestriction() }
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func arrange() {
        expand()
    }

    @objc private func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            if isCollapsed && Settings.revealMode == .secondBar { return toggleSecondBar() }
            return isCollapsed ? expand() : collapse()
        }
        let menu = NSMenu()
        if let failure {
            menu.addItem(withTitle: failure, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        if isCollapsed {
            menu.addItem(withTitle: "Arrange Icons", action: #selector(arrange), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit peekaboo", action: #selector(NSApplication.terminate), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func updateIcon() {
        let state: DividerState = secondBar != nil ? .secondBarOpen : isCollapsed ? .collapsed : .expanded
        let symbol = Settings.glyph.symbol(for: state)
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "peekaboo divider")
    }
}
