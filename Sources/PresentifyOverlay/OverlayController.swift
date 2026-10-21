import AppKit
import Foundation
import PresentifyCapture
import PresentifyCore

/// Manages the annotation overlays, one per display.
///
/// Each display gets its own `OverlayPanel`. The panels are independent so
/// that a user dragging across two monitors sees a continuous stroke, and so
/// that a display unplugged mid-session can be torn down without disturbing
/// the others.
@MainActor
public final class OverlayController {
    /// One panel plus the canvas view that draws into it.
    private struct PanelEntry {
        var panel: OverlayPanel
        var canvas: AnnotationCanvasView
    }

    private var entries: [CGDirectDisplayID: PanelEntry] = [:]
    private let captureService: ScreenCaptureService

    /// The handler invoked when a canvas produces an annotation.
    private var onAnnotationCreated: ((Annotation) -> Void)?
    /// The handler invoked when the canvas is clicked.
    private var onClick: ((Point) -> Void)?

    public init(captureService: ScreenCaptureService) {
        self.captureService = captureService
    }

    /// The number of displays currently overlaid.
    public var overlayCount: Int { entries.count }

    /// Shows overlays on every attached display.
    ///
    /// - Parameter backgrounds: The screenshots to draw behind the
    ///   annotations, keyed by display id. Each panel shows the screenshot of
    ///   its own display; a display without a screenshot simply gets a
    ///   transparent overlay.
    public func showOverlays(backgrounds: [CGDirectDisplayID: CGImage] = [:]) async {
        tearDown()

        guard let displays = try? await captureService.availableDisplays() else { return }

        for display in displays {
            let frame = display.screen.frame
            let rect = NSRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )

            let panel = OverlayPanel(contentRect: rect)
            panel.setFrame(rect, display: true)

            let canvas = AnnotationCanvasView(frame: rect)
            canvas.screen = display.screen
            canvas.tool = .pen
            canvas.autoresizingMask = [.width, .height]
            canvas.wantsLayer = true

            // Re-apply the stored callbacks so annotations created on a
            // freshly shown overlay still reach the app.
            canvas.onAnnotationCreated = onAnnotationCreated
            canvas.onClick = onClick

            if let background = backgrounds[display.displayID] {
                attach(background: background, to: canvas, screen: display.screen)
            }

            panel.contentView = canvas
            panel.presentAboveAll()

            entries[display.displayID] = PanelEntry(panel: panel, canvas: canvas)
        }
    }

    /// Removes all overlays.
    public func tearDown() {
        for entry in entries.values {
            entry.panel.dismiss()
            entry.panel.contentView = nil
            entry.panel.close()
        }
        entries.removeAll()
    }

    /// Pushes a set of annotations to every canvas.
    public func setAnnotations(_ annotations: [Annotation]) {
        for entry in entries.values {
            entry.canvas.annotations = annotations
        }
    }

    /// Sets the tool, colour and width used for new annotations.
    public func apply(settings: ToolSettings) {
        for entry in entries.values {
            entry.canvas.tool = settings.tool
            entry.canvas.color = settings.color
            entry.canvas.lineWidth = settings.lineWidth
            entry.canvas.fillsShapes = settings.fillsShapes
            entry.canvas.nextStepNumber = settings.nextStepNumber
        }
    }

    /// Enables or disables drawing across every canvas.
    public func setInteractionEnabled(_ enabled: Bool) {
        for entry in entries.values {
            entry.canvas.isInteractionEnabled = enabled
        }
    }

    /// Routes canvas callbacks to the given handlers.
    ///
    /// The handlers are stored, not just applied, because overlays are created
    /// after the app starts. Without storing them, canvases created later
    /// would never report their annotations back.
    public func bind(
        onAnnotationCreated: @escaping (Annotation) -> Void,
        onClick: @escaping (Point) -> Void
    ) {
        self.onAnnotationCreated = onAnnotationCreated
        self.onClick = onClick

        for entry in entries.values {
            entry.canvas.onAnnotationCreated = onAnnotationCreated
            entry.canvas.onClick = onClick
        }
    }

    // MARK: - Private

    /// Draws a captured screenshot behind the annotations.
    private func attach(background: CGImage, to canvas: NSView, screen: ScreenFrame) {
        let layer = CALayer()
        layer.contents = background
        layer.contentsGravity = .resizeAspect
        layer.frame = canvas.bounds
        layer.magnificationFilter = .nearest

        let imageWidth = CGFloat(background.width)
        let imageHeight = CGFloat(background.height)
        guard imageWidth > 0, imageHeight > 0 else { return }

        // Scale the image so it covers the canvas while preserving its aspect
        // ratio, matching how the screenshot was taken of this display.
        let scaleX = canvas.bounds.width / imageWidth
        let scaleY = canvas.bounds.height / imageHeight
        layer.contentsScale = max(scaleX, scaleY)

        canvas.layer?.addSublayer(layer)
    }
}
