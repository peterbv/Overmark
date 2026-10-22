import AppKit
import OvermarkCore

/// A borderless, transparent panel that floats above other apps.
///
/// Two properties make this work as an annotation surface:
///
/// - `canBecomeKey` is `false`, so clicking the overlay never steals focus
///   from the app the user is annotating. The user keeps typing in their
///   document while drawing.
/// - The style mask includes `.nonactivatingPanel`, which is what allows a
///   panel to receive mouse events without becoming the active app.
public final class OverlayPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        // Above normal windows, but below the system UI (menu bar, Dock).
        level = .statusBar
        // Follow the user across Spaces and stay visible in full screen.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // The panel must not participate in window cycling or the window menu.
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    /// Shows the panel without activating the app.
    public func presentAboveAll() {
        orderFrontRegardless()
    }

    /// Hides the panel and removes it from the screen.
    public func dismiss() {
        orderOut(nil)
    }
}
