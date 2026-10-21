import CoreGraphics
import Foundation
import PresentifyCore

/// Renders annotations onto a Core Graphics context.
///
/// The renderer is a pure function of (annotations, style) → pixels, which
/// keeps it free of any state and makes it trivially testable: render into a
/// bitmap context, then compare against a known image.
public struct AnnotationRenderer: Sendable {
    /// The visual style applied to every annotation.
    public struct Style: Sendable {
        /// Scale factor from points to device pixels.
        public var scale: Double
        /// Whether shapes are filled with a translucent version of the colour.
        public var fillsShapes: Bool

        public init(scale: Double = 2, fillsShapes: Bool = false) {
            self.scale = scale
            self.fillsShapes = fillsShapes
        }
    }

    public var style: Style

    public init(style: Style = Style()) {
        self.style = style
    }

    /// Draws every annotation in order.
    ///
    /// - Parameters:
    ///   - annotations: The annotations to draw, in painting order.
    ///   - context: The destination context.
    ///   - origin: The screen-space origin of the destination rect, used to
    ///     translate screen coordinates into the context's user space.
    public func draw(
        annotations: [Annotation],
        in context: CGContext,
        origin: Point
    ) {
        context.saveGState()
        context.scaleBy(x: style.scale, y: style.scale)
        context.translateBy(x: -origin.x, y: -origin.y)

        for annotation in annotations {
            draw(annotation, in: context)
        }

        context.restoreGState()
    }

    /// Draws a single annotation.
    public func draw(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setAlpha(annotation.opacity)

        switch annotation.tool {
        case .pen, .highlighter:
            drawStroke(annotation, in: context, isHighlighter: annotation.tool == .highlighter)
        case .line:
            drawLine(annotation, in: context)
        case .arrow:
            drawArrow(annotation, in: context)
        case .rectangle:
            drawRectangle(annotation, in: context)
        case .ellipse:
            drawEllipse(annotation, in: context)
        case .text:
            drawText(annotation, in: context)
        case .stepNumber:
            drawStepNumber(annotation, in: context)
        case .blur, .spotlight, .laserPointer:
            // These are effects rendered by dedicated layers, not by the
            // annotation canvas itself.
            break
        }
    }

    /// Converts a core `Color` into a Core Graphics colour.
    func cgColor(for color: Color, alpha override: Double? = nil) -> CGColor {
        CGColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(override ?? color.alpha)
        )
    }
}

// MARK: - Compositing

/// Draws annotations on top of a captured screenshot.
///
/// The overlay is drawn by the app in its own windows, so a plain screen
/// capture does not contain the annotations. Compositing them into the image
/// is what makes the copied or saved screenshot match what the audience sees.
public enum AnnotationCompositor {
    /// Draws the annotations that fall on a display over its screenshot.
    ///
    /// - Parameters:
    ///   - image: The captured screenshot of the display.
    ///   - annotations: All annotations, in screen space.
    ///   - screen: The frame of the display the screenshot belongs to.
    /// - Returns: A new image with the annotations drawn on top.
    public static func composited(
        image: CGImage,
        annotations: [Annotation],
        screen: ScreenFrame
    ) -> CGImage {
        // Only the annotations that belong to this display are drawn, so a
        // multi-monitor setup does not paint one screen's marks on another.
        let relevant = annotations.filter { screen.frame.contains($0.bounds.center) }
        guard !relevant.isEmpty else { return image }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The screenshot is in device pixels while the annotations are in
        // points, so the scale factor converts between the two.
        let scale = CGFloat(screen.scale)
        let renderer = AnnotationRenderer(style: .init(scale: Double(scale)))

        // The screenshot's origin is the top-left corner of the display,
        // while the annotations use the bottom-left origin of screen space.
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: -screen.minY)
        context.translateBy(x: -screen.minX, y: 0)

        for annotation in relevant {
            renderer.draw(annotation, in: context)
        }

        context.restoreGState()

        guard let result = context.makeImage() else { return image }
        return result
    }
}
