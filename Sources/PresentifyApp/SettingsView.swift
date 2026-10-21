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
                .tabItem { Label("Tools", systemImage: "pencil.tip") }
            cursorSettings
                .tabItem { Label("Cursor", systemImage: "cursorarrow") }
            permissionSettings
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 420)
    }

    // MARK: - Tools

    private var toolSettings: some View {
        Form {
            Section("Tool") {
                Picker("Tool", selection: $coordinator.settings.tool) {
                    ForEach(Self.selectableTools, id: \.self) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                .pickerStyle(.menu)

                Slider(value: $coordinator.settings.lineWidth, in: 1...24, step: 1) {
                    Text("Width")
                } minimumValueLabel: {
                    Text("Thin")
                } maximumValueLabel: {
                    Text("Thick")
                }

                Toggle("Fill shapes", isOn: $coordinator.settings.fillsShapes)
            }

            Section("Colour") {
                ColorPalette(selection: $coordinator.settings.color)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cursor

    private var cursorSettings: some View {
        Form {
            Section("Effects") {
                Toggle("Pointer highlight", isOn: $coordinator.cursorEffects.isHighlightEnabled)
                Toggle("Spotlight", isOn: $coordinator.cursorEffects.isSpotlightEnabled)
                Toggle("Zoom lens", isOn: $coordinator.cursorEffects.isZoomEnabled)
            }

            Section("Zoom") {
                Slider(value: $coordinator.cursorEffects.zoomFactor, in: 1...6, step: 0.5) {
                    Text("Magnification")
                } minimumValueLabel: {
                    Text("1×")
                } maximumValueLabel: {
                    Text("6×")
                }

                Picker("Shape", selection: $coordinator.cursorEffects.zoomShape) {
                    ForEach(ZoomShape.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions

    private var permissionSettings: some View {
        Form {
            Section("Permissions") {
                ForEach(PermissionKind.allCases) { kind in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            Text(kind.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if status(for: kind).isGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Grant") {
                                Task { await coordinator.requestPermission(kind) }
                            }
                        }
                    }
                }
            }

            Section {
                Button("Open System Settings") {
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
    /// The name shown in the tool picker.
    var displayName: String {
        switch self {
        case .pen: "Pen"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .spotlight: "Spotlight"
        case .blur: "Blur"
        case .highlighter: "Highlighter"
        case .stepNumber: "Step Number"
        case .laserPointer: "Laser Pointer"
        }
    }
}

extension ZoomShape {
    /// The name shown in the zoom shape picker.
    var displayName: String {
        switch self {
        case .circle: "Circle"
        case .squircle: "Squircle"
        }
    }
}

extension AnnotationColor {
    /// The colour as SwiftUI sees it.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
