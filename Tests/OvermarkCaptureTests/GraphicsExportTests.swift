import CoreGraphics
import Foundation
import PDFKit
import Testing
import OvermarkCapture

@Suite("Graphics export")
struct GraphicsExportTests {

    let opaqueRed: CGImage = {
        let width = 24
        let height = 16
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }()

    @Test func pngDataCarriesThePNGSignature() throws {
        let data = try #require(GraphicsExport.pngData(from: opaqueRed))
        #expect(data[0] == 0x89)
        #expect(data[1] == 0x50)
        #expect(data[2] == 0x4E)
        #expect(data[3] == 0x47)
    }

    @Test func pngDataSurvivesALosslessRoundTrip() throws {
        let data = try #require(GraphicsExport.pngData(from: opaqueRed))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let raw = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        let properties = try #require(raw as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 24)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 16)
    }

    @Test func pdfDataStartsWithThePDFHeader() throws {
        let data = try #require(GraphicsExport.pdfData(from: opaqueRed))
        #expect(data.prefix(4) == Data("%PDF".utf8))
    }

    @Test func pdfDataParsesAsExactlyOnePage() throws {
        let data = try #require(GraphicsExport.pdfData(from: opaqueRed))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
    }
}
