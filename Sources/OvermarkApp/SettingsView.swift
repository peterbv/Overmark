import AppKit
import SwiftUI
import OvermarkCore

/// The core colour type, aliased to avoid colliding with `SwiftUI.Color`.
public typealias AnnotationColor = OvermarkCore.Color

/// The tabs of the settings window, in display order.
///
/// A plain segmented picker renders a `TabView` as the old classic strip —
/// in newer macOS versions the SwiftUI `TabView` restyles itself as a
/// floating navigation tab bar, which is out of place in a small utility
/// window.
enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case tools
    case cursor
    case general
    case documents
    case shortcuts
    case permissions

    public var id: String { rawValue }

    /// The tab label, in the active language.
    @MainActor var title: String {
        switch self {
        case .tools: L10n.tr("Tools")
        case .cursor: L10n.tr("Cursor")
        case .general: L10n.tr("General")
        case .documents: L10n.tr("Documents")
        case .shortcuts: L10n.tr("Shortcuts")
        case .permissions: L10n.tr("Permissions")
        }
    }
}

/// The settings window.
///
/// It hosts the tool palette, the colour choices and the cursor effect
/// toggles. Everything here is written straight into the coordinator, which
/// pushes the values to the live overlay.
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedTab: SettingsTab = .tools

    /// Tools whose annotations the renderer actually draws.
    private static let selectableTools = AnnotationTool.allCases.filter { $0.producesAnnotation }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 12)

            selectedPane
        }
        .frame(width: 560, height: 460)
    }

    @ViewBuilder private var selectedPane: some View {
        switch selectedTab {
        case .tools: toolSettings
        case .cursor: cursorSettings
        case .general: generalSettings
        case .documents: documentsSettings
        case .shortcuts: HotKeysSettingsView(coordinator: coordinator)
        case .permissions: permissionSettings
        }
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

                Toggle(L10n.tr("Draw while holding the key"), isOn: $coordinator.settings.holdOptionToDraw)
                    .help(
                        L10n.tr("On: clicks pass through to the app underneath and only clicks with the drawing key held draw on the overlay. Off: the overlay captures every click outside the menu bar strip.")
                    )
                if coordinator.settings.holdOptionToDraw {
                    Picker(L10n.tr("Drawing key"), selection: $coordinator.drawingModifier) {
                        ForEach(DrawingModifier.allCases) { modifier in
                            Text(modifier.symbol).tag(modifier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .help(
                        L10n.tr("The key you hold to draw on the overlay.")
                    )
                }
                Text(
                    coordinator.settings.holdOptionToDraw
                        ? L10n.tr("Hold the drawing key (⌥, ⌃ or ⌘) and draw to annotate. Plain clicks go to the app beneath the overlay.")
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

                    Text(L10n.tr("Drawings disappear on their own after this long."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.tr("Whiteboard")) {
                Picker(L10n.tr("Board tone"), selection: $coordinator.whiteboardStyle) {
                    Text(L10n.tr("White")).tag(BoardStyle.white)
                    Text(L10n.tr("Black")).tag(BoardStyle.black)
                }
                .pickerStyle(.segmented)

                Text(L10n.tr("The board's colour. Choose the tone that reads best over your projector or with your recording setup."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Toggle(L10n.tr("Laser Pointer"), isOn: $coordinator.cursorEffects.isLaserEnabled)
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
                Slider(value: $coordinator.cursorEffects.zoomSize, in: 80...420, step: 10) {
                    Text(L10n.tr("Lens size"))
                } minimumValueLabel: {
                    Text("80")
                } maximumValueLabel: {
                    Text("420")
                }

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

                Picker(L10n.tr("Refresh rate"), selection: $coordinator.cursorEffects.lensRefreshRate) {
                    ForEach(LensRefreshRate.allCases) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }
                .pickerStyle(.segmented)

                if NSScreen.screens.count > 1 {
                    Toggle(
                        L10n.tr("Mirror lens on other displays"),
                        isOn: $coordinator.cursorEffects.isLensMirrored
                    )
                }

                Text(L10n.tr("The refresh rate buys motion smoothness at the cost of screen snapshot work in the background."))
            }

            Section(L10n.tr("Laser Pointer")) {
                HStack(spacing: 8) {
                    Text(L10n.tr("Dot colour"))
                    ColorPalette(selection: $coordinator.cursorEffects.laserColor)
                }

                Slider(value: $coordinator.cursorEffects.laserRadius, in: 2...14, step: 1) {
                    Text(L10n.tr("Dot size"))
                } minimumValueLabel: {
                    Text("2")
                } maximumValueLabel: {
                    Text("14")
                }

                Text(L10n.tr("The laser follows your pointer with a short glowing trail, on the overlay and burned into window recordings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            Section(L10n.tr("Floating bar")) {
                Picker(L10n.tr("Toolbar dock"), selection: $coordinator.toolbarDock) {
                    ForEach(ToolbarDock.allCases) { dock in
                        Text(dock.displayName).tag(dock)
                    }
                }
                .pickerStyle(.segmented)

                Text(L10n.tr("The bar starts on the chosen edge; grab it to drag it anywhere, and when it folds its little tab always waits in this dock."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    // MARK: - Documents

    private var documentsSettings: some View {
        Form {
            Section(L10n.tr("Current session")) {
                Text(L10n.tr("Everything you draw is kept in an autosave and comes back when you open Overmark again."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text(L10n.tr("Autosave"))
                    Spacer()
                    if coordinator.document.annotations.isEmpty {
                        Text(L10n.tr("The canvas is empty."))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.annotationCount(coordinator.document.annotations.count))
                            .foregroundStyle(.secondary)
                    }
                }

                Button(L10n.tr("Save Session…")) { presentSaveSessionDialog() }
                    .disabled(coordinator.document.annotations.isEmpty)
            }

            Section(L10n.tr("Saved documents")) {
                if coordinator.savedDocuments.isEmpty {
                    Text(L10n.tr("Nothing saved yet."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.savedDocuments) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text(metaLine(for: entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(L10n.tr("Restore")) {
                                coordinator.restoreSavedDocument(entry)
                            }
                            .buttonStyle(.borderless)

                            Button(role: .destructive) {
                                coordinator.deleteSavedDocument(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.reloadSavedDocuments() }
    }

    /// One line of metadata under each saved document name.
    private func metaLine(for entry: SessionArchive.Entry) -> String {
        let date = entry.snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)
        let count = L10n.annotationCount(entry.snapshot.annotations.count)
        return "\(date) · \(count)"
    }

    /// Asks for a document name and hands it to the coordinator.
    private func presentSaveSessionDialog() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Save the current session")
        alert.informativeText = L10n.tr("Give the document a name; you will be able to restore it later from this list.")
        alert.addButton(withTitle: L10n.tr("Save"))
        alert.addButton(withTitle: L10n.tr("Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultDocumentName()
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            coordinator.saveAnnotationDocument(named: field.stringValue)
        }
    }

    /// A fresh, human-readable name: "Session 22 oct 2026, 10:35".
    private func defaultDocumentName() -> String {
        L10n.tr("Session") + " " + Date.now.formatted(date: .abbreviated, time: .shortened)
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
    /// Row lays the swatches out horizontally (settings + horizontal
    /// toolbar); grid wraps them in a fixed-count grid so the vertical
    /// toolbar can host the same palette in a narrow column.
    var layout: Layout = .row
    /// Swatches per row when the palette uses the grid layout.
    var gridColumns: Int = 4

    enum Layout { case row, grid }

    /// Built-ins plus any favourites that are not already in the palette.
    private var swatches: [AnnotationColor] {
        AnnotationColor.palette + favorites.filter { !AnnotationColor.palette.contains($0) }
    }

    var body: some View {
        switch layout {
        case .row: rowBody
        case .grid: gridBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: 10) {
            ForEach(swatches, id: \.self) { color in
                swatchView(color)
            }

            if onAddFavorite != nil {
                surplusButton
            }
        }
        .padding(.vertical, 4)
    }

    /// A compact multi-row arrangement for narrow columns (the vertical
    /// toolbar): same swatch tiles, wrapped `gridColumns` per row.
    private var gridBody: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(26), spacing: 6), count: max(1, gridColumns)
            ),
            spacing: 6
        ) {
            ForEach(swatches, id: \.self) { color in
                swatchView(color)
            }

            if onAddFavorite != nil {
                surplusButton
            }
        }
    }

    private func swatchView(_ color: AnnotationColor) -> some View {
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

    private var surplusButton: some View {
        Button(action: onAddFavorite ?? {}) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
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

extension LensRefreshRate {
    /// The name shown in the lens refresh picker, in the active language.
    @MainActor var displayName: String {
        switch self {
        case .normal: L10n.tr("Normal (~3 fps)")
        case .responsive: L10n.tr("Smooth (~8 fps)")
        }
    }
}

extension ToolbarDock {
    /// The name shown in the dock picker, in the active language.
    @MainActor var displayName: String {
        switch self {
        case .top: L10n.tr("Dock at the top")
        case .bottom: L10n.tr("Dock at the bottom")
        case .leading: L10n.tr("Dock on the left edge")
        case .trailing: L10n.tr("Dock on the right edge")
        }
    }
}

extension AnnotationColor {
    /// The colour as SwiftUI sees it.
    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
