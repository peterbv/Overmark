import AppKit
import CoreGraphics
import Foundation
import Testing
import OvermarkCore
@testable import OvermarkCapture

/// The painter that both the on-screen windows and the window recorder
/// share: paths, pixel checks and the crop math.
@Suite("CursorEffectRenderer")
struct CursorEffectRendererTests {
    // MARK: - Highlight shapes

    @Test func highlightPathShapesStayInTheirRect() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        for shape in HighlightShape.allCases {
            let path = CursorEffectRenderer.highlightPath(in: rect, shape: shape)
            let bounds = path.boundingBoxOfPath
            #expect(abs(bounds.minX - rect.minX) < 0.001)
            #expect(abs(bounds.maxX - rect.maxX) < 0.001)
            #expect(abs(bounds.minY - rect.minY) < 0.001)
            #expect(abs(bounds.maxY - rect.maxY) < 0.001)
        }
    }

    @Test func rhombusIsClosed() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let path = CursorEffectRenderer.highlightPath(in: rect, shape: .rhombus)
        #expect(!path.isEmpty) // moved through all four corners + close
    }

    // MARK: - Spotlight

    /// Renders spotlight pixels on an opaque bitmap: the hole must keep the
    /// background colour while everything around it dims to black.
    @Test func spotlightPunchesANoticeableHole() {
        let size = CGSize(width: 64, height: 64)
        let context = Self.bitmapContext(size: size)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        CursorEffectRenderer.drawSpotlight(
            dimRect: CGRect(origin: .zero, size: size),
            holeCenter: CGPoint(x: 32, y: 32),
            holeRadius: 8,
            dimOpacity: 1,
            in: context
        )

        let image = context.makeImage()
        #expect(image != nil)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
            Issue.record("bitmap data unavailable")
            return
        }
        let rowBytes = context.bytesPerRow
        // endian-32-little BGRA: byte offsets within a pixel are B, G, R, A.
        let redAt: (Int, Int) -> UInt8 = { x, y in
            let rowIndex = size.height - 1 - CGFloat(y)
            let offset = Int(rowIndex) * rowBytes + x * 4
            return data[offset + 2]
        }
        // Inside the hole: untouched background.
        #expect(redAt(32, 32) > 240)
        #expect(redAt(28, 32) > 240)
        // Corner: fully dimmed.
        #expect(redAt(5, 5) < 15)
        #expect(redAt(59, 59) < 15)
    }

    @Test func uniformDimWithoutHole() {
        let size = CGSize(width: 32, height: 32)
        let context = Self.bitmapContext(size: size)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        CursorEffectRenderer.drawSpotlight(
            dimRect: CGRect(origin: .zero, size: size),
            holeCenter: nil,
            holeRadius: 10,
            dimOpacity: 0.5,
            in: context
        )
        guard let image = context.makeImage() else {
            Issue.record("bitmap unavailable")
            return
        }
        let center = Self.pixel(in: image, at: CGPoint(x: 16, y: 16))
        // alpha .5 black over white: mid grey.
        #expect(abs(center.red - 0.5) < 0.06)
    }

    // MARK: - Ripple math

    @Test func rippleProgressMath() {
        let left0 = CursorEffectRenderer.ripple(
            progress: 0, isRight: false, radius: 40, borderWidth: 3
        )
        #expect(abs(left0.radius - 16) < 0.001) // .40 * 40
        #expect(abs(left0.alpha - 0.85) < 0.001)
        #expect(left0.lineWidth == 3)

        let leftLate = CursorEffectRenderer.ripple(
            progress: 2, isRight: false, radius: 40, borderWidth: 3
        )
        #expect(abs(leftLate.radius - 76) < 0.001) // 1.9 * 40
        #expect(abs(leftLate.alpha) < 0.001)

        let right0 = CursorEffectRenderer.ripple(
            progress: 0, isRight: true, radius: 40, borderWidth: 0
        )
        #expect(abs(right0.radius - 12) < 0.001) // .4 * 40 * .75
        #expect(abs(right0.alpha - 0.5) < 0.001)
        #expect(right0.lineWidth == 1.5) // floor kept
    }

    @Test func drawRippleRejectsStaleClicks() {
        let size = CGSize(width: 32, height: 32)
        let context = Self.bitmapContext(size: size)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        CursorEffectRenderer.drawRipple(
            center: CGPoint(x: 16, y: 16),
            startedAt: Date().addingTimeInterval(-1),
            at: Date(),
            color: .red,
            highlightRadius: 10,
            highlightBorderWidth: 3,
            isRight: false,
            in: context
        )
        guard let image = context.makeImage() else {
            Issue.record("bitmap unavailable")
            return
        }
        // Nothing drawn over the white base.
        #expect(Self.pixel(in: image, at: CGPoint(x: 26, y: 16)).red > 0.98)
    }

    // MARK: - Lens crop

    @Test func lensCropRectCentresNearTheEdges() {
        let imageSize = CGSize(width: 200, height: 100)
        let crop = { (x: CGFloat, y: CGFloat) -> CGRect? in
            CursorEffectRenderer.lensCropRect(
                around: CGPoint(x: x, y: y),
                span: 20,
                origin: .zero,
                pixelsPerPointX: 2,
                pixelsPerPointY: 2,
                pointHeight: 50,
                imageSize: imageSize
            )
        }
        // Fully contained (x = 50*2 − 20 = 80; y = (50−25)*2 − 20 = 30).
        let centered = crop(50, 25)
        #expect(centered == CGRect(x: 80, y: 30, width: 40, height: 40))
        // Left edge clamps the x range but keeps y.
        let left = crop(5, 25)
        #expect(left?.minX == 0)
        #expect(left?.height == 40)
        // A request far outside falls off.
        #expect(crop(500, 25) == nil)
    }

    @Test func lensCropHonoursContentOrigin() {
        let crop = CursorEffectRenderer.lensCropRect(
            around: CGPoint(x: 10, y: 10),
            span: 20,
            origin: CGPoint(x: 40, y: 8),
            pixelsPerPointX: 2,
            pixelsPerPointY: 2,
            pointHeight: 50,
            imageSize: CGSize(width: 200, height: 120)
        )
        // x = 40 + 10·2 − 20 = 40; y = 8 + (50−10)·2 − 20 = 68.
        #expect(crop == CGRect(x: 40, y: 68, width: 40, height: 40))
    }

    /// A tiny background through the full lens path must not crash even when
    /// the crop is clamped into nonsense.
    @Test func drawZoomLensIsSafeWithTinyBackground() throws {
        let size = CGSize(width: 32, height: 32)
        let context = Self.bitmapContext(size: size)
        let tone = try #require(
            context.makeImage()?.cropping(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        )
        CursorEffectRenderer.drawZoomLens(
            at: CGPoint(x: 16, y: 16),
            around: CGPoint(x: 16, y: 16),
            size: 20,
            zoomFactor: 2,
            shape: .circle,
            background: tone,
            contentOriginInPixels: .zero,
            pixelsPerPointX: 1,
            pixelsPerPointY: 1,
            pointHeight: 32,
            in: context
        )
    }

    // MARK: - Contexts

    private static func bitmapContext(size: CGSize) -> CGContext {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context
    }

    private static func pixel(in image: CGImage, at point: CGPoint) -> (red: Double, alpha: Double) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = height - 1 - Int(point.y)
        let column = Int(point.x)
        let index = (row * width + column) * 4
        return (
            Double(pixels[index]) / 255,
            Double(pixels[index + 3]) / 255
        )
    }
}
