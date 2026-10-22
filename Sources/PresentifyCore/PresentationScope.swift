import Foundation

/// Where the annotation overlays appear during a presentation.
///
/// The user chooses between covering every attached screen or annotating
/// on a single one (a second display that mirrors a projector, where the
/// mirrored copy has to stay clean). It is persisted as one string —
/// `"all"` or the localized screen name — so a stale choice (a display
/// that no longer exists) still decodes instead of breaking the stored
/// settings.
public enum PresentationScope: Hashable, Sendable, Codable {
    /// Annotate on every attached screen.
    case all
    /// Annotate only on the screen with this localized name.
    case onlyScreen(String)

    private enum Coding: String, CodingKey {
        case scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Coding.self)
        let raw = try container.decode(String.self, forKey: .scope)
        self = raw == "all" ? .all : .onlyScreen(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Coding.self)
        switch self {
        case .all:
            try container.encode("all", forKey: .scope)
        case .onlyScreen(let name):
            try container.encode(name, forKey: .scope)
        }
    }

    /// The screen name when the scope targets one display; `nil` covers all.
    public var screenName: String? {
        if case .onlyScreen(let name) = self { return name }
        return nil
    }
}
