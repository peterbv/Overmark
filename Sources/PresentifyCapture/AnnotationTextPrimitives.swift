import CoreGraphics
import CoreText
import Foundation
import PresentifyCore

/// Text and step-number drawing.
///
/// Core Text is used directly rather than AppKit so the renderer stays usable
/// from a background render pass without touching the main actor.
extension AnnotationRenderer {
    func drawText(_ annotation: Annotation, in context: CGContext) {
        guard let text = annotation.text, !text.isEmpty else { return }
        let font = CTFontCreateWithName(".SFProDisplay-Bold" as CFString, annotation.lineWidth * 6, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: cgColor(for: annotation.color),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: annotation.bounds.minX, y: annotation.bounds.minY)
        CTLineDraw(line, context)
    }

    func drawStepNumber(_ annotation: Annotation, in context: CGContext) {
        guard let step = annotation.stepNumber else { return }
        let center = annotation.bounds.center
        let radius = max(annotation.lineWidth * 4, 18)

        context.setFillColor(cgColor(for: annotation.color))
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        let font = CTFontCreateWithName(".SFProDisplay-Bold" as CFString, radius * 1.1, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: cgColor(for: .white),
        ]
        let attributed = NSAttributedString(string: "\(step)", attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // Centre the glyph inside the circle.
        context.textPosition = CGPoint(
            x: center.x - bounds.width / 2 - bounds.minX,
            y: center.y - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }
}
