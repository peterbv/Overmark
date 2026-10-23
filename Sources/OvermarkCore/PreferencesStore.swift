import Foundation

/// Persists the user's choices between launches.
///
/// Every stored value is an `OvermarkCore` value type, so a whole struct is
/// encoded as one JSON blob under one key. A blob that fails to decode —
/// corrupted, hand-edited or from an older, differently-shaped version —
/// falls back to the factory defaults instead of crashing or half-loading.
public enum PreferencesStore {
    public static let toolSettingsKey = "Overmark.toolSettings"
    public static let cursorEffectsKey = "Overmark.cursorEffects"
    public static let favoriteColorsKey = "Overmark.favoriteColors"
    public static let whiteboardStyleKey = "Overmark.whiteboardStyle"
    public static let drawingModifierKey = "Overmark.drawingModifier"
    public static let toolbarDockKey = "Overmark.toolbarDock"

    /// Maximum number of favourite colours kept; new ones push the oldest out.
    public static let favoriteLimit = 8

    // MARK: - Load

    public static func loadToolSettings(
        _ defaults: UserDefaults = .standard
    ) -> ToolSettings {
        read(ToolSettings.self, key: toolSettingsKey, defaults) ?? ToolSettings()
    }

    public static func loadCursorEffects(
        _ defaults: UserDefaults = .standard
    ) -> CursorEffects {
        read(CursorEffects.self, key: cursorEffectsKey, defaults) ?? CursorEffects()
    }

    public static func loadFavoriteColors(
        _ defaults: UserDefaults = .standard
    ) -> [Color] {
        read([Color].self, key: favoriteColorsKey, defaults) ?? []
    }

    public static func loadWhiteboardStyle(
        _ defaults: UserDefaults = .standard
    ) -> BoardStyle {
        read(BoardStyle.self, key: whiteboardStyleKey, defaults) ?? .white
    }

    public static func loadDrawingModifier(
        _ defaults: UserDefaults = .standard
    ) -> DrawingModifier {
        read(DrawingModifier.self, key: drawingModifierKey, defaults) ?? .option
    }

    public static func loadToolbarDock(
        _ defaults: UserDefaults = .standard
    ) -> ToolbarDock {
        read(ToolbarDock.self, key: toolbarDockKey, defaults) ?? .top
    }

    // MARK: - Save

    public static func save(_ settings: ToolSettings, _ defaults: UserDefaults = .standard) {
        write(settings, key: toolSettingsKey, defaults)
    }

    public static func save(_ effects: CursorEffects, _ defaults: UserDefaults = .standard) {
        write(effects, key: cursorEffectsKey, defaults)
    }

    public static func save(_ favorites: [Color], _ defaults: UserDefaults = .standard) {
        write(Array(favorites.prefix(favoriteLimit)), key: favoriteColorsKey, defaults)
    }

    public static func save(_ style: BoardStyle, _ defaults: UserDefaults = .standard) {
        write(style, key: whiteboardStyleKey, defaults)
    }

    public static func save(_ modifier: DrawingModifier, _ defaults: UserDefaults = .standard) {
        write(modifier, key: drawingModifierKey, defaults)
    }

    public static func save(_ dock: ToolbarDock, _ defaults: UserDefaults = .standard) {
        write(dock, key: toolbarDockKey, defaults)
    }

    /// Adds a colour to the favourites, deduplicating within a small window.
    public static func addFavorite(_ color: Color, to favorites: [Color]) -> [Color] {
        let isKnown = favorites.contains {
            abs($0.red - color.red) < 0.02 &&
            abs($0.green - color.green) < 0.02 &&
            abs($0.blue - color.blue) < 0.02
        }
        guard !isKnown else { return favorites }

        var next = favorites
        next.append(color)
        if next.count > favoriteLimit {
            next.removeFirst(next.count - favoriteLimit)
        }
        return next
    }

    // MARK: - Internals

    private static func read<T: Decodable>(
        _ type: T.Type,
        key: String,
        _ defaults: UserDefaults
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(
        _ value: T,
        key: String,
        _ defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
