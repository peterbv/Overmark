import CoreGraphics
import Foundation
import Testing
@testable import OvermarkCore

// MARK: - Coordinate conversion

@Suite("Coordinate conversion")
struct CoordinateTests {
    /// A 1440x900 display whose origin is the bottom-left of the primary
    /// screen.
    private let screen = ScreenFrame(
        origin: Point(x: 0, y: 0),
        size: Size(width: 1440, height: 900)
    )

    @Test("Quartz to AppKit flips the vertical axis")
    func quartzToAppKit() {
        // The top-left of the screen in Quartz is the top-left in AppKit,
        // but with the maximum y.
        let result = Point.fromQuartz(CGPoint(x: 10, y: 0), in: screen)

        #expect(result.x == 10)
        #expect(result.y == 900)
    }

    @Test("AppKit to Quartz round-trips")
    func roundTrip() {
        let original = Point(x: 320, y: 480)
        let quartz = original.toQuartz(in: screen)

        #expect(quartz.x == 320)
        #expect(quartz.y == 420)
        #expect(Point.fromQuartz(quartz, in: screen) == original)
    }

    @Test("A secondary display above the primary keeps its own origin")
    func secondaryDisplay() {
        // A display sitting above the primary has a positive y origin in
        // the global AppKit space.
        let upper = ScreenFrame(
            origin: Point(x: 0, y: 900),
            size: Size(width: 1440, height: 900)
        )

        let point = Point.fromQuartz(CGPoint(x: 100, y: 0), in: upper)

        #expect(point.x == 100)
        #expect(point.y == 1800)
    }
}

// MARK: - Annotations

@Suite("Annotation")
struct AnnotationTests {
    @Test("Bounds cover every point of the stroke")
    func bounds() {
        let points = [
            Point(x: 10, y: 20),
            Point(x: 40, y: 5),
            Point(x: 25, y: 60),
        ]

        let bounds = Annotation.bounds(of: points)

        #expect(bounds.minX == 10)
        #expect(bounds.minY == 5)
        #expect(bounds.maxX == 40)
        #expect(bounds.maxY == 60)
    }

    @Test("Bounds of an empty path are empty")
    func emptyBounds() {
        let bounds = Annotation.bounds(of: [])

        #expect(bounds.isEmpty)
        #expect(bounds.area == 0)
    }

    @Test("Drag bounds normalise the drag direction")
    func dragBounds() {
        let bounds = Annotation.dragBounds(
            from: Point(x: 100, y: 100),
            to: Point(x: 40, y: 30)
        )

        #expect(bounds.origin == Point(x: 40, y: 30))
        #expect(bounds.size == Size(width: 60, height: 70))
    }

    @Test("Drag based tools are the ones that follow a gesture")
    func dragBased() {
        #expect(AnnotationTool.pen.isDragBased)
        #expect(AnnotationTool.arrow.isDragBased)
        #expect(!AnnotationTool.text.isDragBased)
        #expect(!AnnotationTool.stepNumber.isDragBased)
    }

    @Test("Only persistent tools produce an annotation")
    func producesAnnotation() {
        #expect(AnnotationTool.pen.producesAnnotation)
        #expect(AnnotationTool.text.producesAnnotation)
        #expect(!AnnotationTool.spotlight.producesAnnotation)
        #expect(!AnnotationTool.laserPointer.producesAnnotation)
    }

    @Test("Moving shifts every point and the bounds")
    func movedShiftsPathAndBounds() {
        let annotation = Annotation(
            tool: .pen,
            path: [Point(x: 10, y: 10), Point(x: 40, y: 60)]
        )

        let moved = annotation.moved(by: Vector(dx: 30, dy: 15))

        #expect(moved.path == [Point(x: 40, y: 25), Point(x: 70, y: 75)])
        #expect(moved.bounds.minX == annotation.bounds.minX + 30)
        #expect(moved.bounds.maxY == annotation.bounds.maxY + 15)
        #expect(moved.id == annotation.id)
    }

    @Test("Moving a shape keeps its size and identity")
    func movedKeepsIdentityForShapes() {
        let annotation = Annotation(
            tool: .rectangle,
            color: .green,
            bounds: Annotation.dragBounds(
                from: Point(x: 20, y: 30),
                to: Point(x: 80, y: 90)
            )
        )

        let moved = annotation.moved(by: Vector(dx: 5, dy: -5))

        let isRectangle = moved.tool == .rectangle
        #expect(isRectangle)
        let isGreen = moved.color == .green
        #expect(isGreen)
        #expect(moved.lineWidth == annotation.lineWidth)
        #expect(moved.bounds.size == annotation.bounds.size)
        #expect(moved.bounds.origin == Point(x: 25, y: 25))
        #expect(moved.id == annotation.id)
    }

    @Test("Recolouring replaces the colour and clears the gradient")
    func withColorReplacesColorAndClearsTheGradient() {
        let original = Annotation(
            tool: .pen,
            path: [Point(x: 0, y: 0)],
            gradientColor: .blue
        )

        let recoloured = original.with(color: .orange)

        #expect(recoloured.color == .orange)
        #expect(recoloured.gradientColor == nil)
        #expect(recoloured.id == original.id)
        #expect(original.gradientColor == .blue)
    }
}
