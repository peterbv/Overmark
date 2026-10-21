import AppKit
import Foundation
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

    /// Whether a build of the overlays is currently running.
    private var isBuilding = false
    /// Whether another overlay build was requested while one was running.
    private var pendingBuild = false

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

    public init() {}

    /// Probe-only stderr logging. Avoids cluttering normal runs: the env
    /// var is only set by the diagnostic probe launcher.
    private static func probeLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["PRESENTIFY_PROBE"] == "1" else { return }
        FileHandle.standardError.write(Data("[BUILD] \(message)\n".utf8))
    }

    /// The number of displays currently overlaid.
    public var overlayCount: Int { entries.count }

    /// Shows overlays on every attached display.
    ///
    /// The panels are intentionally empty: a transparent borderless window
    /// whose canvas draws the strokes directly over the live desktop.
    /// Displaying a captured screenshot here layered a *still image* over
    /// the real screen (and over the annotations themselves), which made
    /// an otherwise healthy session look frozen.
    public func showOverlays() async {
        // Two overlapping builds would interleave their `await`s and leave
        // orphaned panels on screen. Serialize: the latest request wins and
        // is chained after the running build instead of racing it.
        guard !isBuilding else {
            pendingBuild = true
            return
        }
        isBuilding = true

        repeat {
            pendingBuild = false
            await buildOverlays()
            if !pendingBuild {
                break
            }
        } while true

        isBuilding = false
    }

    private func buildOverlays() async {
        tearDown()

        // Enumerate displays from AppKit: the panels must not depend on the
        // Screen Recording permission. Only pixel capture (copy/save, the
        // zoom lens background) does, and it lives elsewhere.
        let screens = NSScreen.screens.compactMap { screen -> ScreenIdentity? in
            guard let displayID = ScreenIdentity.displayID(of: screen) else {
                Self.probeLog("no displayID in deviceDescription for '\(screen.localizedName)'")
                return nil
            }
            return ScreenIdentity(displayID: displayID, screen: screen)
        }
        guard !screens.isEmpty else {
            Self.probeLog("no screens matched; NSScreen.screens.count=\(NSScreen.screens.count)")
            return
        }
        Self.probeLog("building \(screens.count) panels")

        for screen in screens {
            let frame = screen.appKitFrame
            let rect = NSRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )

            let panel = OverlayPanel(contentRect: rect)
            panel.setFrame(rect, display: true)

            let canvas = AnnotationCanvasView(frame: rect)
            canvas.screen = screen.screenFrame
            canvas.menuBarHeight = Self.menuBarHeight(for: screen.screenFrame)
            canvas.tool = .pen
            canvas.autoresizingMask = [.width, .height]
            canvas.wantsLayer = true

            // Re-apply the stored callbacks so annotations created on a
            // freshly shown overlay still reach the app.
            canvas.onAnnotationCreated = onAnnotationCreated
            canvas.onClick = onClick

            panel.contentView = canvas
            panel.presentAboveAll()

            entries[screen.displayID] = PanelEntry(panel: panel, canvas: canvas)
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

    /// One AppKit screen plus the identifiers the controller keys on.
    ///
    /// `NSScreen.screens` needs no permission, unlike ScreenCaptureKit's
    /// display enumeration, so the annotation panels can be built (and torn
    /// down) regardless of what Screen Recording allows.
    private struct ScreenIdentity {
        var displayID: CGDirectDisplayID
        var appKitFrame: NSRect
        var screenFrame: ScreenFrame

        static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        init(displayID: CGDirectDisplayID, screen: NSScreen) {
            self.displayID = displayID
            self.appKitFrame = screen.frame
            let frame = screen.frame
            self.screenFrame = ScreenFrame(
                origin: Point(x: frame.origin.x, y: frame.origin.y),
                size: Size(width: frame.size.width, height: frame.size.height),
                scale: Double(screen.backingScaleFactor)
            )
        }
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

    /// Whether the hold-⌥-to-draw pass-through is fully active.
    ///
    /// The toolbar reflects this in its chip; the degraded case means the ⌥
    /// key could not be observed, so the panels capture clicks everywhere.
    public var isPassthroughMode: Bool {
        isOptionToDrawMode && canMonitorOption
    }

    /// Compactly logs the server-side click routing state of every panel.
    public func debugPanelState() -> String {
        let mode = "optionToDraw=\(isOptionToDrawMode) canMonitor=\(canMonitorOption) held=\(isOptionHeld) count=\(entries.count)"
        let panels = entries.values.map {
            "\($0.panel.ignoresMouseEvents ? "ignore" : "accept") drawOpt=\($0.canvas.holdOptionToDraw)"
        }.joined(separator: ", ")
        return "[OVERLAY] \(mode) panels: [\(panels)]"
    }

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
