import CoreGraphics
import Foundation
import Testing
@testable import OvermarkCore

// MARK: - Geometry

@Suite("Rect")
struct RectTests {
    @Test("Building from two corners normalises negative extents")
    func normalisesCorners() {
        let rect = Rect(
            corner: Point(x: 100, y: 200),
            corner: Point(x: 50, y: 80)
        )

        #expect(rect.origin == Point(x: 50, y: 80))
        #expect(rect.size == Size(width: 50, height: 120))
        #expect(rect.minX == 50)
        #expect(rect.maxY == 200)
    }

    @Test("Union covers both rectangles")
    func union() {
        let a = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
        let b = Rect(origin: Point(x: 5, y: 5), size: Size(width: 10, height: 10))

        let result = a.union(b)

        #expect(result.minX == 0)
        #expect(result.minY == 0)
        #expect(result.maxX == 15)
        #expect(result.maxY == 15)
    }

    @Test("Contains includes the edges")
    func contains() {
        let rect = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))

        #expect(rect.contains(Point(x: 5, y: 5)))
        #expect(rect.contains(Point(x: 0, y: 0)))
        #expect(rect.contains(Point(x: 10, y: 10)))
        #expect(!rect.contains(Point(x: 11, y: 5)))
    }

    @Test("Intersects detects overlap")
    func intersects() {
        let a = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))
        let b = Rect(origin: Point(x: 5, y: 5), size: Size(width: 10, height: 10))
        let c = Rect(origin: Point(x: 20, y: 20), size: Size(width: 5, height: 5))

        #expect(a.intersects(b))
        #expect(!a.intersects(c))
    }

    @Test("Inset shrinks from every side and never goes negative")
    func inset() {
        let rect = Rect(origin: Point(x: 0, y: 0), size: Size(width: 10, height: 10))

        #expect(rect.inset(by: 2).size == Size(width: 6, height: 6))
        #expect(rect.inset(by: 20).size == Size(width: 0, height: 0))
    }
}

