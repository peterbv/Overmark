import Foundation
import AppKit
import OvermarkCore

/// One picker row of a screen choice, as the menus and the Settings render
/// it.
///
/// `value` is what gets stored and resolved (the `ScreenChoice` scheme);
/// `label` is what the user reads — identical twins, which share a stored
/// value by design, get a one-based ordinal appended ("… #2") so the rows
/// can be told apart; `id` identifies the row for SwiftUI lists and is
/// never persisted — the label is unique because every row either already
/// has an unique value or a unique ordinal.
public struct ScreenChoiceRow: Identifiable {
    public let id: String
    /// The stored-and-resolved choice (plain name or qualified twin value).
    public let value: String
    /// The row as read: the value, plus the ordinal when its name shares
    /// the plural with identical twins.
    public let label: String

    public init(id: String, value: String, label: String) {
        self.id = id
        self.value = value
        self.label = label
    }
}

/// Builds the rows for `NSScreen.screens` — the shared option builder for
/// the annotation-scope menus and the recording-screen picker.
@MainActor
enum ScreenChoiceRows {
    static func rows(from screens: [NSScreen]) -> [ScreenChoiceRow] {
        let candidates = AppCoordinator.screenCandidates(screens)
        return screens.enumerated().map { index, _ in
            let candidate = candidates[index]
            let value = ScreenChoice.storedValue(forCandidate: candidate, in: candidates)
            // Identical twins share the value; their ordinal counts the
            // equal-valued rows so far — structural equality has no history,
            // but the array order does.
            let twinsTotal = candidates.filter { $0 == candidate }.count
            let twinsAhead = candidates[..<index].filter { $0 == candidate }.count
            let label = twinsTotal > 1 ? "\(value) #\(twinsAhead + 1)" : value
            return ScreenChoiceRow(id: label, value: value, label: label)
        }
    }
}
