import AppKit

/// Some apps, like Canapé, ignore AXPress and only respond to the mouse, and macOS 27 only delivers
/// clicks that move the pointer. So this is a real click, through any covers, with the pointer hidden
/// while it's away.
enum PointerClick {
    /// A cover still catches clicks for a moment after it's told to ignore them, measured on macOS 27.
    private static let coverReleaseDelay = 0.05
    /// Long enough for a posted click to land before the pointer goes back.
    private static let landDelay = 0.03

    static func post(at point: CGPoint, through covers: [NSPanel]) {
        covers.forEach { $0.ignoresMouseEvents = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + coverReleaseDelay) {
            guard let pointer = CGEvent(source: nil)?.location else { return }
            // By default macOS ignores the real mouse for 0.25s after a posted event or a warp.
            let source = CGEventSource(stateID: .combinedSessionState)
            source?.localEventsSuppressionInterval = 0
            CGDisplayHideCursor(CGMainDisplayID())
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + landDelay) {
                CGWarpMouseCursorPosition(pointer)
                CGAssociateMouseAndMouseCursorPosition(1)
                CGDisplayShowCursor(CGMainDisplayID())
                covers.forEach { $0.ignoresMouseEvents = false }
            }
        }
    }
}
