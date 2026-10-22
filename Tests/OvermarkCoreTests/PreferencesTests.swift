import Foundation
import Testing
@testable import OvermarkCore

@Suite("Preferences persistence", .serialized)
@MainActor
struct PreferencesTests {
    /// A throwaway defaults name, cleaned up at the end of each test.
    private static let suiteNames: [String] = [
        "PreferencesTests-ToolSettings",
        "PreferencesTests-CursorEffects",
        "PreferencesTests-Favorites",
    ]

    @Test("Tool settings round-trip with the gradient fields")
    func toolSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "PreferencesTests-ToolSettings")!
        defer { defaults.removePersistentDomain(forName: "PreferencesTests-ToolSettings") }
        defaults.removePersistentDomain(forName: "PreferencesTests-ToolSettings")

        var loaded = PreferencesStore.loadToolSettings(defaults)
        #expect(loaded == ToolSettings())  // fresh domain: defaults

        var settings = ToolSettings(tool: .ellipse, color: .pink, lineWidth: 9)
        settings.gradientColor = .purpleCustom
        PreferencesStore.save(settings, defaults)
        loaded = PreferencesStore.loadToolSettings(defaults)
        #expect(loaded == settings)

        // Corrupt data falls back to the shapes.
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: PreferencesStore.toolSettingsKey)
        loaded = PreferencesStore.loadToolSettings(defaults)
        #expect(loaded == ToolSettings())
    }

    @Test("Cursor effects round-trip with the shape and ripples")
    func cursorEffectsRoundTrip() {
        let key = "PreferencesTests-CursorEffects"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        defaults.removePersistentDomain(forName: key)

        #expect(PreferencesStore.loadCursorEffects(defaults) == CursorEffects())

        var effects = CursorEffects(isHighlightEnabled: true)
        effects.highlightShape = .rhombus
        effects.highlightBorderWidth = 7
        effects.highlightFillOpacity = 0.6
        effects.isClickAnimationEnabled = false
        PreferencesStore.save(effects, defaults)
        #expect(PreferencesStore.loadCursorEffects(defaults) == effects)

        defaults.set(Data("garbage".utf8), forKey: PreferencesStore.cursorEffectsKey)
        #expect(PreferencesStore.loadCursorEffects(defaults) == CursorEffects())
    }

    @Test("Favourite colours persist and deduplicate")
    func favoritesRoundTrip() {
        let key = "PreferencesTests-Favorites"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        defaults.removePersistentDomain(forName: key)

        #expect(PreferencesStore.loadFavoriteColors(defaults).isEmpty)

        let colors: [Color] = [
            Color(red: 0.1, green: 0.2, blue: 0.3),
            Color(red: 0.9, green: 0.1, blue: 0.4),
        ]
        PreferencesStore.save(colors, defaults)
        #expect(PreferencesStore.loadFavoriteColors(defaults) == colors)

        // Corrupt data → empty list, never a crash.
        defaults.set(Data("nope".utf8), forKey: PreferencesStore.favoriteColorsKey)
        #expect(PreferencesStore.loadFavoriteColors(defaults).isEmpty)
    }

    @Test("addFavorite collapses near-duplicates and rotates the oldest out")
    func addFavoriteRules() {
        let custom = Color(red: 0.1, green: 0.2, blue: 0.35)
        var favorites = [custom]
        favorites = PreferencesStore.addFavorite(
            Color(red: 0.1, green: 0.2, blue: 0.36),  // within epsilon
            to: favorites
        )
        #expect(favorites.count == 1)

        let paletteColor = Color.red
        favorites = PreferencesStore.addFavorite(paletteColor, to: favorites)
        #expect(favorites.count == 2)

        // Fill the list up to the limit and beyond: the oldest falls out.
        var many = favorites
        for index in 0..<PreferencesStore.favoriteLimit + 3 {
            many = PreferencesStore.addFavorite(
                Color(red: Double(index), green: 0.5, blue: 0.5),
                to: many
            )
        }
        #expect(many.count == PreferencesStore.favoriteLimit)
        #expect(!many.contains(custom))  // rotated out long ago
    }
}

extension Color {
    /// A non-palette purple used to prove the gradient colour round-trips.
    static let purpleCustom = Color(red: 0.55, green: 0.19, blue: 0.86)
}

@Suite("Gradient maths")
struct GradientMathTests {
    @Test("lerped interpolates and clamps")
    func lerpedMaths() {
        let a = Color(red: 0, green: 0, blue: 0)
        let b = Color(red: 1, green: 0.5, blue: 0.25)

        let zero = a.lerped(to: b, at: 0)
        #expect(zero.red == 0 && zero.green == 0 && zero.blue == 0)

        let half = a.lerped(to: b, at: 0.5)
        #expect(abs(half.red - 0.5) < 0.0001)
        #expect(abs(half.green - 0.25) < 0.0001)
        #expect(abs(half.blue - 0.125) < 0.0001)

        let one = a.lerped(to: b, at: 1)
        #expect(one.red == 1 && one.green == 0.5 && one.blue == 0.25)

        let under = a.lerped(to: b, at: -3)
        #expect(under.red == 0)
        let over = a.lerped(to: b, at: 7)
        #expect(over.red == 1)
    }

    @Test("New fields default off and round-trip through JSON")
    func annotationCoding() throws {
        #expect(!Annotation(tool: .pen).fillsShapes)
        #expect(Annotation(tool: .pen).gradientColor == nil)

        let filled = Annotation(
            tool: .rectangle,
            color: .red,
            fillsShapes: true,
            gradientColor: .blue
        )
        let data = try JSONEncoder().encode(filled)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded == filled)
    }

    @Test("ToolSettings stores the gradient colour")
    func toolSettingsDefaults() {
        #expect(ToolSettings().gradientColor == nil)
        var settings = ToolSettings()
        settings.gradientColor = .blue
        #expect(settings.gradientColor == .blue)
    }
}
