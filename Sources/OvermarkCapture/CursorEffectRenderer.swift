import CoreGraphics
import Foundation
import OvermarkCore

/// Stateless painter for the cursor effects, written against `CGContext`
/// alone so the same code paints on-screen windows and recorded frames.
///
/// The on-screen path (`OvermarkCursor`) builds these calls on a context it
/// owns; the window recorder concatenates the frame's annotation transform
/// first and then paints in AppKit screen space, so effects land in the video
/// exactly where they float on the screen. Everything takes explicit
/// parameters: nothing here reads settings or global state.
public enum CursorEffectRenderer {
    /// How long one click ripple plays, in seconds.
    public static let rippleDuration: TimeInterval = 0.45

    /// Extra time after a ripple's duration in which late frames may still
    /// draw the tail of the animation.
    public static let rippleGrace: TimeInterval = 0.05

    // MARK: - Spotlight

    /// Dims `dimRect` except for a circle around `holeCenter`.
    ///
    /// The hole is punched with an even-odd clip instead of a clear blend, so
    /// the routine is safe on opaque destinations (recorded frames): clear
    /// blending would black them out there. `holeCenter == nil` dims the
    /// whole rect uniformly — displays that do not host the pointer.
    public static func drawSpotlight(
        dimRect: CGRect,
        holeCenter: CGPoint?,
        holeRadius: CGFloat,
        dimOpacity: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let path = CGMutablePath()
        path.addRect(dimRect)
        if let holeCenter {
            path.addEllipse(in: CGRect(
                x: holeCenter.x - holeRadius,
                y: holeCenter.y - holeRadius,
                width: holeRadius * 2,
                height: holeRadius * 2
            ))
        }
        context.addPath(path)
        context.clip(using: .evenOdd)

        context.setFillColor(CGColor(
            red: 0, green: 0, blue: 0,
            alpha: max(0, min(1, dimOpacity))
        ))
        context.fill(dimRect)
    }

    // MARK: - Highlight ring

    /// The configured ring shape as a reusable path.
    public static func highlightPath(in rect: CGRect, shape: HighlightShape) -> CGPath {
        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .squircle:
            return CGPath(
                roundedRect: rect,
                cornerWidth: rect.width * 0.25,
                cornerHeight: rect.height * 0.25,
                transform: nil
            )
        case .rhombus:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }

    /// Draws the styled ring around a point.
    ///
    /// The fill stays translucent so what is under the pointer stays
    /// readable, and the border sits centered on the shape path like the old
    /// solid ring did.
    public static func drawHighlight(
        center: CGPoint,
        radius: CGFloat,
        color: Color,
        shape: HighlightShape,
        borderWidth: CGFloat,
        fillOpacity: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = highlightPath(in: rect, shape: shape)

        context.setFillColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: max(0, min(1, fillOpacity))
        ))
        context.addPath(path)
        context.fillPath()

        let width = max(0, borderWidth)
        if width >= 0.5 {
            context.setStrokeColor(CGColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: 1
            ))
            context.setLineWidth(width)
            context.addPath(path)
            context.strokePath()
        }
    }

    // MARK: - Click ripple

    /// The one ring geometry for a ripple at `progress` (0…1).
    ///
    /// Left clicks use the ring colour at full presence; right clicks draw a
    /// thinner, more subdued ripple, so the two feel different without
    /// needing a separate setting.
    static func ripple(
        progress: Double,
        isRight: Bool,
        radius: CGFloat,
        borderWidth: CGFloat
    ) -> (radius: CGFloat, alpha: CGFloat, lineWidth: CGFloat) {
        let clamped = max(0, min(1, progress))
        let startRadius = radius * 0.4
        let endRadius = radius * 1.9
        let rippleRadius = (startRadius + (endRadius - startRadius) * clamped)
            * (isRight ? 0.75 : 1)
        let alpha = (isRight ? 0.5 : 0.85) * (1 - clamped)
        let lineWidth = max(1.5, borderWidth * (isRight ? 0.6 : 1))
        return (rippleRadius, alpha, lineWidth)
    }

    /// Plays one click ripple: a circle that expands and fades.
    ///
    /// - Parameters:
    ///   - center: Where the click happened, in the space the context is in.
    ///   - startedAt: When the animation started.
    ///   - now: The moment this frame is being painted.
    public static func drawRipple(
        center: CGPoint,
        startedAt: Date,
        at now: Date,
        color: Color,
        highlightRadius: CGFloat,
        highlightBorderWidth: CGFloat,
        isRight: Bool,
        in context: CGContext
    ) {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 0, elapsed < rippleDuration + rippleGrace else { return }

        context.saveGState()
        defer { context.restoreGState() }

        let (radius, alpha, lineWidth) = ripple(
            progress: elapsed / rippleDuration,
            isRight: isRight,
            radius: highlightRadius,
            borderWidth: highlightBorderWidth
        )

        context.setStrokeColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: alpha
        ))
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    // MARK: - Zoom lens

    /// The background region the lens shows, in the image's top-down pixel
    /// space.
    ///
    /// - Parameters:
    ///   - local: The pointer in content-local points (bottom-left origin).
    ///   - span: How much content the lens shows, in points.
    ///   - origin: Offset of the content region within the image, in pixels.
    ///   - pixelsPerPointX/Y: Content-to-pixel factors (distinct when the
    ///     stream stretches the window into the track).
    ///   - pointHeight: The content height in points, for the axis flip.
    ///   - imageSize: The image bounds the result is clamped to.
    /// - Returns: The clamped crop, or `nil` when the requested region falls
    ///   entirely outside the image.
    static func lensCropRect(
        around local: CGPoint,
        span: CGFloat,
        origin pixelOrigin: CGPoint,
        pixelsPerPointX: CGFloat,
        pixelsPerPointY: CGFloat,
        pointHeight: CGFloat,
        imageSize: CGSize
    ) -> CGRect? {
        // Pointer position in the image's top-down pixel space: x follows
        // points directly, y is measured from the top edge, mirroring the
        // on-screen lens's screenshot mapping.
        let centerX = pixelOrigin.x + local.x * pixelsPerPointX
        let centerY = pixelOrigin.y + (pointHeight - local.y) * pixelsPerPointY

        let halfSpanX = (span / 2) * pixelsPerPointX
        let halfSpanY = (span / 2) * pixelsPerPointY
        let source = CGRect(
            x: centerX - halfSpanX,
            y: centerY - halfSpanY,
            width: halfSpanX * 2,
            height: halfSpanY * 2
        )

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: max(0, imageSize.width),
            height: max(0, imageSize.height)
        )
        let clamped = source.intersection(imageBounds)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            return nil
        }
        return clamped
    }

    /// Maps the pointer from the screen it sits on to the screen that
    /// mirrors the lens.
    ///
    /// Both screens are treated as normalized work areas: a pointer at 25%
    /// across the source screen places the lens at 25% across the mirror
    /// screen. The returned destination point lives in the destination
    /// screen's local (origin-subtracted) space, ready to use as the lens
    /// center; the source point is the crop center in source-local space.
    /// When the source and destination are the same screen the mapping is
    /// the identity, which is exactly the built-in single-screen lens.
    ///
    /// - Returns: nil when the cursor is outside the source screen frame
    ///   (the crop would clamp away from real content) or a frame is empty.
    public static func mirrorLensPlacement(
        cursor: Point,
        source: ScreenFrame,
        destination: ScreenFrame
    ) -> (source: CGPoint, destination: CGPoint)? {
        guard source.size.width > 0, source.size.height > 0,
              destination.size.width > 0, destination.size.height > 0 else {
            return nil
        }
        let tx = cursor.x - source.origin.x
        let ty = cursor.y - source.origin.y
        guard tx >= -1, ty >= -1,
              tx <= source.size.width + 1, ty <= source.size.height + 1
        else { return nil }
        let relativeX = tx / source.size.width
        let relativeY = ty / source.size.height
        return (
            source: CGPoint(x: tx, y: ty),
            destination: CGPoint(
                x: relativeX * destination.size.width,
                y: relativeY * destination.size.height
            )
        )
    }

    /// Draws a magnified lens showing the pixels under the pointer.
    ///
    /// The lens shows a *crop* of `background` around the pointer, magnified
    /// by `zoomFactor`. Drawing the whole background into the lens would just
    /// show a shrunken picture rather than a magnification of the area being
    /// pointed at.
    ///
    /// - Parameters:
    ///   - center: Lens destination center, in the context's point space.
    ///   - local: The pointer in content-local points, for the crop mapping.
    ///   - background: The clean pixels under the content (the on-screen lens
    ///     uses a fresh screenshot; the recorder burns a snapshot taken
    ///     before annotations land in the frame).
    ///   - contentOriginInPixels: Where the content sits inside `background`,
    ///     in its top-down pixel space.
    public static func drawZoomLens(
        at center: CGPoint,
        around local: CGPoint,
        size lensSize: CGFloat,
        zoomFactor: Double,
        shape: ZoomShape,
        background: CGImage,
        contentOriginInPixels: CGPoint,
        pixelsPerPointX: CGFloat,
        pixelsPerPointY: CGFloat,
        pointHeight: CGFloat,
        in context: CGContext
    ) {
        let radius = lensSize / 2
        let destination = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: lensSize,
            height: lensSize
        )

        // The region of the content shown inside the lens, in points.
        let span = lensSize / max(zoomFactor, 0.01)
        guard let cropRect = lensCropRect(
            around: local,
            span: span,
            origin: contentOriginInPixels,
            pixelsPerPointX: pixelsPerPointX,
            pixelsPerPointY: pixelsPerPointY,
            pointHeight: pointHeight,
            imageSize: CGSize(width: background.width, height: background.height)
        ) else { return }
        guard let crop = background.cropping(to: cropRect) else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Clip to the lens shape.
        switch shape {
        case .circle:
            context.addEllipse(in: destination)
        case .squircle:
            context.addPath(CGPath(
                roundedRect: destination,
                cornerWidth: lensSize * 0.25,
                cornerHeight: lensSize * 0.25,
                transform: nil
            ))
        }
        context.clip()

        // The cropped image keeps a top-left origin, and `CGContext.draw`
        // places the first row at the top of the destination rect, so no
        // additional flip is needed here.
        context.draw(crop, in: destination)

        // Draw the lens border on top of the magnified content.
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.setLineWidth(3)
        switch shape {
        case .circle:
            context.strokeEllipse(in: destination)
        case .squircle:
            context.addPath(CGPath(
                roundedRect: destination,
                cornerWidth: lensSize * 0.25,
                cornerHeight: lensSize * 0.25,
                transform: nil
            ))
            context.strokePath()
        }
    }

    // MARK: - Laser pointer

    /// How long the laser trail keeps glowing, in seconds.
    ///
    /// Points older than this have faded out entirely and are dropped by the
    /// sources feeding this renderer, not by the drawing itself.
    public static let trailDuration: TimeInterval = 0.7

    /// The tail's style at `progress` (0 fresh … 1 about to fade out).
    ///
    /// The stroke thins towards the tail but never fully vanishes in width,
    /// while its alpha falls linearly to nothing — that combination reads as
    /// light dimming rather than a shrinking wire.
    static func laserFade(progress: Double) -> (widthFactor: Double, alpha: Double) {
        let clamped = max(0, min(1, progress))
        return (widthFactor: max(0.25, 1 - clamped), alpha: 0.85 * (1 - clamped))
    }

    /// Draws the laser trail: a fading polyline along recent pointer
    /// samples, oldest first.
    ///
    /// Segments with both ends inside `keep` are drawn; everything else is
    /// skipped, so a trail is never published across display borders into
    /// the wrong coordinates. On-screen each view passes its own bounds; the
    /// recorder passes the whole window (the frame buffer clips anyway).
    public static func drawLaserTrail(
        _ samples: [(point: CGPoint, at: Date)],
        at now: Date,
        color: Color,
        radius: Double,
        keep: CGRect,
        in context: CGContext
    ) {
        guard samples.count > 1 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        ))
        for index in 1..<samples.count {
            let start = samples[index - 1].point
            let end = samples[index].point
            guard keep.contains(CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)) else {
                continue
            }
            let age = now.timeIntervalSince(samples[index].at)
            guard age >= 0, age < trailDuration else { continue }
            let fade = laserFade(progress: age / trailDuration)
            context.setLineWidth(max(0.5, radius * 2 * fade.widthFactor))
            context.setAlpha(fade.alpha)
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }

    /// Draws the bright laser dot itself: a soft halo, a saturated core and
    /// a small white fleck for the punch of real presenter hardware.
    public static func drawLaserDot(
        at point: CGPoint,
        color: Color,
        radius: Double,
        in context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        let colour = CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        )

        context.setFillColor(colour)
        context.setAlpha(0.3)
        context.fillEllipse(in: CGRect(
            x: point.x - radius * 2.75,
            y: point.y - radius * 2.75,
            width: radius * 5.5,
            height: radius * 5.5
        ))

        context.setAlpha(0.95)
        context.fillEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setAlpha(0.55)
        context.fillEllipse(in: CGRect(
            x: point.x - radius * 0.4,
            y: point.y - radius * 0.4,
            width: radius * 0.8,
            height: radius * 0.8
        ))
    }
}
