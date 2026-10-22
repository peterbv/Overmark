import AppKit
import Foundation
import OvermarkCapture
import OvermarkCore
import OvermarkCursor
import OvermarkHotkeys
import OvermarkOverlay
import OvermarkRecorder
import ScreenCaptureKit
import SwiftUI

/// The object that owns the app's behaviour.
///
/// SwiftUI views observe this object; it in turn drives the overlay, the hot
/// keys and the cursor tracker. Keeping the orchestration in one observable
/// object means the views stay declarative and the side effects stay in one
/// place.
@MainActor
public final class AppCoordinator: ObservableObject {
    /// The current app mode.
    @Published public private(set) var mode: AppMode = .idle {
        didSet { overlay.setInteractionEnabled(mode.allowsDrawing) }
    }

    /// The annotations and their undo history.
    @Published public private(set) var document = AnnotationDocument() {
        didSet {
            overlay.setAnnotations(document.annotations)
            // The window recorder draws whatever is on the canvas right
            // now; keep its snapshot in step with every document change.
            recordingAnnotations.set(document.annotations)
            syncStepNumber()
        }
    }

    /// The selected tool, colour and width.
    ///
    /// Changes persist between launches: the whole struct is written through
    /// to user defaults on every change.
    @Published public var settings = ToolSettings() {
        didSet {
            overlay.apply(settings: settings)
            PreferencesStore.save(settings)
        }
    }

    /// Colours the user added from the colour panel, shown in the palette.
    @Published public var favoriteColors: [AnnotationColor] = [] {
        didSet { PreferencesStore.save(favoriteColors) }
    }

    /// The cursor effects currently enabled.
    ///
    /// The effects are applied without rebuilding their windows unless the
    /// change genuinely needs one (see `CursorEffectController.apply`),
    /// which keeps the spotlight/zoom controls smooth while they change.
    @Published public var cursorEffects = CursorEffects() {
        didSet {
            PreferencesStore.save(cursorEffects)
            updateClickMonitor()
            Task { await effectController.apply(effects: cursorEffects) }
        }
    }

    /// The most recent error message, shown in the UI.
    @Published public var lastError: String?

    /// The `NSColorWell` that receives the shared colour panel's picks while
    /// the user chooses a favourite colour.
    private var colorWell: NSColorWell?

    /// The app's user-facing language, shown in the General settings tab.
    ///
    /// Every window re-renders when this changes because all of them observe
    /// the coordinator; the status-bar menu rebuilds on the same signal.
    @Published public var language: L10n.Language = .spanish {
        didSet {
            guard language != oldValue else { return }
            L10n.selected = L10n.resolve(language)
            UserDefaults.standard.set(language.rawValue, forKey: "Overmark.language")
        }
    }

    /// The permission state.
    @Published public private(set) var permissions: PermissionState = PermissionState()

    /// The microphone permission, tracked separately because it is an
    /// optional permission that only matters to the recorder.
    @Published public private(set) var microphonePermission: PermissionStatus = .notDetermined

    /// The recorder's configuration, edited from Preferencias and persisted.
    @Published public var recorderSettings = RecorderSettings() {
        didSet {
            let clamped = recorderSettings.clamped()
            if clamped != recorderSettings {
                recorderSettings = clamped
            }
            Self.persist(recorderSettings)
        }
    }

    /// The presentation recorder state: idle while nothing is captured.
    @Published public private(set) var recordingState: RecordingState = .idle

    /// The URL of the most recently completed recording, for "Reveal".
    @Published public private(set) var lastRecordingURL: URL?

    /// The windows the recorder can follow when the target is a window:
    /// the titled windows of other apps on screen, by title + owner.
    @Published public private(set) var recordableWindows: [RecordingWindowChoice] = []

    /// Where the annotation overlays appear: every screen or one chosen
    /// display (Mirrored projector screens work best annotated on only
    /// one of them). Persisted; changes rebuild an active session live.
    @Published public private(set) var presentationScope: PresentationScope = .all

    /// Bumped whenever the system reports a screen layout change. SwiftUI
    /// views that list the screens re-read it, so pickers pick up displays
    /// that were connected or unplugged mid-session.
    @Published public private(set) var screensEpoch = 0

    /// The hot key combinations in effect: the factory defaults merged with
    /// the user's persisted overrides. Observable for the settings shortcut
    /// tab and the toolbar cheat-sheet.
    @Published public private(set) var hotKeyBindings: [HotKeyAction: HotKeyManager.Binding] = [:]

    /// Watches the system-wide displays notification.
    private var screensObserver: (any NSObjectProtocol)?

    private let captureService: ScreenCaptureService
    private let overlay: OverlayController
    private let effectController: CursorEffectController
    private let hotKeys: HotKeyManager
    private let cursorTracker: CursorTracker
    private let permissionService: PermissionService
    /// The actor running the presentation recording.
    private let recorder = PresentationRecorder()
    /// The annotations snapshot the window recorder burns into the frames.
    /// The document is a value on the main actor; the recorder's callback
    /// queue cannot touch it directly, so changes are posted to this box
    /// and the burn-in reads the latest set under a lock.
    private let recordingAnnotations = RecordingAnnotationBox()
    /// The text editor window; excluded from recordings like the other chrome.
    private var textEditorWindow: NSWindow?
    /// The floating control bar shown while annotating.

    /// Opens the app's settings window; wired by the app delegate, which
    /// owns that window.
    public var onShowAppSettings: (() -> Void)?

    /// Extra app chrome (the settings window, the onboarding) that has to
    /// be excluded from a recording; wired by the app delegate, which owns
    /// those windows.
    public var onRecordingExcludedWindows: () -> [Int] = { [] }

    /// The floating control bar shown while annotating.
    private var toolbar: AnnotationToolbarController?

    /// Retains the delegate of the text editor window.
    ///
    /// `NSWindow` holds its delegate weakly, so it has to be kept alive
    /// somewhere for as long as the editor is open.
    private var textEditorDelegate: TextEditorWindowDelegate?

    /// Monitors that play the click ripple (global + local).
    ///
    /// A global monitor never sees events aimed at this app's own windows:
    /// while Overmark is frontmost — its editor windows, or its panels when
    /// they have claimed the mouse — clicks arrive locally instead. Both are
    /// installed while the ripple is on, and `NSEvent.mouseLocation` gives a
    /// screen-space position for either kind.
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    public init() {
        let captureService = ScreenCaptureService()
        let cursorTracker = CursorTracker()
        let overlay = OverlayController()

        self.captureService = captureService
        self.cursorTracker = cursorTracker
        self.overlay = overlay
        self.effectController = CursorEffectController(captureService: captureService)
        self.hotKeys = HotKeyManager()
        self.permissionService = PermissionService(
            captureService: captureService,
            cursorTracker: cursorTracker
        )

        // Restore the user's choices before any handler registers, so the
        // first push to the overlay already carries the persisted state. The
        // assignments fire the `didSet` blocks, which push to the overlay,
        // apply the effects and write through — all harmless repeats.
        settings = PreferencesStore.loadToolSettings()
        favoriteColors = PreferencesStore.loadFavoriteColors()
        cursorEffects = PreferencesStore.loadCursorEffects()

        hotKeys.onAction = { [weak self] action in
            self?.handle(action)
        }

        // The pointer position drives the cursor effects. The tracker only
        // runs while the Accessibility permission is granted.
        cursorTracker.onMove = { [weak self] point in
            self?.effectController.updateCursorLocation(point)
        }

        updateClickMonitor()

        overlay.bind(
            onAnnotationCreated: { [weak self] annotation in
                self?.document.add(annotation)
                self?.scheduleAutoFade(annotation)
            },
            onClick: { [weak self] point in
                self?.handleCanvasClick(at: point)
            },
            onAnnotationDelete: { [weak self] annotation in
                self?.document.remove(id: annotation.id)
            },
            onAnnotationEdit: { [weak self] annotation in
                let anchor = annotation.path.first ?? annotation.bounds.origin
                self?.presentTextEditor(at: anchor, editing: annotation)
            }
        )

        hotKeyBindings = HotKeyBindingStore.load()
        for (action, binding) in hotKeyBindings {
            hotKeys.register(action, binding: binding)
        }
        permissionService.refresh()
        permissions = permissionService.state
        microphonePermission = permissionService.microphone

        // Restore the persisted language before any view is built so the
        // onboarding window and the status-bar menu come up translated.
        let stored = L10n.Language(
            rawValue: UserDefaults.standard.string(forKey: "Overmark.language") ?? ""
        ) ?? .spanish
        L10n.selected = L10n.resolve(stored)
        self.language = stored

        recorderSettings = Self.storedRecorderSettings()
        presentationScope = Self.storedPresentationScope()

        // Display changes (plug, unplug, rearrange) must keep an active
        // session honest: the overlays follow whatever ends up attached.
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreensChanged() }
        }

        toolbar = AnnotationToolbarController(coordinator: self)
    }

    // MARK: - Lifecycle

    /// Starts the app: registers permissions refresh and enables cursor
    /// tracking when it is allowed.
    public func start() {
        permissionService.refresh()
        permissions = permissionService.state
        microphonePermission = permissionService.microphone

        applyPermissionSideEffects()
    }

    /// Stops all ongoing activity.
    public func stop() {
        cursorTracker.stop()
        hotKeys.unregisterAll()
        hotKeys.unregisterEscape()
        toolbar?.hide()
        overlay.tearDown()
        effectController.tearDown()
        removeClickMonitors()
        // The colour well outlives the overlay windows; detach it so a quit
        // does not leave a target pointing at a coordinator that is going
        // away.
        colorWell?.target = nil
        colorWell = nil
        NSColorPanel.shared.orderOut(nil)
        if let screensObserver {
            NotificationCenter.default.removeObserver(screensObserver)
        }
        screensObserver = nil
        mode = .idle
        // A recording still being finalized keeps running on its own task;
        // `applicationWillTerminate` awaits it via `quit(afterStopping:)`.
    }

    // MARK: - Permissions

    /// Whether the overlay pass-through is fully active right now.
    public var overlayPassthroughActive: Bool {
        overlay.isPassthroughMode
    }

    /// Compactly logs the overlay click-routing state (diagnostics only).
    public func debugOverlayState() -> String {
        overlay.debugPanelState()
    }

    /// Requests a permission and refreshes the state.
    @discardableResult
    public func requestPermission(_ kind: PermissionKind) async -> Bool {
        let granted = await permissionService.request(kind)
        permissions = permissionService.state
        microphonePermission = permissionService.microphone
        // The Accessibility prompt is answered asynchronously, so the grant
        // usually lands *after* this call returns. The pointer tap has to be
        // created at that moment, otherwise the permission reads as granted
        // but the cursor effect never follows the pointer.
        if granted { applyPermissionSideEffects() }
        return granted
    }

    /// Opens the System Settings pane for a permission.
    public func openSettings(for kind: PermissionKind) {
        permissionService.openSettings(for: kind)
    }

    /// Re-reads the permission state.
    public func refreshPermissions() {
        permissionService.refresh()
        permissions = permissionService.state
        microphonePermission = permissionService.microphone
        applyPermissionSideEffects()
    }

    /// Starts the pointer tracking when Accessibility is available.
    ///
    /// The `CGEventTap` is created once and cannot be created before the
    /// permission is granted: `tapCreate` fails silently and leaves the
    /// tracker inert, so the cursor effect would never move even though the
    /// permission reads as granted. Starting it whenever the permission
    /// becomes available keeps the two in sync.
    private func applyPermissionSideEffects() {
        if permissions.accessibility.isGranted {
            cursorTracker.start()
        } else {
            cursorTracker.stop()
        }
    }

    // MARK: - Modes

    /// Enters annotation mode, capturing the screen and showing the overlays.
    public func enterAnnotationMode() async {
        // The diagnostic probe exercises the panel/passthrough machinery even
        // when the probe process (a bare exec'd binary) has no TCC grant: it
        // cannot answer System Settings prompts on its own.
        if ProcessInfo.processInfo.environment["OVERMARK_PROBE"] == "1" {
            await presentOverlays()
            return
        }

        guard !permissions.screenRecording.isGranted else {
            await presentOverlays()
            return
        }

        let granted = await requestPermission(.screenRecording)
        guard granted else {
            lastError = L10n.tr("Overmark needs Screen Recording access to capture the screen.")
            return
        }
        await presentOverlays()
    }

    /// Leaves annotation mode and removes the overlays.
    public func exitAnnotationMode() {
        toolbar?.hide()
        hotKeys.unregisterEscape()
        overlay.tearDown()
        mode = .idle
        // ESC is the guaranteed exit, and that promise extends to the
        // recording: ending a session never loses the file — it is
        // finalized here and announced when done.
        if recordingState.isActive {
            Task { await runStopRecording() }
        }
    }

    /// Toggles annotation mode on or off.
    public func toggleAnnotationMode() async {
        if mode == .idle {
            await enterAnnotationMode()
        } else {
            exitAnnotationMode()
        }
    }

    /// Pauses or resumes the overlay.
    ///
    /// While paused the overlay stays visible but stops accepting mouse
    /// events, so the user can interact with the app underneath.
    public func togglePause() {
        switch mode {
        case .idle:
            break
        case .annotating:
            mode = .paused
        case .paused:
            mode = .annotating
        }
    }

    // MARK: - Presentation scope

    /// Changes where the overlays annotate and persists the choice.
    ///
    /// While a presentation is running the change applies live: the panels
    /// rebuild on the allowed screens and the existing annotations come
    /// back on them, because strokes live in the document, not in windows.
    public func setPresentationScope(_ scope: PresentationScope) {
        guard scope != presentationScope else { return }
        presentationScope = scope
        Self.persistPresentationScope(scope)
        guard mode != .idle else { return }
        Task { await rebuildOverlaysForScope() }
    }

    /// The localized names of the attached screens, for the scope picker.
    /// Duplicate names (two identical monitors) collapse to one entry:
    /// picking it annotates the first matching screen.
    public var screenNames: [String] {
        var seen = Set<String>()
        return NSScreen.screens.compactMap {
            seen.insert($0.localizedName).inserted ? $0.localizedName : nil
        }
    }

    /// Rebuilds the overlays for the current scope while presenting.
    private func rebuildOverlaysForScope() async {
        guard mode != .idle else { return }
        await overlay.showOverlays(allowedDisplayIDs: allowedOverlayDisplayIDs())
        guard overlay.overlayCount > 0 else {
            lastError = L10n.tr("No displays were available to annotate.")
            return
        }
        overlay.setAnnotations(document.annotations)
        overlay.apply(settings: settings)
        overlay.setInteractionEnabled(mode.allowsDrawing)
    }

    /// The concrete overlay filter of the stored scope.
    ///
    /// `nil` covers every screen. A single-screen scope resolves to that
    /// display's id; when the named screen no longer exists the main one
    /// takes over (with a notice) so the presentation is never left
    /// without a canvas.
    private func allowedOverlayDisplayIDs() -> Set<CGDirectDisplayID>? {
        guard let name = presentationScope.screenName else { return nil }
        let screens = NSScreen.screens
        if let match = screens.first(where: { $0.localizedName == name }),
           let displayID = Self.displayID(of: match) {
            return [displayID]
        }
        lastError = L10n.tr(
            "The chosen annotation screen is not available; annotating the main display."
        )
        let main = NSScreen.main ?? screens.first
        guard let main, let displayID = Self.displayID(of: main) else { return nil }
        return [displayID]
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The system rearranged the displays (plug, unplug, reorder).
    ///
    /// An active session follows the new layout: the panels rebuild on the
    /// screens still in scope — annotations survive because they live in
    /// the document — and the bar re-clamps onto a screen that exists.
    /// The epoch bump lets screen pickers refresh their lists.
    private func handleScreensChanged() {
        screensEpoch += 1
        guard mode != .idle else { return }
        lastError = L10n.tr("Displays changed; the annotation overlay was rebuilt.")
        Task { await rebuildOverlaysForScope() }
        toolbar?.handleScreensChanged()
    }

    // MARK: - Presentation scope storage

    private static let presentationScopeKey = "Overmark.presentationScope"

    private static func storedPresentationScope() -> PresentationScope {
        guard let data = UserDefaults.standard.data(forKey: presentationScopeKey),
              let scope = try? JSONDecoder().decode(PresentationScope.self, from: data) else {
            return .all
        }
        return scope
    }

    private static func persistPresentationScope(_ scope: PresentationScope) {
        guard let data = try? JSONEncoder().encode(scope) else { return }
        UserDefaults.standard.set(data, forKey: presentationScopeKey)
    }

    // MARK: - Hot keys

    /// Applies a new combination to an action, re-registers the global hot
    /// key and persists the choice.
    public func updateHotKeyBinding(_ action: HotKeyAction, binding: HotKeyManager.Binding) {
        var bindings = hotKeyBindings
        bindings[action] = binding
        hotKeyBindings = bindings
        hotKeys.register(action, binding: binding)
        HotKeyBindingStore.save(bindings)
    }

    /// Restores one action's factory default and persists it.
    public func resetHotKeyBinding(_ action: HotKeyAction) {
        guard let binding = HotKeyManager.defaultBindings[action] else { return }
        updateHotKeyBinding(action, binding: binding)
    }

    /// Restores every factory default and persists them.
    public func resetHotKeyBindings() {
        hotKeyBindings = HotKeyManager.defaultBindings
        for (action, binding) in hotKeyBindings {
            hotKeys.register(action, binding: binding)
        }
        HotKeyBindingStore.save(hotKeyBindings)
    }

    /// The action already bound to a combination, if any, for the settings
    /// UI to report a conflict before the assignment is applied.
    public func hotKeyConflict(
        for binding: HotKeyManager.Binding,
        excluding action: HotKeyAction
    ) -> HotKeyAction? {
        HotKeyManager.conflict(for: binding, in: hotKeyBindings, for: action)
    }

    /// Shows the overlays: a transparent canvas over the live desktop on
    /// the screens the presentation scope allows.
    ///
    /// No screenshot is displayed behind the strokes. An earlier design
    /// layered a fresh capture under the annotations, but rendering it as a
    /// sublayer of the canvas meant the picture sat *above* both the live
    /// desktop and the strokes: the whole screen looked frozen inside a
    /// static photo, clicks landed on apps that stayed invisibly busy, and
    /// every annotation drawn was hidden underneath it.
    private func presentOverlays() async {
        await overlay.showOverlays(allowedDisplayIDs: allowedOverlayDisplayIDs())

        guard overlay.overlayCount > 0 else {
            // Panels can fail to build only when no screens are matched at
            // all. Surface it: the toolbar was never built, so without an
            // alert the user just sees "nothing happens".
            lastError = L10n.tr("No displays were available to annotate.")
            let alert = NSAlert()
            alert.messageText = L10n.tr("No displays were available to annotate.")
            alert.informativeText = L10n.tr(
                "Reopen Overmark or check System Settings → Displays if this persists."
            )
            alert.runModal()
            return
        }

        overlay.setAnnotations(document.annotations)
        overlay.apply(settings: settings)
        mode = .annotating

        // The control bar is what makes annotation mode self-serve: no
        // hot keys required to switch tools, undo a stroke or stop.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            toolbar?.show(on: screen)
        }

        // And Escape is the guaranteed exit hatch, even if the control
        // bar ever fails to appear.
        registerEscapeHotKey()
    }

    /// Registers the Escape key so it ends the presentation while the
    /// overlays are on screen.
    private func registerEscapeHotKey() {
        hotKeys.registerEscape { [weak self] in
            guard let self, self.mode != .idle else { return }
            self.exitAnnotationMode()
        }
    }

    // MARK: - History

    /// Undoes the last annotation.
    public func undo() {
        document.undo()
    }

    /// Redoes the last undone annotation.
    public func redo() {
        document.redo()
    }

    /// Removes every annotation.
    public func clearAll() {
        document.removeAll()
    }

    // MARK: - Actions

    /// Captures the whole desktop across every attached display and returns
    /// the resulting image.
    ///
    /// The annotations are composited on top of the captures, because the
    /// overlay lives in the app's own windows and would not otherwise appear
    /// in the screenshot. Each display's own marks are drawn on its own
    /// piece, and the pieces are stitched into the desktop's bounding
    /// rectangle, so a multi-monitor presentation copies and saves in full —
    /// not just the first display.
    ///
    /// Returns `nil` when there is nothing to capture, for example because
    /// Screen Recording access has not been granted or no display is
    /// reachable.
    private func captureDesktopImage() async -> CGImage? {
        guard let snapshots = try? await captureService.captureAllDisplays(),
              !snapshots.isEmpty else {
            return nil
        }
        return AnnotationCompositor.desktopImage(
            from: snapshots.map {
                AnnotationCompositor.DisplayPiece(image: $0.image, screen: $0.screen)
            },
            annotations: document.annotations
        )
    }

    /// Handles a global hot key action.
    private func handle(_ action: HotKeyAction) {
        switch action {
        case .toggleAnnotation:
            Task { await toggleAnnotationMode() }
        case .togglePause:
            togglePause()
        case .toggleSpotlight:
            cursorEffects.isSpotlightEnabled.toggle()
        case .toggleHighlight:
            cursorEffects.isHighlightEnabled.toggle()
        case .toggleZoom:
            cursorEffects.isZoomEnabled.toggle()
        case .toggleRecording:
            toggleRecording()
        case .undo:
            undo()
        case .redo:
            redo()
        case .copyScreenshot:
            Task { await copyScreenshot() }
        case .saveScreenshot:
            Task { await saveScreenshot() }
        case .quit:
            quitOvermark()
        }
    }

    /// Handles a click on the canvas that did not produce an annotation.
    ///
    /// Only the text tool needs the app layer: it opens a small editor and
    /// turns the result into a `.text` annotation.
    private func handleCanvasClick(at point: Point) {
        guard settings.tool == .text else { return }
        presentTextEditor(at: point)
    }

    // MARK: - Click ripple

    /// Installs or removes the click-ripple monitors.
    ///
    /// The monitors exist only while the ripple setting is on; the effect
    /// controller ignores trigger requests whenever no effect window is
    /// up, so switching the toggle on with every effect off stays a no-op.
    private func updateClickMonitor() {
        guard cursorEffects.isClickAnimationEnabled else {
            removeClickMonitors()
            return
        }
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                Task { @MainActor in self?.playClickPulse(for: event) }
            }
        )
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.playClickPulse(for: event)
            return event
        }
    }

    /// Forwards a click under the pointer to the effect controller.
    private func playClickPulse(for event: NSEvent) {
        let point = Point(
            x: Double(NSEvent.mouseLocation.x),
            y: Double(NSEvent.mouseLocation.y)
        )
        effectController.triggerClick(
            point: point,
            isRight: event.type == .rightMouseDown
        )
    }

    /// Drops both click monitors.
    private func removeClickMonitors() {
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        localClickMonitor = nil
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalClickMonitor = nil
    }

    // MARK: - Colour favourites

    /// Shows the system colour panel, raised above the overlay panels, and
    /// records picked colours as favourites.
    ///
    /// A detached `NSColorWell` is the receiver: activating it opens the
    /// shared panel and every picked colour flows back through the well's
    /// target/action, which is portable across SDK versions where
    /// `NSColorPanel`'s own target/action are unavailable.
    public func showColorPanel() {
        let well = NSColorWell()
        well.target = self
        well.action = #selector(colorWellPicked(_:))
        colorWell = well
        well.activate(true)

        // The overlays float at the status bar level; keep the panel above
        // them so it stays usable during a presentation.
        NSColorPanel.shared.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1
        )
    }

    @objc private func colorWellPicked(_ sender: NSColorWell) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        addFavorite(AnnotationColor(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent)
        ))
    }

    /// Records a colour as a favourite. Duplicates are collapsed and the
    /// oldest colours fall out once the list is full.
    public func addFavorite(_ color: AnnotationColor) {
        favoriteColors = PreferencesStore.addFavorite(color, to: favoriteColors)
    }

    /// Opens the text editor and adds the resulting annotation.
    ///
    /// Pass `editing` to re-edit an existing text annotation: the editor is
    /// prefilled with its text and the commit replaces it in place (same id,
    /// colour and stroke width), which also keeps undo a single step.
    private func presentTextEditor(at point: Point, editing existing: Annotation? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        textEditorWindow = window
        window.title = L10n.tr(existing == nil ? "Add Text" : "Edit Text")
        // The coordinator holds no strong reference to this window, so it must
        // not self-release on close(): close() defers an autorelease and
        // popping that pool after the last strong reference goes away would
        // over-release freed memory.
        window.isReleasedWhenClosed = false
        // The overlay panels float at `.statusBar` level and cover every
        // screen, so a normal window would open behind them — invisible and
        // unable to receive the keystrokes. The editor is placed just above
        // the overlays to stay usable.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

        // Suspend the overlay while the editor is open so a stray click
        // cannot draw on the canvas behind the panel.
        overlay.setInteractionEnabled(false)

        // `NSWindow` keeps its delegate weakly, so it is retained here.
        // Closing the window with the title bar button must also restore the
        // overlay, which is what the delegate is for.
        let delegate = TextEditorWindowDelegate { [weak self] in
            self?.endTextEditing()
        }
        textEditorDelegate = delegate
        window.delegate = delegate

        window.contentView = NSHostingView(
            rootView: TextAnnotationEditorView(
                color: existing?.color ?? settings.color,
                lineWidth: existing?.lineWidth ?? settings.lineWidth,
                initialText: existing?.text ?? "",
                onCancel: { [weak self] in
                    window.close()
                    self?.endTextEditing()
                },
                onCommit: { [weak self] (text: String) in
                    window.close()
                    self?.endTextEditing()
                    if let existing {
                        self?.updateTextAnnotation(existing, with: text)
                    } else {
                        self?.addTextAnnotation(text, at: point)
                    }
                }
            )
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Resumes the overlay after the text editor closes.
    private func endTextEditing() {
        overlay.setInteractionEnabled(mode.allowsDrawing)
        textEditorWindow = nil
        textEditorDelegate = nil
    }

    /// Keeps the step counter in sync with the document.
    ///
    /// The number is derived from the annotations that are present, so undoing
    /// or clearing annotations also rewinds the counter. This keeps the
    /// settings view and the canvas in agreement.
    private func syncStepNumber() {
        let next = document.nextStepNumber
        guard settings.nextStepNumber != next else { return }
        settings.nextStepNumber = next
    }

    /// Adds a text annotation to the document.
    private func addTextAnnotation(_ text: String, at point: Point) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let annotation = Annotation(
            tool: .text,
            color: settings.color,
            lineWidth: settings.lineWidth,
            path: [point],
            bounds: Annotation.textBounds(
                for: trimmed,
                lineWidth: settings.lineWidth,
                origin: point
            ),
            text: trimmed
        )
        document.add(annotation)
        scheduleAutoFade(annotation)
    }

    /// Replaces the text of an existing text annotation.
    ///
    /// The id, colour and stroke width are kept, so the edit is visually
    /// continuous with what was on screen. Clearing the text deletes the
    /// annotation — there is nothing meaningful left to show.
    private func updateTextAnnotation(_ existing: Annotation, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            document.remove(id: existing.id)
            return
        }
        var updated = existing
        updated.text = trimmed
        updated.opacity = 1
        updated.bounds = Annotation.textBounds(
            for: trimmed,
            lineWidth: existing.lineWidth,
            origin: existing.path.first ?? existing.bounds.origin
        )
        document.update(updated)
        scheduleAutoFade(updated)
    }

    // MARK: - Auto-erase

    /// Fades an annotation away after the configured delay.
    ///
    /// The delay is read once, when the annotation is created: changing the
    /// setting later only affects annotations drawn afterwards. Step
    /// numbers are excluded from the timer entirely (see `isFadeable`).
    private func scheduleAutoFade(_ annotation: Annotation) {
        guard settings.autoFadeSeconds > 0, annotation.isFadeable else { return }
        let id = annotation.id
        let delay = settings.autoFadeSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            self?.fadeOut(id: id)
        }
    }

    /// Animates one annotation's opacity down and then removes it.
    ///
    /// None of the fade steps nor the final removal enter the undo history
    /// (`recordHistory: false`): the timer is not a user decision, so undo
    /// stays reserved for the actions the user actually took. Each step
    /// re-reads the annotation, so anything that happens in flight — an
    /// undo, a manual delete, an edit — is respected and quietly ends the
    /// fade; turning the setting off mid-fade abandons the fade too.
    private func fadeOut(id: Annotation.ID) {
        Task { @MainActor [weak self] in
            let steps = 5
            for _ in 0..<steps {
                guard let self,
                      self.settings.autoFadeSeconds > 0,
                      let current = self.document.annotations.first(where: { $0.id == id })
                else { return }

                var fading = current
                fading.opacity = max(fading.opacity - 1 / Double(steps), 0)
                self.document.update(fading, recordHistory: false)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard let self, self.settings.autoFadeSeconds > 0 else { return }
            self.document.remove(id: id, recordHistory: false)
        }
    }

    // MARK: - Recording

    /// Starts or stops the presentation recording.
    ///
    /// Non-async entry point for toolbar buttons, menu items and the hot
    /// key; the async work runs on the coordinator's actor context.
    public func toggleRecording() {
        Task { await runToggleRecording() }
    }

    /// Quits the app, finalizing a running recording first.
    public func quitOvermark() {
        Task {
            if recordingState.isActive {
                await runStopRecording()
            }
            NSApp.terminate(nil)
        }
    }

    private func runToggleRecording() async {
        if recordingState.allowsStart {
            await startRecording()
        } else {
            await runStopRecording()
        }
    }

    /// Starts the recording: sorts out permissions, gathers the window
    /// numbers that must be excluded and kicks the capture actor.
    public func startRecording() async {
        guard recordingState.allowsStart else { return }

        guard mode != .idle else {
            lastError = L10n.tr("Start a presentation first to record it.")
            return
        }

        if permissions.screenRecording.isGranted {
            // Already granted: nothing to ask.
        } else {
            let granted = await requestPermission(.screenRecording)
            guard granted else {
                lastError = L10n.tr("Overmark needs Screen Recording access to record.")
                return
            }
        }
        permissions = permissionService.state

        // The microphone was never requested → ask now. If the user has
        // previously chosen Don't Allow, record without sound rather than
        // refusing to record at all.
        let includeMicrophone: Bool
        if recorderSettings.includesMicrophone {
            switch microphonePermission {
            case .notDetermined:
                _ = await requestPermission(.microphone)
            default:
                break
            }
            includeMicrophone = microphonePermission.isGranted
            if !includeMicrophone {
                lastError = L10n.tr("Microphone access is off — recording without sound.")
            }
        } else {
            includeMicrophone = false
        }

        let windowsToExclude = Set(excludedWindowNumbers())
        var settings = recorderSettings
        settings.includesMicrophone = includeMicrophone
        let (displayID, displayWarning) = resolveRecordingDisplayID()
        let configuration = PresentationRecorder.Configuration(
            displayID: displayID,
            excludedWindowNumbers: windowsToExclude,
            settings: settings,
            destinationFolder: recordingsFolderURL,
            windowChoice: settings.target == .window ? settings.windowChoice : nil,
            annotationsProvider: { [recordingAnnotations] in
                recordingAnnotations.current()
            }
        )

        recordingState = .recording(startedAt: Date.now)
        do {
            let url = try await runStartRecording(with: configuration)
            // Non-fatal notices: the recording is up, the user just should
            // know the compromises it is running with.
            var notices: [String] = []
            if let displayWarning {
                notices.append(displayWarning)
            }
            if !includeMicrophone, recorderSettings.includesMicrophone {
                notices.append(L10n.tr("Microphone access is off — recording without sound."))
            }
            if !notices.isEmpty {
                lastError = notices.joined(separator: " ")
            }
            _ = url
        } catch {
            recordingState = .idle
            lastError = L10n.tr("Could not start the recording:") + " \(error.localizedDescription)"
        }
    }

    /// Starts the recorder, falling back to the full display when the
    /// window target cannot find its window anymore (it was closed or
    /// retitled since it was picked).
    private func runStartRecording(
        with configuration: PresentationRecorder.Configuration
    ) async throws -> URL {
        do {
            return try await recorder.start(configuration)
        } catch let error as RecorderDisplayError where error == .windowGone {
            var fallback = configuration
            fallback.windowChoice = nil
            lastError = L10n.tr("The chosen recording window is not available; recording the full screen.")
            return try await recorder.start(fallback)
        }
    }

    /// Re-lists the recordable windows for the settings pickers. Only the
    /// titled windows of other apps are offered: an unlabeled window cannot
    /// be re-found reliably across app launches.
    public func refreshRecordableWindows() async {
        guard permissions.screenRecording.isGranted else {
            recordableWindows = []
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let ownBundle = Bundle.main.bundleIdentifier
            var choices: [RecordingWindowChoice] = []
            var seen = Set<RecordingWindowChoice>()
            for window in content.windows {
                guard let title = window.title, !title.isEmpty,
                      window.frame.width >= 150,
                      window.frame.height >= 100,
                      let owner = window.owningApplication?.applicationName,
                      window.owningApplication?.bundleIdentifier != ownBundle else {
                    continue
                }
                let choice = RecordingWindowChoice(title: title, ownerName: owner)
                if seen.insert(choice).inserted {
                    choices.append(choice)
                }
            }
            choices.sort { first, second in
                if first.ownerName != second.ownerName {
                    return first.ownerName < second.ownerName
                }
                return first.title < second.title
            }
            recordableWindows = choices
        } catch {
            // Keep the previous list; the settings view shows the stale
            // pick as unavailable.
        }
    }


    /// Stops the recording and finalizes the file. Runs even without the
    /// overlays up: ESC leaves the presentation, the recording still banks.
    public func stopRecording() {
        Task { await runStopRecording() }
    }

    private func runStopRecording() async {
        guard recordingState.isActive else { return }
        recordingState = .finishing

        let outcome = await recorder.stop()
        recordingState = .idle
        lastRecordingURL = outcome.url

        if let failure = outcome.streamFailure {
            // The display went away mid-session; the prefix that was
            // captured is complete, so it is a warning, not a loss.
            lastError = L10n.tr("The recording stopped early, but what was captured was saved:")
                + " \(failure.localizedDescription)"
        } else if outcome.videoFramesAppended == 0 && outcome.audioBuffersAppended == 0 {
            lastError = L10n.tr("The recording ended up empty.")
        }
    }

    /// Reveals the last finished recording in Finder (the row is selected),
    /// so the presenter can rename, share or move the `.mov` right away.
    public func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The chrome windows no recording should include.
    private func excludedWindowNumbers() -> [Int] {
        var numbers = onRecordingExcludedWindows()
        if let toolbar {
            numbers.append(contentsOf: toolbar.chromeWindowNumbers())
        }
        if let number = textEditorWindow?.windowNumber {
            numbers.append(number)
        }
        return numbers
    }

    // MARK: - Save folder

    /// Resolves the saved display policy against the screens present right
    /// now, returning the `CGDirectDisplayID` to capture plus an optional
    /// warning when a fallback had to happen.
    ///
    /// Resolution runs through `NSScreen` (which needs no permission) and
    /// matches on the localized name the user picked. A single-screen Mac
    /// trivially records its only display.
    private func resolveRecordingDisplayID() -> (CGDirectDisplayID, String?) {
        switch recorderSettings.displayChoice {
        case .main:
            return (CGMainDisplayID(), nil)
        case .namedScreen(let name):
            let screens = NSScreen.screens
            guard screens.count > 1 else {
                return (CGMainDisplayID(), nil)
            }
            if let screen = screens.first(where: { $0.localizedName == name }) {
                if let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    return (value.uint32Value, nil)
                }
            }
            // The chosen screen is unplugged or was renamed: the
            // presentation still needs its video, so the main display
            // steps in and the notice explains it.
            return (
                CGMainDisplayID(),
                L10n.tr("The chosen recording screen is not available; recording the main display.")
            )
        }
    }

    /// Opens a folder picker and stores the user's pick as the recordings
    /// destination. `runModal` keeps working from a menu-bar-only app; the
    /// `recorderSettings` setter renormalizes and persists on its own.
    public func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = recordingsFolderURL
        panel.prompt = L10n.tr("Choose")
        panel.message = L10n.tr("Overmark will save presentations here.")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorderSettings.folderPath = url.path
    }

    /// Puts recordings back into the default folder (`~/Movies/Overmark`).
    public func resetRecordingsFolder() {
        recorderSettings.folderPath = nil
    }

    /// The folder recordings land in: the user's choice, or the default
    /// (`~/Movies/Overmark`). Created by the recorder on first use.
    public var recordingsFolderURL: URL {
        if let path = recorderSettings.folderPath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Self.defaultRecordingsFolder()
    }

    /// Where recordings land. Created by the recorder on first use.
    public static func defaultRecordingsFolder() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return movies.appendingPathComponent("Overmark", isDirectory: true)
    }

    // MARK: - Recorder settings storage

    private static let recorderSettingsKey = "Overmark.recorderSettings"

    private static func storedRecorderSettings() -> RecorderSettings {
        guard let data = UserDefaults.standard.data(forKey: recorderSettingsKey),
              let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data) else {
            return RecorderSettings()
        }
        return settings
    }

    private static func persist(_ settings: RecorderSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: recorderSettingsKey)
    }

    /// Copies a fresh screenshot of the whole desktop to the clipboard.
    public func copyScreenshot() async {
        guard let image = await captureDesktopImage() else {
            lastError = L10n.tr("Could not capture the screen.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // `NSImage` already conforms to `NSPasteboardWriting`, so no adapter
        // is needed to put a captured screen on the clipboard.
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    /// Saves a fresh screenshot of the whole desktop to disk.
    public func saveScreenshot() async {
        guard let image = await captureDesktopImage() else {
            lastError = L10n.tr("Could not capture the screen.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Overmark-\(Date.now.formatted(.iso8601.year().month().day()))"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return }

        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// A tiny lock-protected snapshot of the annotations the window recorder
/// burns into the frames.
///
/// The document lives on the main actor; the recorder's callback queue fires
/// at 30–60 fps and cannot touch it. Every document change posts its
/// annotations here, and the burn-in reads the latest set per frame — the
/// presentation keeps drawing while the recording runs.
private final class RecordingAnnotationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var annotations: [Annotation] = []

    func set(_ annotations: [Annotation]) {
        lock.lock()
        defer { lock.unlock() }
        self.annotations = annotations
    }

    func current() -> [Annotation] {
        lock.lock()
        defer { lock.unlock() }
        return annotations
    }
}
