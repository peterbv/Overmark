import Foundation
import Testing
@testable import OvermarkCore

/// Tests for the whiteboard's persisted tone.
@Suite("BoardStyle")
struct BoardStyleTests {
    @Test("The two tones resolve to the palette's board colours")
    func toneColours() {
        #expect(BoardStyle.allCases == [.white, .black])
        #expect(BoardStyle.white.color == .white)
        #expect(BoardStyle.black.color == .black)
        #expect(BoardStyle.white.rawValue == "white")
        #expect(BoardStyle.black.rawValue == "black")
    }

    @Test("The tone round-trips through JSON")
    func codableRoundTrip() throws {
        for style in BoardStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(BoardStyle.self, from: data)
            #expect(decoded == style)
        }
    }

    @Test("A fresh store answers the white tone")
    func defaultIsWhite() {
        let key = "BoardStyleTests-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(PreferencesStore.loadWhiteboardStyle(defaults) == .white)
    }

    @Test("The chosen tone persists between launches")
    func saveLoadRoundTrip() {
        let key = "BoardStyleTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }

        PreferencesStore.save(.black, defaults)
        #expect(PreferencesStore.loadWhiteboardStyle(defaults) == .black)

        PreferencesStore.save(.white, defaults)
        #expect(PreferencesStore.loadWhiteboardStyle(defaults) == .white)
    }
}
