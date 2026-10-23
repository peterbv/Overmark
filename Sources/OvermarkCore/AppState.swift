import Foundation

/// What the app is currently doing.
///
/// The mode is a single enum rather than a set of booleans, which makes
/// impossible combinations unrepresentable: the app cannot be annotating and
/// zooming at the same time, and it cannot be idle while a spotlight is up.
public enum AppMode: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// Nothing is happening; only the menu bar item is visible.
    case idle
    /// The annotation canvas is active and the user can draw.
    case annotating
    /// The annotation canvas is visible but paused, so the user can interact
    /// with the app underneath.
    case paused

    public var id: String { rawValue }

    /// Whether the annotation overlay should be on screen.
    public var showsOverlay: Bool { self != .idle }

    /// Whether the user can currently add annotations.
    public var allowsDrawing: Bool { self == .annotating }
}

/// The cursor effects the app can apply independently of annotation mode.
public struct CursorEffects: Hashable, Sendable, Codable {
    /// Whether a halo is drawn around the pointer.
    public var isHighlightEnabled: Bool
    /// Radius of the highlight halo, in points.
    public var highlightRadius: Double
    /// Colour of the highlight halo.
    public var highlightColor: Color
    /// Whether the screen is dimmed except for a circle around the pointer.
    public var isSpotlightEnabled: Bool
    /// Radius of the spotlight cut-out, in points.
    public var spotlightRadius: Double
    /// Opacity of the dimmed area, 0...1.
    public var spotlightDimOpacity: Double
    /// Whether a magnified view of the pointer's surroundings is shown.
    public var isZoomEnabled: Bool
    /// Magnification factor of the zoom lens.
    public var zoomFactor: Double
    /// Size of the zoom lens window, in points.
    public var zoomSize: Double
    /// Shape of the zoom lens.
    public var zoomShape: ZoomShape
    /// Shape of the highlight ring drawn around the pointer.
    public var highlightShape: HighlightShape
    /// Thickness of the highlight ring's border, in points.
    public var highlightBorderWidth: Double
    /// Opacity of the highlight ring's fill, 0...1.
    public var highlightFillOpacity: Double
    /// Whether clicks play a ripple animation around the pointer.
    public var isClickAnimationEnabled: Bool
    /// Whether the pointer is followed by a laser dot with a short
    /// glowing trail.
    public var isLaserEnabled: Bool
    /// Colour of the laser dot and its trail.
    public var laserColor: Color
    /// Radius of the laser dot core, in points.
    public var laserRadius: Double
    /// Whether displays other than the pointer's own show the same zoom
    /// lens, placed where the pointer would map onto them.
    public var isLensMirrored: Bool
    /// How often the lens re-captures the screen content it magnifies.
    public var lensRefreshRate: LensRefreshRate

    public init(
        isHighlightEnabled: Bool = false,
        highlightRadius: Double = 40,
        highlightColor: Color = .yellow,
        isSpotlightEnabled: Bool = false,
        spotlightRadius: Double = 260,
        spotlightDimOpacity: Double = 0.55,
        isZoomEnabled: Bool = false,
        zoomFactor: Double = 2,
        zoomSize: Double = 240,
        zoomShape: ZoomShape = .circle,
        highlightShape: HighlightShape = .circle,
        highlightBorderWidth: Double = 3,
        highlightFillOpacity: Double = 0.35,
        isClickAnimationEnabled: Bool = true,
        isLaserEnabled: Bool = false,
        laserColor: Color = .red,
        laserRadius: Double = 5,
        isLensMirrored: Bool = false,
        lensRefreshRate: LensRefreshRate = .normal
    ) {
        self.isHighlightEnabled = isHighlightEnabled
        self.highlightRadius = highlightRadius
        self.highlightColor = highlightColor
        self.isSpotlightEnabled = isSpotlightEnabled
        self.spotlightRadius = spotlightRadius
        self.spotlightDimOpacity = spotlightDimOpacity
        self.isZoomEnabled = isZoomEnabled
        self.zoomFactor = zoomFactor
        self.zoomSize = zoomSize
        self.zoomShape = zoomShape
        self.highlightShape = highlightShape
        self.highlightBorderWidth = highlightBorderWidth
        self.highlightFillOpacity = highlightFillOpacity
        self.isClickAnimationEnabled = isClickAnimationEnabled
        self.isLaserEnabled = isLaserEnabled
        self.laserColor = laserColor
        self.laserRadius = laserRadius
        self.isLensMirrored = isLensMirrored
        self.lensRefreshRate = lensRefreshRate
    }

    /// Decodes settings tolerantly, so stored bundles written before a field
    /// existed keep working: older blobs simply get the default for the new
    /// fields instead of failing the whole decode and falling back to factory
    /// settings (which would drop the user's highlight/spotlight choices).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isHighlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .isHighlightEnabled) ?? false
        highlightRadius = try container.decodeIfPresent(Double.self, forKey: .highlightRadius) ?? 40
        highlightColor = try container.decodeIfPresent(Color.self, forKey: .highlightColor) ?? .yellow
        isSpotlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSpotlightEnabled) ?? false
        spotlightRadius = try container.decodeIfPresent(Double.self, forKey: .spotlightRadius) ?? 260
        spotlightDimOpacity = try container.decodeIfPresent(Double.self, forKey: .spotlightDimOpacity) ?? 0.55
        isZoomEnabled = try container.decodeIfPresent(Bool.self, forKey: .isZoomEnabled) ?? false
        zoomFactor = try container.decodeIfPresent(Double.self, forKey: .zoomFactor) ?? 2
        zoomSize = try container.decodeIfPresent(Double.self, forKey: .zoomSize) ?? 240
        zoomShape = try container.decodeIfPresent(ZoomShape.self, forKey: .zoomShape) ?? .circle
        highlightShape = try container.decodeIfPresent(HighlightShape.self, forKey: .highlightShape) ?? .circle
        highlightBorderWidth = try container.decodeIfPresent(Double.self, forKey: .highlightBorderWidth) ?? 3
        highlightFillOpacity = try container.decodeIfPresent(Double.self, forKey: .highlightFillOpacity) ?? 0.35
        isClickAnimationEnabled = try container.decodeIfPresent(Bool.self, forKey: .isClickAnimationEnabled) ?? true
        isLaserEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLaserEnabled) ?? false
        laserColor = try container.decodeIfPresent(Color.self, forKey: .laserColor) ?? .red
        laserRadius = try container.decodeIfPresent(Double.self, forKey: .laserRadius) ?? 5
        isLensMirrored = try container.decodeIfPresent(Bool.self, forKey: .isLensMirrored) ?? false
        lensRefreshRate = try container.decodeIfPresent(LensRefreshRate.self, forKey: .lensRefreshRate) ?? .normal
    }
}

/// How often the zoom lens re-captures the content it magnifies.
///
/// A lens stays live, so this choice trades motion smoothness against the
/// cost of grabbing screen snapshots in the background.
public enum LensRefreshRate: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// The original cadence, about three updates per second.
    case normal
    /// A quicker cadence for hand-drawn material, at a battery cost.
    case responsive

    public var id: String { rawValue }

    /// Seconds between two lens background refreshes.
    public var interval: TimeInterval {
        self == .normal ? 0.32 : 0.12
    }
}

/// The shape of the pointer highlight ring.
public enum HighlightShape: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case circle
    case squircle
    case rhombus

    public var id: String { rawValue }
}

/// The shape of the zoom lens.
public enum ZoomShape: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case circle
    case squircle

    public var id: String { rawValue }
}

/// The tone of the dedicated whiteboard surface.
///
/// The whiteboard replaces the screen contents with a blank board for the
/// length of the annotation session; the tone chooses what that board looks
/// like — a bright board for classrooms on projectors, a dark one for code
/// walk-throughs on OLED-friendly setups.
public enum BoardStyle: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case white
    case black

    public var id: String { rawValue }

    /// The surface colour of the board.
    public var color: Color {
        self == .white ? .white : .black
    }
}

/// The key the user holds to draw while the hold-to-draw gate is on.
///
/// The overlay panels stay transparent to the window server unless that key
/// is down, which is what keeps the rest of the Mac usable during a session.
/// ⌥ (Option) remains the default — it is the least conflict-prone chord on
/// a Mac — but ⌃ and ⌘ are selectable in Settings → Tools for keyboards or
/// habits that reach ⌥ less comfortably.
public enum DrawingModifier: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case option
    case control
    case command

    public var id: String { rawValue }

    /// The glyph shown in the toolbar chip, the Settings picker and debug
    /// output.
    public var symbol: String {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        }
    }
}

/// The tools and styles the user has selected.
public struct ToolSettings: Hashable, Sendable, Codable {
    public var tool: AnnotationTool
    public var color: Color
    public var lineWidth: Double
    /// Whether shapes are filled with a translucent version of the colour.
    public var fillsShapes: Bool
    /// The next step number to stamp.
    public var nextStepNumber: Int
    /// Whether the canvas only captures input while the configured drawing
    /// key (⌥ by default, ⌃/⌘ selectable in Settings) is held.
    ///
    /// With this on, every other click falls through to the app underneath,
    /// which keeps the Mac usable while the overlay is up — the user draws
    /// by holding the drawing key and drawing, and interacts normally
    /// otherwise. With it off the canvas owns all clicks outside the menu
    /// bar strip (the older behaviour).
    public var holdOptionToDraw: Bool
    /// Seconds after which a drawn annotation fades away on its own.
    ///
    /// `0` disables the timer. Step numbers are excluded — they anchor the
    /// narrative — and only annotations *created* while the timer is on are
    /// affected.
    public var autoFadeSeconds: Int
    /// Final colour of the gradient stroke, or `nil` while gradients are off.
    ///
    /// Strokes blend from `color` at the start of the mark to this colour at
    /// the end. `nil` (the default) keeps every stroke solid.
    public var gradientColor: Color?

    public init(
        tool: AnnotationTool = .pen,
        color: Color = .red,
        lineWidth: Double = 4,
        fillsShapes: Bool = false,
        nextStepNumber: Int = 1,
        holdOptionToDraw: Bool = true,
        autoFadeSeconds: Int = 0,
        gradientColor: Color? = nil
    ) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.fillsShapes = fillsShapes
        self.nextStepNumber = nextStepNumber
        self.holdOptionToDraw = holdOptionToDraw
        self.autoFadeSeconds = autoFadeSeconds
        self.gradientColor = gradientColor
    }
}
