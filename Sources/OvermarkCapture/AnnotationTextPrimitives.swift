import CoreGraphics
import CoreText
import Foundation
import OvermarkCore

/// Text and step-number drawing.
///
/// Core Text is used directly rather than AppKit so the renderer stays usable
/// from a background render pass without touching the main actor.
extension AnnotationRenderer {
    func drawText(_ annotation: Annotation, in context: CGContext) {
        guard let text = annotation.text, !text.isEmpty else { return }
        let fontSize = annotation.lineWidth * Annotation.textFontFactor
        let lineHeight = fontSize * Annotation.textLineHeightFactor
        let font = CTFontCreateWithName(".SFProDisplay-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: cgColor(for: annotation.color),
        ]

        // Each newline starts a new line. Lines are drawn top to bottom, each
        // baseline separated by the line height; `0.8` pushes the first line
        // to sit just under the top edge of the stored bounds so the glyphs
        // stay inside them.
        let lines = text.components(separatedBy: .newlines)
        for (index, lineText) in lines.enumerated() where !lineText.isEmpty {
            let attributed = NSAttributedString(string: lineText, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attributed)
            let baselineY = annotation.bounds.maxY - (CGFloat(index) + 0.8) * lineHeight
            context.textPosition = CGPoint(x: annotation.bounds.minX, y: baselineY)
            CTLineDraw(line, context)
        }
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
