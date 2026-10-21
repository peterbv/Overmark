#!/usr/bin/env swift

// Renders the Presentify app icon as a PNG.
//
// The icon is drawn programmatically instead of being checked in as a binary
// asset so that it stays editable and reviewable. Run it with the output
// size and path:
//
//     swift Scripts/make-icon.swift 512 out/icon_512x512.png
//
// `Scripts/build-app.sh` drives it for every size and packs the results into
// an `.icns` file with `iconutil`.

import AppKit
import CoreGraphics
import CoreText
import Foundation

/// The size the artwork is authored at. Everything is drawn at this scale and
/// scaled down, so the proportions stay identical at every resolution.
private let canvasSize: CGFloat = 1024

private func makeImage(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let scale = CGFloat(size) / canvasSize
    context.scaleBy(x: scale, y: scale)

    drawBackground(in: context)
    drawScreen(in: context)
    drawAnnotation(in: context)

    return context.makeImage()
}

private func drawBackground(in context: CGContext) {
    let bounds = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    let path = CGPath(
        roundedRect: bounds,
        cornerWidth: 224,
        cornerHeight: 224,
        transform: nil
    )

    context.saveGState()
    context.addPath(path)
    context.clip()

    let colors = [
        CGColor(srgbRed: 0.31, green: 0.22, blue: 0.78, alpha: 1),
        CGColor(srgbRed: 0.58, green: 0.27, blue: 0.93, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: canvasSize),
            end: CGPoint(x: canvasSize, y: 0),
            options: []
        )
    }
    context.restoreGState()
}

private func drawScreen(in context: CGContext) {
    // The screen body.
    let screen = CGRect(x: 176, y: 372, width: 672, height: 360)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97))
    context.addPath(
        CGPath(
            roundedRect: screen,
            cornerWidth: 28,
            cornerHeight: 28,
            transform: nil
        )
    )
    context.fillPath()

    // The neck of the stand.
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 460, y: 300, width: 104, height: 84),
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )
    )
    context.fillPath()

    // The base of the stand.
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 356, y: 262, width: 312, height: 48),
            cornerWidth: 24,
            cornerHeight: 24,
            transform: nil
        )
    )
    context.fillPath()
}

private func drawAnnotation(in context: CGContext) {
    // A freehand stroke in the annotation green, echoing the app's pen tool.
    context.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.85, blue: 0.45, alpha: 1))
    context.setLineWidth(58)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: 296, y: 560))
    path.addCurve(
        to: CGPoint(x: 452, y: 640),
        control1: CGPoint(x: 340, y: 620),
        control2: CGPoint(x: 372, y: 560)
    )
    path.addCurve(
        to: CGPoint(x: 616, y: 548),
        control1: CGPoint(x: 520, y: 700),
        control2: CGPoint(x: 574, y: 640)
    )
    context.addPath(path)
    context.strokePath()

    // A numbered step badge, the other thing the app draws.
    let badge = CGRect(x: 604, y: 548, width: 150, height: 150)
    context.setFillColor(CGColor(srgbRed: 1, green: 0.42, blue: 0.42, alpha: 1))
    context.addEllipse(in: badge)
    context.fillPath()

    // The digit is drawn with CoreText rather than AppKit: `NSAttributedString`
    // needs a current `NSGraphicsContext`, which a bare `CGContext` does not
    // provide, and the text would silently not be drawn.
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 110, nil)
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
    ]
    let attributed = CFAttributedStringCreate(
        kCFAllocatorDefault,
        "1" as CFString,
        attributes as CFDictionary
    )
    guard let attributed else { return }

    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(
        x: badge.midX - bounds.width / 2 - bounds.origin.x,
        y: badge.midY - bounds.height / 2 - bounds.origin.y
    )
    CTLineDraw(line, context)
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let size = Int(arguments[1]) else {
    FileHandle.standardError.write(
        Data("usage: make-icon.swift <size> <output.png>\n".utf8)
    )
    exit(1)
}

let outputPath = arguments[2]
guard let image = makeImage(size: size) else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}

let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL,
    "public.png" as CFString,
    1,
    nil
)
guard let destination else {
    FileHandle.standardError.write(Data("could not create \(outputPath)\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(outputPath)\n".utf8))
    exit(1)
}
