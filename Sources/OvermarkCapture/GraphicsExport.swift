import CoreGraphics
import Foundation
import ImageIO

/// Encodes captured desktop frames into shareable file formats.
///
/// The exporters are pure Core Graphics: they take the composited image the
/// coordinator already produces (annotations, whiteboard and frozen stills
/// burned in) and wrap it into the bytes of a file, so both the menu-bar
/// export flows and the tests exercise the same encoding path.
public enum GraphicsExport {
    /// Encodes an image as a PNG, preserving alpha when it has any.
    public static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Encodes an image as a single-page PDF the size of the image.
    ///
    /// The page is filled white first: PDF viewers render a transparent
    /// background as black, and the white page keeps alpha-only exports
    /// (such as whiteboard shots) legible everywhere.
    public static func pdfData(from image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0) else { return nil }
        guard let consumer = CGDataConsumer(data: data) else { return nil }

        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        context.draw(image, in: mediaBox)
        context.closePDF()

        return (data as NSData) as Data
    }
}
