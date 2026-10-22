import CoreGraphics
import Foundation
import OvermarkCore

/// The drawing primitives behind each annotation tool.
///
/// These are pure Core Graphics operations on a caller-supplied context; the
/// renderer above decides *which* primitive runs for a given tool.
extension AnnotationRenderer {
    func drawStroke(_ annotation: Annotation, in context: CGContext, isHighlighter: Bool) {
        guard let finalColor = annotation.gradientColor, !isHighlighter else {
            drawSingleColorStroke(annotation, in: context, isHighlighter: isHighlighter)
            return
        }

        guard annotation.path.count > 1 else {
            drawSingleColorStroke(annotation, in: context, isHighlighter: isHighlighter)
            return
        }

        // A gradient stroke is drawn in a fixed number of sub-strokes, each
        // carrying the colour of its end: the whole mark blends from the
        // start colour to the gradient colour across `stops` pieces. The pen
        // draws opaque with round caps and joins, so consecutive pieces meet
        // invisibly. The highlighter is exempt — its translucent band would
        // double-darken at every seam, so it always paints one solid colour.
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let stops = 8
        var previous = annotation.path[0]
        for index in 1...stops {
            let fraction = Double(index) / Double(stops)
            let point = Self.resampledPoint(in: annotation.path, at: fraction)
            let color = annotation.color.lerped(to: finalColor, at: fraction)
            context.setStrokeColor(cgColor(for: color))
            context.move(to: CGPoint(x: previous.x, y: previous.y))
            context.addLine(to: CGPoint(x: point.x, y: point.y))
            context.strokePath()
            previous = point
        }
    }

    /// The point of a polyline at fraction `f` of its point count (index
    /// spacing, not arc length — good enough for colour ramps).
    private static func resampledPoint(in path: [Point], at fraction: Double) -> Point {
        guard path.count > 1 else { return path[0] }
        let position = fraction * Double(path.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, path.count - 1)
        let remainder = position - Double(lower)
        let start = path[lower]
        let end = path[upper]
        return Point(
            x: start.x + (end.x - start.x) * remainder,
            y: start.y + (end.y - start.y) * remainder
        )
    }

    /// Solid coloured stroke: the pen/highlighter's original look, still used
    /// for single taps (dots) and whenever the gradient is off.
    private func drawSingleColorStroke(
        _ annotation: Annotation,
        in context: CGContext,
        isHighlighter: Bool
    ) {
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

    /// The stroke colour at progress `t` (0 = start colour, 1 = gradient
    /// colour) — plain colour when no gradient is set.
    func strokeColor(for annotation: Annotation, at t: Double) -> CGColor {
        guard let finalColor = annotation.gradientColor else {
            return cgColor(for: annotation.color)
        }
        return cgColor(for: annotation.color.lerped(to: finalColor, at: t))
    }

    func drawLine(_ annotation: Annotation, in context: CGContext) {
        guard annotation.path.count >= 2,
              let start = annotation.path.first,
              let end = annotation.path.last else { return }

        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        if annotation.gradientColor == nil {
            context.setStrokeColor(cgColor(for: annotation.color))
            context.move(to: CGPoint(x: start.x, y: start.y))
            context.addLine(to: CGPoint(x: end.x, y: end.y))
            context.strokePath()
            return
        }

        // Otherwise blend the colour across sub-segments. The stroke is
        // opaque, so the round-capped pieces overlap without visible seams.
        let stops = 8
        for index in 0..<stops {
            let t0 = Double(index) / Double(stops)
            let t1 = Double(index + 1) / Double(stops)
            let from = lerp(start, end, at: t0)
            let to = lerp(start, end, at: t1)
            context.setStrokeColor(strokeColor(for: annotation, at: (t0 + t1) / 2))
            context.move(to: CGPoint(x: from.x, y: from.y))
            context.addLine(to: CGPoint(x: to.x, y: to.y))
            context.strokePath()
        }
    }

    /// The point between two stroke ends at progress `t`.
    private func lerp(_ start: Point, _ end: Point, at t: Double) -> Point {
        Point(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
    }

    func drawArrow(_ annotation: Annotation, in context: CGContext) {
        guard annotation.path.count >= 2,
              let start = annotation.path.first,
              let end = annotation.path.last else { return }
        let from = CGPoint(x: start.x, y: start.y)
        let to = CGPoint(x: end.x, y: end.y)

        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        if annotation.gradientColor == nil {
            context.setStrokeColor(cgColor(for: annotation.color))
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
        } else {
            // The shaft blends across sub-segments; the stroke is opaque, so
            // the round-capped pieces meet without visible seams.
            let stops = 8
            for index in 0..<stops {
                let t0 = Double(index) / Double(stops)
                let t1 = Double(index + 1) / Double(stops)
                let piece0 = lerp(start, end, at: t0)
                let piece1 = lerp(start, end, at: t1)
                context.setStrokeColor(strokeColor(for: annotation, at: (t0 + t1) / 2))
                context.move(to: CGPoint(x: piece0.x, y: piece0.y))
                context.addLine(to: CGPoint(x: piece1.x, y: piece1.y))
                context.strokePath()
            }
        }

        // Arrow head: two short strokes angled back from the tip, painted in
        // the stroke's end colour (the tip sits at t = 1 of the gradient).
        context.setStrokeColor(strokeColor(for: annotation, at: 1))
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

        // The fill is the annotation's own choice, made while drawing it, so
        // exports and recordings match the live canvas exactly.
        if annotation.fillsShapes {
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

        if annotation.fillsShapes {
            context.setFillColor(cgColor(for: annotation.color, alpha: 0.25))
            context.fillEllipse(in: cgRect)
        }
    }
}
