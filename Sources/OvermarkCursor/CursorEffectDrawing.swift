import AppKit
import Foundation
import OvermarkCapture
import OvermarkCore

/// The zoom lens and the pointer halo.
///
/// These are split out of the main view because they are self-contained
/// drawing routines, and keeping them separate keeps each method short. The
/// painting itself lives in `CursorEffectRenderer` so the window recorder can
/// burn identical effects into recorded frames.
extension CursorEffectView {
    /// Draws a magnified lens showing the pixels under the pointer.
    ///
    /// The lens shows a *crop* of the screenshot around the pointer,
    /// magnified by `zoomFactor`. Drawing the whole screenshot into the lens
    /// would just show a shrunken picture of the screen rather than a
    /// magnification of the area the user is pointing at.
    ///
    /// On-screen the screenshot covers the whole view, so the content maps
    /// one-to-one into the image with `screen.scale` pixels per point.
    func drawZoomLens(cursor: Point, in context: CGContext) {
        guard let backgroundImage else { return }
        let scale = screen.scale > 0 ? screen.scale : 1

        CursorEffectRenderer.drawZoomLens(
            at: CGPoint(x: cursor.x, y: cursor.y),
            around: CGPoint(x: cursor.x, y: cursor.y),
            size: effects.zoomSize,
            zoomFactor: effects.zoomFactor,
            shape: effects.zoomShape,
            background: backgroundImage,
            contentOriginInPixels: .zero,
            pixelsPerPointX: scale,
            pixelsPerPointY: scale,
            pointHeight: bounds.height,
            in: context
        )
    }

    /// Draws the styled ring around the pointer.
    ///
    /// The shape, fill opacity and border thickness all come from settings;
    /// the fill is kept translucent so what is under the pointer stays
    /// readable, and the border sits centered on the shape path like the old
    /// solid ring did.
    func drawHighlight(cursor: Point, in context: CGContext) {
        CursorEffectRenderer.drawHighlight(
            center: CGPoint(x: cursor.x, y: cursor.y),
            radius: effects.highlightRadius,
            color: effects.highlightColor,
            shape: effects.highlightShape,
            borderWidth: effects.highlightBorderWidth,
            fillOpacity: effects.highlightFillOpacity,
            in: context
        )
    }

    /// Plays one click ripple: a circle that expands and fades.
    func drawClickPulse(
        _ pulse: ClickPulse,
        originX: Double,
        originY: Double,
        in context: CGContext
    ) {
        CursorEffectRenderer.drawRipple(
            center: CGPoint(
                x: pulse.point.x - originX,
                y: pulse.point.y - originY
            ),
            startedAt: pulse.startedAt,
            at: Date(),
            color: effects.highlightColor,
            highlightRadius: effects.highlightRadius,
            highlightBorderWidth: effects.highlightBorderWidth,
            isRight: pulse.button == .right,
            in: context
        )
    }
}
