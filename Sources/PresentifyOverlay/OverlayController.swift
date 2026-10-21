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

    /// Whether a build of the overlays is currently running.
    private var isBuilding = false
    /// Background settings that arrived while a build was running.
    private var pendingBackgrounds: [CGDirectDisplayID: CGImage]?

    /// Watches the ⌥ key while the overlays are on screen so the panels can
    /// toggle window-level pass-through (see `refreshMouseTransparency`).
    private var optionMonitor: OptionKeyMonitor?
    /// Whether the ⌥ modifier is currently held system-wide.
    private var isOptionHeld = false
    /// Whether the canvases run in "hold ⌥ to draw" mode.
    private var isOptionToDrawMode = false
    /// Whether the ⌥ tap could be created. When the Accessibility permission
    /// is missing it cannot, and the hold-⌥ mode degrades to classic
    /// always-drawing so the app never becomes unusable.
    private var canMonitorOption = true

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
        // Two overlapping builds would interleave their `await`s and leave
        // orphaned panels on screen. Serialize: the latest request wins and
        // is chained after the running build instead of racing it.
        guard !isBuilding else {
            pendingBackgrounds = backgrounds
            return
        }
        isBuilding = true

        var current = backgrounds
        repeat {
            pendingBackgrounds = nil
            await buildOverlays(backgrounds: current)
            if let pending = pendingBackgrounds {
                current = pending
                continue
            }
            break
        } while true

        isBuilding = false
    }

    private func buildOverlays(backgrounds: [CGDirectDisplayID: CGImage]) async {
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
            canvas.menuBarHeight = Self.menuBarHeight(for: display.screen)
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

        startOptionMonitoring()
        refreshMouseTransparency()
    }

    /// Removes all overlays.
    public func tearDown() {
        stopOptionMonitoring()
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
        // The hold-⌥ mode only makes sense while the key can be observed;
        // without it the canvases would swallow every click and the app
        // would be unusable.
        isOptionToDrawMode = settings.holdOptionToDraw && canMonitorOption

        for entry in entries.values {
            // The palette only ever offers tools the renderer can draw, but
            // guard anyway: routing a ghost tool into the canvas would
            // otherwise produce invisible annotations.
            entry.canvas.tool = settings.tool.producesAnnotation ? settings.tool : .pen
            entry.canvas.color = settings.color
            entry.canvas.lineWidth = settings.lineWidth
            entry.canvas.fillsShapes = settings.fillsShapes
            entry.canvas.nextStepNumber = settings.nextStepNumber
            entry.canvas.holdOptionToDraw = isOptionToDrawMode
        }
        refreshMouseTransparency()
    }

    /// Enables or disables drawing across every canvas.
    public func setInteractionEnabled(_ enabled: Bool) {
        for entry in entries.values {
            entry.canvas.isInteractionEnabled = enabled
        }
        refreshMouseTransparency()
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

        // `contentsScale` is the layer's backing pixels *per point*. The
        // screenshot arrives in device pixels, so the scale is pixels ÷
        // points — the inverse of point ÷ pixels. The inverted version
        // downsampled every screenshot to a fraction of its resolution,
        // which showed as blurry overlays under Retina-quality strokes.
        let scaleX = imageWidth / max(canvas.bounds.width, 1)
        let scaleY = imageHeight / max(canvas.bounds.height, 1)
        layer.contentsScale = max(scaleX, scaleY)

        canvas.layer?.addSublayer(layer)
    }

    /// The height of the menu bar for the screen a canvas covers.
    ///
    /// Falling out of the matching `NSScreen` keeps the canvas in sync with
    /// whatever menu bar or notch the display actually has; screens with no
    /// menu bar (or an auto-hidden one) yield zero and keep the whole canvas
    /// drawable.
    private static func menuBarHeight(for screen: ScreenFrame) -> Double {
        let match = NSScreen.screens.first { candidate in
            abs(candidate.frame.origin.x - screen.origin.x) < 1
                && abs(candidate.frame.origin.y - screen.origin.y) < 1
        }
        guard let match else { return 0 }
        return Double(max(match.frame.height - match.visibleFrame.height, 0))
    }

    // MARK: - Pass-through

    /// Starts watching the ⌥ modifier for the hold-⌥-to-draw mode.
    ///
    /// `hitTest`-level filtering cannot forward a click to another app: by
    /// the time the view stack runs, the window server has already decided
    /// the topmost window owns the event, and returning `nil` just drops it.
    /// The panels therefore alternate `ignoresMouseEvents` — server-level
    /// transparency — based on the live key state, which keeps every other
    /// app clickable while the overlay is on screen.
    private func startOptionMonitoring() {
        if optionMonitor == nil {
            let monitor = OptionKeyMonitor { [weak self] held in
                self?.handleOptionStateChanged(held)
            }
            guard monitor.start() else {
                // Without the Accessibility permission the ⌥ key cannot be
                // observed; degrade to the classic always-draws mode so the
                // app stays usable (Pause provides desktop interaction).
                canMonitorOption = false
                isOptionToDrawMode = false
                for entry in entries.values {
                    entry.canvas.holdOptionToDraw = false
                }
                return
            }
            optionMonitor = monitor
            canMonitorOption = true
        }
    }

    private func handleOptionStateChanged(_ held: Bool) {
        isOptionHeld = held
        if !held {
            // The panels stop accepting events exactly when ⌥ is released,
            // so a stroke in flight can never see its own `mouseUp`; discard
            // the half-drawn annotation instead of leaving it stuck on
            // screen.
            for entry in entries.values {
                entry.canvas.cancelPendingStroke()
            }
        }
        refreshMouseTransparency()
    }

    private func stopOptionMonitoring() {
        optionMonitor?.stop()
        optionMonitor = nil
        isOptionHeld = false
    }

    /// Syncs `ignoresMouseEvents` on every panel with the current mode.
    ///
    /// This is the switch the window server honours: with the flag on, clicks
    /// reach the Dock, the menu bar and the apps underneath; with it off —
    /// only while ⌥ is held in hold-⌥-to-draw mode — the panels receive the
    /// drawing gestures.
    private func refreshMouseTransparency() {
        for entry in entries.values {
            let accepts: Bool
            if isOptionToDrawMode {
                accepts = entry.canvas.isInteractionEnabled && isOptionHeld
            } else {
                accepts = entry.canvas.isInteractionEnabled
            }
            entry.panel.ignoresMouseEvents = !accepts
        }
    }
}
