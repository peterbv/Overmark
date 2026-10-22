import SwiftUI
import PresentifyCore

/// The onboarding window shown on first launch.
///
/// The goal is to get the two permissions granted without confusing the user.
/// Each permission is explained in plain language, with a button that both
/// requests it and opens the right System Settings pane.
struct OnboardingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Welcome to Presentify"))
                    .font(.largeTitle.bold())
                Text(L10n.tr("Two permissions are needed to annotate your screen. You can change them later in System Settings."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(PermissionKind.required) { kind in
                    PermissionRow(
                        kind: kind,
                        status: status(for: kind),
                        onRequest: { request(kind) },
                        onOpenSettings: { coordinator.openSettings(for: kind) }
                    )
                }
            }

            Spacer(minLength: 0)

            HStack {
                if !coordinator.permissions.isFullyGranted {
                    Text(L10n.tr("Some features stay unavailable until every permission is granted."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L10n.tr("Continue")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 520, height: 460)
        .onAppear {
            coordinator.refreshPermissions()
        }
    }

    private func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording: coordinator.permissions.screenRecording
        case .accessibility: coordinator.permissions.accessibility
        case .microphone: coordinator.microphonePermission
        }
    }

    private func request(_ kind: PermissionKind) {
        Task {
            await coordinator.requestPermission(kind)
        }
    }
}

/// A single row describing one permission.
private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(kind.title))
                    .font(.headline)
                Text(L10n.tr(kind.explanation))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(spacing: 6) {
                statusLabel

                if status != .granted {
                    Button(L10n.tr("Grant Access"), action: onRequest)
                        .buttonStyle(.borderedProminent)

                    Button(L10n.tr("Open Settings"), action: onOpenSettings)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .granted:
            Label(L10n.tr("Granted"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        case .denied:
            Label(L10n.tr("Denied"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout.weight(.medium))
        case .notDetermined:
            Label(L10n.tr("Not set up"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.callout.weight(.medium))
        }
    }

    private var iconName: String {
        switch kind {
        case .screenRecording: "rectangle.on.rectangle"
        case .accessibility: "figure.pointer"
        case .microphone: "mic"
        }
    }

    private var iconColor: SwiftUI.Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        }
    }
}
