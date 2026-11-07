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
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
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
}

struct BarPicture {
    /// The bar's lowest points can hold a sliver of the window below it.
    private static let coverBottomInset: CGFloat = 2
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
        let bottom = screen.visibleFrame.maxY + Self.coverBottomInset
        let frame = CGRect(x: screen.frame.midX, y: bottom, width: dividerX - Self.coverDividerGap - screen.frame.midX, height: screen.frame.maxY - bottom)
        let crop = CGRect(x: (frame.minX - screen.frame.minX) * scale, y: 0, width: frame.width * scale, height: frame.height * scale)
        guard frame.width > 0, let part = image.cropping(to: crop) else { return nil }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = CoverView(image: NSImage(cgImage: part, size: frame.size))
        view.imageScaling = .scaleAxesIndependently
        view.onClick = onClick
        panel.contentView = view
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
}

private final class CoverView: NSImageView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
}
