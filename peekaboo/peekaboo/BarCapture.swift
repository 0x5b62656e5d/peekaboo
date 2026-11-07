import AppKit
import ScreenCaptureKit

/// A picture of one screen's menu bar. MenuBarAgent composites the icons, so the screen is the only
/// place they can be read from.
struct BarPicture {
    let screen: NSScreen
    /// The screen in global coordinates with a top-left origin, like AX frames.
    let displayFrame: CGRect
    let image: CGImage

    static func all(hidingOwnWindows: Bool) async throws -> [BarPicture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = hidingOwnWindows ? content.windows.filter { $0.owningApplication?.processID == getpid() } : []
        var pictures: [BarPicture] = []
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.maxY - screen.visibleFrame.maxY)
            config.width = Int(config.sourceRect.width * screen.backingScaleFactor)
            config.height = Int(config.sourceRect.height * screen.backingScaleFactor)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            pictures.append(BarPicture(screen: screen, displayFrame: display.frame, image: image))
        }
        return pictures
    }

    /// The part of the bar under an AX frame, trimmed to `height` around its center.
    func icon(at frame: CGRect, height: CGFloat) -> NSImage? {
        let scale = CGFloat(image.width) / displayFrame.width
        let rect = CGRect(x: (frame.minX - displayFrame.minX) * scale,
                          y: (CGFloat(image.height) - height * scale) / 2,
                          width: frame.width * scale,
                          height: height * scale)
        return image.cropping(to: rect).map { NSImage(cgImage: $0, size: CGSize(width: frame.width, height: height)) }
    }

    /// Puts the picture over the bar so the bar can change underneath without being seen.
    func freeze() -> NSPanel {
        let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let frame = CGRect(x: screen.frame.minX, y: screen.visibleFrame.maxY, width: screen.frame.width, height: barHeight)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSImageView(image: NSImage(cgImage: image, size: frame.size))
        view.imageScaling = .scaleAxesIndependently
        panel.contentView = view
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
}
