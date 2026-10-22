import Foundation
import Testing
@testable import OvermarkCore

@Suite("Presentation scope")
struct PresentationScopeTests {
    @Test("Encoding an all-screens scope round-trips")
    func allScreensRoundTrip() throws {
        let original = PresentationScope.all

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PresentationScope.self, from: data)

        #expect(decoded == original)
        #expect(decoded.screenName == nil)
    }

    @Test("Encoding a single-screen scope keeps its name")
    func singleScreenRoundTrip() throws {
        let original = PresentationScope.onlyScreen("Studio Display")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PresentationScope.self, from: data)

        #expect(decoded == original)
        #expect(decoded.screenName == "Studio Display")
    }

    @Test("A stale screen name still decodes")
    func staleNameDecodes() throws {
        // A display that stopped existing must not break stored settings:
        // the coordinator resolves it to the main display at runtime.
        let json = Data(#"{"scope":"Dell U2720Q (desconectada)"}"#.utf8)
        let decoded = try JSONDecoder().decode(PresentationScope.self, from: json)

        #expect(decoded.screenName == "Dell U2720Q (desconectada)")
    }

    @Test("Missing-first-run storage falls back to decode failure handling")
    func garbageFallsBack() {
        // Garbage data cannot decode; AppCoordinator's storedPresentationScope
        // treats any throw as "no stored scope" and returns .all — this test
        // pins that decode does in fact throw for garbage.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PresentationScope.self, from: Data("nu".utf8))
        }
    }
}
