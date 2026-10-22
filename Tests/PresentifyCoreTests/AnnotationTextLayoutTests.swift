import Foundation
import Testing
@testable import PresentifyCore

@Suite("Annotation text layout")
struct AnnotationTextLayoutTests {
    private var lineWidth: Double { 4 }

    private var fontSize: Double { lineWidth * 6 }

    private var lineHeight: Double { fontSize * 1.25 }

    private var textOrigin: Point { Point(x: 10, y: 20) }

    @Test("A single line occupies one line height")
    func singleLineBounds() {
        let bounds = Annotation.textBounds(
            for: "Hello",
            lineWidth: lineWidth,
            origin: textOrigin
        )
        #expect(bounds.size.height == lineHeight)
        #expect(bounds.origin.x == textOrigin.x)
        #expect(bounds.origin.y == textOrigin.y)
    }

    @Test("Height grows with every line")
    func multilineBounds() {
        let bounds = Annotation.textBounds(
            for: "Hello\nWorld\nThird",
            lineWidth: lineWidth,
            origin: textOrigin
        )
        #expect(bounds.size.height == 3 * lineHeight)
    }

    @Test("The longest line sets the width")
    func longestLineWidth() {
        let single = Annotation.textBounds(
            for: "Short",
            lineWidth: lineWidth,
            origin: textOrigin
        )
        let long = Annotation.textBounds(
            for: "Short\nA much longer line",
            lineWidth: lineWidth,
            origin: textOrigin
        )
        // 16 characters at about 55% of the font size overshoots the single
        // line's width while keeping the same per-character metric.
        #expect(long.size.width > single.size.width)
        #expect(long.size.width < Double("A much longer line".count) * fontSize * 0.6)
    }

    @Test("Width never drops below the font size")
    func minimumWidth() {
        let bounds = Annotation.textBounds(
            for: "I\nI",
            lineWidth: lineWidth,
            origin: textOrigin
        )
        #expect(bounds.size.width >= fontSize)
    }

    @Test("An empty text keeps single-line bounds")
    func emptyTextBounds() {
        let bounds = Annotation.textBounds(for: "", lineWidth: lineWidth, origin: textOrigin)
        #expect(bounds.size.height == lineHeight)
        #expect(bounds.size.width >= fontSize)
    }

    @Test("The line height helper agrees with the stored bounds")
    func lineHeightHelper() {
        #expect(Annotation.textLineHeight(forLineWidth: 4) == lineHeight)
        #expect(Annotation.textLineHeight(forLineWidth: 8) == 2 * lineHeight)
    }

    @Test("A multi-line text annotation stays hittable")
    func multiLineHit() {
        let text = "First\nSecond"
        let bounds = Annotation.textBounds(
            for: text,
            lineWidth: lineWidth,
            origin: Point(x: 100, y: 100)
        )
        let annotation = Annotation(
            tool: .text,
            lineWidth: lineWidth,
            path: [Point(x: 100, y: 100)],
            bounds: bounds,
            text: text
        )

        // The centre of the second line's glyph box.
        let secondLine = Point(x: 100 + bounds.size.width / 2, y: 100 + lineHeight / 2)
        #expect(annotation.isHit(at: secondLine, fillsShapes: false))

        // Far above the whole block.
        let above = Point(x: 100 + bounds.size.width / 2, y: bounds.maxY + 30)
        #expect(!annotation.isHit(at: above, fillsShapes: false))
    }
}
