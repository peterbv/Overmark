import Testing
@testable import OvermarkCore

private enum Fixtures {
    static let internal4K = ScreenCandidate(name: "BenQ", pixelWidth: 3840, pixelHeight: 2160)
    static let external4K = ScreenCandidate(name: "BenQ", pixelWidth: 3840, pixelHeight: 2160)
    static let builtin = ScreenCandidate(
        name: "Built-in Retina Display",
        pixelWidth: 3024,
        pixelHeight: 1964
    )
    /// The name "BenQ" is twinned here; its pixels are identical.
    static let twins = [builtin, internal4K, external4K]
    /// Every name is unique.
    static let singletons = [builtin, internal4K]
}

@Suite("Screen choice")
struct ScreenChoiceTests {
    /// A plain name stores unchanged.
    @Test func singletonStoresItsName() {
        #expect(
            ScreenChoice.storedValue(
                forCandidate: Fixtures.builtin,
                in: Fixtures.twins
            ) == "Built-in Retina Display"
        )
        #expect(
            ScreenChoice.storedValue(
                forCandidate: Fixtures.internal4K,
                in: Fixtures.singletons
            ) == "BenQ"
        )
    }

    /// A twinned name gains the pixel-size qualifier; identical twins share
    /// their stored value (they resolve to the same screen either way).
    @Test func twinStoresQualifiedValue() {
        let first = ScreenChoice.storedValue(forCandidate: Fixtures.internal4K, in: Fixtures.twins)
        let second = ScreenChoice.storedValue(forCandidate: Fixtures.external4K, in: Fixtures.twins)
        #expect(first == "BenQ (3840×2160)")
        #expect(first == second)
    }

    /// Plain names resolve by exact match, stored names included.
    @Test func plainStoredResolvesExactName() {
        #expect(
            ScreenChoice.matchingCandidate(forStored: "BenQ", in: Fixtures.twins)
                == Fixtures.internal4K
        )
        #expect(
            ScreenChoice.matchingCandidate(forStored: "BenQ", in: Fixtures.singletons)
                == Fixtures.internal4K
        )
        #expect(
            ScreenChoice.matchingCandidate(forStored: "Nope", in: Fixtures.twins) == nil
        )
    }

    /// A stored qualified twin value resolves to the twin wearing those
    /// pixels; the pixels carry the identity, the name only scopes the
    /// search.
    @Test func qualifiedStoredResolvesByPixels() {
        // Distinct-pixel twins resolve each to their own; identical-pixel
        // twins (like the fixture) are stored the same way and resolve to
        // the first matching twin.
        let display4kWide = ScreenCandidate(name: "BenQ", pixelWidth: 3840, pixelHeight: 2160)
        let display4kTall = ScreenCandidate(name: "BenQ", pixelWidth: 2160, pixelHeight: 3840)
        let differ = [display4kWide, display4kTall]

        #expect(
            ScreenChoice.matchingCandidate(
                forStored: ScreenChoice.storedValue(forCandidate: display4kWide, in: differ),
                in: differ
            ) == display4kWide
        )
        #expect(
            ScreenChoice.matchingCandidate(
                forStored: ScreenChoice.storedValue(forCandidate: display4kTall, in: differ),
                in: differ
            ) == display4kTall
        )
    }

    /// A stored value that accidentally matches the qualifier shape but has
    /// no twin wearing those pixels does not resolve.
    @Test func qualifiedStoredWithoutMatchingTwinFails() {
        #expect(
            ScreenChoice.matchingCandidate(forStored: "Ghost (1111×2222)", in: Fixtures.twins) == nil
        )
        #expect(
            ScreenChoice.matchingCandidate(forStored: "Ghost (3840×2160)", in: Fixtures.twins) == nil
        )
    }

    /// The strict qualifier shape is required: garbage in brackets, a name
    /// that merely ends with " (…)" without a resolvable pair, or a value
    /// trailing past the qualifier all fall to `nil`.
    @Test func malformedQualifierDoesNotParse() {
        #expect(
            ScreenChoice.matchingCandidate(forStored: "BenQ (not digits)", in: Fixtures.twins) == nil
        )
        #expect(
            ScreenChoice.matchingCandidate(forStored: "BenQ (3840)", in: Fixtures.twins) == nil
        )
        #expect(
            ScreenChoice.matchingCandidate(
                forStored: "BenQ (3840×2160) trailing",
                in: Fixtures.twins
            ) == nil
        )
    }

    /// Identical twins share the stored value, and labels may append a
    /// caller-computed one-based ordinal; the resolution honours the
    /// ordinal, clamps it to range (a stale `#9` or the unplugged twin's
    /// `#2`), and a missing ordinal resolves to the first twin.
    @Test func identicalTwinsShareValueAndOrdinalsResolve() {
        let copy = ScreenCandidate(name: "BenQ", pixelWidth: 3840, pixelHeight: 2160)
        let twinsIdentical = [Fixtures.internal4K, copy]
        // Same value for both: the label ordinal is caller-side decoration.
        #expect(
            ScreenChoice.storedValue(forCandidate: copy, in: twinsIdentical)
                == "BenQ (3840×2160)"
        )
        #expect(
            ScreenChoice.matchingCandidate(
                forStored: ScreenChoice.storedValue(forCandidate: copy, in: twinsIdentical) + " #2",
                in: twinsIdentical
            ) == copy
        )
        // The twinned #2 was unplugged: the stored label still resolves to
        // the one left.
        #expect(
            ScreenChoice.matchingCandidate(
                forStored: "BenQ (3840×2160) #2",
                in: [Fixtures.internal4K]
            ) == Fixtures.internal4K
        )
        #expect(
            ScreenChoice.matchingCandidate(
                forStored: "BenQ (3840×2160) #9",
                in: twinsIdentical
            ) == Fixtures.internal4K
        )
        #expect(
            ScreenChoice.matchingCandidate(
                forStored: "BenQ (3840×2160)",
                in: twinsIdentical
            ) == Fixtures.internal4K
        )
    }

    /// Names may legitimately contain parentheses and digits of their own;
    /// the qualifier splits from the right. A parenthesizedName does not by
    /// itself twin the screens.
    @Test func parenthesizedNameStoresAndResolves() {
        let quirky = ScreenCandidate(name: "Studio (v2)", pixelWidth: 2560, pixelHeight: 1440)
        let other = ScreenCandidate(name: "Studio", pixelWidth: 1920, pixelHeight: 1080)
        let screens = [quirky, other]
        let stored = ScreenChoice.storedValue(forCandidate: other, in: screens)
        #expect(stored == "Studio")
        #expect(ScreenChoice.matchingCandidate(forStored: stored, in: screens) == other)
    }
}
