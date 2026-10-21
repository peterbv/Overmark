import AppKit
import Foundation

/// Watches the text editor window so the overlay can be restored when the
/// user dismisses the window with the title bar button instead of the
/// Cancel button.
@MainActor
final class TextEditorWindowDelegate: NSObject, NSWindowDelegate {
    /// Called once the window is closed.
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
