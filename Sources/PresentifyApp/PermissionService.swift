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
    public func refresh() {
        state = PermissionState(
            screenRecording: captureService.hasPermission() ? .granted : .notDetermined,
            accessibility: CursorTracker.hasAccessibilityPermission() ? .granted : .notDetermined
        )
    }

    /// Requests a permission, prompting the system dialog if needed.
    ///
    /// - Returns: `true` if the permission is granted afterwards.
    @discardableResult
    public func request(_ kind: PermissionKind) async -> Bool {
        var granted: Bool
        switch kind {
        case .screenRecording:
            granted = await captureService.requestPermission()
        case .accessibility:
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
