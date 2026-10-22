import AppKit
import Foundation
import OvermarkCore

/// The zoom lens and the pointer halo.
///
/// These are split out of the main view because they are self-contained
/// drawing routines, and keeping them separate keeps each method short.
extension CursorEffectView {
    /// Draws a magnified lens showing the pixels under the pointer.
    ///
    /// The lens shows a *crop* of the screenshot around the pointer,
    /// magnified by `zoomFactor`. Drawing the whole screenshot into the lens
    /// would just show a shrunken picture of the screen rather than a
    /// magnification of the area the user is pointing at.
    func drawZoomLens(cursor: Point, in context: CGContext) {
        guard let backgroundImage else { return }

        let size = effects.zoomSize
        let radius = size / 2

        let destination = CGRect(
            x: cursor.x - radius,
            y: cursor.y - radius,
            width: size,
            height: size
        )

        // The region of the screen shown inside the lens, in points.
        let visibleSpan = size / max(effects.zoomFactor, 0.01)

        guard let crop = cropImage(
            backgroundImage,
            around: cursor,
            visibleSpan: visibleSpan
        ) else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Clip to the lens shape.
        switch effects.zoomShape {
        case .circle:
            context.addEllipse(in: destination)
        case .squircle:
            context.addPath(CGPath(
                roundedRect: destination,
                cornerWidth: size * 0.25,
                cornerHeight: size * 0.25,
                transform: nil
            ))
        }
        context.clip()

        // The cropped image keeps the screenshot's top-left origin, and
        // `CGContext.draw(_:in:)` places the first row at the top of the
        // destination rect, so no additional flip is needed here.
        context.draw(crop, in: destination)

        // Draw the lens border on top of the magnified content.
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.setLineWidth(3)
        switch effects.zoomShape {
        case .circle:
            context.strokeEllipse(in: destination)
        case .squircle:
            context.addPath(CGPath(
                roundedRect: destination,
                cornerWidth: size * 0.25,
                cornerHeight: size * 0.25,
                transform: nil
            ))
            context.strokePath()
        }
    }

    /// Crops the screenshot to the region around the pointer.
    ///
    /// The screenshot is in device pixels with a top-left origin, while the
    /// pointer is in view points with a bottom-left origin, so the vertical
    /// axis is flipped during the conversion.
    ///
    /// - Returns: The cropped image, or `nil` when the requested region falls
    ///   entirely outside the screenshot.
    private func cropImage(
        _ image: CGImage,
        around cursor: Point,
        visibleSpan: Double
    ) -> CGImage? {
        let scale = screen.scale > 0 ? screen.scale : 1
        let viewHeight = bounds.height

        // Pointer position in the screenshot's pixel space.
        let centerX = cursor.x * scale
        let centerY = (viewHeight - cursor.y) * scale

        let halfSpan = (visibleSpan / 2) * scale
        let source = CGRect(
            x: centerX - halfSpan,
            y: centerY - halfSpan,
            width: halfSpan * 2,
            height: halfSpan * 2
        )

        // Clamp the crop to the image, so the lens never samples pixels that
        // do not exist. The result is offset so the pointer stays centred on
        // what the user is pointing at.
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let clamped = source.intersection(imageBounds)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            return nil
        }

        return image.cropping(to: clamped)
    }

    /// Draws the styled ring around the pointer.
    ///
    /// The shape, fill opacity and border thickness all come from settings;
    /// the fill is kept translucent so what is under the pointer stays
    /// readable, and the border sits centered on the shape path like the old
    /// solid ring did.
    func drawHighlight(cursor: Point, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let radius = effects.highlightRadius
        let color = effects.highlightColor
        let rect = CGRect(
            x: cursor.x - radius,
            y: cursor.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = highlightPath(in: rect, shape: effects.highlightShape)

        context.setFillColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: max(0, min(1, effects.highlightFillOpacity))
        ))
        context.addPath(path)
        context.fillPath()

        let borderWidth = max(0, effects.highlightBorderWidth)
        if borderWidth >= 0.5 {
            context.setStrokeColor(CGColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: 1
            ))
            context.setLineWidth(borderWidth)
            context.addPath(path)
            context.strokePath()
        }
    }

    /// The configured ring shape as a reusable path.
    private func highlightPath(in rect: CGRect, shape: HighlightShape) -> CGPath {
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

    /// Plays one click ripple: a circle that expands and fades.
    ///
    /// Left clicks use the ring colour at full presence; right clicks draw a
    /// thinner, more subdued ripple, so the two feel different without
    /// needing a separate setting.
    func drawClickPulse(
        _ pulse: ClickPulse,
        originX: Double,
        originY: Double,
        in context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let progress = min(
            max(Date().timeIntervalSince(pulse.startedAt) / Self.pulseDuration, 0),
            1
        )
        let color = effects.highlightColor
        let isRight = pulse.button == .right
        let startRadius = effects.highlightRadius * 0.4
        let endRadius = effects.highlightRadius * 1.9
        let radius = (startRadius + (endRadius - startRadius) * progress)
            * (isRight ? 0.75 : 1)
        let alpha = (isRight ? 0.5 : 0.85) * (1 - progress)

        context.setStrokeColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: alpha
        ))
        context.setLineWidth(
            max(1.5, effects.highlightBorderWidth * (isRight ? 0.6 : 1))
        )
        context.strokeEllipse(in: CGRect(
            x: pulse.point.x - originX - radius,
            y: pulse.point.y - originY - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}
