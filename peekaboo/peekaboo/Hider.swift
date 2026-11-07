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
    /// Lets the divider's pressed highlight fade, or the frozen picture would hold it.
    private static let highlightFadeDelay = 0.25
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
    private var iconRefresh: Task<Void, Never>?
    /// Set while only the hidden apps are allowed, so their items can be photographed.
    private var isCapturing = false

    var onOpenSettings: (() -> Void)?

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
        if isCollapsed && Settings.revealMode == .secondBar { refreshIcons() }
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
        guard isCollapsed, !hidden.isEmpty else { return replaceToken(with: nil) }

        // The divider must never hide, or the user has no way back. macOS also drops the items of
        // apps outside /Applications while restricted, so peekaboo has to be installed there.
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let shown = isCapturing ? running.filter(hidden.contains) : running.filter { !hidden.contains($0) || $0 == peeked?.bundleIdentifier }
        let allowed = shown + [Bundle.main.bundleIdentifier ?? ""]
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
        refreshIcons()
    }

    /// The last pictures of the hidden items, with the app's icon for any app without one.
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

    private func refreshIcons() {
        guard iconRefresh == nil, CGPreflightScreenCaptureAccess(), !hiddenApps().isEmpty else { return }
        iconRefresh = Task {
            await captureIcons()
            iconRefresh = nil
        }
    }

    /// Macs only draw allowed items, so this allows just the hidden apps for a moment and photographs
    /// them. Leaving the rest out gives them room, as items that don't fit aren't drawn at all. A
    /// frozen picture of the bar covers the change.
    private func captureIcons() async {
        try? await Task.sleep(nanoseconds: UInt64(Self.highlightFadeDelay * 1_000_000_000))
        guard !Task.isCancelled else { return }
        // The divider moves during the capture, so this has to be read first.
        let anchor = item.button?.window?.frame ?? .zero
        let apps = hiddenApps()
        do {
            let panels = try await BarPicture.all(hidingOwnWindows: false).compactMap { $0.freeze { [weak self] in self?.closeSecondBar() } }
            isCapturing = true
            applyRestriction()
            try? await Task.sleep(nanoseconds: UInt64(Self.showSettleDelay * 1_000_000_000))
            let captured = Task.isCancelled ? nil : await readIcons(of: apps, onScreenWith: anchor)
            isCapturing = false
            applyRestriction()
            if let captured {
                capturedIcons = captured
                secondBar?.show(currentIcons())
            }
            // Detached because this wait has to hold even when the capture was cancelled.
            await Task.detached { try? await Task.sleep(nanoseconds: UInt64(Self.hideSettleDelay * 1_000_000_000)) }.value
            panels.forEach { $0.close() }
        } catch {
            fail("Couldn't capture the menu bar: \(error.localizedDescription)")
        }
    }

    private func readIcons(of apps: [NSRunningApplication], onScreenWith anchor: CGRect) async -> [BarIcon]? {
        do {
            // An inactive display draws its items dimmed, so read the one that was clicked.
            let pictures = try await BarPicture.all(hidingOwnWindows: true)
            guard let picture = pictures.first(where: { $0.screen.frame.contains(anchor.origin) }) else { return nil }
            return MenuBarAgent.items(onDisplay: picture.displayFrame).sorted { $0.frame.minX < $1.frame.minX }.compactMap { item in
                guard let app = apps.first(where: { $0.processIdentifier == item.owner }),
                      let image = picture.icon(at: item.frame, height: SecondBar.height) else { return nil }
                return BarIcon(app: app, image: image)
            }
        } catch {
            fail("Couldn't capture the menu bar: \(error.localizedDescription)")
            return nil
        }
    }

    private func closeSecondBar() {
        secondBar?.close()
        secondBar = nil
        updateIcon()
    }

    /// Shows a hidden app's items and presses its item if it has just one. With several there's no
    /// telling which was wanted, so they stay up for the user to click.
    private func peek(_ app: NSRunningApplication) {
        closeSecondBar()
        // A capture in progress moves the items and covers the bar, so cut it short and wait for the bar to settle.
        iconRefresh?.cancel()
        Task {
            await iconRefresh?.value
            startPeek(app)
        }
    }

    private func startPeek(_ app: NSRunningApplication) {
        peeked = app
        applyRestriction()
        pressWhenVisible(app, attemptsLeft: Self.peekPollAttempts)
        peekEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click on the bar may be on the peeked item, so only a click elsewhere ends the peek.
            let pointer = NSEvent.mouseLocation
            if !NSScreen.screens.contains(where: { $0.visibleFrame.maxY <= pointer.y && $0.frame.minX...$0.frame.maxX ~= pointer.x }) {
                self?.endPeek()
            }
        }
    }

    private func pressWhenVisible(_ app: NSRunningApplication, attemptsLeft: Int) {
        guard peeked == app, attemptsLeft > 0 else { return }
        let items = MenuBarAgent.items().filter { $0.owner == app.processIdentifier }
        guard let first = items.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekPollInterval) { [weak self] in
                self?.pressWhenVisible(app, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        if items.count == 1 {
            AXUIElementPerformAction(first.button, kAXPressAction as CFString)
        }
    }

    @objc private func endPeek() {
        if let peekEndMonitor { NSEvent.removeMonitor(peekEndMonitor) }
        peekEndMonitor = nil
        guard peeked != nil else { return }
        peeked = nil
        applyRestriction()
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
