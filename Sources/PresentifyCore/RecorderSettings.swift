import Foundation

/// The video codec the presentation recorder encodes with.
///
/// H.264 is the default because it decodes everywhere (every player, every
/// chat app preview) and hardware-encodes up to 4K. HEVC compresses the same
/// footage smaller but its playback is out of reach on some older machines,
/// so it is offered as explicit choice rather than default.
public enum RecordingCodec: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    public var id: String { rawValue }
}

/// Which display the presentation recorder captures.
///
/// Display identifiers (`CGDirectDisplayID`) are unstable across reboots and
/// monitor re-connections, so the saved choice is a *policy* rather than an
/// ID: the coordinator resolves it against the screens present when the
/// recording actually starts, falling back to the main display when the
/// chosen screen is gone.
public enum RecordingDisplayChoice: Hashable, Sendable, Codable {
    /// The display macOS marks as main (menu bar and login screen live here).
    case main
    /// A picked screen, matched by its localized name when recording starts.
    case namedScreen(String)
}

/// Which surface the presentation recorder captures.
///
/// Display identifiers and window handles are unstable across launches, so
/// persisted choices are *policies* resolved when the recording actually
/// starts — see `RecordingDisplayChoice` and `windowChoice` below.
public enum RecordingTarget: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// The whole display, annotation windows included live.
    case display
    /// One chosen window, annotation burn-in style (the annotation canvases
    /// live in separate windows that a single-window capture never sees, so
    /// the recorder draws them into the window frames itself).
    case window

    public var id: String { rawValue }
}

/// The window the presentation recorder captures, as a persisted policy.
///
/// A window handle (`SCWindow.windowID`) changes every launch of the owning
/// app, so the choice is stored as its human identity — the title and the
/// owning application's name — and resolved against the windows present when
/// the recording starts.
public struct RecordingWindowChoice: Hashable, Sendable, Codable {
    /// The window title (`SCWindow.title`) at pick time.
    public var title: String
    /// The name of the owning application (`owningApplication.applicationName`).
    public var ownerName: String

    public init(title: String, ownerName: String) {
        self.title = title
        self.ownerName = ownerName
    }
}

/// What the presentation recorder writes to disk.
///
/// The settings are plain values — no timers, no file handles — so they can
/// be persisted (`Codable`) and tested like the rest of the core model. The
/// recorder itself lives in `PresentifyRecorder`, which keeps the side
/// effects out of the core.
public struct RecorderSettings: Hashable, Sendable, Codable {
    /// Frames captured and encoded per second.
    public var frameRate: Int
    /// The video codec to encode with.
    public var codec: RecordingCodec
    /// Whether the microphone is mixed into the recording as an audio track.
    public var includesMicrophone: Bool
    /// Absolute path of the folder recordings are written to, or `nil` to
    /// use the default (`~/Movies/Presentify`). Stored as a plain string so
    /// Persisting one URL does not anchor on an app container that moves.
    public var folderPath: String?
    /// Which display to capture: resolved at recording start, see `RecordingDisplayChoice`.
    public var displayChoice: RecordingDisplayChoice
    /// What surface gets captured: the full display or one window.
    public var target: RecordingTarget
    /// The window to capture when `target == .window`, resolved at start.
    public var windowChoice: RecordingWindowChoice?

    public init(
        frameRate: Int = 30,
        codec: RecordingCodec = .h264,
        includesMicrophone: Bool = false,
        folderPath: String? = nil,
        displayChoice: RecordingDisplayChoice = .main,
        target: RecordingTarget = .display,
        windowChoice: RecordingWindowChoice? = nil
    ) {
        self.frameRate = frameRate
        self.codec = codec
        self.includesMicrophone = includesMicrophone
        self.folderPath = folderPath
        self.displayChoice = displayChoice
        self.target = target
        self.windowChoice = windowChoice
    }

    /// Decodes tolerantly: settings blobs written before a field existed
    /// (or by another version) keep loading, missing keys become defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = RecorderSettings()
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? base.frameRate
        codec = try container.decodeIfPresent(RecordingCodec.self, forKey: .codec) ?? base.codec
        includesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .includesMicrophone)
            ?? base.includesMicrophone
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        displayChoice = try container.decodeIfPresent(RecordingDisplayChoice.self, forKey: .displayChoice)
            ?? base.displayChoice
        target = try container.decodeIfPresent(RecordingTarget.self, forKey: .target) ?? base.target
        windowChoice = try container.decodeIfPresent(RecordingWindowChoice.self, forKey: .windowChoice)
    }

    /// Encodes every field; pairs with the tolerant `init(from:)` below.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(codec, forKey: .codec)
        try container.encode(includesMicrophone, forKey: .includesMicrophone)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encode(displayChoice, forKey: .displayChoice)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(windowChoice, forKey: .windowChoice)
    }

    private enum CodingKeys: String, CodingKey {
        case frameRate
        case codec
        case includesMicrophone
        case folderPath
        case displayChoice
        case target
        case windowChoice
    }

    /// The legal frame rates the UI offers; anything else snaps to 30.
    public static let supportedFrameRates: [Int] = [30, 60]

    /// A copy of these settings with the frame rate clamped to a legal value
    /// and the folder reduced to a usable path (blank, home-only or missing
    /// values fall back to the default).
    public func clamped() -> RecorderSettings {
        var copy = self
        copy.frameRate = Self.supportedFrameRates.contains(frameRate)
            ? frameRate
            : RecorderSettings().frameRate

        let trimmed = folderPath?.trimmingCharacters(in: .whitespaces)
        let home = NSHomeDirectory()
        if let trimmed, !trimmed.isEmpty, trimmed != home, trimmed != (home as NSString).appendingPathComponent("Movies") {
            copy.folderPath = trimmed
        } else {
            copy.folderPath = nil
        }
        return copy
    }
}

/// The state of the presentation recorder, published by the app.
///
/// It is a small state machine on purpose: the user cannot redo the first
/// frame of a recording, so "recording" and "finishing" are explicit states
/// the UI can show instead of guessing while files are being closed.
public enum RecordingState: Hashable, Sendable {
    /// Nothing is being recorded.
    case idle
    /// The screens and (optional) microphone are being captured to disk.
    case recording(startedAt: Date)
    /// The streams stopped and the file is being finalized; the recording
    /// cannot be aborted, only completed.
    case finishing

    /// Whether capture is up right now (recording or about to finish).
    public var isActive: Bool {
        self != .idle
    }

    /// Whether a new recording may be started.
    public var allowsStart: Bool {
        self == .idle
    }
}
