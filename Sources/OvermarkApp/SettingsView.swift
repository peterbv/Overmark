import AppKit
import SwiftUI
import OvermarkCore

/// The core colour type, aliased to avoid colliding with `SwiftUI.Color`.
public typealias AnnotationColor = OvermarkCore.Color

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
            HotKeysSettingsView(coordinator: coordinator)
                .tabItem { Label(L10n.tr("Shortcuts"), systemImage: "command.square") }
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

                Toggle(
                    L10n.tr("Gradient stroke"),
                    isOn: Binding(
                        get: { coordinator.settings.gradientColor != nil },
                        set: { on in
                            if on, coordinator.settings.gradientColor == nil {
                                coordinator.settings.gradientColor = AnnotationColor.blue
                            } else if !on {
                                coordinator.settings.gradientColor = nil
                            }
                        }
                    )
                )

                if coordinator.settings.gradientColor != nil {
                    HStack(spacing: 8) {
                        Text(L10n.tr("End colour"))
                        ColorPalette(selection: Binding(
                            get: { coordinator.settings.gradientColor ?? AnnotationColor.blue },
                            set: { coordinator.settings.gradientColor = $0 }
                        ))
                    }

                    Text(L10n.tr("Strokes blend from the starting colour into the end colour along the line."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

            Section(L10n.tr("Auto-erase")) {
                Toggle(
                    L10n.tr("Fade drawings away on their own"),
                    isOn: Binding(
                        get: { coordinator.settings.autoFadeSeconds > 0 },
                        set: { coordinator.settings.autoFadeSeconds = $0 ? 10 : 0 }
                    )
                )

                if coordinator.settings.autoFadeSeconds > 0 {
                    Slider(
                        value: Binding(
                            get: { Double(coordinator.settings.autoFadeSeconds) },
                            set: { coordinator.settings.autoFadeSeconds = Int($0) }
                        ),
                        in: 3...60,
                        step: 1
                    ) {
                        Text(L10n.tr("Fade delay"))
                    } minimumValueLabel: {
                        Text("3s")
                    } maximumValueLabel: {
                        Text("60s")
                    }

                    Text(L10n.tr("Drawings disappear on their own after this long. Step numbers never fade."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.tr("Colour")) {
                ColorPalette(
                    selection: $coordinator.settings.color,
                    favorites: coordinator.favoriteColors,
                    onAddFavorite: { coordinator.showColorPanel() }
                )
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

            Section(L10n.tr("Pointer highlight customization")) {
                Slider(value: $coordinator.cursorEffects.highlightRadius, in: 20...80, step: 5) {
                    Text(L10n.tr("Ring size"))
                } minimumValueLabel: {
                    Text("20")
                } maximumValueLabel: {
                    Text("80")
                }

                HStack(spacing: 8) {
                    Text(L10n.tr("Ring colour"))
                    ColorPalette(selection: $coordinator.cursorEffects.highlightColor)
                }

                Picker(L10n.tr("Ring shape"), selection: $coordinator.cursorEffects.highlightShape) {
                    ForEach(HighlightShape.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                Slider(value: $coordinator.cursorEffects.highlightBorderWidth, in: 1...12, step: 1) {
                    Text(L10n.tr("Border width"))
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("12")
                }

                Slider(value: $coordinator.cursorEffects.highlightFillOpacity, in: 0...0.8, step: 0.05) {
                    Text(L10n.tr("Fill opacity"))
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("80%")
                }
            }

            Section(L10n.tr("Click animation")) {
                Toggle(
                    L10n.tr("Show click ripples"),
                    isOn: $coordinator.cursorEffects.isClickAnimationEnabled
                )
                Text(L10n.tr("Ripples play while the cursor effect windows are up — turn any effect on to see them."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Spotlight")) {
                Slider(value: $coordinator.cursorEffects.spotlightRadius, in: 100...450, step: 10) {
                    Text(L10n.tr("Hole size"))
                } minimumValueLabel: {
                    Text("100")
                } maximumValueLabel: {
                    Text("450")
                }

                Slider(value: $coordinator.cursorEffects.spotlightDimOpacity, in: 0...1, step: 0.05) {
                    Text(L10n.tr("Dimming"))
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
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

            recordingSettings
        }
        .formStyle(.grouped)
    }

    // MARK: - Recording

    private var recordingSettings: some View {
        Section(L10n.tr("Recording")) {
            Picker(L10n.tr("Recording target"), selection: $coordinator.recorderSettings.target) {
                Text(L10n.tr("Full screen")).tag(RecordingTarget.display)
                Text(L10n.tr("A window")).tag(RecordingTarget.window)
            }
            .pickerStyle(.segmented)

            if coordinator.recorderSettings.target == .window {
                Picker(L10n.tr("Recording window"), selection: recordingWindowBinding) {
                    ForEach(coordinator.recordableWindows, id: \.self) { choice in
                        Text("\(choice.title) — \(choice.ownerName)")
                            .tag(RecordingWindowChoice?.some(choice))
                    }

                    if let stale = staleWindowChoice {
                        Text("\(stale.title) — \(L10n.tr("Not available"))")
                            .tag(RecordingWindowChoice?.some(stale))
                    }
                }

                Text(L10n.tr("The chosen window is recorded following it; the annotations are burned into the video."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(L10n.tr("Refresh windows")) {
                    Task { await coordinator.refreshRecordableWindows() }
                }
            }

            Picker(L10n.tr("Recording screen"), selection: recordingScreenBinding) {
                Text(L10n.tr("Main display")).tag(String?.none)

                ForEach(currentScreenOptions, id: \.id) { option in
                    Text(option.label).tag(String?.some(option.id))
                }

                if let stale = staleRecordingName {
                    Text("\(stale) — \(L10n.tr("Not available"))")
                        .tag(String?.some(stale))
                }
            }

            if coordinator.recorderSettings.target == .display {
                Text(L10n.tr("Overmark records the whole display, annotations included live."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(L10n.tr("Frame rate"), selection: $coordinator.recorderSettings.frameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)

            Picker(
                L10n.tr("Codec"),
                selection: Binding(
                    get: { coordinator.recorderSettings.codec },
                    set: { coordinator.recorderSettings.codec = $0 }
                )
            ) {
                Text("H.264").tag(RecordingCodec.h264)
                Text("HEVC").tag(RecordingCodec.hevc)
            }

            Toggle(L10n.tr("Record the microphone"), isOn: $coordinator.recorderSettings.includesMicrophone)
            Text(L10n.tr("While this is on, Overmark asks for the microphone permission and records its sound into the presentation video."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if coordinator.recorderSettings.includesMicrophone,
               !coordinator.microphonePermission.isGranted {
                Button(L10n.tr("Open Microphone settings")) {
                    coordinator.openSettings(for: .microphone)
                }
            }

            LabeledContent(L10n.tr("Save folder")) {
                HStack(spacing: 8) {
                    Text(recordingsFolderDisplay)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(recordingsFolderDisplay)

                    Button(L10n.tr("Choose")) {
                        coordinator.chooseRecordingsFolder()
                    }

                    if coordinator.recorderSettings.folderPath != nil {
                        Button(L10n.tr("Use default")) {
                            coordinator.resetRecordingsFolder()
                        }
                    }
                }
            }

            if let lastRecording = coordinator.lastRecordingURL {
                LabeledContent(L10n.tr("Last recording")) {
                    HStack(spacing: 8) {
                        Text(lastRecording.lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(lastRecording.path)

                        Button(L10n.tr("Show in Finder")) {
                            coordinator.revealLastRecording()
                        }
                    }
                }
            }
        }
        .task(id: coordinator.recorderSettings.target) {
            // Keep the window picker fresh: it lists what is on screen at
            // the moment the settings are open (or the target flips).
            await coordinator.refreshRecordableWindows()
        }
    }

    /// The window the recording follows, or `nil` for the full screen —
    /// the persisted choice is matched against the windows on screen.
    private var recordingWindowBinding: Binding<RecordingWindowChoice?> {
        Binding(
            get: { coordinator.recorderSettings.windowChoice },
            set: { coordinator.recorderSettings.windowChoice = $0 }
        )
    }

    /// The saved window when it is no longer on screen, so the picker can
    /// show the stale pick instead of silently switching to nothing.
    private var staleWindowChoice: RecordingWindowChoice? {
        guard let choice = coordinator.recorderSettings.windowChoice else {
            return nil
        }
        return coordinator.recordableWindows.contains(choice) ? nil : choice
    }

    /// The save folder as the user reads it: outside of home it is the
    /// absolute path, inside home the leading part is the familiar `~`.
    private var recordingsFolderDisplay: String {
        let path = coordinator.recordingsFolderURL.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Recording screen

    /// The saved display policy flattened to the picker's selection: `nil`
    /// is the main display, a name is the picked screen.
    private var recordingScreenBinding: Binding<String?> {
        Binding(
            get: {
                switch coordinator.recorderSettings.displayChoice {
                case .main: return nil
                case .namedScreen(let name): return name
                }
            },
            set: { newValue in
                coordinator.recorderSettings.displayChoice =
                    newValue.map { .namedScreen($0) } ?? .main
            }
        )
    }

    /// The screens that exist right now, named; identical names (two
    /// identical monitors) gain their pixel size to stay distinguishable.
    private var currentScreenOptions: [(id: String, label: String)] {
        let screens = NSScreen.screens
        return screens.map { screen in
            let name = screen.localizedName
            let twins = screens.filter { $0.localizedName == name }
            guard twins.count > 1 else {
                return (id: name, label: name)
            }
            let width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
            let height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
            return (id: name, label: "\(name) (\(width)×\(height))")
        }
    }

    /// A chosen screen that no longer matches any connected screen: shown
    /// so the user sees the state instead of the picker silently falling
    /// back to the main display.
    private var staleRecordingName: String? {
        guard case .namedScreen(let name) = coordinator.recorderSettings.displayChoice else {
            return nil
        }
        return NSScreen.screens.contains { $0.localizedName == name } ? nil : name
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
                ForEach(PermissionKind.required) { kind in
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

                // The microphone is optional, so its row only appears when
                // the user has recording audio switched on.
                if coordinator.recorderSettings.includesMicrophone {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr(PermissionKind.microphone.title))
                            Text(L10n.tr(PermissionKind.microphone.explanation))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if coordinator.microphonePermission.isGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button(L10n.tr("Grant")) {
                                Task { await coordinator.requestPermission(.microphone) }
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
        case .microphone: coordinator.microphonePermission
        }
    }
}

/// The row of colour swatches, shared by the settings window and the
/// annotation toolbar.
///
/// Favourite colours appear after the built-in palette, and a "+" button
/// opens the system colour panel to record a new favourite.
struct ColorPalette: View {
    @Binding var selection: AnnotationColor
    /// Custom colours the user saved, drawn after the built-in palette.
    var favorites: [AnnotationColor] = []
    /// Starts the "add a colour" flow when non-nil.
    var onAddFavorite: (() -> Void)? = nil

    /// Built-ins plus any favourites that are not already in the palette.
    private var swatches: [AnnotationColor] {
        AnnotationColor.palette + favorites.filter { !AnnotationColor.palette.contains($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(swatches, id: \.self) { color in
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

            if let onAddFavorite {
                Button(action: onAddFavorite) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .strokeBorder(
                                    Color.primary.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(L10n.tr("Add colour…"))
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

extension HighlightShape {
    /// The name shown in the ring shape picker, in the active language.
    @MainActor var displayName: String {
        switch self {
        case .circle: L10n.tr("Circle")
        case .squircle: L10n.tr("Squircle")
        case .rhombus: L10n.tr("Rhombus")
        }
    }
}

extension AnnotationColor {
    /// The colour as SwiftUI sees it.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
