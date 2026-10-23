import Foundation
import Testing
@testable import OvermarkCore

/// Tests for the floating bar's docking choice and its persistence.
@Suite("ToolbarDock")
struct ToolbarDockTests {
    @Test("The four docks keep their order and orientation")
    func docksAndOrientations() {
        #expect(ToolbarDock.allCases == [.top, .bottom, .leading, .trailing])
        #expect(ToolbarDock.top.rawValue == "top")
        #expect(ToolbarDock.bottom.rawValue == "bottom")
        #expect(ToolbarDock.leading.rawValue == "leading")
        #expect(ToolbarDock.trailing.rawValue == "trailing")
        #expect(ToolbarDock.top.isHorizontal)
        #expect(ToolbarDock.bottom.isHorizontal)
        #expect(!ToolbarDock.leading.isHorizontal)
        #expect(!ToolbarDock.trailing.isHorizontal)
    }

    @Test("The dock round-trips through JSON")
    func codableRoundTrip() throws {
        for dock in ToolbarDock.allCases {
            let data = try JSONEncoder().encode(dock)
            let decoded = try JSONDecoder().decode(ToolbarDock.self, from: data)
            #expect(decoded == dock)
        }
    }

    @Test("A fresh store docks the bar at the top")
    func defaultIsTop() {
        let key = "ToolbarDockTests-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }
        #expect(PreferencesStore.loadToolbarDock(defaults) == .top)
    }

    @Test("The chosen dock persists between launches")
    func saveLoadRoundTrip() {
        let key = "ToolbarDockTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }

        PreferencesStore.save(.trailing, defaults)
        #expect(PreferencesStore.loadToolbarDock(defaults) == .trailing)

        PreferencesStore.save(.bottom, defaults)
        #expect(PreferencesStore.loadToolbarDock(defaults) == .bottom)
    }

    @Test("A corrupted blob falls back to the top dock")
    func corruptedFallsBackToDefault() {
        let key = "ToolbarDockTests-corrupt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: key)!
        defer { defaults.removePersistentDomain(forName: key) }

        defaults.set(Data("not json".utf8), forKey: PreferencesStore.toolbarDockKey)
        #expect(PreferencesStore.loadToolbarDock(defaults) == .top)
    }
}
