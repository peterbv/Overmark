import Foundation

/// The system permissions the app needs, and their current status.
///
/// Presentify needs two distinct macOS permissions, and users confuse them
/// constantly. Modelling them explicitly — and explaining what each one is
/// *for* — is what turns a confusing permission wall into a guided setup.
public enum PermissionKind: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    /// Required to read the screen contents (Screen Recording).
    case screenRecording
    /// Required to observe global mouse/keyboard events (Accessibility).
    case accessibility
    /// Required to mix the presenter's voice into a recording. Optional: the
    /// app annotates fine without it, so it is only requested when the user
    /// turns the microphone on for a recording.
    case microphone

    public var id: String { rawValue }

    /// The permissions the app fundamentally needs. The microphone is
    /// deliberately left out: it is an optional permission, only requested
    /// when the user turns recording audio on.
    public static var required: [PermissionKind] {
        [.screenRecording, .accessibility]
    }

    /// A short title for the onboarding UI.
    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    /// A plain-language explanation of why the permission is needed.
    ///
    /// The wording is deliberately non-technical: users grant permissions when
    /// they understand the benefit, not when they understand the API.
    public var explanation: String {
        switch self {
        case .screenRecording:
            "Presentify needs to see the screen so it can draw annotations on top of whatever you are showing."
        case .accessibility:
            "Presentify needs this to track your pointer and notice keyboard shortcuts while you are in other apps."
        case .microphone:
            "Presentify needs your microphone to record its sound along with the presentation video."
        }
    }

    /// The name of the relevant System Settings pane.
    public var settingsPane: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }
}

/// The resolved state of a single permission.
public enum PermissionStatus: Hashable, Sendable, Codable {
    case notDetermined
    case denied
    case granted

    /// Whether the permission is currently satisfied.
    public var isGranted: Bool { self == .granted }

    /// Whether the user has to be sent to System Settings to fix it.
    public var needsAttention: Bool { self == .denied }
}

/// The overall permission state of the app.
public struct PermissionState: Hashable, Sendable, Codable {
    public var screenRecording: PermissionStatus
    public var accessibility: PermissionStatus

    public init(
        screenRecording: PermissionStatus = .notDetermined,
        accessibility: PermissionStatus = .notDetermined
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    /// Whether every required permission has been granted.
    public var isFullyGranted: Bool {
        screenRecording.isGranted && accessibility.isGranted
    }

    /// The permissions that still need action, in the order they should be
    /// requested (screen recording first — it is the one users understand).
    public var outstanding: [PermissionKind] {
        var result: [PermissionKind] = []
        if !screenRecording.isGranted { result.append(.screenRecording) }
        if !accessibility.isGranted { result.append(.accessibility) }
        return result
    }
}
