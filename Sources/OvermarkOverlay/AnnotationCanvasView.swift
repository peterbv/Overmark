import AppKit
import Foundation
import OvermarkCapture
import OvermarkCore

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
    /// Called when the user right-clicks an existing annotation asking to
    /// delete it.
    public var onAnnotationDelete: ((Annotation) -> Void)?
    /// Called when a selection gesture finishes, with the ids now selected
    /// (an empty set means the gesture cleared the selection).
    public var onSelectionCommitted: ((Set<Annotation.ID>) -> Void)?
    /// Called when a selection drag ends, carrying the moved annotation
    /// copies for the app layer to commit as one batch.
    public var onSelectionMoved: (([Annotation]) -> Void)?

    // MARK: - State

    /// The annotations to render.
    public var annotations: [Annotation] = [] {
        didSet {
            needsDisplay = true
            // Fresh values (the app layer pushed the committed batch) make
            // the in-flight previews stale; the real annotations now carry
            // the move.
            if !movePreview.isEmpty { movePreview = [:] }
        }
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
    ///
    /// The value is baked into annotations while they are created, so
    /// changing it later only affects new shapes.
    public var fillsShapes = false {
        didSet { needsDisplay = true }
    }

    /// The final colour of gradient strokes for new annotations, or `nil`
    /// while gradients are off. Like the fill flag, it is stored on each
    /// annotation at creation time.
    public var gradientColor: Color? {
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

    /// Whether the canvas captures input only while the configured drawing
    /// key (⌥ by default, ⌃/⌘ selectable) is held.
    ///
    /// On, every plain click is handed straight to the app underneath, so
    /// the user keeps driving the app they are presenting while the overlay
    /// is up; holding the drawing key is the explicit "draw here" gesture.
    /// Off, the canvas owns every click outside the menu bar strip and the
    /// drawing key is not required.
    public var holdOptionToDraw = false

    /// The modifier flags the user must hold while `holdOptionToDraw` is on.
    ///
    /// The monitor tracks the down/up state of the matching physical key at
    /// the window-server level; this gate re-checks the live event so a stroke
    /// can only start when the key is genuinely held.
    public var requiredModifier: NSEvent.ModifierFlags = .option

    /// Whether the canvas paints a blank board instead of letting the screen
    /// underneath show through.
    ///
    /// The dedicated whiteboard is an overlay state, not a separate mode: the
    /// panel, gestures and annotations keep working exactly the same, only the
    /// pixels behind the marks become an opaque board. While the board is up
    /// the canvas claims every click — there is nothing underneath that is
    /// worth falling through to.
    public var isWhiteboard = false {
        didSet { needsDisplay = true }
    }

    /// The surface colour of the whiteboard.
    public var boardColor: Color = .white {
        didSet { needsDisplay = true }
    }

    /// The frozen frame painted behind the marks while the screen freeze
    /// is up.
    ///
    /// Like the whiteboard board, the freeze is an overlay state: the panel,
    /// gestures and annotations keep working exactly the same, only what the
    /// pixels stand for changes — a captured still of the desktop instead of
    /// the live contents underneath. The image covers the screen this canvas
    /// belongs to, at that display's device-pixel resolution, and the canvas
    /// scales it into its own bounds.
    public var backdropImage: CGImage? {
        didSet { needsDisplay = true }
    }

    // MARK: - Selection

    /// Whether gestures route to the selection machinery instead of drawing.
    ///
    /// Like the whiteboard and the freeze, selection is a state of the
    /// running session: gestures still pass the same `hitTest` gates (the
    /// drawing key, pause, the menu-bar strip); only what a gesture *means*
    /// changes — dragging draws a marquee or moves a selection instead of
    /// laying down ink.
    public var isSelectionMode = false {
        didSet {
            needsDisplay = true
            resetSelectionGesture()
        }
    }

    /// The marks currently highlighted as selected.
    public var selectedIDs: Set<Annotation.ID> = [] {
        didSet { needsDisplay = true }
    }

    /// One selection gesture in progress.
    private enum SelectionGesture: Equatable {
        /// Empty canvas: dragging stretches a marquee rectangle.
        case marquee(start: Point)
        /// A mark (or the selection): dragging moves its originals.
        case move(start: Point, originals: [Annotation])
        case none
    }

    private var selectionGesture: SelectionGesture = .none
    /// The marquee rectangle, in screen space, while it stretches.
    private var marqueeRect: Rect?
    /// The translation currently applied to the moving group, clamped so it
    /// cannot leave the screen.
    private var moveDelta: Vector = .zero
    /// Moved copies shown while the drag is in flight; the committed values
    /// arrive through `annotations` once the app layer records the batch.
    private var movePreview: [Annotation.ID: Annotation] = [:]

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

        if isWhiteboard {
            // Paint the dedicated board first: an opaque surface standing in
            // for the screen snapshot that normally sits (invisibly) behind
            // the panel.
            context.setFillColor(CGColor(
                red: CGFloat(boardColor.red),
                green: CGFloat(boardColor.green),
                blue: CGFloat(boardColor.blue),
                alpha: 1
            ))
            context.fill(bounds)
        } else if let backdropImage {
            // The frozen frame replaces the live screen: draw the captured
            // still across the whole canvas. The context runs y-up in view
            // space and CG images draw upright there, so the frame lands
            // with its top row at the top of the screen.
            context.draw(backdropImage, in: bounds)
        }

        // The view's coordinate space is already in points with the origin at
        // the bottom-left, matching the screen space the annotations use. The
        // only translation needed is the screen's origin within the desktop.
        let renderer = AnnotationRenderer(style: .init(scale: 1))

        var toDraw = annotations
        // While a move drags, the previewed copies stand in for their
        // originals; the committed values arrive via `annotations` right
        // after the gesture and the mapping empties.
        if !movePreview.isEmpty {
            toDraw = annotations.map { movePreview[$0.id] ?? $0 }
        }
        if let inProgress {
            toDraw.append(inProgress)
        }

        renderer.draw(annotations: toDraw, in: context, origin: screen.origin)

        drawSelectionChrome(context: context)
    }

    /// Paints the selection chrome: dashed outlines around selected marks
    /// and the dashed marquee while it stretches.
    ///
    /// The chrome floats above the ink on purpose — it is an interaction
    /// affordance, not a mark — and it follows a move preview so the
    /// outlines travel with the dragged copies.
    private func drawSelectionChrome(context: CGContext) {
        guard isSelectionMode else { return }

        let chrome = CGColor(srgbRed: 0.15, green: 0.55, blue: 1, alpha: 1)

        for annotation in annotations {
            guard selectedIDs.contains(annotation.id) else { continue }
            let shown = movePreview[annotation.id] ?? annotation
            // Marks that live on another display highlight on their own
            // canvas only, exactly like the panel they render on.
            guard shown.bounds.intersects(screen.frame) else { continue }
            let rect = CGRect(
                x: shown.bounds.minX - screen.origin.x,
                y: shown.bounds.minY - screen.origin.y,
                width: shown.bounds.size.width,
                height: shown.bounds.size.height
            )

            context.saveGState()
            context.setStrokeColor(chrome)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(rect.insetBy(dx: -3, dy: -3))
            context.restoreGState()
        }

        if let marqueeRect {
            let rect = CGRect(
                x: marqueeRect.minX - screen.origin.x,
                y: marqueeRect.minY - screen.origin.y,
                width: marqueeRect.size.width,
                height: marqueeRect.size.height
            )
            context.saveGState()
            context.setFillColor(CGColor(srgbRed: 0.15, green: 0.55, blue: 1, alpha: 0.10))
            context.fill(rect)
            context.setStrokeColor(chrome)
            context.setLineWidth(2)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(rect)
            context.restoreGState()
        }
    }

    // MARK: - Dirty rectangles

    // Per-sample gesture updates do not repaint the whole canvas. Every
    // gesture paints a bounded area — the growing stroke's hull bounds, the
    // marquee rectangle, the moving group's copies — so the invalidated area
    // is the union of where that area *was* and where it now is. The painter
    // is deterministic on state (strokes are prefix-stable polylines,
    // annotation records carry no transient styling, the board fill and the
    // backdrop draw are uniform under clipping), so the untouched pixels
    // inside a dirty rect re-derive to exactly what was already there.
    // Structural changes (annotations committed, tool, board state) keep the
    // full `needsDisplay` of their `didSet`s.

    /// Repaints the union of the old and the new painted area of one
    /// evolving region; a nil at both ends paints nothing.
    private func markDirty(between old: Rect?, and new: Rect?, pad: Double) {
        var rect: NSRect?
        if let old {
            rect = paintedRect(old, pad: pad)
        }
        if let new {
            let fresh = paintedRect(new, pad: pad)
            rect = rect?.union(fresh) ?? fresh
        }
        if let rect {
            setNeedsDisplay(rect)
        }
    }

    /// The view-local rectangle of a screen-space rect padded for centered
    /// strokes, dashes and anti-aliasing — the same translation the painter
    /// applies in `draw` and in the selection chrome.
    private func paintedRect(_ rect: Rect, pad: Double) -> NSRect {
        NSRect(
            x: rect.minX - screen.origin.x - pad,
            y: rect.minY - screen.origin.y - pad,
            width: rect.size.width + pad * 2,
            height: rect.size.height + pad * 2
        )
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

    /// Fired when a click lands on an existing text annotation, so the app
    /// layer can reopen the editor over it. Only used by the text tool.
    public var onAnnotationEdit: ((Annotation) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = screenPoint(from: event)

        if isSelectionMode {
            beginSelectionGesture(at: point)
            return
        }

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
        guard isInteractionEnabled else { return }
        let point = screenPoint(from: event)

        if isSelectionMode {
            updateSelectionGesture(to: point)
            return
        }

        guard isDragging else { return }
        dragPoints.append(point)
        onDragUpdated?(point)

        if tool.isDragBased {
            // The stroke is prefix-stable: growing it only adds a segment
            // inside the new hull bounds. Repaint where the painted area
            // was and where it now is; the pad covers the stroke reaching
            // past the path plus soft/anti-aliased edges.
            let previous = inProgress?.bounds
            inProgress = makeAnnotation(from: dragPoints)
            markDirty(between: previous, and: inProgress?.bounds, pad: lineWidth / 2 + 4)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = screenPoint(from: event)

        if isSelectionMode {
            finishSelectionGesture(at: point)
            return
        }

        if isDragging, tool.isDragBased {
            dragPoints.append(point)
            let annotation = makeAnnotation(from: dragPoints)
            inProgress = nil
            needsDisplay = true
            onAnnotationCreated?(annotation)
            onDragEnded?(point)
        } else if let down = mouseDownPoint, down.distance(to: point) < 3 {
            if tool == .text,
               let hit = Annotation.annotation(at: point, in: annotations, on: screen),
               hit.tool == .text {
                // A plain click on an existing text annotation re-edits it
                // instead of stacking a fresh one on top. Creating new text
                // is what a click on empty canvas does.
                onAnnotationEdit?(hit)
            } else {
                onClick?(point)
            }
        }

        isDragging = false
        dragPoints = []
        mouseDownPoint = nil
    }

    /// Discards any half-drawn stroke.
    ///
    /// Used when the ⌥-pass-through mode changes under an active gesture: the
    /// panels stop accepting events mid-stroke the moment ⌥ is released, so
    /// the canvas would never receive `mouseUp` and the half-drawn annotation
    /// would stay stuck on screen.
    public func cancelPendingStroke() {
        inProgress = nil
        isDragging = false
        dragPoints = []
        mouseDownPoint = nil
        resetSelectionGesture()
        needsDisplay = true
    }

    // MARK: - Selection gestures

    /// Starts a selection gesture on a mouse-down.
    ///
    /// A press on a mark moves it (or the whole selection when it is part of
    /// one); a press on empty canvas stretches a marquee. The drawing-key
    /// gate and the pause gate apply upstream, exactly as they gate ink.
    private func beginSelectionGesture(at point: Point) {
        mouseDownPoint = point
        isDragging = true

        if let hit = Annotation.annotation(at: point, in: annotations, on: screen) {
            // Marks outside this canvas's screen cannot be hit, so the
            // selection the tap owns is always local-friendly.
            let group = selectedIDs.contains(hit.id) ? selectedIDs : [hit.id]
            let originals = annotations.filter { group.contains($0.id) }
            guard !originals.isEmpty else {
                selectionGesture = .none
                return
            }
            selectionGesture = .move(start: point, originals: originals)
            if group != selectedIDs {
                // Tapping a mark that is not part of the selection makes it
                // the selection before the drag moves it.
                onSelectionCommitted?(group)
            }
        } else {
            selectionGesture = .marquee(start: point)
            marqueeRect = Rect(origin: point, size: Size(width: 0, height: 0))
            needsDisplay = true
        }
    }

    /// Advances the in-flight selection gesture on a drag.
    private func updateSelectionGesture(to point: Point) {
        switch selectionGesture {
        case .marquee(let start):
            let previous = marqueeRect
            marqueeRect = Annotation.dragBounds(from: start, to: point)
            // The pad covers the dashed 2pt border and its 0.10 fill.
            markDirty(between: previous, and: marqueeRect, pad: 6)
        case .move(let start, let originals):
            var delta = Vector(dx: point.x - start.x, dy: point.y - start.y)
            delta = clampedTranslation(delta, for: originals)
            moveDelta = delta
            let previous = movePreview
            movePreview = Dictionary(uniqueKeysWithValues: originals.map {
                ($0.id, $0.moved(by: delta))
            })
            // The copies travel as a group. The painted area transitions
            // from every original's bounds (where the ink was) to the moved
            // copy's bounds (where it now is), unioned over the whole group
            // since the delta may cross either way. The pad covers the ink's
            // stroke reach and the selection chrome (dashed outline inset
            // 3 at width 2).
            let pad = max(lineWidth / 2 + 4, 8)
            var rect: NSRect?
            for original in originals {
                let fromRect = paintedRect(original.bounds, pad: pad)
                rect = rect?.union(fromRect) ?? fromRect
                if let shown = previous[original.id] ?? movePreview[original.id] {
                    let toRect = paintedRect(shown.bounds, pad: pad)
                    rect = rect?.union(toRect) ?? toRect
                }
            }
            if let rect {
                setNeedsDisplay(rect)
            }
        case .none:
            break
        }
    }

    /// Ends the in-flight selection gesture on a mouse-up.
    private func finishSelectionGesture(at point: Point) {
        let down = mouseDownPoint ?? point
        let isDrag = down.distance(to: point) >= 3

        switch selectionGesture {
        case .marquee:
            if isDrag, let rect = marqueeRect {
                // Marquee selects by bounds intersection, matching what the
                // user sees highlighted while the rectangle stretches.
                onSelectionCommitted?(Set(
                    annotations
                        .filter { $0.bounds.intersects(rect) }
                        .map(\.id)
                ))
            } else {
                // A click on empty canvas clears the selection; empty commit
                // and clear are the same event for the app layer.
                onSelectionCommitted?([])
            }
        case .move(_, let originals):
            if moveDelta != Vector(dx: 0, dy: 0) {
                onSelectionMoved?(originals.map { $0.moved(by: moveDelta) })
            }
            // A click with no drag already committed its selection on the
            // way down; nothing more to do.
        case .none:
            break
        }

        resetSelectionGesture()
        isDragging = false
        mouseDownPoint = nil
    }

    /// The largest translation that keeps the whole moving group on the
    /// screen this canvas covers.
    private func clampedTranslation(_ delta: Vector, for originals: [Annotation]) -> Vector {
        guard screen.size.width > 0, screen.size.height > 0 else { return delta }

        var lowerX = -Double.infinity
        var upperX = Double.infinity
        var lowerY = -Double.infinity
        var upperY = Double.infinity
        for annotation in originals {
            lowerX = max(lowerX, screen.minX - annotation.bounds.minX)
            upperX = min(upperX, screen.maxX - annotation.bounds.maxX)
            lowerY = max(lowerY, screen.minY - annotation.bounds.minY)
            upperY = min(upperY, screen.maxY - annotation.bounds.maxY)
        }
        // A group wider (or taller) than the screen has no clamping range;
        // let it move freely rather than fighting the gesture.
        var clamped = delta
        if lowerX <= upperX {
            clamped.dx = min(max(delta.dx, lowerX), upperX)
        }
        if lowerY <= upperY {
            clamped.dy = min(max(delta.dy, lowerY), upperY)
        }
        return clamped
    }

    /// Drops any in-flight selection gesture.
    ///
    /// Previews are display-only — the committed document never saw them —
    /// so discarding restores the marks by simply forgetting the mapping.
    private func resetSelectionGesture() {
        let hadGesture = selectionGesture != .none || marqueeRect != nil || !movePreview.isEmpty
        selectionGesture = .none
        marqueeRect = nil
        moveDelta = .zero
        movePreview = [:]
        if hadGesture {
            needsDisplay = true
        }
    }

    // MARK: - Right-click deletion

    /// Deletes the annotation under a right-click, if any.
    ///
    /// A right-click with no annotation underneath is a no-op on purpose:
    /// no context menus while presenting, and the click never falls to the
    /// app underneath (the panels are not mouse-transparent then, either).
    /// In hold-⌥ mode the panels only accept events while ⌥ is held, so this
    /// fires with ⌥ only — the same gate drawing has, keeping both gestures
    /// consistent.
    public override func rightMouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = screenPoint(from: event)
        guard let annotation = Annotation.annotation(
            at: point,
            in: annotations,
            on: screen
        ) else { return }
        onAnnotationDelete?(annotation)
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
    ///   menu bar, the Dock and Overmark's own status item stay usable
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

        if isWhiteboard {
            // The board replaces the screen contents: every click belongs to
            // the canvas, bypassing the ⌥ gate entirely.
            return super.hitTest(point)
        }

        if backdropImage != nil {
            // The frozen frame stands in for the screen contents: same
            // reasoning as the board, there is nothing underneath worth
            // falling through to.
            return super.hitTest(point)
        }

        if holdOptionToDraw {
            // `NSApp.currentEvent` is the mouse event being routed while the
            // window hit-tests it.
            guard NSApp.currentEvent?.modifierFlags.contains(requiredModifier) == true else {
                return nil
            }
        }

        return super.hitTest(point)
    }

    // MARK: - Annotation construction

    /// Builds an annotation from the collected drag points.
    ///
    /// The fill and gradient state is recorded on the annotation itself, so
    /// the mark keeps the look it had when drawn even after the settings
    /// change.
    private func makeAnnotation(from points: [Point]) -> Annotation {
        var annotation = Annotation(
            tool: tool,
            color: color,
            lineWidth: lineWidth,
            path: points,
            bounds: Annotation.bounds(of: points),
            fillsShapes: fillsShapes,
            gradientColor: gradientColor
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
