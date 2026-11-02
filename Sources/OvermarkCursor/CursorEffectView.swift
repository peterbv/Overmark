import AppKit
import Foundation
import OvermarkCapture
import OvermarkCore

/// One click's ripple animation: where it happened and which button.
public struct ClickPulse: Equatable, Sendable {
    public enum Button: String, Equatable, Sendable {
        case left
        case right
    }

    /// The click position, in screen space.
    public let point: Point
    /// Which button made the click.
    public let button: Button
    /// When the animation started.
    let startedAt: Date

    public init(point: Point, button: Button = .left) {
        self.point = point
        self.button = button
        self.startedAt = Date()
    }
}

/// A transparent, non-activating view that draws the cursor effects.
///
/// Like the annotation overlay, this view never becomes key, so the user can
/// keep working in the app underneath while the effects are visible.
public final class CursorEffectView: NSView {
    /// The pointer position, in screen space.
    ///
    /// Repaints only the ground the pointer moved through: the old and the
    /// new pointer-following regions. On a mouse-move every display's
    /// dirty rect shrinks from the full screen to a couple of effect discs,
    /// which is the whole point of the dirty-rect scheme — the dim layer
    /// and anything outside those discs keeps the pixels of the previous
    /// paint, which are still correct because `draw(_:)` is state-derived
    /// (it re-derives every pixel inside its clip from the current state).
    public var cursorLocation: Point = .zero {
        didSet {
            if effects.isLaserEnabled {
                appendTrailSample(cursorLocation)
            }
            markDirty(invalidate(between: oldValue, and: cursorLocation))
        }
    }

    /// The effects to draw. Repaints everything: a change here (a radius, a
    /// dim opacity, an effect toggle) can alter any pixel on the display.
    public var effects: CursorEffects {
        didSet {
            needsDisplay = true
            if !effects.isLaserEnabled {
                laserTrail.removeAll()
                stopTrailTicker()
            }
            if !effects.isLensMirrored && lensSourceScreen != nil {
                // Mirroring just ended: the stale magnification mapping
                // would place the crop at a foreign position.
                lensSourceScreen = nil
            }
        }
    }

    /// The screenshot shown under the zoom lens.
    ///
    /// The screenshot feeds the lens alone, so only the lens square needs a
    /// repaint when it changes.
    public var backgroundImage: CGImage? {
        didSet { markDirty(lensRect(cursor: cursorLocation, source: lensSourceScreen)) }
    }

    /// The screen the magnified pixels come from when the lens is mirrored.
    ///
    /// nil means: the lens magnifies this view's own `screen`. The refresh
    /// loop sets it on every non-hosting display while mirroring is on, so
    /// those screens show the same lens the pointer's display does.
    ///
    /// The mirrored placement maps through the source frame, so switching
    /// sources (or dropping to the local lens) moves the lens: repaint both
    /// placements.
    public var lensSourceScreen: ScreenFrame? {
        didSet {
            var rect = lensRect(cursor: cursorLocation, source: oldValue)
            if let fresh = lensRect(cursor: cursorLocation, source: lensSourceScreen) {
                rect = rect?.union(fresh) ?? fresh
            }
            markDirty(rect)
        }
    }

    /// The screen the effects cover.
    public var screen: ScreenFrame = ScreenFrame(origin: .zero, size: .zero) {
        didSet { needsDisplay = true }
    }

    /// The click animation currently playing, in screen space.
    ///
    /// Assigning starts the ripple on this display; clearing it (or letting
    /// it time out) stops it. The effect windows are built per display, so a
    /// click only ever lives on the one view that hosts that screen — the
    /// controller decides which view gets it.
    ///
    /// The repaint covers the ripple's travel (it expands to roughly twice
    /// the highlight radius), unioned with the ring the outgoing pulse left
    /// so a mid-animation replacement erases the old one.
    public var clickPulse: ClickPulse? {
        didSet {
            var rect = oldValue.map(pulseRect)
            if let fresh = clickPulse.map(pulseRect) {
                rect = rect?.union(fresh) ?? fresh
            }
            markDirty(rect)
            if clickPulse == nil {
                stopPulseTicker()
            } else {
                startPulseTicker()
            }
        }
    }

    /// How long one click ripple plays, in seconds.
    ///
    /// Kept equal to the renderer's constant so on-screen ripples and burned
    /// ripples never drift apart.
    static let pulseDuration: TimeInterval = CursorEffectRenderer.rippleDuration

    /// The 60 fps ticker that keeps redrawing while a ripple plays.
    private var pulseTicker: Timer?

    /// Recent laser positions, in screen space, oldest first.
    private var laserTrail: [LaserSample] = []
    /// The 30 fps ticker that fades the laser tail out while it lives.
    private var trailTicker: Timer?
    /// Upper bound on remembered samples; mirrors the recorder's trail box.
    private static let trailCapacity = 64

    public override init(frame frameRect: NSRect) {
        self.effects = CursorEffects()
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Convert the screen-space pointer into the view's own coordinates.
        // The view fills the window, so the window's frame origin is this
        // display's origin in screen space (bounds.origin is always (0, 0)
        // for a borderless window's content view and must NOT be used).
        let windowOrigin = window?.frame.origin
        let originX = windowOrigin.map { Double($0.x) } ?? screen.origin.x
        let originY = windowOrigin.map { Double($0.y) } ?? screen.origin.y
        let cursor = Point(
            x: cursorLocation.x - originX,
            y: cursorLocation.y - originY
        )

        // The pointer lives on exactly one display. Respectively effects that
        // follow the pointer — the lens, the highlight ring and the spotlight
        // hole — only make sense on that display; every other display keeps
        // its dimming layer without punching a hole for a pointer it hosts on
        // a neighbor.
        let isCursorHere =
            cursor.x >= bounds.minX - 1 && cursor.x <= bounds.maxX + 1 &&
            cursor.y >= bounds.minY - 1 && cursor.y <= bounds.maxY + 1

        if effects.isSpotlightEnabled {
            // Even-odd clip: works on-screen (transparent window) and on the
            // opaque buffers the window recorder burns into.
            CursorEffectRenderer.drawSpotlight(
                dimRect: bounds,
                holeCenter: isCursorHere ? CGPoint(x: cursor.x, y: cursor.y) : nil,
                holeRadius: effects.spotlightRadius,
                dimOpacity: effects.spotlightDimOpacity,
                in: context
            )
        }
        if effects.isZoomEnabled &&
            (isCursorHere || (effects.isLensMirrored && lensSourceScreen != nil)) {
            drawZoomLens(cursor: cursor, in: context)
        }
        if effects.isHighlightEnabled && isCursorHere {
            drawHighlight(cursor: cursor, in: context)
        }

        // The laser paints fresh: stale samples are dropped before anything
        // is drawn, and the dot is layered above its tail.
        if effects.isLaserEnabled {
            pruneTrail()
            let trail = laserTrail.map { sample in
                (
                    point: CGPoint(
                        x: sample.point.x - originX,
                        y: sample.point.y - originY
                    ),
                    at: sample.at
                )
            }
            CursorEffectRenderer.drawLaserTrail(
                trail,
                at: Date(),
                color: effects.laserColor,
                radius: effects.laserRadius,
                keep: bounds,
                in: context
            )
            if isCursorHere {
                CursorEffectRenderer.drawLaserDot(
                    at: CGPoint(x: cursor.x, y: cursor.y),
                    color: effects.laserColor,
                    radius: effects.laserRadius,
                    in: context
                )
            }
        }

        if let pulse = clickPulse,
           pulseElapsed(pulse) < Self.pulseDuration + 0.05 {
            let local = Point(
                x: pulse.point.x - originX,
                y: pulse.point.y - originY
            )
            // The ripple may spill past the edge, hence the generous margin:
            // what matters is rejecting ripples that belong to a neighbour.
            let margin = effects.highlightRadius * 2
            let pulseHere =
                local.x >= -margin && local.x <= bounds.maxX + margin &&
                local.y >= -margin && local.y <= bounds.maxY + margin
            if pulseHere {
                drawClickPulse(
                    pulse,
                    originX: originX,
                    originY: originY,
                    in: context
                )
            }
        }
    }

    // MARK: - Dirty rectangles

    // Mouse-driven updates never repaint the whole view: every effect paints
    // a bounded region (a disc at the pointer, the lens square, the trail's
    // capsule, the ripple's ring), so the invalidated area is the union of
    // the regions where the state *was* and the regions where it now is.
    // This is safe because `draw(_:)` derives every pixel inside its clip
    // from the current state: pixels outside the dirty rect keep the values
    // of the previous paint, and those values only change when the state
    // they derive from changes — which is exactly what the rects here track.
    // AppKit unions the given rect into the pending invalidation and clips
    // the next `draw` to it.

    /// Repaints a dirty rectangle; there is nothing to do when nothing
    /// changed.
    private func markDirty(_ rect: NSRect?) {
        guard let rect else { return }
        setNeedsDisplay(rect)
    }

    /// The view-local rectangle where one effect may paint a screen-space
    /// disc of the given half-extent, with the origin `draw(_:)` conversion
    /// (window frame origin, else the screen's).
    private func discRect(around point: Point, extent: Double) -> NSRect {
        let origin = drawOrigin
        return NSRect(
            x: point.x - origin.x - extent,
            y: point.y - origin.y - extent,
            width: extent * 2,
            height: extent * 2
        )
    }

    /// The screen-space origin `draw(_:)` converts positions against.
    private var drawOrigin: Point {
        let windowOrigin = window?.frame.origin
        return Point(
            x: windowOrigin.map { Double($0.x) } ?? screen.origin.x,
            y: windowOrigin.map { Double($0.y) } ?? screen.origin.y
        )
    }

    /// Whether `draw(_:)` treats the pointer as being on this display
    /// (bounds ±1 — the same gate, kept in step with the drawing code).
    private func isCursorHere(at location: Point) -> Bool {
        let origin = drawOrigin
        let x = location.x - origin.x
        let y = location.y - origin.y
        return x >= bounds.minX - 1 && x <= bounds.maxX + 1 &&
            y >= bounds.minY - 1 && y <= bounds.maxY + 1
    }

    /// The rectangle where all pointer-following effects paint for a
    /// location: the spotlight hole and the highlight ring appear only when
    /// the pointer is here, the laser dot's soft halo is the widest of the
    /// pointer discs, and the mirrored lens lands at the proportionally
    /// mapped placement on this screen.
    private func invalidate(between from: Point, and to: Point) -> NSRect? {
        var rect = effectsRect(at: from)
        if let next = effectsRect(at: to) {
            rect = rect?.union(next) ?? next
        }
        return rect
    }

    private func effectsRect(at location: Point) -> NSRect? {
        let here = isCursorHere(at: location)
        var rect = NSRect.null
        if effects.isSpotlightEnabled && here {
            rect = rect.union(discRect(around: location, extent: effects.spotlightRadius + 4))
        }
        if effects.isHighlightEnabled && here {
            // The border is stroked centered on the shape path, so half of
            // it reaches beyond the disc.
            rect = rect.union(discRect(
                around: location,
                extent: effects.highlightRadius + effects.highlightBorderWidth / 2 + 4
            ))
        }
        if effects.isLaserEnabled && here {
            // The dot's soft halo is `2.75 × radius` wide.
            rect = rect.union(discRect(around: location, extent: effects.laserRadius * 2.75))
        }
        if let lens = lensRect(cursor: location, source: lensSourceScreen) {
            rect = rect.union(lens)
        }
        return rect == .null ? nil : rect
    }

    /// The lens square for a placement, or nil when the lens paints nothing.
    ///
    /// Mirrors the visibility gates of `draw(_:)` + `drawZoomLens`: zoom on,
    /// a background captured for the crop, pointer on this display (or
    /// mirroring feeding this screen), and the pointer inside the source
    /// frame so a placement exists at all. Non-mirrored placement degenerates
    /// to the local lens at the pointer; on-screen the destination-frame
    /// local coordinates of the placement *are* view coordinates (the view
    /// fills the borderless window whose content is the screen).
    private func lensRect(cursor: Point, source: ScreenFrame?) -> NSRect? {
        guard effects.isZoomEnabled, backgroundImage != nil else { return nil }
        guard isCursorHere(at: cursor) || (effects.isLensMirrored && source != nil) else {
            return nil
        }
        guard let placement = CursorEffectRenderer.mirrorLensPlacement(
            cursor: cursor,
            source: source ?? screen,
            destination: screen
        ) else { return nil }
        let center = Point(
            x: screen.origin.x + placement.destination.x,
            y: screen.origin.y + placement.destination.y
        )
        // The square plus the centered 3pt border, with anti-aliasing margin.
        return discRect(around: center, extent: effects.zoomSize / 2 + 6)
    }

    /// The rectangle the ripple may paint for a pulse: it expands to about
    /// twice the highlight radius with a centered stroke on top.
    private func pulseRect(_ pulse: ClickPulse) -> NSRect {
        let extent = effects.highlightRadius * 1.9 +
            max(1.5, effects.highlightBorderWidth) / 2 + 4
        return discRect(around: pulse.point, extent: extent)
    }

    /// One remembered trail sample's painted disc: the stroke reaches a
    /// radius past the sample point, and round joins sit inside that.
    private func sampleDisc(_ sample: LaserSample) -> NSRect {
        discRect(around: sample.point, extent: effects.laserRadius)
    }

    /// The painted laser tail's rectangle: every remembered sample's disc —
    /// consecutive samples' discs unioned cover each connecting stroke —
    /// plus the dot at the pointer.
    ///
    /// Covering *all* remembered samples (not just the fresh ones) is what
    /// keeps the fade seamless: `draw(_:)` prunes samples that aged out
    /// before painting, and a sample pruned mid-life would otherwise leave
    /// its last painted glow on screen forever. Since every invalidation
    /// covers the whole remembered tail, anything `pruneTrail` discards at
    /// draw time is already inside the dirty rect and gets cleared.
    private func trailRect() -> NSRect? {
        guard effects.isLaserEnabled, !laserTrail.isEmpty else { return nil }
        var rect = NSRect.null
        for sample in laserTrail {
            rect = rect.union(sampleDisc(sample))
        }
        if isCursorHere(at: cursorLocation) {
            rect = rect.union(discRect(
                around: cursorLocation,
                extent: effects.laserRadius * 2.75
            ))
        }
        return rect == .null ? nil : rect
    }

    // MARK: - Pulse timing

    /// Seconds since the pulse started.
    private func pulseElapsed(_ pulse: ClickPulse) -> TimeInterval {
        Date().timeIntervalSince(pulse.startedAt)
    }

    // MARK: - Laser trail

    /// Appends one trail sample and keeps the tail short enough to glow.
    ///
    /// The repaint covers three things at once, because the *removals* are
    /// the ghost-pixel hazard: a sample that aged out (or fell off the tail
    /// capacity) was painted last frame but is gone from the array by the
    /// time `draw` runs, so its disc must be inside the dirty rect or its
    /// pixels survive as a stale glow. Hence: the discarded samples' discs,
    /// the whole live tail (which contains the segment that reaches the
    /// samples next to anything dropped), and the dot at the pointer.
    private func appendTrailSample(_ point: Point) {
        let now = Date()
        var erased = NSRect.null
        laserTrail.removeAll { sample in
            guard now.timeIntervalSince(sample.at) > CursorEffectRenderer.trailDuration else {
                return false
            }
            erased = erased.union(sampleDisc(sample))
            return true
        }
        if laserTrail.count > Self.trailCapacity {
            for sample in laserTrail.prefix(laserTrail.count - Self.trailCapacity) {
                erased = erased.union(sampleDisc(sample))
            }
            laserTrail.removeFirst(laserTrail.count - Self.trailCapacity)
        }
        laserTrail.append(LaserSample(point: point, at: now))
        startTrailTicker()

        var rect = erased
        if let live = trailRect() {
            rect = rect.union(live)
        }
        markDirty(rect)
    }

    /// Drops samples whose glow has fully faded.
    private func pruneTrail() {
        let now = Date()
        laserTrail.removeAll {
            now.timeIntervalSince($0.at) > CursorEffectRenderer.trailDuration
        }
        if laserTrail.isEmpty {
            stopTrailTicker()
        }
    }

    /// Keeps redrawing while the tail fades out, like the pulse ticker does
    /// for ripples. Nothing else invalidates the view while the pointer is
    /// still, so this 30 fps ticker drives the trail's fade.
    private func startTrailTicker() {
        guard trailTicker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] sender in
            guard let self else {
                // The view is gone; nobody else can stop this timer.
                sender.invalidate()
                return
            }
            MainActor.assumeIsolated {
                if self.laserTrail.isEmpty {
                    self.stopTrailTicker()
                } else {
                    self.markDirty(self.trailRect())
                }
            }
        }
        trailTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTrailTicker() {
        trailTicker?.invalidate()
        trailTicker = nil
    }

    /// Keeps redrawing while a ripple plays.
    ///
    /// The ripple animates over time, but nothing moves the view itself, so
    /// nothing else would invalidate it — this 60 fps ticker drives the
    /// redraws and stops itself once the pulse is done. The tick always runs
    /// on the main run loop, so the isolated body is assumed intentionally.
    private func startPulseTicker() {
        guard pulseTicker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] sender in
            guard let self else {
                // The view is gone; nobody else can stop this timer.
                sender.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard let pulse = self.clickPulse else {
                    self.stopPulseTicker()
                    return
                }
                let elapsed = Date().timeIntervalSince(pulse.startedAt)
                if elapsed > Self.pulseDuration + 0.05 {
                    self.stopPulseTicker()
                } else {
                    self.markDirty(self.pulseRect(pulse))
                }
            }
        }
        pulseTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPulseTicker() {
        pulseTicker?.invalidate()
        pulseTicker = nil
    }
}
