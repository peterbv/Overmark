import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import PresentifyCapture
@testable import PresentifyCore

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
    /// Row 0 is the bottom of the image, which is how CoreGraphics stores a
    /// bitmap.
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
}
