import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OvermarkCapture
@testable import OvermarkCore

/// Shorthand for the compositor's input piece type.
private typealias DisplayPiece = AnnotationCompositor.DisplayPiece

@Suite("Annotation compositing")
struct AnnotationCompositorTests {
    /// A 200x100 display at the origin of the primary screen.
    private let screen = ScreenFrame(
        origin: Point(x: 0, y: 0),
        size: Size(width: 200, height: 100)
    )

    /// Builds a solid white image of the given size.
    private func whiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Reads the raw RGBA bytes of an image.
    ///
    /// The image is drawn into a known-format context first, so the byte
    /// layout is guaranteed to be four bytes per pixel in RGBA order.
    private func rawPixels(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return Array(UnsafeBufferPointer(start: buffer, count: width * height * 4))
    }

    /// The colour of a pixel, given its row and column.
    ///
    /// The returned buffer is laid out top-down: row 0 is the top of the
    /// image, and row `height - 1` is the bottom (the tests convert from
    /// AppKit's y-up coordinates with `row = height - 1 - y`).
    private func pixel(
        of pixels: [UInt8],
        width: Int,
        row: Int,
        column: Int
    ) -> (r: Int, g: Int, b: Int) {
        let index = (row * width + column) * 4
        return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
    }

    @Test("An image without annotations is returned untouched")
    func noAnnotationsReturnsOriginal() {
        let image = whiteImage(width: 200, height: 100)

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [],
            screen: screen
        )

        #expect(result === image)
    }

    @Test("Annotations on another display are not drawn")
    func annotationsAreFilteredByDisplay() {
        let image = whiteImage(width: 200, height: 100)
        // A stroke that belongs to a second display, off to the right.
        let elsewhere = Annotation(
            tool: .pen,
            color: .red,
            lineWidth: 8,
            path: [Point(x: 500, y: 50), Point(x: 600, y: 50)],
            bounds: Rect(
                origin: Point(x: 500, y: 50),
                size: Size(width: 100, height: 0)
            )
        )

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [elsewhere],
            screen: screen
        )

        // Nothing was drawn, so the image is the original one.
        #expect(result === image)
    }

    @Test("An annotation lands in the same visual place as the overlay")
    func annotationMatchesTheOverlayOrientation() {
        // A 200x100 image whose upper half is red and lower half is blue.
        // In CoreGraphics the origin is bottom-left, so the red half is the
        // one that appears at the top of the screen.
        let context = CGContext(
            data: nil,
            width: 200,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        let image = context.makeImage()!

        // A green stroke near the top of the display in screen space.
        let marker = Annotation(
            tool: .pen,
            color: .green,
            lineWidth: 10,
            path: [Point(x: 20, y: 90), Point(x: 60, y: 90)],
            bounds: Rect(
                origin: Point(x: 20, y: 90),
                size: Size(width: 40, height: 0)
            )
        )

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [marker],
            screen: screen
        )

        let pixels = rawPixels(of: result)
        let width = result.width

        // The buffer of a bitmap context is stored top-down, so row 0 is the
        // top of the screen. The stroke sits at screen y = 90 of a 100pt
        // tall display, which is row 10 of the buffer.
        let onStroke = pixel(of: pixels, width: width, row: 10, column: 40)
        #expect(onStroke.g > 150)
        #expect(onStroke.r < 120)

        // The stroke is not at the bottom of the screen.
        let atBottom = pixel(
            of: pixels, width: width, row: result.height - 1, column: 40
        )
        #expect(atBottom.g < 100)

        // The screenshot underneath is left untouched: the top of the screen
        // is red and the bottom is blue.
        let topLeft = pixel(of: pixels, width: width, row: 2, column: 5)
        #expect(topLeft.r > 200)

        let bottomLeft = pixel(
            of: pixels, width: width, row: result.height - 1, column: 5
        )
        #expect(bottomLeft.b > 200)
    }

    @Test("Multi-line text draws every line inside its bounds")
    func multilineTextRendering() {
        // lineWidth 8 → font 48, line height 60. The two "AB" lines sit at
        // baselines 102 and 42 in a 120pt-tall block; the band between them
        // must stay white.
        let tallScreen = ScreenFrame(
            origin: Point(x: 0, y: 0),
            size: Size(width: 200, height: 200)
        )
        let image = whiteImage(width: 200, height: 200)
        let origin = Point(x: 20, y: 30)
        let annotation = Annotation(
            tool: .text,
            color: .red,
            lineWidth: 8,
            path: [origin],
            bounds: Annotation.textBounds(for: "AB\nAB", lineWidth: 8, origin: origin),
            text: "AB\nAB"
        )

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [annotation],
            screen: tallScreen
        )

        let pixels = rawPixels(of: result)
        let width = result.width

        /// Counts strongly-red pixels along a horizontal band.
        func redInk(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Int {
            var count = 0
            for row in rows where row >= 0 && row < result.height {
                for column in columns where column >= 0 && column < width {
                    let sample = pixel(of: pixels, width: width, row: row, column: column)
                    if sample.r > 150 && sample.g < 100 && sample.b < 100 { count += 1 }
                }
            }
            return count
        }

        // Buffer rows run top-down: row = 199 - y. The first line inks
        // roughly y 100..136 (rows 63..99), the second y 40..76
        // (rows 123..159), and the band between them stays white.
        #expect(redInk(rows: 74...84, columns: 25...70) > 3)
        #expect(redInk(rows: 137...147, columns: 25...70) > 3)
        #expect(redInk(rows: 104...115, columns: 25...70) == 0)
    }

    /// Builds a solid image of the given colour and size.
    private func solidImage(_ color: CGColor, width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Screen freeze

    @Test("The frozen frame replaces the capture")
    func frozenFrameReplacesTheCapture() {
        let capture = solidImage(red, width: 200, height: 100)
        let frame = solidImage(white, width: 200, height: 100)

        let result = AnnotationCompositor.composited(
            image: capture,
            annotations: [],
            screen: screen,
            frozen: frame
        )

        // The still is what the audience saw: every pixel of the output is
        // the frozen frame, the live capture is dropped even though the
        // canvas carries no annotation.
        let pixels = rawPixels(of: result)
        let topLeft = pixel(of: pixels, width: result.width, row: 2, column: 5)
        #expect(topLeft.r > 200)
        #expect(topLeft.g > 200)
        #expect(topLeft.b > 200)
    }

    @Test("The frozen frame clears the board colour when both are answered")
    func frozenFrameWinsOverTheBoardFill() {
        let capture = whiteImage(width: 200, height: 100)
        let frame = solidImage(red, width: 200, height: 100)

        let result = AnnotationCompositor.composited(
            image: capture,
            annotations: [],
            screen: screen,
            backdrop: CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            frozen: frame
        )

        // The session never shows a board and a still at once; if both
        // resolvers answer, the frozen frame is the one that applied.
        let pixels = rawPixels(of: result)
        let centre = pixel(of: pixels, width: result.width, row: 50, column: 100)
        #expect(centre.r > 200)
        #expect(centre.g < 100)
    }

    @Test("With no frozen frame and no board the capture survives untouched")
    func nothingToCompositeKeepsTheCapture() {
        let image = whiteImage(width: 200, height: 100)

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [],
            screen: screen,
            frozen: nil
        )

        #expect(result === image)
    }

    // MARK: - Desktop stitching (multi-monitor)

    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)

    @Test("No snapshots produce no image")
    func emptySnapshotsProduceNothing() {
        #expect(AnnotationCompositor.desktopImage(from: [], annotations: []) == nil)
    }

    @Test("A single display composites as before")
    func singleDisplay() {
        let image = whiteImage(width: 200, height: 100)
        let snapshot = DisplayPiece(image: image, screen: screen)

        let result = AnnotationCompositor.desktopImage(
            from: [snapshot],
            annotations: []
        )

        #expect(result === image)
    }

    @Test("Side-by-side displays are stitched left to right")
    func sideBySideStitching() {
        let left = DisplayPiece(
            image: whiteImage(width: 200, height: 100),
            screen: ScreenFrame(origin: Point(x: 0, y: 0), size: Size(width: 200, height: 100)),
        )
        let right = DisplayPiece(
            image: solidImage(red, width: 200, height: 100),
            screen: ScreenFrame(origin: Point(x: 200, y: 0), size: Size(width: 200, height: 100)),
        )
        // A green mark on the left display, a blue one on the right. Both
        // annotations live in global screen space.
        let greenPath = [Point(x: 10, y: 50), Point(x: 60, y: 50)]
        let bluePath = [Point(x: 210, y: 50), Point(x: 260, y: 50)]
        let greenStroke = Annotation(
            tool: .pen, color: .green, lineWidth: 8,
            path: greenPath, bounds: Annotation.bounds(of: greenPath)
        )
        let blueStroke = Annotation(
            tool: .pen, color: .blue, lineWidth: 8,
            path: bluePath, bounds: Annotation.bounds(of: bluePath)
        )

        let result = AnnotationCompositor.desktopImage(
            from: [left, right],
            annotations: [greenStroke, blueStroke]
        )!

        // The bounding rectangle of the desktop, at the sharpest scale.
        #expect(result.width == 400)
        #expect(result.height == 100)

        let pixels = rawPixels(of: result)
        // Memory row 50 is the vertical middle of the image.

        // Left display's screenshot (white) with its green stroke across
        // the middle at image columns 10..60.
        let leftEdge = pixel(of: pixels, width: result.width, row: 20, column: 5)
        #expect(leftEdge.r > 200)

        let onGreen = pixel(of: pixels, width: result.width, row: 50, column: 35)
        #expect(onGreen.g > 170)
        #expect(onGreen.r < 140)

        // The right display's screenshot sits at columns 200..400, red.
        let rightEdge = pixel(of: pixels, width: result.width, row: 20, column: 300)
        #expect(rightEdge.r > 200)
        #expect(rightEdge.g < 60)

        // The blue stroke on the right display lands at columns 210..260 —
        // the display's own coordinates plus its origin, each mark on its
        // own screen.
        let onBlue = pixel(of: pixels, width: result.width, row: 50, column: 235)
        #expect(onBlue.b > 200)
        #expect(onBlue.r < 140)
    }

    @Test("A display above the primary sits at the top of the image")
    func verticalStitching() {
        let bottom = DisplayPiece(
            image: whiteImage(width: 200, height: 100),
            screen: ScreenFrame(origin: Point(x: 0, y: 0), size: Size(width: 200, height: 100)),
        )
        let top = DisplayPiece(
            image: solidImage(red, width: 200, height: 100),
            screen: ScreenFrame(origin: Point(x: 0, y: 100), size: Size(width: 200, height: 100)),
        )

        let result = AnnotationCompositor.desktopImage(
            from: [bottom, top],
            annotations: []
        )!

        #expect(result.width == 200)
        #expect(result.height == 200)

        let pixels = rawPixels(of: result)
        // Memory row 0 is the top of the image, which is the top display.
        let topEdge = pixel(of: pixels, width: result.width, row: 20, column: 100)
        #expect(topEdge.r > 200)
        #expect(topEdge.g < 60)

        let bottomEdge = pixel(of: pixels, width: result.width, row: 150, column: 100)
        #expect(bottomEdge.r > 200)
        #expect(bottomEdge.g > 200)
    }

    @Test("Mixed scales lay out on the sharpest display's pixel grid")
    func mixedScaleStitching() {
        // A 1x display of 100x50 points and a Retina 2x display of the same
        // point size, wedged to its right.
        let humble = DisplayPiece(
            image: whiteImage(width: 100, height: 50),
            screen: ScreenFrame(
                origin: Point(x: 0, y: 0),
                size: Size(width: 100, height: 50),
                scale: 1
            ),
        )
        let retina = DisplayPiece(
            image: solidImage(red, width: 200, height: 100),
            screen: ScreenFrame(
                origin: Point(x: 100, y: 0),
                size: Size(width: 100, height: 50),
                scale: 2
            ),
        )

        let result = AnnotationCompositor.desktopImage(
            from: [humble, retina],
            annotations: []
        )!

        // 200x50 points at a 2x grid.
        #expect(result.width == 400)
        #expect(result.height == 100)

        let pixels = rawPixels(of: result)
        let leftEdge = pixel(of: pixels, width: result.width, row: 20, column: 5)
        #expect(leftEdge.r > 200 && leftEdge.g > 200)
        let rightEdge = pixel(of: pixels, width: result.width, row: 20, column: 300)
        #expect(rightEdge.r > 200)
        #expect(rightEdge.g < 60)
    }

    @Test("A filled rectangle exports with its interior")
    func filledShapeExportsLikeTheCanvas() {
        let image = whiteImage(width: 200, height: 100)
        let rect = Annotation(
            tool: .rectangle,
            color: .red,
            path: [Point(x: 20, y: 30), Point(x: 140, y: 80)],
            bounds: Rect(origin: Point(x: 20, y: 30), size: Size(width: 120, height: 50)),
            fillsShapes: true
        )

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [rect],
            screen: screen
        )

        // The fill flag lives on the annotation now, so the compositor —
        // which passes no fill state of its own — still shows the interior.
        let pixels = rawPixels(of: result)
        let inside = pixel(of: pixels, width: 200, row: 99 - 55, column: 80)
        #expect(inside.r > 250)  // 25% red over white
        #expect(inside.g < 230)  // ...and green pulled toward red's g
    }

    @Test("A gradient pen stroke blends along its length")
    func gradientStrokeBlendsAlongItsLength() {
        let image = whiteImage(width: 200, height: 100)
        let stroke = Annotation(
            tool: .pen,
            color: .red,
            lineWidth: 10,
            path: [Point(x: 30, y: 50), Point(x: 170, y: 50)],
            bounds: Rect(origin: Point(x: 30, y: 50), size: Size(width: 140, height: 0)),
            gradientColor: .blue
        )

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [stroke],
            screen: screen
        )

        let pixels = rawPixels(of: result)
        // Row 49 is inside the 10-point band at y = 50. The blends come in
        // quantized pieces, so the test asserts the DIRECTION of the blend
        // with a forgiving margin rather than exact channel values.
        let nearStart = pixel(of: pixels, width: 200, row: 49, column: 36)
        let nearEnd = pixel(of: pixels, width: 200, row: 49, column: 164)
        // Red dominates near the start, blue near the end.
        #expect(nearStart.r > nearStart.b + 60)
        #expect(nearEnd.b > nearEnd.r + 60)
        #expect(nearEnd.b > nearStart.b)  // blue rises towards the end
        #expect(nearEnd.b > 200)
    }

    @Test("A solid stroke ignores the gradient state entirely")
    func solidStrokeStaysSolid() {
        let image = whiteImage(width: 200, height: 100)
        // gradientColor is nil: whole stroke is the start colour.
        let stroke = Annotation(
            tool: .line,
            color: .green,
            lineWidth: 10,
            path: [Point(x: 30, y: 50), Point(x: 170, y: 50)],
            bounds: Rect(origin: Point(x: 30, y: 50), size: Size(width: 140, height: 0))
        )

        let result = AnnotationCompositor.composited(
            image: image,
            annotations: [stroke],
            screen: screen
        )

        let pixels = rawPixels(of: result)
        let start = pixel(of: pixels, width: 200, row: 49, column: 45)
        let end = pixel(of: pixels, width: 200, row: 49, column: 155)
        // Both ends show the same green: no drift towards blue.
        #expect(abs(start.g - end.g) < 60)
        #expect(start.r < 150 && end.r < 150)
    }
}
