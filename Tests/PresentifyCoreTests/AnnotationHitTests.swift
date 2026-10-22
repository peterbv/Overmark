import Foundation
import Testing
@testable import PresentifyCore

// MARK: - Stroke geometry

@Suite("Annotation hit testing")
struct AnnotationHitTests {
    /// A default-4-width pen stroke from (20, 50) to (100, 50).
    private var penStroke: Annotation {
        let path = [Point(x: 20, y: 50), Point(x: 100, y: 50)]
        return Annotation(
            tool: .pen,
            lineWidth: 4,
            path: path,
            bounds: Annotation.bounds(of: path)
        )
    }

    @Test("A stroke counts the points along its path")
    func strokeHit() {
        let stroke = penStroke
        #expect(stroke.isHit(at: Point(x: 60, y: 50), fillsShapes: false))
        #expect(stroke.isHit(at: Point(x: 104, y: 50), fillsShapes: false))
    }

    @Test("The hit area includes the slack around the ink")
    func strokeSlack() {
        let stroke = penStroke
        // Half width (2) + slack (6) = 8 points of tolerance.
        #expect(stroke.isHit(at: Point(x: 60, y: 57), fillsShapes: false))
        #expect(!stroke.isHit(at: Point(x: 60, y: 60), fillsShapes: false))
        #expect(!stroke.isHit(at: Point(x: 110, y: 50), fillsShapes: false))
    }

    @Test("A single tap with a stroke tool hits as a dot")
    func dotHit() {
        let dot = Annotation(tool: .pen, lineWidth: 4, path: [Point(x: 50, y: 50)])
        #expect(dot.isHit(at: Point(x: 55, y: 50), fillsShapes: false))
        #expect(!dot.isHit(at: Point(x: 60, y: 50), fillsShapes: false))
    }

    @Test("An arrow covers the shaft and the arrowhead strokes")
    func arrowHit() {
        let path = [Point(x: 20, y: 10), Point(x: 80, y: 10)]
        let arrow = Annotation(
            tool: .arrow,
            lineWidth: 4,
            path: path,
            bounds: Annotation.bounds(of: path)
        )
        // The head extends back-left from the tip; the midpoint of the
        // upper head stroke sits around (73.7, 13.0).
        #expect(arrow.isHit(at: Point(x: 50, y: 10), fillsShapes: false))
        #expect(arrow.isHit(at: Point(x: 73.7, y: 13), fillsShapes: false))
        #expect(!arrow.isHit(at: Point(x: 73.7, y: 26), fillsShapes: false))
    }

    @Test("The highlighter hit area matches its tripled width")
    func highlighterHit() {
        let path = [Point(x: 20, y: 50), Point(x: 100, y: 50)]
        let band = Annotation(
            tool: .highlighter,
            lineWidth: 4,
            path: path,
            bounds: Annotation.bounds(of: path)
        )
        // Painted at 24 wide: half (12) + slack (6) = 18 points.
        #expect(band.isHit(at: Point(x: 60, y: 66), fillsShapes: false))
        #expect(!band.isHit(at: Point(x: 60, y: 72), fillsShapes: false))
    }

    @Test("A wide pen would miss the highlighter's band")
    func penIsNotTheHighlighter() {
        let path = [Point(x: 20, y: 50), Point(x: 100, y: 50)]
        let stroke = Annotation(
            tool: .pen,
            lineWidth: 4,
            path: path,
            bounds: Annotation.bounds(of: path)
        )
        #expect(!stroke.isHit(at: Point(x: 60, y: 66), fillsShapes: false))
    }

    // MARK: - Shapes

    @Test("A rectangle counts its outline, and its interior when filled")
    func rectangleHit() {
        let rect = Annotation(
            tool: .rectangle,
            lineWidth: 4,
            bounds: Rect(origin: Point(x: 20, y: 20), size: Size(width: 80, height: 60))
        )
        #expect(rect.isHit(at: Point(x: 60, y: 20), fillsShapes: false))
        #expect(!rect.isHit(at: Point(x: 10, y: 50), fillsShapes: false))
        #expect(!rect.isHit(at: Point(x: 60, y: 50), fillsShapes: false))
        #expect(rect.isHit(at: Point(x: 60, y: 50), fillsShapes: true))
    }

    @Test("An ellipse counts its outline, and its interior when filled")
    func ellipseHit() {
        let ellipse = Annotation(
            tool: .ellipse,
            lineWidth: 4,
            bounds: Rect(origin: Point(x: 20, y: 20), size: Size(width: 80, height: 60))
        )
        #expect(ellipse.isHit(at: Point(x: 100, y: 50), fillsShapes: false))
        #expect(ellipse.isHit(at: Point(x: 112, y: 50), fillsShapes: false) == false)
        #expect(!ellipse.isHit(at: Point(x: 60, y: 50), fillsShapes: false))
        #expect(ellipse.isHit(at: Point(x: 60, y: 50), fillsShapes: true))
    }

    @Test("A thin drag ellipse still counts its flattened band")
    func flattenedEllipseHit() {
        let ellipse = Annotation(
            tool: .ellipse,
            lineWidth: 4,
            bounds: Rect(origin: Point(x: 20, y: 20), size: Size(width: 80, height: 10))
        )
        // The shrunken interior ellipse degenerates, so the band covers the
        // whole interior.
        #expect(ellipse.isHit(at: Point(x: 60, y: 25), fillsShapes: false))
    }

    // MARK: - Click-stamped annotations

    @Test("Text counts generous bounds around the glyphs")
    func textHit() {
        let text = Annotation(
            tool: .text,
            lineWidth: 4,
            path: [Point(x: 100, y: 100)],
            bounds: Rect(origin: Point(x: 100, y: 100), size: Size(width: 90, height: 20)),
            text: "Hola"
        )
        // Actual glyphs grow past the rough stored bounds: the hit box is
        // wider than them.
        #expect(text.isHit(at: Point(x: 200, y: 105), fillsShapes: false))
        #expect(!text.isHit(at: Point(x: 220, y: 105), fillsShapes: false))
        #expect(!text.isHit(at: Point(x: 150, y: 132), fillsShapes: false))
    }

    @Test("Empty text is never hittable")
    func emptyText() {
        let text = Annotation(
            tool: .text,
            lineWidth: 4,
            bounds: Rect(origin: Point(x: 100, y: 100), size: Size(width: 90, height: 20)),
            text: ""
        )
        #expect(!text.isHit(at: Point(x: 120, y: 105), fillsShapes: false))
    }

    @Test("A step number counts the circle it stamps")
    func stepNumberHit() {
        let step = Annotation(
            tool: .stepNumber,
            lineWidth: 4,
            path: [Point(x: 50, y: 50)],
            bounds: Rect(origin: Point(x: 50, y: 50), size: .zero),
            stepNumber: 1
        )
        // Radius max(18) + slack = 24.
        #expect(step.isHit(at: Point(x: 68, y: 50), fillsShapes: false))
        #expect(!step.isHit(at: Point(x: 76, y: 50), fillsShapes: false))
    }

    // MARK: - Selection rules

    @Test("The topmost annotation answering first is the one deleted")
    func topmostFirst() {
        let under = penStroke
        let over = {
            let path = [Point(x: 10, y: 10), Point(x: 40, y: 10)]
            return Annotation(
                tool: .pen,
                lineWidth: 4,
                path: path,
                bounds: Annotation.bounds(of: path)
            )
        }()
        let found = Annotation.annotation(
            at: Point(x: 20, y: 10),
            in: [under, over],
            fillsShapes: false
        )
        #expect(found?.id == over.id)
    }

    @Test("Annotations on another display are skipped")
    func screenFilter() {
        let foreign = Annotation(
            tool: .pen,
            lineWidth: 4,
            path: [Point(x: 2000, y: 50), Point(x: 2100, y: 50)],
            bounds: Rect(origin: Point(x: 2000, y: 50), size: Size(width: 100, height: 0))
        )
        let screen = ScreenFrame(origin: Point(x: 0, y: 0), size: Size(width: 1440, height: 900))
        let found = Annotation.annotation(
            at: Point(x: 2050, y: 50),
            in: [foreign],
            fillsShapes: false,
            on: screen
        )
        #expect(found == nil)
        // Without a display, the same point hits the same annotation.
        let unfiltered = Annotation.annotation(
            at: Point(x: 2050, y: 50),
            in: [foreign],
            fillsShapes: false
        )
        #expect(unfiltered?.id == foreign.id)
    }

    @Test("Tools that paint nothing are never hittable")
    func invisibleTools() {
        for tool in [AnnotationTool.spotlight, .blur, .laserPointer] {
            let annotation = Annotation(
                tool: tool,
                path: [Point(x: 10, y: 10)],
                bounds: Rect(origin: Point(x: 10, y: 10), size: Size(width: 40, height: 40))
            )
            #expect(!annotation.isHit(at: Point(x: 20, y: 20), fillsShapes: false))
        }
    }

    @Test("An empty document answers nothing")
    func nothingToHit() {
        #expect(Annotation.annotation(
            at: Point(x: 50, y: 50),
            in: [],
            fillsShapes: false
        ) == nil)
    }
}
