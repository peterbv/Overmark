import Foundation
import Testing
@testable import OvermarkCore

/// CursorEffects persistence: tolerant decoding keeps older stored bundles
/// working when a new effect field appears.
@Suite("CursorEffects")
struct CursorEffectsTests {
    /// A bundle written before the laser was modelled: the original keys
    /// only, with distinctive values to prove they survive the decode.
    private static let legacyJSON = """
    {
        "isHighlightEnabled": true,
        "highlightRadius": 55,
        "highlightColor": {"red": 1, "green": 0.827, "blue": 0.176, "alpha": 1},
        "isSpotlightEnabled": true,
        "spotlightRadius": 300,
        "spotlightDimOpacity": 0.6,
        "isZoomEnabled": false,
        "zoomFactor": 3,
        "zoomSize": 280,
        "zoomShape": "squircle",
        "highlightShape": "rhombus",
        "highlightBorderWidth": 5,
        "highlightFillOpacity": 0.4,
        "isClickAnimationEnabled": false
    }
    """

    @Test func legacyBlobDecodesWithLaserDefaults() throws {
        let effects = try JSONDecoder().decode(CursorEffects.self, from: Data(Self.legacyJSON.utf8))

        // Old choices survive…
        #expect(effects.isHighlightEnabled)
        #expect(effects.highlightRadius == 55)
        #expect(effects.isSpotlightEnabled)
        #expect(effects.spotlightRadius == 300)
        #expect(effects.spotlightDimOpacity == 0.6)
        #expect(effects.zoomFactor == 3)
        #expect(effects.zoomSize == 280)
        #expect(effects.zoomShape == .squircle)
        #expect(effects.highlightShape == .rhombus)
        #expect(effects.highlightBorderWidth == 5)
        #expect(effects.highlightFillOpacity == 0.4)
        #expect(!effects.isClickAnimationEnabled)

        // …and the fields added later come up with their defaults.
        #expect(!effects.isLaserEnabled)
        #expect(effects.laserColor == .red)
        #expect(effects.laserRadius == 5)
        #expect(!effects.isLensMirrored)
        #expect(effects.lensRefreshRate == .normal)
    }

    @Test func roundTripCarriesTheLaserSettings() throws {
        var effects = CursorEffects()
        effects.isLaserEnabled = true
        effects.laserColor = .black
        effects.laserRadius = 9

        let data = try JSONEncoder().encode(effects)
        let decoded = try JSONDecoder().decode(CursorEffects.self, from: data)

        #expect(decoded == effects)
        #expect(decoded.isLaserEnabled)
        #expect(decoded.laserColor == .black)
        #expect(decoded.laserRadius == 9)
    }

    @Test func laserDefaults() {
        let effects = CursorEffects()
        #expect(!effects.isLaserEnabled)
        #expect(effects.laserColor == .red)
        #expect(effects.laserRadius == 5)
    }

    @Test func lensDefaults() {
        let effects = CursorEffects()
        #expect(effects.zoomSize == 240)
        #expect(!effects.isLensMirrored)
        #expect(effects.lensRefreshRate == .normal)
        #expect(effects.lensRefreshRate.interval == 0.32)
        #expect(LensRefreshRate.responsive.interval == 0.12)
    }

    @Test func roundTripCarriesTheLensSettings() throws {
        var effects = CursorEffects()
        effects.zoomSize = 380
        effects.lensRefreshRate = .responsive
        effects.isLensMirrored = true

        let data = try JSONEncoder().encode(effects)
        let decoded = try JSONDecoder().decode(CursorEffects.self, from: data)

        #expect(decoded == effects)
        #expect(decoded.zoomSize == 380)
        #expect(decoded.lensRefreshRate == .responsive)
        #expect(decoded.isLensMirrored)
    }
}
