import AppKit
import Foundation
import PresentifyCapture
import PresentifyCore
import PresentifyCursor

/// Bridges the real macOS permission state into the core model.
///
/// The core module knows *what* a permission means; this service knows *how*
/// to ask the system about it. Keeping them apart means the core stays
/// testable without a running app.
@MainActor
public final class PermissionService: ObservableObject {
    /// The current permission state, published so SwiftUI can react to changes.
    @Published public private(set) var state: PermissionState = PermissionState()

    private let captureService: ScreenCaptureService
    private let cursorTracker: CursorTracker

    public init(captureService: ScreenCaptureService, cursorTracker: CursorTracker) {
        self.captureService = captureService
        self.cursorTracker = cursorTracker
    }

    /// Re-reads the permission status from the system.
    ///
    /// A bare "not granted" is ambiguous: the prompt may never have been
    /// shown, or the user may have answered "Don't Allow" in System
    /// Settings, in which case asking again shows no new dialog. Once a
    /// prompt has been shown (tracked in `UserDefaults`) the not-granted
    /// state is reported as `.denied`, so the UI offers System Settings
    /// instead of a Grant button that silently does nothing.
    public func refresh() {
        let defaults = UserDefaults.standard
        state = PermissionState(
            screenRecording: captureService.hasPermission()
                ? .granted
                : (defaults.bool(forKey: Self.hasPromptedScreenRecording) ? .denied : .notDetermined),
            accessibility: CursorTracker.hasAccessibilityPermission()
                ? .granted
                : (defaults.bool(forKey: Self.hasPromptedAccessibility) ? .denied : .notDetermined)
        )
    }

    private static let hasPromptedScreenRecording = "Presentify.hasPromptedScreenRecording"
    private static let hasPromptedAccessibility = "Presentify.hasPromptedAccessibility"

    /// Requests a permission, prompting the system dialog if needed.
    ///
    /// - Returns: `true` if the permission is granted afterwards.
    @discardableResult
    public func request(_ kind: PermissionKind) async -> Bool {
        var granted: Bool
        switch kind {
        case .screenRecording:
            // Record that a prompt was shown *before* asking, so the follow-up
            // refresh can tell "denied" from "never asked". macOS shows the
            // TCC prompt only once; later calls return without a new dialog.
            UserDefaults.standard.set(true, forKey: Self.hasPromptedScreenRecording)
            granted = await captureService.requestPermission()
        case .accessibility:
            UserDefaults.standard.set(true, forKey: Self.hasPromptedAccessibility)
            granted = CursorTracker.requestAccessibilityPermission()
            // The Accessibility prompt is asynchronous in practice: the system
            // shows a dialog and the user answers it later. Re-reading the
            // trust status right after the call reflects the "not yet" case
            // honestly rather than claiming a grant that has not happened.
            if !granted {
                granted = CursorTracker.hasAccessibilityPermission()
            }
        }

        refresh()
        return granted
    }

    /// Opens the relevant System Settings pane.
    public func openSettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        case .accessibility:
            anchor = "Privacy_Accessibility"
        }

        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
