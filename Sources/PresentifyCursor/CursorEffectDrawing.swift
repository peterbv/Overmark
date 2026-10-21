import AppKit
import Foundation
import PresentifyCore

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

    /// Draws a coloured ring around the pointer.
    func drawHighlight(cursor: Point, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        let radius = effects.highlightRadius
        let color = effects.highlightColor

        context.setFillColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 0.35
        ))
        context.fillEllipse(in: CGRect(
            x: cursor.x - radius,
            y: cursor.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        context.setStrokeColor(CGColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        ))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(
            x: cursor.x - radius,
            y: cursor.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}
