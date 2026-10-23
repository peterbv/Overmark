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
    public var cursorLocation: Point = .zero {
        didSet {
            needsDisplay = true
            if effects.isLaserEnabled {
                appendTrailSample(cursorLocation)
            }
        }
    }

    /// The effects to draw.
    public var effects: CursorEffects {
        didSet {
            needsDisplay = true
            if !effects.isLaserEnabled {
                laserTrail.removeAll()
                stopTrailTicker()
            }
        }
    }

    /// The screenshot shown under the zoom lens.
    public var backgroundImage: CGImage? {
        didSet { needsDisplay = true }
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
    public var clickPulse: ClickPulse? {
        didSet {
            needsDisplay = true
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
        if effects.isZoomEnabled && isCursorHere {
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

    // MARK: - Pulse timing

    /// Seconds since the pulse started.
    private func pulseElapsed(_ pulse: ClickPulse) -> TimeInterval {
        Date().timeIntervalSince(pulse.startedAt)
    }

    // MARK: - Laser trail

    /// Appends one trail sample and keeps the tail short enough to glow.
    private func appendTrailSample(_ point: Point) {
        let now = Date()
        laserTrail.removeAll {
            now.timeIntervalSince($0.at) > CursorEffectRenderer.trailDuration
        }
        laserTrail.append(LaserSample(point: point, at: now))
        if laserTrail.count > Self.trailCapacity {
            laserTrail.removeFirst(laserTrail.count - Self.trailCapacity)
        }
        startTrailTicker()
        needsDisplay = true
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
                    self.needsDisplay = true
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
                    self.needsDisplay = true
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
