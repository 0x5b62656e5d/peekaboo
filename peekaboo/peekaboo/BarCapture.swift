import AppKit
import ScreenCaptureKit

/// Takes pictures of one screen's menu bar. MenuBarAgent composites the icons, so the screen is
/// the only place they can be read from.
struct BarCamera {
    let screen: NSScreen
    /// The screen in global coordinates with a top-left origin, like AX frames.
    let displayFrame: CGRect
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    /// Own windows are left out of the pictures only if they exist when this is called.
    static func all(hidingOwnWindows: Bool) async throws -> [BarCamera] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = hidingOwnWindows ? content.windows.filter { $0.owningApplication?.processID == getpid() } : []
        return NSScreen.screens.compactMap { screen in
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.menuBarHeight)
            config.width = Int(config.sourceRect.width * screen.backingScaleFactor)
            config.height = Int(config.sourceRect.height * screen.backingScaleFactor)
            config.showsCursor = false
            return BarCamera(screen: screen, displayFrame: display.frame, filter: SCContentFilter(display: display, excludingWindows: own), config: config)
        }
    }

    func picture() async throws -> BarPicture {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return BarPicture(screen: screen, displayFrame: displayFrame, image: image)
    }

    /// Pictures of these apps' items as they are on the bar now, or nil if the bar can't be read.
    func icons(of apps: [NSRunningApplication]) async throws -> [BarIcon]? {
        let picture = try await picture()
        let items = MenuBarAgent.items(onDisplay: displayFrame)
        guard !items.isEmpty else { return nil }
        var itemCounts: [pid_t: Int] = [:]
        return items.compactMap { item in
            guard let app = apps.first(where: { $0.processIdentifier == item.owner }),
                  let image = picture.icon(at: item.frame, height: SecondBar.height) else { return nil }
            let index = itemCounts[item.owner, default: 0]
            itemCounts[item.owner] = index + 1
            return BarIcon(app: app, image: image, itemIndex: index)
        }
    }
}

struct BarPicture {
    /// The divider's pressed highlight spills past its frame and may be in the picture.
    private static let coverDividerGap: CGFloat = 4

    let screen: NSScreen
    let displayFrame: CGRect
    let image: CGImage

    /// The part of the bar under an AX frame, trimmed to `height` around its center.
    func icon(at frame: CGRect, height: CGFloat) -> NSImage? {
        let scale = CGFloat(image.width) / displayFrame.width
        let rect = CGRect(x: (frame.minX - displayFrame.minX) * scale,
                          y: (CGFloat(image.height) - height * scale) / 2,
                          width: frame.width * scale,
                          height: height * scale)
        return image.cropping(to: rect).map { NSImage(cgImage: $0, size: CGSize(width: frame.width, height: height)) }
    }

    /// Covers the bar between its middle and the divider with this picture, so hidden items can be
    /// drawn there unseen. They're real items under the cover, so it takes the clicks.
    func cover(leftOf dividerX: CGFloat, onClick: @escaping () -> Void) -> NSPanel? {
        let scale = CGFloat(image.width) / displayFrame.width
        let frame = CGRect(x: screen.frame.midX, y: screen.visibleFrame.maxY + NSScreen.menuBarCoverInset, width: dividerX - Self.coverDividerGap - screen.frame.midX, height: screen.menuBarHeight - NSScreen.menuBarCoverInset)
        let crop = CGRect(x: (frame.minX - screen.frame.minX) * scale, y: 0, width: frame.width * scale, height: frame.height * scale)
        guard frame.width > 0, let part = image.cropping(to: crop) else { return nil }
        let panel = NSPanel(barFrame: frame, level: .popUpMenu, inFullScreen: true)
        let view = CoverView()
        view.wantsLayer = true
        view.layer?.contents = part
        view.layer?.contentsGravity = .resize
        view.onClick = onClick
        panel.contentView = view
        let slice = CGRect(x: (frame.minX - screen.frame.minX) / screen.frame.width, y: 0, width: frame.width / screen.frame.width, height: 1)
        DesktopMirror.shared.observe(screen, owner: view) { [weak view] background in
            guard let background else { return }
            view?.layer?.contents = background
            view?.layer?.contentsRect = slice
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
}

private final class CoverView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}
