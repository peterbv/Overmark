import CoreGraphics
import Foundation
import OvermarkCore

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
    /// One display's capture plus the frame it covers in screen space.
    ///
    /// A loose input type the compositor stitches from, so the renderer
    /// stays independent of the capture service that produces the pieces.
    public struct DisplayPiece: Sendable {
        /// The captured screenshot, in device pixels.
        public let image: CGImage
        /// The display's frame in AppKit screen space.
        public let screen: ScreenFrame

        public init(image: CGImage, screen: ScreenFrame) {
            self.image = image
            self.screen = screen
        }
    }

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

    /// Composites the annotations over a screenshot of the whole desktop.
    ///
    /// A multi-monitor presentation spans one desktop across several
    /// displays; a screenshot that took only the first display would drop
    /// whatever the audience sees on the projector. Each display is
    /// captured (excluding Overmark's own chrome) and annotated on its
    /// own, then the pieces are stitched at their real positions into the
    /// bounding rectangle of the desktop.
    ///
    /// Layout runs on a pixel grid of the sharpest display, so a Retina
    /// screen keeps its detail and a lower-resolution display is drawn
    /// scaled up. Mirrored displays share their frame: they overlap in the
    /// stitched image and the last capture drawn wins.
    ///
    /// - Parameters:
    ///   - snapshots: One capture per attached display, in any order.
    ///   - annotations: All annotations, in screen space; each one is drawn
    ///     only on the display it belongs to.
    /// - Returns: The stitched desktop image, or `nil` with no snapshots.
    public static func desktopImage(
        from snapshots: [DisplayPiece],
        annotations: [Annotation]
    ) -> CGImage? {
        guard !snapshots.isEmpty else { return nil }
        guard snapshots.count > 1 else {
            let snapshot = snapshots[0]
            return composited(
                image: snapshot.image,
                annotations: annotations,
                screen: snapshot.screen
            )
        }

        // The bounding rectangle of every display, in AppKit points. Every
        // point of it is covered by some display, so the stitching leaves
        // no gaps.
        var desktop = snapshots[0].screen.frame
        for snapshot in snapshots.dropFirst() {
            desktop = desktop.union(snapshot.screen.frame)
        }

        let scale = snapshots.map { $0.screen.scale }.max() ?? 1
        guard scale > 0 else { return nil }
        let width = Int((desktop.size.width * scale).rounded())
        let height = Int((desktop.size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        for snapshot in snapshots {
            let annotated = composited(
                image: snapshot.image,
                annotations: annotations,
                screen: snapshot.screen
            )
            let frame = snapshot.screen.frame
            // AppKit points and Core Graphics points both run bottom-up, so
            // the piece sits at its own frame, shifted by the desktop's
            // minimum: the image itself is drawn upright by `draw`.
            context.draw(annotated, in: CGRect(
                x: (frame.minX - desktop.minX) * scale,
                y: (frame.minY - desktop.minY) * scale,
                width: frame.size.width * scale,
                height: frame.size.height * scale
            ))
        }

        return context.makeImage()
    }
}
