import CoreGraphics
import Foundation

/// The drawing tools available in annotation mode.
///
/// The tool set mirrors what presenters actually need: mark things down, point
/// at them, and make them stand out — without a full Photoshop.
public enum AnnotationTool: String, Hashable, Sendable, Codable, CaseIterable {
    case pen
    case line
    case arrow
    case rectangle
    case ellipse
    case text
    case spotlight
    case blur
    case highlighter
    case stepNumber
    case laserPointer

    /// Whether the tool is one that produces a persistent annotation.
    ///
    /// `.blur`, `.spotlight` and `.laserPointer` are modelled for the future
    /// but the renderer draws nothing for them, so they must never claim to
    /// produce an annotation: doing so would let "ghost" annotations pile up
    /// in the document without ever being visible.
    public var producesAnnotation: Bool {
        switch self {
        case .pen, .line, .arrow, .rectangle, .ellipse, .text,
             .highlighter, .stepNumber:
            true
        case .spotlight, .blur, .laserPointer:
            false
        }
    }

    /// Whether the tool draws by dragging a gesture.
    public var isDragBased: Bool {
        switch self {
        case .pen, .line, .arrow, .rectangle, .ellipse, .blur, .highlighter:
            true
        case .text, .stepNumber, .spotlight, .laserPointer:
            false
        }
    }
}

/// The colour of an annotation stroke.
///
/// Colours are stored as RGBA components rather than `NSColor` so the core
/// module stays free of AppKit and remains trivially testable and portable.
public struct Color: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = Color(red: 1, green: 0.231, blue: 0.188, alpha: 1)
    public static let yellow = Color(red: 1, green: 0.827, blue: 0.176, alpha: 1)
    public static let green = Color(red: 0.204, green: 0.827, blue: 0.6, alpha: 1)
    public static let blue = Color(red: 0.204, green: 0.51, blue: 0.988, alpha: 1)
    public static let white = Color(red: 1, green: 1, blue: 1, alpha: 1)
    public static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)
    public static let orange = Color(red: 1, green: 0.549, blue: 0.153, alpha: 1)
    public static let pink = Color(red: 0.988, green: 0.353, blue: 0.627, alpha: 1)

    /// The palette shown in the annotation toolbar.
    public static let palette: [Color] = [
        .red, .yellow, .green, .blue, .orange, .pink, .white, .black,
    ]

    /// The colour reached from `self` after `t` of the way towards `other`.
    ///
    /// `t` 0 is `self`, `t` 1 is `other`, values outside 0...1 are clamped.
    /// Used by the gradient stroke, which blends the two ends of a mark.
    public func lerped(to other: Color, at t: Double) -> Color {
        let t = min(max(t, 0), 1)
        return Color(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }
}

/// A single annotation drawn on the canvas.
///
/// Annotations are immutable value types: editing one produces a new value
/// rather than mutating in place. That makes undo/redo a matter of swapping
/// arrays, and it keeps the canvas free of any shared mutable state.
public struct Annotation: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var tool: AnnotationTool
    public var color: Color
    /// Stroke width in points.
    public var lineWidth: Double
    /// Points the stroke passes through, in screen space.
    public var path: [Point]
    /// Bounding box of the annotation, in screen space.
    public var bounds: Rect
    /// Text payload, for `.text` annotations.
    public var text: String?
    /// Numeric payload, for `.stepNumber` annotations.
    public var stepNumber: Int?
    /// Opacity of the annotation (0...1).
    public var opacity: Double
    /// Whether the shape is drawn with a translucent interior.
    ///
    /// Stored at creation time (like the colour), so shapes keep the fill the
    /// user chose when drawing them and exports or recordings render exactly
    /// what the live canvas showed.
    public var fillsShapes: Bool
    /// Final colour of a gradient stroke, or `nil` for a solid stroke.
    ///
    /// When set, stroke tools blend from the annotation's colour at the start
    /// of the path to this colour at the end.
    public var gradientColor: Color?

    public init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        color: Color = .red,
        lineWidth: Double = 4,
        path: [Point] = [],
        bounds: Rect = Rect(origin: .zero, size: .zero),
        text: String? = nil,
        stepNumber: Int? = nil,
        opacity: Double = 1,
        fillsShapes: Bool = false,
        gradientColor: Color? = nil
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.path = path
        self.bounds = bounds
        self.text = text
        self.stepNumber = stepNumber
        self.opacity = opacity
        self.fillsShapes = fillsShapes
        self.gradientColor = gradientColor
    }

    /// Computes the bounding box of a sequence of points.
    public static func bounds(of points: [Point]) -> Rect {
        guard let first = points.first else {
            return Rect(origin: .zero, size: .zero)
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return Rect(
            origin: Point(x: minX, y: minY),
            size: Size(width: maxX - minX, height: maxY - minY)
        )
    }

    /// The rectangle a drag-based tool should fill, given a start and end point.
    public static func dragBounds(from start: Point, to end: Point) -> Rect {
        Rect(corner: start, corner: end)
    }
}

// MARK: - Hit testing

public extension Annotation {
    /// Extra slack, in points, beyond the drawn geometry when hit-testing.
    ///
    /// A presenter aims with a cursor, not a stylus, so the selectable area
    /// is a little wider than the ink: a near miss still deletes the mark
    /// the user is pointing at.
    static let hitSlack: Double = 6

    /// Finds the topmost annotation under a screen-space point.
    ///
    /// The array is scanned back to front because that is the painting order
    /// of the renderer: the last annotation drawn is the one the user sees
    /// on top, so it is the one that answers first. When `screen` is given,
    /// annotations belonging to a different display are skipped — the same
    /// centre-in-frame rule the screenshot compositor uses — so a right-click
    /// on one monitor never deletes a mark drawn on another.
    ///
    /// - Parameters:
    ///   - point: The point, in screen space.
    ///   - annotations: The candidate annotations, in painting order.
    ///   - fillsShapes: An override for whether filled shapes count their
    ///     interior. `nil` (the default) means each annotation decides with
    ///     its own stored `fillsShapes` flag, which is how it is drawn; a
    ///     value can force the answer for a caller that renders with a
    ///     different fill state.
    ///   - screen: The display the point belongs to, or `nil` to test against
    ///     the whole desktop.
    /// - Returns: The topmost annotation hit, or `nil` when none matches.
    static func annotation(
        at point: Point,
        in annotations: [Annotation],
        fillsShapes: Bool? = nil,
        on screen: ScreenFrame? = nil
    ) -> Annotation? {
        for annotation in annotations.reversed() {
            if let screen, !screen.frame.contains(annotation.bounds.center) { continue }
            if annotation.isHit(at: point, fillsShapes: fillsShapes) { return annotation }
        }
        return nil
    }

    /// Whether a screen-space point lands on the annotation.
    ///
    /// Pure geometry, faithful to what the renderer paints: strokes count
    /// their path, shapes count their outline (or interior when filled),
    /// text and step numbers count generous bounds. Tools that paint nothing
    /// — spotlight, blur, laser — are never hittable, matching
    /// `producesAnnotation`.
    func isHit(at point: Point, fillsShapes override: Bool? = nil) -> Bool {
        let fill = override ?? fillsShapes
        guard tool.producesAnnotation else { return false }

        switch tool {
        case .pen, .highlighter, .line, .arrow:
            return isStrokeHit(at: point)
        case .rectangle:
            return isRectangleHit(at: point, fillsShapes: fill)
        case .ellipse:
            return isEllipseHit(at: point, fillsShapes: fill)
        case .text:
            return isTextHit(at: point)
        case .stepNumber:
            return isStepNumberHit(at: point)
        case .spotlight, .blur, .laserPointer:
            return false
        }
    }

    /// The width the renderer paints this annotation's stroke with.
    ///
    /// The highlighter is an exception among the stroke tools: it multiplies
    /// the line width by six to paint a wide translucent band, so its hit
    /// area has to widen the same way.
    private var paintedStrokeWidth: Double {
        tool == .highlighter ? lineWidth * 6 : lineWidth
    }

    /// Whether the point lands on the drawn stroke this tool paints.
    private func isStrokeHit(at point: Point) -> Bool {
        let half = paintedStrokeWidth / 2 + Self.hitSlack

        guard path.count > 1, let first = path.first, let last = path.last else {
            // A single tap with a stroke tool paints a dot — a wide one for
            // the highlighter, matching its tripled dot radius.
            guard let only = path.first else { return false }
            let radius = tool == .highlighter ? lineWidth * 3 : lineWidth / 2
            return point.distance(to: only) <= radius + Self.hitSlack
        }

        switch tool {
        case .pen, .highlighter:
            return zip(path, path.dropFirst()).contains {
                point.distance(toSegment: $0, and: $1) <= half
            }
        case .line:
            return point.distance(toSegment: first, and: last) <= half
        case .arrow:
            if point.distance(toSegment: first, and: last) <= half { return true }
            // The two head strokes, built exactly as the renderer builds
            // them, so the hit area covers the visible arrowhead.
            let angle = atan2(last.y - first.y, last.x - first.x)
            let headLength = max(lineWidth * 3.5, 12)
            let spread = Double.pi / 7
            for offset in [spread, -spread] {
                let headAngle = angle + .pi + offset
                let headEnd = Point(
                    x: last.x + cos(headAngle) * headLength,
                    y: last.y + sin(headAngle) * headLength
                )
                if point.distance(toSegment: last, and: headEnd) <= half { return true }
            }
            return false
        default:
            return false
        }
    }

    /// Whether the point lands on a drawn rectangle: the outline band, or
    /// the interior when shapes are filled.
    private func isRectangleHit(at point: Point, fillsShapes: Bool) -> Bool {
        guard !bounds.isEmpty else { return false }
        if fillsShapes, bounds.contains(point) { return true }

        // Distance from the point to the closest point of the perimeter.
        let half = lineWidth / 2 + Self.hitSlack
        if bounds.contains(point) {
            let dx = min(abs(point.x - bounds.minX), abs(point.x - bounds.maxX))
            let dy = min(abs(point.y - bounds.minY), abs(point.y - bounds.maxY))
            return min(dx, dy) <= half
        }
        let outsideX = max(bounds.minX - point.x, point.x - bounds.maxX, 0)
        let outsideY = max(bounds.minY - point.y, point.y - bounds.maxY, 0)
        return (outsideX * outsideX + outsideY * outsideY).squareRoot() <= half
    }

    /// Whether the point lands on a drawn ellipse: the outline band, or the
    /// interior when shapes are filled.
    ///
    /// The ellipse is tested with the normalised quadratic form — the ratio
    /// `(dx/rx)² + (dy/ry)²` — grown and shrunk by the hit radius to make the
    /// band the stroke paints.
    private func isEllipseHit(at point: Point, fillsShapes: Bool) -> Bool {
        guard !bounds.isEmpty else { return false }
        let center = bounds.center
        let rx = bounds.size.width / 2
        let ry = bounds.size.height / 2
        guard rx > 0, ry > 0 else { return false }

        let dx = point.x - center.x
        let dy = point.y - center.y
        let hit = lineWidth / 2 + Self.hitSlack

        let outerX = rx + hit
        let outerY = ry + hit
        guard (dx * dx) / (outerX * outerX) + (dy * dy) / (outerY * outerY) <= 1 else {
            return false
        }
        if fillsShapes { return true }

        // The inner boundary of the band. A thin drag leaves no interior
        // band boundary at all — the shrunken ellipse degenerates — and then
        // every point inside the outer ellipse counts.
        let innerX = rx - hit
        let innerY = ry - hit
        guard innerX > 0, innerY > 0 else { return true }
        return (dx * dx) / (innerX * innerX) + (dy * dy) / (innerY * innerY) >= 1
    }

    /// Whether the point lands on drawn text.
    ///
    /// The stored bounds are a rough estimate of the glyphs' extent, so this
    /// widens them by an amount derived from the rendered font size
    /// (`lineWidth * 6`, as the renderer draws it) and the character count —
    /// generous on purpose, because the exact glyph metrics are not worth a
    /// Core Text dependency in the core module.
    private func isTextHit(at point: Point) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let fontSize = lineWidth * 6
        let padX = max(Self.hitSlack, fontSize * 0.3)
            + Double(max(text.count - 1, 0)) * fontSize * 0.1
        let padY = max(Self.hitSlack, fontSize * 0.45)
        let box = Rect(
            origin: bounds.origin.offsetBy(dx: -padX, dy: -padY),
            size: Size(width: bounds.size.width + padX * 2, height: bounds.size.height + padY * 2)
        )
        return box.contains(point)
    }

    /// Whether the point lands on a stamped step-number circle.
    private func isStepNumberHit(at point: Point) -> Bool {
        let radius = max(lineWidth * 4, 18)
        return point.distance(to: bounds.center) <= radius + Self.hitSlack
    }

    /// Whether the auto-erase timer applies to this annotation.
    ///
    /// Everything drawn or stamped fades away on its own when the timer is
    /// on — step-number stamps included. The coordinator keeps the step
    /// counter ahead of what has already faded, so a number is never shown
    /// for a second time until the canvas is cleared or a document is
    /// restored (see `AppCoordinator.syncStepNumber`). The dedicated effect
    /// tools (laser pointer, blur, spotlight) never reach the document, so
    /// they stay out of the timer by construction.
    var isFadeable: Bool {
        tool.producesAnnotation
    }
}

// MARK: - Text layout

public extension Annotation {
    /// The renderer's font size for a text annotation is the stroke width
    /// times this factor.
    static let textFontFactor: Double = 6

    /// Line spacing between the lines of a multi-line text annotation, as a
    /// factor of the font size.
    static let textLineHeightFactor: Double = 1.25

    /// The rendered line height for a given text stroke width.
    static func textLineHeight(forLineWidth lineWidth: Double) -> Double {
        lineWidth * textFontFactor * textLineHeightFactor
    }

    /// Approximate on-screen bounds of the glyphs a text annotation draws.
    ///
    /// The metrics are intentionally approximate: the stored bounds anchor
    /// the hit-test (which pads generously around them) and the per-screen
    /// filter, not glyph-exact layout. The width assumes an average glyph is
    /// a bit over half the font size wide, which overestimates narrow strings
    /// and underestimates wide ones by a small margin.
    static func textBounds(for text: String, lineWidth: Double, origin: Point) -> Rect {
        let fontSize = lineWidth * textFontFactor
        let lineHeight = fontSize * textLineHeightFactor
        let lines = text.components(separatedBy: .newlines)
        let longest = lines.map(\.count).max() ?? 1
        let width = max(Double(longest) * fontSize * 0.55, fontSize)
        let height = Double(lines.count) * lineHeight
        return Rect(origin: origin, size: Size(width: width, height: height))
    }
}
