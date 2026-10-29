import Foundation

/// One connected screen as the stored-choice model sees it: its localized
/// name and its pixel size (`frame × backingScale`).
///
/// Two identical external monitors report the same localized name, which
/// used to collapse them into one choice — the pixel size is the only
/// thing presented to the user that tells them apart, so it is what the
/// stored value leans on when a name is twinned.
public struct ScreenCandidate: Hashable, Sendable {
    public let name: String
    /// Pixel width of the screen (`frame.width * backingScaleFactor`).
    public let pixelWidth: Int
    /// Pixel height of the screen.
    public let pixelHeight: Int

    public init(name: String, pixelWidth: Int, pixelHeight: Int) {
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The stored screen-choice scheme, shared by the annotation scope and the
/// recording-screen picker.
///
/// Choices are persisted as strings and resolved against the connected
/// screens by name. Plain names keep exactly that behaviour (a stored name
/// from an older build keeps resolving to the first screen wearing it —
/// the historical behaviour for duplicates). When a name is twinned, the
/// stored value gains the pixel size as a qualifier — `"Name (3840×2160)"` —
/// so distinct-pixel twins are distinct choices. Twins indistinguishable
/// even by pixels share their stored value (they resolve to the same
/// screen either way); callers that list them count equal-value rows by
/// index and append a one-based ordinal to the label ("… #2") purely for
/// readability.
///
/// Resolution accepts an ordinal suffix appended by a caller that wants the
/// *n-th* identical twin (`"Name (3840×2160) #2"`), but a missing or stale
/// ordinal never fails: it clamps to the first surviving twin — the
/// historical duplicate-name behaviour.
public enum ScreenChoice {
    /// The value stored for `screen`: its plain name, or the
    /// `name (w×h)` qualifier when `candidates` holds more than one screen
    /// with that name.
    public static func storedValue(
        forCandidate screen: ScreenCandidate,
        in candidates: [ScreenCandidate]
    ) -> String {
        let namedTwins = candidates.filter { $0.name == screen.name }
        guard namedTwins.count > 1 else { return screen.name }
        return "\(screen.name) (\(screen.pixelWidth)×\(screen.pixelHeight))"
    }

    /// The candidate a stored value resolves to.
    ///
    /// An exact name match wins (an actual screen can legitimately be
    /// *named* "Model (3840×2160)"). Otherwise a stored qualified twin
    /// value — and only that shape — parses into name + pixel size, and an
    /// optional trailing ordinal splits identical twins. The ordinal never
    /// fails a resolution: it clamps into range, so a stale `#2` (the twin
    /// left) resolves to the remaining screen instead of nothing.
    public static func matchingCandidate(
        forStored stored: String,
        in candidates: [ScreenCandidate]
    ) -> ScreenCandidate? {
        if let exact = candidates.first(where: { $0.name == stored }) {
            return exact
        }

        // Optional ordinal: "… #2".
        var base = stored
        var ordinal: Int?
        if let tail = base.range(of: " #", options: .backwards),
           let number = Int(base[tail.upperBound...])
        {
            ordinal = number
            base = String(base[..<tail.lowerBound])
        }

        // Qualified form: "name (w×h)" — split from the right so a name may
        // itself contain parentheses, and require the strict tail shape the
        // qualifier builds, not "any text between brackets".
        guard
            let parens = base.range(of: " (", options: .backwards),
            parens.upperBound < base.endIndex,
            base[base.index(before: base.endIndex)] == ")"
        else { return nil }

        let close = base.index(before: base.endIndex)
        let name = String(base[..<parens.lowerBound])
        let dims = String(base[parens.upperBound..<close])
        let parts = dims.split(separator: "×", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1])
        else { return nil }

        let wearing = candidates.filter {
            $0.name == name && $0.pixelWidth == width && $0.pixelHeight == height
        }
        guard !wearing.isEmpty else { return nil }
        // The ordinal is a 1-based pick into the wearing twins; absent or
        // out of range resolves to the first one.
        let index = ordinal.map { min(max($0 - 1, 0), wearing.count - 1) } ?? 0
        return wearing[index]
    }
}
