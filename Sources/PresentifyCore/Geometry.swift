import CoreGraphics
import Foundation

/// A point in screen space.
///
/// Presentify standardises on **AppKit screen coordinates**: origin at the
/// bottom-left of the primary display, `y` increasing upwards, units = points
/// (not pixels). Every platform boundary (CoreGraphics events, ScreenCaptureKit
/// images, `NSScreen.frame`) converts into this space explicitly.
public struct Point: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

extension Point {
    /// Translates a CoreGraphics/Quartz point (origin top-left) into AppKit
    /// screen space (origin bottom-left) for the display that contains it.
    ///
    /// - Parameters:
    ///   - quartzPoint: Point in global Quartz coordinates.
    ///   - screen: The display the point belongs to, used to derive the flip origin.
    public static func fromQuartz(_ quartzPoint: CGPoint, in screen: ScreenFrame) -> Point {
        Point(x: quartzPoint.x, y: screen.maxY - quartzPoint.y)
    }

    /// Converts back to global Quartz coordinates (origin top-left).
    public func toQuartz(in screen: ScreenFrame) -> CGPoint {
        CGPoint(x: x, y: screen.maxY - y)
    }
}

extension Point {
    public func offsetBy(dx: Double, dy: Double) -> Point {
        Point(x: x + dx, y: y + dy)
    }

    public func distance(to other: Point) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The shortest distance from the receiver to a line segment.
    ///
    /// Works in both directions along the segment (clamped to its ends), so
    /// the caller can treat a stroke as a chain of segments without caring
    /// where a point projects to. A degenerate segment — both ends equal —
    /// measures as the distance to that end point.
    public func distance(toSegment start: Point, and end: Point) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: start) }
        let t = max(0, min(1, ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared))
        return distance(to: Point(x: start.x + t * dx, y: start.y + t * dy))
    }

    public func translated(by translation: Vector) -> Point {
        Point(x: x + translation.dx, y: y + translation.dy)
    }
}

/// A translation in screen space.
public struct Vector: Hashable, Sendable, Codable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = Vector(dx: 0, dy: 0)
}

/// The rectangle of a display in AppKit screen coordinates.
///
/// Wrapping the display geometry keeps the flip arithmetic in one place instead
/// of scattering `maxY` maths across the capture and overlay layers.
public struct ScreenFrame: Hashable, Sendable, Codable {
    /// Origin (bottom-left) of the display in global screen coordinates.
    public var origin: Point
    /// Size of the display in points.
    public var size: Size
    /// Backing scale factor (2.0 on Retina).
    public var scale: Double

    public init(origin: Point, size: Size, scale: Double = 1) {
        self.origin = origin
        self.size = size
        self.scale = scale
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    public var frame: Rect { Rect(origin: origin, size: size) }
}

/// A width/height pair in points.
public struct Size: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

/// An axis-aligned rectangle in screen space.
///
/// Rectangles are stored as origin + size rather than as two corners so that
/// dragging a shape never inverts the geometry: the model simply keeps a
/// non-negative width and height at all times.
public struct Rect: Hashable, Sendable, Codable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    /// Builds a rectangle from two arbitrary corners, normalising the result so
    /// that width and height are never negative.
    public init(corner a: Point, corner b: Point) {
        let origin = Point(x: min(a.x, b.x), y: min(a.y, b.y))
        let size = Size(width: abs(b.x - a.x), height: abs(b.y - a.y))
        self.init(origin: origin, size: size)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var center: Point { Point(x: midX, y: midY) }
    public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }
    public var area: Double { size.width * size.height }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    public func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    public func inset(by amount: Double) -> Rect {
        Rect(
            origin: Point(x: minX + amount, y: minY + amount),
            size: Size(width: max(0, size.width - amount * 2), height: max(0, size.height - amount * 2))
        )
    }

    /// Returns the smallest rectangle containing both receivers.
    public func union(_ other: Rect) -> Rect {
        Rect(
            corner: Point(x: min(minX, other.minX), y: min(minY, other.minY)),
            corner: Point(x: max(maxX, other.maxX), y: max(maxY, other.maxY))
        )
    }
}

