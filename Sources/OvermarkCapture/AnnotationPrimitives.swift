import CoreGraphics
import Foundation
import OvermarkCore

/// The drawing primitives behind each annotation tool.
///
/// These are pure Core Graphics operations on a caller-supplied context; the
/// renderer above decides *which* primitive runs for a given tool.
extension AnnotationRenderer {
    func drawStroke(_ annotation: Annotation, in context: CGContext, isHighlighter: Bool) {
        guard annotation.path.count > 1 else {
            // A single tap with a stroke tool is a dot.
            if let point = annotation.path.first {
                let radius = isHighlighter ? annotation.lineWidth * 3 : annotation.lineWidth / 2
                context.setFillColor(cgColor(for: annotation.color))
                context.fillEllipse(in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
            return
        }

        context.setStrokeColor(cgColor(for: annotation.color))
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if isHighlighter {
            // A highlighter paints a wide, translucent band.
            context.setAlpha(annotation.opacity * 0.35)
            context.setLineWidth(annotation.lineWidth * 6)
            context.setLineCap(.butt)
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: annotation.path[0].x, y: annotation.path[0].y))
        for point in annotation.path.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        context.addPath(path)
        context.strokePath()
    }

    func drawLine(_ annotation: Annotation, in context: CGContext) {
        guard annotation.path.count >= 2,
              let start = annotation.path.first,
              let end = annotation.path.last else { return }
        context.setStrokeColor(cgColor(for: annotation.color))
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: start.x, y: start.y))
        context.addLine(to: CGPoint(x: end.x, y: end.y))
        context.strokePath()
    }

    func drawArrow(_ annotation: Annotation, in context: CGContext) {
        guard annotation.path.count >= 2,
              let start = annotation.path.first,
              let end = annotation.path.last else { return }
        let from = CGPoint(x: start.x, y: start.y)
        let to = CGPoint(x: end.x, y: end.y)

        context.setStrokeColor(cgColor(for: annotation.color))
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()

        // Arrow head: two short strokes angled back from the tip.
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLength = max(annotation.lineWidth * 3.5, 12)
        let spread = Double.pi / 7

        for offset in [spread, -spread] {
            let headAngle = angle + .pi + offset
            let headEnd = CGPoint(
                x: to.x + cos(headAngle) * headLength,
                y: to.y + sin(headAngle) * headLength
            )
            context.move(to: to)
            context.addLine(to: headEnd)
        }
        context.strokePath()
    }

    func drawRectangle(_ annotation: Annotation, in context: CGContext) {
        let rect = annotation.bounds
        guard !rect.isEmpty else { return }
        let cgRect = CGRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)

        context.setStrokeColor(cgColor(for: annotation.color))
        context.setLineWidth(annotation.lineWidth)
        context.stroke(cgRect)

        if style.fillsShapes {
            context.setFillColor(cgColor(for: annotation.color, alpha: 0.25))
            context.fill(cgRect)
        }
    }

    func drawEllipse(_ annotation: Annotation, in context: CGContext) {
        let rect = annotation.bounds
        guard !rect.isEmpty else { return }
        let cgRect = CGRect(x: rect.minX, y: rect.minY, width: rect.size.width, height: rect.size.height)

        context.setStrokeColor(cgColor(for: annotation.color))
        context.setLineWidth(annotation.lineWidth)
        context.strokeEllipse(in: cgRect)

        if style.fillsShapes {
            context.setFillColor(cgColor(for: annotation.color, alpha: 0.25))
            context.fillEllipse(in: cgRect)
        }
    }
}
