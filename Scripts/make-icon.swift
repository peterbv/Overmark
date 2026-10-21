#!/usr/bin/env swift

// Renders the Presentify app icon as a PNG.
//
// The design reads as a slide being annotated live: a deep indigo stage, a
// floating white screen carrying two ghosted text bars, a glowing green
// sweep underlining one of them (the pen tool) and a red numbered step badge
// (the step counter). Drawn programmatically instead of being checked in as
// a binary asset so it stays editable and reviewable.
//
// Run it with the output size and path:
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

    // A deep indigo night that brightens toward the lower right — calmer and
    // richer than a flat violet wash.
    let colors = [
        CGColor(srgbRed: 0.10, green: 0.08, blue: 0.28, alpha: 1),
        CGColor(srgbRed: 0.24, green: 0.15, blue: 0.55, alpha: 1),
        CGColor(srgbRed: 0.44, green: 0.25, blue: 0.92, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 0.55, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvasSize * 0.12, y: canvasSize),
            end: CGPoint(x: canvasSize * 0.88, y: 0),
            options: []
        )
    }

    // A soft light from the upper-left keeps the backdrop from feeling flat.
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: canvasSize * 0.16, y: canvasSize * 0.94),
            startRadius: 0,
            endCenter: CGPoint(x: canvasSize * 0.16, y: canvasSize * 0.94),
            endRadius: canvasSize * 0.78,
            options: []
        )
    }
    context.restoreGState()
}

private func drawScreen(in context: CGContext) {
    context.saveGState()

    // A soft drop shadow lifts the display off the gradient backdrop.
    context.setShadow(
        offset: CGSize(width: 0, height: -28),
        blur: 64,
        color: CGColor(srgbRed: 0.04, green: 0.02, blue: 0.16, alpha: 0.45)
    )

    // The screen body.
    let screen = CGRect(x: 176, y: 360, width: 672, height: 372)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98))
    context.addPath(
        CGPath(
            roundedRect: screen,
            cornerWidth: 30,
            cornerHeight: 30,
            transform: nil
        )
    )
    context.fillPath()

    // The neck of the stand.
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 460, y: 288, width: 104, height: 86),
            cornerWidth: 14,
            cornerHeight: 14,
            transform: nil
        )
    )
    context.fillPath()

    // The base of the stand.
    context.addPath(
        CGPath(
            roundedRect: CGRect(x: 352, y: 250, width: 320, height: 48),
            cornerWidth: 24,
            cornerHeight: 24,
            transform: nil
        )
    )
    context.fillPath()

    context.restoreGState()

    // Ghosted text bars — the slide the presenter is talking over.
    context.setFillColor(CGColor(srgbRed: 0.78, green: 0.76, blue: 0.88, alpha: 1))
    for bar in [
        CGRect(x: 268, y: 640, width: 340, height: 22),
        CGRect(x: 268, y: 592, width: 232, height: 22),
    ] {
        context.addPath(
            CGPath(
                roundedRect: bar,
                cornerWidth: 11,
                cornerHeight: 11,
                transform: nil
            )
        )
        context.fillPath()
    }
}

private func drawAnnotation(in context: CGContext) {
    // A glowing freehand sweep underlining the second text bar — the app's
    // pen tool captured mid-annotation.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 252, y: 556))
    path.addCurve(
        to: CGPoint(x: 544, y: 540),
        control1: CGPoint(x: 356, y: 534),
        control2: CGPoint(x: 420, y: 586)
    )

    // Glow pass: the shadow paints a green halo around the stroke.
    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: 30,
        color: CGColor(srgbRed: 0.30, green: 0.90, blue: 0.55, alpha: 0.65)
    )
    context.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.90, blue: 0.55, alpha: 1))
    context.setLineWidth(34)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    context.strokePath()
    context.restoreGState()

    // A numbered step badge, the other thing the app draws.
    let badgeCenter = CGPoint(x: 668, y: 488)
    let badgeRadius: CGFloat = 84

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 30,
        color: CGColor(srgbRed: 0.35, green: 0.04, blue: 0.10, alpha: 0.45)
    )
    context.setFillColor(CGColor(srgbRed: 1, green: 0.40, blue: 0.44, alpha: 1))
    context.addEllipse(in: CGRect(
        x: badgeCenter.x - badgeRadius,
        y: badgeCenter.y - badgeRadius,
        width: badgeRadius * 2,
        height: badgeRadius * 2
    ))
    context.fillPath()
    context.restoreGState()

    // A darker rim gives the badge the same drawn-on feel as the stroke.
    context.setStrokeColor(CGColor(srgbRed: 0.74, green: 0.15, blue: 0.24, alpha: 0.9))
    context.setLineWidth(7)
    context.addEllipse(in: CGRect(
        x: badgeCenter.x - badgeRadius + 4.5,
        y: badgeCenter.y - badgeRadius + 4.5,
        width: (badgeRadius - 4.5) * 2,
        height: (badgeRadius - 4.5) * 2
    ))
    context.strokePath()

    // The digit is drawn with CoreText rather than AppKit: `NSAttributedString`
    // needs a current `NSGraphicsContext`, which a bare `CGContext` does not
    // provide, and the text would silently not be drawn.
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 104, nil)
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
        x: badgeCenter.x - bounds.width / 2 - bounds.origin.x,
        y: badgeCenter.y - bounds.height / 2 - bounds.origin.y
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
