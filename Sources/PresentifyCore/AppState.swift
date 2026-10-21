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
        zoomShape: ZoomShape = .circle
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
    }
}

/// The shape of the zoom lens.
public enum ZoomShape: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case circle
    case squircle

    public var id: String { rawValue }
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

    public init(
        tool: AnnotationTool = .pen,
        color: Color = .red,
        lineWidth: Double = 4,
        fillsShapes: Bool = false,
        nextStepNumber: Int = 1
    ) {
        self.tool = tool
        self.color = color
        self.lineWidth = lineWidth
        self.fillsShapes = fillsShapes
        self.nextStepNumber = nextStepNumber
    }
}
