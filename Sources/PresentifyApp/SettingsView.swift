import SwiftUI
import PresentifyCore

/// The core colour type, aliased to avoid colliding with `SwiftUI.Color`.
typealias AnnotationColor = PresentifyCore.Color

/// The settings window.
///
/// It hosts the tool palette, the colour choices and the cursor effect
/// toggles. Everything here is written straight into the coordinator, which
/// pushes the values to the live overlay.
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    /// Tools whose annotations the renderer actually draws.
    private static let selectableTools = AnnotationTool.allCases.filter { $0.producesAnnotation }

    var body: some View {
        TabView {
            toolSettings
                .tabItem { Label(L10n.tr("Tools"), systemImage: "pencil.tip") }
            cursorSettings
                .tabItem { Label(L10n.tr("Cursor"), systemImage: "cursorarrow") }
            generalSettings
                .tabItem { Label(L10n.tr("General"), systemImage: "globe") }
            permissionSettings
                .tabItem { Label(L10n.tr("Permissions"), systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 440)
    }

    // MARK: - Tools

    private var toolSettings: some View {
        Form {
            Section(L10n.tr("Tool")) {
                Picker(L10n.tr("Tool"), selection: $coordinator.settings.tool) {
                    ForEach(Self.selectableTools, id: \.self) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .pickerStyle(.menu)

                Slider(value: $coordinator.settings.lineWidth, in: 1...24, step: 1) {
                    Text(L10n.tr("Width"))
                } minimumValueLabel: {
                    Text(L10n.tr("Thin"))
                } maximumValueLabel: {
                    Text(L10n.tr("Thick"))
                }

                Toggle(L10n.tr("Fill shapes"), isOn: $coordinator.settings.fillsShapes)

                Toggle(L10n.tr("Draw with ⌥ held"), isOn: $coordinator.settings.holdOptionToDraw)
                    .help(
                        L10n.tr("On: clicks pass through to the app underneath and only clicks with ⌥ (Option) held draw on the overlay. Off: the overlay captures every click outside the menu bar strip.")
                    )
                Text(
                    coordinator.settings.holdOptionToDraw
                        ? L10n.tr("Hold ⌥ (Option) and draw to annotate. Plain clicks go to the app beneath the overlay.")
                        : L10n.tr("The overlay captures every click. Use the pause button on the toolbar to interact with other apps.")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Colour")) {
                ColorPalette(selection: $coordinator.settings.color)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cursor

    private var cursorSettings: some View {
        Form {
            Section(L10n.tr("Effects")) {
                Toggle(L10n.tr("Pointer highlight"), isOn: $coordinator.cursorEffects.isHighlightEnabled)
                Toggle(L10n.tr("Spotlight"), isOn: $coordinator.cursorEffects.isSpotlightEnabled)
                Toggle(L10n.tr("Zoom lens"), isOn: $coordinator.cursorEffects.isZoomEnabled)
            }

            Section(L10n.tr("Zoom")) {
                Slider(value: $coordinator.cursorEffects.zoomFactor, in: 1...6, step: 0.5) {
                    Text(L10n.tr("Magnification"))
                } minimumValueLabel: {
                    Text("1×")
                } maximumValueLabel: {
                    Text("6×")
                }

                Picker(L10n.tr("Shape"), selection: $coordinator.cursorEffects.zoomShape) {
                    ForEach(ZoomShape.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General

    private var generalSettings: some View {
        Form {
            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Language"), selection: $coordinator.language) {
                    ForEach(L10n.Language.allCases) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Text(L10n.tr("Changes apply immediately to the menus, the toolbar and every window."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// The picker label of a language. Language names are shown in their own
    /// language ("Español", "English"), which is how every well-behaved system
    /// UI does it.
    private func languageName(_ language: L10n.Language) -> String {
        switch language {
        case .auto: L10n.tr("Automatic")
        case .english: "English"
        case .spanish: "Español"
        }
    }

    // MARK: - Permissions

    private var permissionSettings: some View {
        Form {
            Section(L10n.tr("Permissions")) {
                ForEach(PermissionKind.allCases) { kind in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr(kind.title))
                            Text(L10n.tr(kind.explanation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if status(for: kind).isGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button(L10n.tr("Grant")) {
                                Task { await coordinator.requestPermission(kind) }
                            }
                        }
                    }
                }
            }

            Section {
                Button(L10n.tr("Open System Settings")) {
                    if let kind = coordinator.permissions.outstanding.first {
                        coordinator.openSettings(for: kind)
                    }
                }
                .disabled(coordinator.permissions.outstanding.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording: coordinator.permissions.screenRecording
        case .accessibility: coordinator.permissions.accessibility
        }
    }
}

/// The row of colour swatches, shared by the settings window and the
/// annotation toolbar.
struct ColorPalette: View {
    @Binding var selection: AnnotationColor

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AnnotationColor.palette, id: \.self) { color in
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                selection == color ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                            .padding(-3)
                    }
                    .onTapGesture {
                        selection = color
                    }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Display names

extension AnnotationTool {
    /// The name shown in the tool picker, in the active language.
    @MainActor var displayName: String {
        switch self {
        case .pen: L10n.tr("Pen")
        case .line: L10n.tr("Line")
        case .arrow: L10n.tr("Arrow")
        case .rectangle: L10n.tr("Rectangle")
        case .ellipse: L10n.tr("Ellipse")
        case .text: L10n.tr("Text")
        case .spotlight: L10n.tr("Spotlight")
        case .blur: L10n.tr("Blur")
        case .highlighter: L10n.tr("Highlighter")
        case .stepNumber: L10n.tr("Step Number")
        case .laserPointer: L10n.tr("Laser Pointer")
        }
    }
}

extension ZoomShape {
    /// The name shown in the zoom shape picker, in the active language.
    @MainActor var displayName: String {
        switch self {
        case .circle: L10n.tr("Circle")
        case .squircle: L10n.tr("Squircle")
        }
    }
}

extension AnnotationColor {
    /// The colour as SwiftUI sees it.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
