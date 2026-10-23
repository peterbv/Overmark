import Foundation

/// One click that the click-ripple effect registered while recording.
///
/// Screen-space coordinates, the same annotation space the recorder burns in.
public struct CursorClick: Hashable, Sendable {
    /// Where the click happened, in AppKit screen space.
    public var point: Point
    /// Whether it was the right button (right ripples look subdued).
    public var isRight: Bool
    /// When the ripple starts: ripples are drawn for a fixed window after it.
    public var startedAt: Date

    public init(point: Point, isRight: Bool, startedAt: Date = Date()) {
        self.point = point
        self.isRight = isRight
        self.startedAt = startedAt
    }
}

/// One sampled position of the laser trail, while it is on.
public struct LaserSample: Hashable, Sendable {
    /// Where the pointer was, in screen space.
    public var point: Point
    /// When the sample was taken; the trail fades over a fixed window.
    public var at: Date

    public init(point: Point, at: Date = Date()) {
        self.point = point
        self.at = at
    }
}

/// A frame's worth of cursor-effect state for the recorder.
///
/// The presenter thread writes (tool settings, pointer position, clicks) and
/// each recorded frame reads the whole snapshot on the pipeline queue, so the
/// burn-in never races the user drawing or moving the mouse.
public struct CursorEffectFrame: Hashable, Sendable {
    /// The configured effects (the same set the on-screen windows use).
    public var effects: CursorEffects
    /// Where the pointer is, in screen space; `nil` when tracking is
    /// unavailable (e.g. Accessibility was revoked) or nothing was read yet.
    public var cursor: Point?
    /// Recent clicks, oldest first; the frame keeps a short window because a
    /// ripple only animates for a fraction of a second.
    public var clicks: [CursorClick]
    /// Recent laser positions, oldest first; the trail glows briefly and
    /// fades, so only a short window matters.
    public var laserTrail: [LaserSample]

    public init(
        effects: CursorEffects = CursorEffects(),
        cursor: Point? = nil,
        clicks: [CursorClick] = [],
        laserTrail: [LaserSample] = []
    ) {
        self.effects = effects
        self.cursor = cursor
        self.clicks = clicks
        self.laserTrail = laserTrail
    }

    /// Whether this frame carries anything worth burning into video.
    ///
    /// Click ripples only exist if a click was registered, so a default
    /// settings bundle with no clicks has nothing to draw.
    public var hasBurnableContent: Bool {
        effects.isHighlightEnabled
            || effects.isSpotlightEnabled
            || effects.isZoomEnabled
            || effects.isLaserEnabled
            || !clicks.isEmpty
            || !laserTrail.isEmpty
    }
}

/// Thread-safe store of `CursorEffectFrame` state.
///
/// Mirrors the annotation box used for burn-in: the app layer pushes updates
/// from its main-actor world and the recorder's frame callbacks read the
/// latest snapshot on their own queue.
public final class CursorEffectBox: @unchecked Sendable {
    /// Clicks older than this can no longer produce a drawable ripple.
    static let clickWindow: TimeInterval = 1.2
    /// Upper bound on remembered clicks: a frame only spans a fraction of a
    /// second of ripple time, and bursts of clicks are dropped oldest-first.
    static let clickCapacity = 8
    /// How long the laser trail keeps glowing.
    static let trailWindow: TimeInterval = 0.75
    /// Upper bound on remembered trail samples; movement can emit many
    /// samples per second, so the tail is capped oldest-first.
    static let trailCapacity = 64

    private let lock = NSLock()
    private var effects = CursorEffects()
    private var cursor: Point?
    private var clicks: [CursorClick] = []
    private var laserTrail: [LaserSample] = []

    public init() {}

    /// Replaces the settings, keeping the live pointer and clicks around.
    ///
    /// Turning the laser off also forgets its trail: a stale tail would glow
    /// again the moment the laser turns back on.
    public func updateEffects(_ effects: CursorEffects) {
        lock.lock()
        defer { lock.unlock() }
        self.effects = effects
        if !effects.isLaserEnabled {
            laserTrail.removeAll()
        }
    }

    /// Updates the pointer position; `nil` forgets the previous one (tracking
    /// may stop providing locations, e.g. when Accessibility is revoked).
    ///
    /// While the laser is on this also appends a trail sample, fading and
    /// capping the tail as it goes.
    public func updateCursor(_ position: Point?, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        cursor = position
        guard let position else {
            // Tracking is gone; a trail pointing nowhere is worse than none.
            laserTrail.removeAll()
            return
        }
        guard effects.isLaserEnabled else { return }
        laserTrail.removeAll {
            now.timeIntervalSince($0.at) > Self.trailWindow
        }
        laserTrail.append(LaserSample(point: position, at: now))
        if laserTrail.count > Self.trailCapacity {
            laserTrail.removeFirst(laserTrail.count - Self.trailCapacity)
        }
    }

    /// Records one click and prunes stale entries.
    public func appendClick(_ click: CursorClick, prunedAt now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        clicks.removeAll {
            now.timeIntervalSince($0.startedAt) > Self.clickWindow
        }
        clicks.append(click)
        if clicks.count > Self.clickCapacity {
            clicks.removeFirst(clicks.count - Self.clickCapacity)
        }
    }

    /// The current snapshot for one frame.
    public func current() -> CursorEffectFrame {
        lock.lock()
        defer { lock.unlock() }
        return CursorEffectFrame(
            effects: effects,
            cursor: cursor,
            clicks: clicks,
            laserTrail: laserTrail
        )
    }
}
