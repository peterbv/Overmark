import AppKit
import CoreGraphics
import Foundation

/// Resolves the primary display for the global AppKit coordinate space.
///
/// AppKit places the global origin at the *bottom-left* of the primary
/// display, and every conversion between global coordinate spaces (Quartz,
/// ScreenCaptureKit, `CGWindow` lists) flips around that display's height.
/// `NSScreen.screens` does **not** guarantee that the primary screen comes
/// first — on some setups the order follows the display initialization
/// order instead — so the primary is identified structurally: it is the one
/// anchored at (0, 0). Every module that maps screen geometry through
/// `OvermarkCapture` shares this definition.
public enum PrimaryScreen {
    /// The display anchored at (0, 0), falling back to the first screen.
    ///
    /// The fallback keeps the geometry defined (however unusually) when
    /// AppKit reports the primary somewhere else than (0, 0) — e.g. setups
    /// that mirror displays — instead of dropping the conversion.
    public static var screen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == NSPoint(x: 0, y: 0) }
            ?? NSScreen.screens.first
    }
}
