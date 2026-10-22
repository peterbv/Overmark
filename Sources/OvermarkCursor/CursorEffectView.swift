import AppKit
import Foundation
import OvermarkCore

/// A transparent, non-activating view that draws the cursor effects.
///
/// Like the annotation overlay, this view never becomes key, so the user can
/// keep working in the app underneath while the effects are visible.
public final class CursorEffectView: NSView {
    /// The pointer position, in screen space.
    public var cursorLocation: Point = .zero {
        didSet { needsDisplay = true }
    }

    /// The effects to draw.
    public var effects: CursorEffects {
        didSet { needsDisplay = true }
    }

    /// The screenshot shown under the zoom lens.
    public var backgroundImage: CGImage? {
        didSet { needsDisplay = true }
    }

    /// The screen the effects cover.
    public var screen: ScreenFrame = ScreenFrame(origin: .zero, size: .zero) {
        didSet { needsDisplay = true }
    }

    public override init(frame frameRect: NSRect) {
        self.effects = CursorEffects()
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Convert the screen-space pointer into the view's own coordinates.
        // The view fills the window, so the window's frame origin is this
        // display's origin in screen space (bounds.origin is always (0, 0)
        // for a borderless window's content view and must NOT be used).
        let windowOrigin = window?.frame.origin
        let originX = windowOrigin.map { Double($0.x) } ?? screen.origin.x
        let originY = windowOrigin.map { Double($0.y) } ?? screen.origin.y
        let cursor = Point(
            x: cursorLocation.x - originX,
            y: cursorLocation.y - originY
        )

        // The pointer lives on exactly one display. Respectively effects that
        // follow the pointer — the lens, the highlight ring and the spotlight
        // hole — only make sense on that display; every other display keeps
        // its dimming layer without punching a hole for a pointer it hosts on
        // a neighbor.
        let isCursorHere =
            cursor.x >= bounds.minX - 1 && cursor.x <= bounds.maxX + 1 &&
            cursor.y >= bounds.minY - 1 && cursor.y <= bounds.maxY + 1

        if effects.isSpotlightEnabled {
            drawSpotlight(cursor: cursor, punchesHole: isCursorHere, in: context)
        }
        if effects.isZoomEnabled && isCursorHere {
            drawZoomLens(cursor: cursor, in: context)
        }
        if effects.isHighlightEnabled && isCursorHere {
            drawHighlight(cursor: cursor, in: context)
        }
    }

    // MARK: - Effects

    /// Dims the screen except for a circle around the pointer.
    ///
    /// On the display the pointer is on, the dimming layer punches a clean
    /// hole around the pointer. Displays without the pointer stay uniformly
    /// dimmed.
    private func drawSpotlight(cursor: Point, punchesHole: Bool, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(CGColor(
            red: 0, green: 0, blue: 0,
            alpha: effects.spotlightDimOpacity
        ))
        context.fill(bounds)

        guard punchesHole else { return }

        // Punch the spotlight out of the dimming layer, so the app below shows
        // through the hole.
        context.setBlendMode(.clear)
        let radius = effects.spotlightRadius
        context.fillEllipse(in: CGRect(
            x: cursor.x - radius,
            y: cursor.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.setBlendMode(.normal)
    }
}
