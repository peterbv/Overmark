import AppKit
import AVFoundation
import Foundation
import OvermarkCapture
import OvermarkCore
import OvermarkCursor

/// Bridges the real macOS permission state into the core model.
///
/// The core module knows *what* a permission means; this service knows *how*
/// to ask the system about it. Keeping them apart means the core stays
/// testable without a running app.
@MainActor
public final class PermissionService: ObservableObject {
    /// The current permission state, published so SwiftUI can react to changes.
    @Published public private(set) var state: PermissionState = PermissionState()
    /// The microphone permission, kept apart from `state` because it is an
    /// optional permission: the core `PermissionState` only tracks what the
    /// app fundamentally needs (screen, accessibility).
    @Published public private(set) var microphone: PermissionStatus = .notDetermined

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
        microphone = Self.microphoneStatus()
    }

    private static let hasPromptedScreenRecording = "Overmark.hasPromptedScreenRecording"
    private static let hasPromptedAccessibility = "Overmark.hasPromptedAccessibility"
    private static let hasPromptedMicrophone = "Overmark.hasPromptedMicrophone"

    /// Calls the system for the microphone permission; the app layer keeps
    /// it apart from the two *required* permissions because a user who never
    /// records audio should never be nagged about it.
    static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined:
            UserDefaults.standard.bool(forKey: hasPromptedMicrophone) ? .denied : .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .notDetermined
        }
    }

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
        case .microphone:
            UserDefaults.standard.set(true, forKey: Self.hasPromptedMicrophone)
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            if !granted {
                granted = Self.microphoneStatus().isGranted
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
        case .microphone:
            anchor = "Privacy_Microphone"
        }

        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
