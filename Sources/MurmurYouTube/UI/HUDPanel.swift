import AppKit
import SwiftUI

/// The floating pill that appears while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**. If it
/// did, the user's text field would lose focus and `TextInjector` would have nothing to
/// insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(origin: .zero, size: HUDView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let hosting = NSHostingView(rootView: HUDView(controller: controller))
        hosting.frame = NSRect(origin: .zero, size: HUDView.size)
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Parks the pill just below the text caret, so it sits with what you're typing rather
    /// than in a corner you aren't looking at.
    ///
    /// Below rather than above: a caret is usually at the end of what you've just written,
    /// and the space underneath is empty while the space above holds the text you're
    /// still reading.
    func reposition() {
        let anchor = CaretLocator.anchorRect()
        let size = frame.size
        let gap: CGFloat = 8

        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - size.height - gap
        )

        // Keep the whole pill on the screen it landed on. Without this it disappears off
        // the bottom edge whenever you dictate into the last line of a full-height window.
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
            if origin.y < visible.minY + gap {
                // No room below: flip above the caret instead of clamping onto it.
                origin.y = anchor.maxY + gap
            }
            origin.y = min(origin.y, visible.maxY - size.height - gap)
        }

        setFrameOrigin(origin)
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}
