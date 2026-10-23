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
        isClickAnimationEnabled: Bool = true
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
