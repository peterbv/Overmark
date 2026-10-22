import AppKit
import Carbon.HIToolbox
import SwiftUI
import OvermarkHotkeys

/// The shortcuts tab of the settings window.
///
/// Lists every action with its current system-wide combination and lets the
/// user record a new one: after pressing "Change", the next keystroke is
/// captured through a local monitor (which swallows those events) and either
/// becomes the new binding or explains why it was rejected. ⎋ cancels.
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
            handleKeyDown(event)
            return nil // consumed while the capture is armed
        }
    }

    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recordingAction = nil
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard let action = recordingAction else { return }

        // ⎋ always cancels instead of assigning itself.
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            return
        }

        // Bare modifier presses never form a binding; keep waiting.
        guard let binding = HotKeyManager.binding(fromKeyDown: event) else { return }

        guard HotKeyManager.isAcceptable(binding) else {
            message = L10n.tr("The combination must include ⌘")
            return
        }

        if let conflict = coordinator.hotKeyConflict(for: binding, excluding: action) {
            message = String(
                format: L10n.tr("Already used by %@"),
                HotKeyLabels.name(for: conflict)
            )
            return
        }

        coordinator.updateHotKeyBinding(action, binding: binding)
        endRecording()
        message = nil
    }
}
