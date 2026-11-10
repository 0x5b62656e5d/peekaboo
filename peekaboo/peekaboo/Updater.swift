import AppKit

/// Updates peekaboo from its GitHub releases. A download only installs if it's signed the same way as the
/// running app, so nothing else can be swapped in. It isn't quarantined either, so Gatekeeper doesn't ask again.
final class Updater: NSObject {
    private static let latestRelease = URL(string: "https://api.github.com/repos/0x5b62656e5d/peekaboo/releases/latest")!
    private static let assetName = "peekaboo.zip"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// How often to see whether a check is due, so a Mac that slept through one catches up.
    private static let pollInterval: TimeInterval = 60 * 60

    private var isChecking = false
    /// Open while an update is on offer. Checking again brings it forward instead of opening another.
    private var window: UpdateWindow?

    func start() {
        checkIfDue()
        Timer.scheduledTimer(timeInterval: Self.pollInterval, target: self, selector: #selector(checkIfDue), userInfo: nil, repeats: true)
    }

    @objc func checkForUpdates() {
        check(manually: true)
    }

    @objc private func checkIfDue() {
        guard Settings.checksForUpdates, -(Settings.lastUpdateCheck ?? .distantPast).timeIntervalSinceNow >= Self.checkInterval else { return }
        check(manually: false)
    }

    /// A manual check says when there's nothing new and offers a version the user skipped. An automatic one stays quiet.
    private func check(manually: Bool) {
        if let window { return window.show() }
        guard !isChecking else { return }
        isChecking = true
        Task { [self] in
            defer { isChecking = false }
            let release: Release
            do {
                release = try await Self.fetchLatest()
                Settings.lastUpdateCheck = Date()
            } catch {
                NSLog("peekaboo: update check failed: %@", error.localizedDescription)
                if manually { Self.alert("Couldn't check for updates", error.localizedDescription) }
                return
            }
            guard release.version.compare(Self.currentVersion, options: .numeric) == .orderedDescending else {
                if manually { Self.alert("You're up to date", "peekaboo \(Self.currentVersion) is the latest version.") }
                return
            }
            guard manually || release.version != Settings.skippedVersion else { return }
            window = UpdateWindow(version: release.version, current: Self.currentVersion, notes: release.body ?? "") { [weak self] choice in
                self?.chose(choice, release)
            }
            window?.show()
        }
    }

    private func chose(_ choice: UpdateWindow.Choice, _ release: Release) {
        switch choice {
        case .install:
            Task {
                do {
                    try await install(release)
                } catch {
                    NSLog("peekaboo: update failed: %@", error.localizedDescription)
                    window?.close()
                    window = nil
                    if Self.alert("Couldn't install the update", error.localizedDescription, buttons: ["Open Release Page", "Cancel"]) == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(release.htmlUrl)
                    }
                }
            }
        case .skip:
            Settings.skippedVersion = release.version
            window = nil
        case .later:
            window = nil
        }
    }

    /// Downloads and checks the new copy, then swaps it in for this one. The running copy is already
    /// loaded, so replacing it on disk is safe.
    private func install(_ release: Release) async throws {
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else { throw UpdateError("The release has no \(Self.assetName).") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (zip, response) = try await URLSession.shared.download(from: asset.browserDownloadUrl)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let unzip = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, folder.path])
        unzip.waitUntilExit()
        let app = folder.appendingPathComponent("peekaboo.app")
        guard unzip.terminationStatus == 0, Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The download isn't peekaboo \(release.version).")
        }
        guard Self.isSignedLikeThisApp(app) else { throw UpdateError("The download isn't signed by peekaboo's developer.") }

        _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
        AppDelegate.relaunch()
    }

    /// Checks the copy against this app's designated requirement: the same bundle ID, signed by the same certificate.
    private static func isSignedLikeThisApp(_ app: URL) -> Bool {
        var running: SecCode?, own: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &own) == errSecSuccess, let own,
              SecCodeCopyDesignatedRequirement(own, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new else { return false }
        return SecStaticCodeCheckValidity(new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static func fetchLatest() async throws -> Release {
        let (data, response) = try await URLSession.shared.data(from: latestRelease)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub didn't return the latest release.") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    /// peekaboo usually isn't the active app, so it comes forward first or the alert opens behind other windows.
    @discardableResult
    private static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}

private struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }

    let tagName: String
    let body: String?
    let htmlUrl: URL
    let assets: [Asset]

    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
}

private struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
