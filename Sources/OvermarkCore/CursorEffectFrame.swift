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

    public init(
        effects: CursorEffects = CursorEffects(),
        cursor: Point? = nil,
        clicks: [CursorClick] = []
    ) {
        self.effects = effects
        self.cursor = cursor
        self.clicks = clicks
    }

    /// Whether this frame carries anything worth burning into video.
    ///
    /// Click ripples only exist if a click was registered, so a default
    /// settings bundle with no clicks has nothing to draw.
    public var hasBurnableContent: Bool {
        effects.isHighlightEnabled
            || effects.isSpotlightEnabled
            || effects.isZoomEnabled
            || !clicks.isEmpty
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

    private let lock = NSLock()
    private var effects = CursorEffects()
    private var cursor: Point?
    private var clicks: [CursorClick] = []

    public init() {}

    /// Replaces the settings, keeping the live pointer and clicks around.
    public func updateEffects(_ effects: CursorEffects) {
        lock.lock()
        defer { lock.unlock() }
        self.effects = effects
    }

    /// Updates the pointer position; `nil` forgets the previous one (tracking
    /// may stop providing locations, e.g. when Accessibility is revoked).
    public func updateCursor(_ position: Point?) {
        lock.lock()
        defer { lock.unlock() }
        cursor = position
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
            clicks: clicks
        )
    }
}
