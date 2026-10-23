import Foundation
import Testing
@testable import OvermarkCore

/// Tests for the drawing modifier (the key held to draw while the
/// hold-to-draw gate is on) and its persisted choice.
@Suite("DrawingModifier")
struct DrawingModifierTests {
    @Test("The three modifiers keep their identities and glyphs")
    func modifiersAndSymbols() {
        #expect(DrawingModifier.allCases == [.option, .control, .command])
        #expect(DrawingModifier.option.rawValue == "option")
        #expect(DrawingModifier.control.rawValue == "control")
        #expect(DrawingModifier.command.rawValue == "command")
        #expect(DrawingModifier.option.symbol == "⌥")
        #expect(DrawingModifier.control.symbol == "⌃")
        #expect(DrawingModifier.command.symbol == "⌘")
    }

    @Test("The modifier round-trips through JSON")
    func codableRoundTrip() throws {
        for modifier in DrawingModifier.allCases {
            let data = try JSONEncoder().encode(modifier)
            let decoded = try JSONDecoder().decode(DrawingModifier.self, from: data)
            #expect(decoded == modifier)
        }
    }

    @Test("A fresh store answers ⌥ (Option)")
    func defaultIsOption() {
        let key = "DrawingModifierTests-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(PreferencesStore.loadDrawingModifier(defaults) == .option)
    }

    @Test("The chosen modifier persists between launches")
    func saveLoadRoundTrip() {
        let key = "DrawingModifierTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }

        PreferencesStore.save(.control, defaults)
        #expect(PreferencesStore.loadDrawingModifier(defaults) == .control)

        PreferencesStore.save(.command, defaults)
        #expect(PreferencesStore.loadDrawingModifier(defaults) == .command)
    }

    @Test("A corrupted blob falls back to ⌥ (Option)")
    func corruptedFallsBackToDefault() {
        let key = "DrawingModifierTests-corrupt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }

        defaults.set(Data("not json".utf8), forKey: PreferencesStore.drawingModifierKey)
        #expect(PreferencesStore.loadDrawingModifier(defaults) == .option)
    }
}
