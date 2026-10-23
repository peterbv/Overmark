import Foundation
import OvermarkHotkeys

/// Localized display names for the triggerable hot key actions.
///
/// Shared by the toolbar cheat-sheet and the shortcuts settings tab so both
/// always describe the same action with the same words.
enum HotKeyLabels {
    @MainActor
    static func name(for action: HotKeyAction) -> String {
        switch action {
        case .toggleAnnotation: return L10n.tr("Enter / end the presentation")
        case .togglePause: return L10n.tr("Pause")
        case .toggleWhiteboard: return L10n.tr("Whiteboard")
        case .toggleFreezeScreen: return L10n.tr("Freeze the screen")
        case .toggleSpotlight: return L10n.tr("Spotlight")
        case .toggleHighlight: return L10n.tr("Pointer highlight")
        case .toggleZoom: return L10n.tr("Zoom lens")
        case .toggleRecording: return L10n.tr("Record the presentation")
        case .undo: return L10n.tr("Undo")
        case .redo: return L10n.tr("Redo")
        case .copyScreenshot: return L10n.tr("Copy Screenshot")
        case .saveScreenshot: return L10n.tr("Save Screenshot…")
        case .quit: return L10n.tr("Quit Overmark")
        }
    }
}
