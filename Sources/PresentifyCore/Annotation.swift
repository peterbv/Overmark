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

    public init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        color: Color = .red,
        lineWidth: Double = 4,
        path: [Point] = [],
        bounds: Rect = Rect(origin: .zero, size: .zero),
        text: String? = nil,
        stepNumber: Int? = nil,
        opacity: Double = 1
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
