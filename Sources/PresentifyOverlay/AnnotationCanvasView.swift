import AppKit
import Foundation
import PresentifyCapture
import PresentifyCore

/// A view that renders annotations and captures the user's drawing gestures.
///
/// The view owns two things: the pixels and the gesture recognition. It
/// deliberately does *not* own the document — the document is pushed in and
/// changes are reported through closures, which keeps the view free of
/// duplicated state.
public final class AnnotationCanvasView: NSView {
    // MARK: - Callbacks

    /// Called when the user completes a stroke or shape.
    public var onAnnotationCreated: ((Annotation) -> Void)?
    /// Called when the user begins a drag.
    public var onDragBegan: ((Point) -> Void)?
    /// Called continuously while the user drags.
    public var onDragUpdated: ((Point) -> Void)?
    /// Called when the user finishes a drag.
    public var onDragEnded: ((Point) -> Void)?
    /// Called when the user clicks without dragging.
    public var onClick: ((Point) -> Void)?

    // MARK: - State

    /// The annotations to render.
    public var annotations: [Annotation] = [] {
        didSet { needsDisplay = true }
    }

    /// The in-progress annotation, rendered on top of the committed ones.
    private var inProgress: Annotation?

    /// The tool currently in use.
    public var tool: AnnotationTool = .pen {
        didSet { needsDisplay = true }
    }

    /// The colour for new annotations.
    public var color: Color = .red

    /// The stroke width for new annotations.
    public var lineWidth: Double = 4

    /// Whether shapes should be filled.
    public var fillsShapes = false {
        didSet { needsDisplay = true }
    }

    /// The next step number to stamp.
    public var nextStepNumber = 1

    /// The screen this canvas covers, used to map coordinates.
    public var screen: ScreenFrame = ScreenFrame(origin: .zero, size: .zero) {
        didSet { needsDisplay = true }
    }

    /// Whether the view accepts mouse events. When false, clicks fall through
    /// to the app underneath, which is what "paused" mode means.
    public var isInteractionEnabled = true

    /// Height of the menu bar on the screen this canvas covers.
    ///
    /// Clicks landing inside the top strip are never swallowed, so the menu
    /// bar, the Dock-independent status items and the system UI stay usable
    /// while the user is annotating. Zero means "exhaust the whole canvas".
    public var menuBarHeight: Double = 0

    /// Whether the canvas captures input only while ⌥ (Option) is held.
    ///
    /// On, every plain click is handed straight to the app underneath, so
    /// the user keeps driving the app they are presenting while the overlay
    /// is up; holding ⌥ is the explicit "draw here" gesture. Off, the canvas
    /// owns every click outside the menu bar strip and ⌥ is not required.
    public var holdOptionToDraw = false

    // MARK: - Tracking

    private var dragPoints: [Point] = []
    private var isDragging = false
    /// The point where the mouse went down, used to detect a click.
    private var mouseDownPoint: Point?

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The view's coordinate space is already in points with the origin at
        // the bottom-left, matching the screen space the annotations use. The
        // only translation needed is the screen's origin within the desktop.
        let renderer = AnnotationRenderer(
            style: .init(scale: 1, fillsShapes: fillsShapes)
        )

        var toDraw = annotations
        if let inProgress {
            toDraw.append(inProgress)
        }

        renderer.draw(annotations: toDraw, in: context, origin: screen.origin)
    }

    // MARK: - Coordinate mapping

    /// Converts a point in the view's coordinate space into screen space.
    ///
    /// AppKit view coordinates have their origin at the bottom-left, the same
    /// convention the core module uses, so the mapping is a plain translation
    /// by the screen's origin within the desktop.
    private func screenPoint(from event: NSEvent) -> Point {
        let local = convert(event.locationInWindow, from: nil)
        return Point(
            x: Double(local.x) + screen.origin.x,
            y: Double(local.y) + screen.origin.y
        )
    }

    // MARK: - Mouse events

    public override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = screenPoint(from: event)
        mouseDownPoint = point
        dragPoints = [point]
        isDragging = true

        onDragBegan?(point)
        onDragUpdated?(point)

        if !tool.isDragBased {
            // Click-based tools (text, step number) commit immediately.
            commitClick(at: point)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled, isDragging else { return }
        let point = screenPoint(from: event)
        dragPoints.append(point)
        onDragUpdated?(point)

        if tool.isDragBased {
            inProgress = makeAnnotation(from: dragPoints)
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = screenPoint(from: event)

        if isDragging, tool.isDragBased {
            dragPoints.append(point)
            let annotation = makeAnnotation(from: dragPoints)
            inProgress = nil
            needsDisplay = true
            onAnnotationCreated?(annotation)
            onDragEnded?(point)
        } else if let down = mouseDownPoint, down.distance(to: point) < 3 {
            onClick?(point)
        }

        isDragging = false
        dragPoints = []
        mouseDownPoint = nil
    }

    // MARK: - Hit testing

    /// Decides which clicks the canvas is allowed to swallow.
    ///
    /// Three rules keep the screen usable while the overlay is up:
    ///
    /// - A paused overlay is fully click-through (`nil` matches nothing, so
    ///   the click falls to the app underneath while the picture stays
    ///   visible).
    /// - Clicks inside the menu bar strip are never swallowed. Returning
    ///   `nil` there hands them to the window sitting below the panel: the
    ///   menu bar, the Dock and Presentify's own status item stay usable
    ///   during a presentation instead of being blocked by the canvas.
    /// - In "hold ⌥ to draw" mode every plain click falls through and only a
    ///   click that arrives with ⌥ held is claimed as a drawing gesture.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled else { return nil }

        if menuBarHeight > 0, let window {
            // `point` arrives in the superview's space, which for a window's
            // content view is the window base space; converting to screen
            // space keeps the comparison independent of window placement.
            let inScreen = window.convertToScreen(NSRect(origin: point, size: .zero))
            let maxY = screen.origin.y + screen.size.height
            if inScreen.origin.y > maxY - menuBarHeight {
                return nil
            }
        }

        if holdOptionToDraw {
            // `NSApp.currentEvent` is the mouse event being routed while the
            // window hit-tests it.
            guard NSApp.currentEvent?.modifierFlags.contains(.option) == true else {
                return nil
            }
        }

        return super.hitTest(point)
    }

    // MARK: - Annotation construction

    /// Builds an annotation from the collected drag points.
    private func makeAnnotation(from points: [Point]) -> Annotation {
        var annotation = Annotation(
            tool: tool,
            color: color,
            lineWidth: lineWidth,
            path: points,
            bounds: Annotation.bounds(of: points)
        )

        if tool == .stepNumber {
            annotation.stepNumber = nextStepNumber
        }
        return annotation
    }

    /// Commits a click-based annotation.
    private func commitClick(at point: Point) {
        switch tool {
        case .stepNumber:
            var annotation = Annotation(
                tool: .stepNumber,
                color: color,
                lineWidth: lineWidth,
                path: [point],
                bounds: Rect(origin: point, size: .zero)
            )
            annotation.stepNumber = nextStepNumber
            onAnnotationCreated?(annotation)
        case .text:
            // The text editor lives in the app layer. The click is reported
            // from `mouseUp`, once the gesture is known not to be a drag, so
            // the editor is not opened twice.
            break
        default:
            break
        }
    }
}
