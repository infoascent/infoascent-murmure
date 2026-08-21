import AppKit
import ApplicationServices

/// Where the text caret is on screen, so the HUD can sit next to what you're typing into
/// rather than in a fixed corner.
///
/// Asked of the Accessibility API, which is already available to this app — the same
/// permission that makes the push-to-talk tap possible. Not every app answers: Electron
/// apps, terminals and canvas-drawn editors frequently expose no caret bounds at all. So
/// every step degrades rather than fails, ending at the mouse pointer, which is near enough
/// to where you're looking to be a reasonable last resort.
enum CaretLocator {
    /// - Returns: the caret's rect in screen coordinates (origin bottom-left, the coordinate
    ///   space `NSWindow.setFrameOrigin` uses), or nil if nothing could be resolved.
    static func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()

        guard let focused = copyElement(system, kAXFocusedUIElementAttribute) else { return nil }

        // The caret is a *range* on the focused element, and its bounds are obtained by
        // asking the element to map that range back to screen space. Two hops, both of which
        // an app may decline to answer.
        guard let range = copyValue(focused, kAXSelectedTextRangeAttribute) else { return nil }

        var bounds: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &bounds
        )
        guard status == .success, let bounds else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }

        // A zero-width caret is normal; a zero-height one means the app answered with
        // nothing useful.
        guard rect.height > 0 else { return nil }

        return flipped(rect)
    }

    /// The caret if the focused app will say, otherwise the mouse pointer.
    static func anchorRect() -> NSRect {
        if let caret = caretRect() { return caret }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 18)
    }

    // MARK: - Accessibility plumbing

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    /// Accessibility reports screen coordinates with the origin at the *top* left of the
    /// primary display; AppKit window frames use the bottom left. Without this flip the HUD
    /// lands mirrored vertically — near the bottom of the screen when you're typing at the
    /// top, which looks like it is simply appearing in the wrong place at random.
    private static func flipped(_ rect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let maxY = primary.frame.maxY
        return NSRect(
            x: rect.origin.x,
            y: maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
