import AppKit
import Carbon.HIToolbox
import SwiftUI
import OvermarkHotkeys

/// The shortcuts tab of the settings window.
///
/// Lists every action with its current system-wide combination and lets the
/// user record a new one: after pressing "Change", the next keystroke is
/// observed through a local monitor and either becomes the new binding,
/// rejects a reserved or conflicting combination, or passes through when it
/// belongs to the app's own menu. ⎋ cancels.
struct HotKeysSettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    /// The action currently waiting for a keystroke, if any.
    @State private var recordingAction: HotKeyAction?
    /// The last capture problem, shown inline until resolved or cancelled.
    @State private var message: String?
    /// The local key-down monitor installed while recording.
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases, id: \.rawValue) { action in
                    row(for: action)
                }
            } footer: {
                Text(L10n.tr("The combination must include ⌘. ESC cancels the capture."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let message {
                    Text(message)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.orange)
                }
                Button(L10n.tr("Reset shortcuts")) {
                    endRecording()
                    message = nil
                    coordinator.resetHotKeyBindings()
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { endRecording() }
    }

    // MARK: - Rows

    private func row(for action: HotKeyAction) -> some View {
        HStack(spacing: 12) {
            Text(HotKeyLabels.name(for: action))

            Spacer()

            if recordingAction == action {
                Text(L10n.tr("Press a new combination…"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if let binding = coordinator.hotKeyBindings[action] {
                Text(binding.readableDescription)
                    .font(.system(size: 13, weight: .medium).monospaced())
                    .foregroundStyle(.secondary)
                Button(L10n.tr("Change")) {
                    beginRecording(action)
                }
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Capture

    private func beginRecording(_ action: HotKeyAction) {
        endRecording()
        recordingAction = action
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKeyDown(event)
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingAction = nil
    }

    /// Handles a key press while the capture is armed.
    ///
    /// - Returns: `nil` when the monitor consumed the event, or the event
    ///   itself so it travels on to the responder chain. Reserved ⌘
    ///   combinations (⌘Q, ⌘W, ⌘M, ⌘H) are never assignments: the monitor
    ///   disarms and lets them reach the app menu, because swallowing them
    ///   used to block quit, close, minimize and hide outright.
    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let action = recordingAction else { return event }

        // ⎋ always cancels instead of assigning itself.
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            return nil // consumed
        }

        // Plain-⌘ menu accelerators pass through untouched. Comparing the
        // flags through the device-independent mask keeps hardware-specific
        // bits out of the equality, mirroring HotKeyManager's binding read.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, Self.reservedKeycodes.contains(event.keyCode) {
            endRecording()
            message = L10n.tr("That combination is reserved (⌘Q, ⌘W, ⌘M or ⌘H); the capture was cancelled.")
            return event // to the app menu
        }

        // Bare modifier presses never form a binding; keep waiting.
        guard let binding = HotKeyManager.binding(fromKeyDown: event) else {
            return nil // consumed while the capture is armed
        }

        guard HotKeyManager.isAcceptable(binding) else {
            message = L10n.tr("The combination must include ⌘")
            return nil // consumed; still waiting for a valid one
        }

        if let conflict = coordinator.hotKeyConflict(for: binding, excluding: action) {
            message = String(
                format: L10n.tr("Already used by %@"),
                HotKeyLabels.name(for: conflict)
            )
            return nil // consumed; conflict reported
        }

        coordinator.updateHotKeyBinding(action, binding: binding)
        endRecording()
        message = nil
        return nil // consumed
    }

    /// The keycodes whose plain-⌘ forms are the app's own accelerators:
    /// quit, close, minimize and hide.
    private static let reservedKeycodes: Set<UInt16> = [
        UInt16(kVK_ANSI_Q),
        UInt16(kVK_ANSI_W),
        UInt16(kVK_ANSI_M),
        UInt16(kVK_ANSI_H),
    ]
}
