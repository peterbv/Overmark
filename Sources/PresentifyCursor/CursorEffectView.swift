import AppKit
import Foundation
import PresentifyCore

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
        let local = Point(x: Double(bounds.origin.x), y: Double(bounds.origin.y))
        let cursor = Point(
            x: cursorLocation.x - local.x,
            y: cursorLocation.y - local.y
        )

        if effects.isSpotlightEnabled {
            drawSpotlight(cursor: cursor, in: context)
        }
        if effects.isZoomEnabled {
            drawZoomLens(cursor: cursor, in: context)
        }
        if effects.isHighlightEnabled {
            drawHighlight(cursor: cursor, in: context)
        }
    }

    // MARK: - Effects

    /// Dims the screen except for a circle around the pointer.
    private func drawSpotlight(cursor: Point, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setFillColor(CGColor(
            red: 0, green: 0, blue: 0,
            alpha: effects.spotlightDimOpacity
        ))
        context.fill(bounds)

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
