import AppKit
import Foundation
import OvermarkCapture
import OvermarkCore
import OvermarkCursor
import OvermarkHotkeys
import OvermarkOverlay
import OvermarkRecorder
import ScreenCaptureKit
import UniformTypeIdentifiers
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
        didSet {
            overlay.setInteractionEnabled(mode.allowsDrawing)
            // Pausing folds the board away so the desktop interaction window
            // behaves normally; the whiteboard returns with the session.
            // The frozen frame folds the same way.
            overlay.setBoardVisible(mode != .paused)
            overlay.setFreezeVisible(mode != .paused)
        }
    }

    /// The annotations and their undo history.
    @Published public private(set) var document = AnnotationDocument() {
        didSet {
            overlay.setAnnotations(document.annotations)
            // The window recorder draws whatever is on the canvas right
            // now; keep its snapshot in step with every document change.
            recordingAnnotations.set(document.annotations)
            syncStepNumber()
            scheduleAutosave()
            // The selection cannot outlive its annotations: a delete, a
            // fade or a restore that lost ids prunes the selection itself,
            // so the chrome never highlights ghosts.
            let existing = Set(document.annotations.map(\.id))
            if !selectionIDs.isSubset(of: existing) {
                selectionIDs = selectionIDs.intersection(existing)
            }
        }
    }

    /// Documents saved to the archive, newest first.
    @Published public private(set) var savedDocuments: [SessionArchive.Entry] = []

    /// The lowest step number that the next stamp must respect.
    ///
    /// Auto-erase can remove a stamp that holds the highest issued number;
    /// the document keeps its counter derived from what is present, so
    /// without this floor the next stamp would reuse a number that already
    /// faded on screen. Fades raise the floor; clearing the canvas or
    /// restoring a saved document resets it, restarting the numbering.
    private var stepNumberFloor = 0

    /// Whether the dedicated whiteboard is currently covering the screens.
    ///
    /// The board is an overlay state inside the running session, not a
    /// separate mode: while the session is up, this folds the desktop away
    /// and draws a blank board instead.
    @Published public private(set) var isWhiteboardActive = false {
        didSet { overlay.setWhiteboard(isWhiteboardActive, style: whiteboardStyle) }
    }

    /// The tone the whiteboard surface is painted with; persists between
    /// launches.
    @Published public var whiteboardStyle: BoardStyle = .white {
        didSet {
            PreferencesStore.save(whiteboardStyle)
            overlay.setWhiteboard(isWhiteboardActive, style: whiteboardStyle)
        }
    }

    /// Which screen edge the floating toolbar docks on, and where its
    /// collapsed tab always waits. Persisted between launches.
    @Published public var toolbarDock: ToolbarDock = .top {
        didSet {
            guard toolbarDock != oldValue else { return }
            PreferencesStore.save(toolbarDock)
            toolbar?.reapplyDock()
        }
    }

    /// Whether the screens show a frozen frame instead of the live desktop.
    ///
    /// Like the board, the freeze is an overlay state inside the running
    /// session: the coordinator captures the displays in scope once, hands
    /// the frames to the overlays and the canvases paint them behind the
    /// marks, so the backdrop stands still while the apps underneath keep
    /// running. Pausing folds it away like the board; exiting the session
    /// drops it.
    @Published public private(set) var isFreezeActive = false {
        didSet { overlay.setFreeze(isFreezeActive, images: freezeImages) }
    }

    /// The frozen frames per display, kept next to the overlay's own copies
    /// so copies and saves can answer "what did the audience see" without
    /// touching the live screen.
    private var freezeImages: [CGDirectDisplayID: CGImage] = [:]

    /// Whether clicks are routed to marquee selection instead of drawing.
    ///
    /// Like the board and the freeze, selection is an overlay session state:
    /// gestures highlight or move what is already drawn instead of creating
    /// new marks. Turning the mode off clears the selection.
    @Published public var isSelectionMode = false {
        didSet {
            guard isSelectionMode != oldValue else { return }
            overlay.setSelectionMode(isSelectionMode)
            if !isSelectionMode {
                selectionIDs = []
            }
        }
    }

    /// The annotation ids highlighted by the selection gesture.
    @Published public private(set) var selectionIDs: Set<Annotation.ID> = [] {
        didSet { overlay.setSelection(selectionIDs) }
    }

    /// The key the user holds to draw while the hold-to-draw gate is on
    /// (⌥ by default, ⌃/⌘ selectable); persists between launches.
    public var drawingModifier: DrawingModifier = .option {
        didSet {
            PreferencesStore.save(drawingModifier)
            overlay.setDrawingModifier(drawingModifier)
        }
    }

    /// Debounced autosave; cancelled and rescheduled as the document churns.
    private var autosaveTask: Task<Void, Never>?

    /// The selected tool, colour and width.
    ///
    /// Changes persist between launches: the whole struct is written through
    /// to user defaults on every change.
    @Published public var settings = ToolSettings() {
        didSet {
            // Recolor offsets the selection while the mode is on: every
            // selected annotation picks the newly chosen colour (and stops
            // any gradient it had), as one undo step per palette pick.
            if isSelectionMode, !selectionIDs.isEmpty, oldValue.color != settings.color {
                applyAnnotationEdits(
                    document.annotations
                        .filter { selectionIDs.contains($0.id) }
                        .map { $0.with(color: settings.color) }
                )
            }
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
            recordingEffects.updateEffects(cursorEffects)
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

    /// Observes the distributed notification macOS posts when the
    /// Accessibility permission list changes, so the ⌥ pass-through recovers
    /// the moment the user re-grants it — without restarting the app.
    private var accessibilityObserver: (any NSObjectProtocol)?

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
    /// Burn-in feed for cursor effects (ring, spotlight, lens, ripples) in
    /// window recordings. Updated alongside the on-screen effects and fed to
    /// the recorder at start.
    private let recordingEffects = CursorEffectBox()
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
        whiteboardStyle = PreferencesStore.loadWhiteboardStyle()
        drawingModifier = PreferencesStore.loadDrawingModifier()
        // The toolbar exists until later in this initializer, so the dock
        // didSet may find no bar to move; `show` reads the restored dock
        // when the first session begins.
        toolbarDock = PreferencesStore.loadToolbarDock()

        hotKeys.onAction = { [weak self] action in
            self?.handle(action)
        }

        // The pointer position drives the cursor effects. The tracker only
        // runs while the Accessibility permission is granted.
        // didSet observers do not fire during init, so the fresh burn-in
        // box gets the stored effect settings explicitly too.
        recordingEffects.updateEffects(cursorEffects)
        cursorTracker.onMove = { [weak self] point in
            self?.effectController.updateCursorLocation(point)
            self?.recordingEffects.updateCursor(point)
        }

        updateClickMonitor()

        // Accessibility changes are announced system-wide ("Accesibilidad"
        // pane in System Settings toggles the app in or out). Reacting here
        // makes the degraded "capture mode" chip disappear and the ⌥
        // pass-through come back live the moment the user re-grants.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
            }
        }

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
            },
            onSelectionCommitted: { [weak self] ids in
                self?.selectionIDs = ids
            },
            onSelectionMoved: { [weak self] edits in
                self?.applyAnnotationEdits(edits)
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

        // Bring back whatever the previous session was annotating on, so a
        // relaunch never drops the user's work without a trace.
        restoreAutosavedDocument()

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
        // A quit must not lose the tail of the session: flush now rather
        // than wait out the autosave debounce.
        persistAutosave()
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
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
        mode = .idle
        // The recorder is deliberately untouched here: a running or
        // finishing recording is finalized by `runStopRecording()`, which
        // `prepareForTermination` awaits from `applicationShouldTerminate`
        // before the process is allowed to die.
    }

    /// Lets the host wait out a recording before the process dies: `done`
    /// runs after a running or finishing recording is finalized — or right
    /// away when none is. Wired to `applicationShouldTerminate`, so ⌘Q,
    /// logout and AppleScript quits finalize the file the same way the
    /// menu's Quit command does.
    public func prepareForTermination(_ done: @escaping () -> Void) {
        guard recordingState.isActive else {
            done()
            return
        }
        Task {
            await runStopRecording()
            done()
        }
    }

    // MARK: - Documents

    /// Restores what the previous session was annotating on.
    private func restoreAutosavedDocument() {
        let snapshot = SessionArchive.loadAutosave()
        savedDocuments = SessionArchive.listSnapshots()
        guard let snapshot, !snapshot.annotations.isEmpty else { return }
        document = AnnotationDocument(annotations: snapshot.annotations)
        // The content is already on disk; skip the debounced rewrite.
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Publishes a debounced autosave of the current document.
    ///
    /// Drawing floods `document` with changes; the delay collapses each
    /// burst into one final write, and an empty document clears the slot
    /// right away so a cleaned canvas does not resurrect stale strokes.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard !document.isEmpty else {
            persistAutosave()
            return
        }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.persistAutosave()
        }
    }

    /// Writes the autosave slot synchronously. Main actor only.
    private func persistAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        let snapshot = SessionSnapshot(
            screens: screenFrames(),
            annotations: document.annotations
        )
        try? SessionArchive.autosaveSnapshot(snapshot)
    }

    /// Captures the current display layout as global AppKit frames.
    private func screenFrames() -> [ScreenFrame] {
        NSScreen.screens.map { screen in
            ScreenFrame(
                origin: Point(
                    x: screen.frame.origin.x,
                    y: screen.frame.origin.y
                ),
                size: Size(
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                scale: screen.backingScaleFactor
            )
        }
    }

    /// Saves the current document to the archive under a name and refreshes
    /// the list.
    public func saveAnnotationDocument(named name: String) {
        let snapshot = SessionSnapshot(
            screens: screenFrames(),
            annotations: document.annotations
        )
        _ = try? SessionArchive.saveSnapshot(snapshot, name: name)
        reloadSavedDocuments()
    }

    /// Puts a saved document back on the canvas.
    public func restoreSavedDocument(_ entry: SessionArchive.Entry) {
        // The restored stamps define the counter from their own numbers.
        stepNumberFloor = 0
        document = AnnotationDocument(annotations: entry.snapshot.annotations)
        // The step counter follows the restored annotations.
        syncStepNumber()
        // The restored content is not an autosave of itself; skip the write.
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// Removes a document from the archive and refreshes the list.
    public func deleteSavedDocument(_ entry: SessionArchive.Entry) {
        try? SessionArchive.deleteSnapshot(named: entry.name)
        reloadSavedDocuments()
    }

    /// Rebuilds the saved-documents list from disk.
    public func reloadSavedDocuments() {
        savedDocuments = SessionArchive.listSnapshots()
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
            // With the permission back, the ⌥ tap can now be created; the
            // overlay recovers its pass-through without a rebuild.
            overlay.retryOptionMonitoring(settings.holdOptionToDraw)
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
        // The session ends here; whatever is drawn gets captured on disk
        // right away instead of waiting for the autosave debounce.
        persistAutosave()
        toolbar?.hide()
        hotKeys.unregisterEscape()
        overlay.tearDown()
        mode = .idle
        // The board is a state of the running session: leaving it up would
        // surprise the next session, since the panels rebuild honouring it.
        isWhiteboardActive = false
        // So is the frozen frame: a next session starts over the live
        // desktop, not over yesterday's still.
        freezeImages = [:]
        isFreezeActive = false
        // And the selection: a next session draws first and selects only
        // from a blank slate.
        isSelectionMode = false
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

    /// Switches the session between the see-through overlay and the
    /// dedicated whiteboard.
    ///
    /// Only meaningful while a session is up: with the board on, the screens
    /// in scope show a blank surface to draw on instead of the desktop, and
    /// every click goes to the canvas. Pausing temporarily folds the board
    /// back to the desktop view, and exiting the session turns it off for
    /// the next one.
    public func toggleWhiteboard() {
        guard mode != .idle else { return }
        isWhiteboardActive.toggle()
        guard isWhiteboardActive else { return }
        // One surface cannot be both a blank board and a frozen frame:
        // raising the board drops the freeze.
        if isFreezeActive {
            freezeImages = [:]
            isFreezeActive = false
        }
    }

    /// Toggles the marquee-selection mode.
    ///
    /// Selection is a state of the running session, like the board and the
    /// freeze: while it is on, gestures highlight or move what is already
    /// drawn instead of creating new marks.
    public func toggleSelectionMode() {
        guard mode != .idle else { return }
        isSelectionMode.toggle()
    }

    /// Flips the floating toolbar between the minimized (essentials only)
    /// and the full layout. The toolbar owns the state; this exposed for
    /// the probe and any future menu entry.
    public func toggleToolbarMinimized() {
        toolbar?.toggleMinimized()
    }

    /// Headless probe support: the floating bar's measured layout sizes,
    /// so a probe run logs whether the windows still hold their content
    /// (a frozen constant once clipped the expanded bar).
    public func probeToolbarSizes() -> String? {
        toolbar?.probeSummary()
    }

    /// Applies edits (moves, recolors) to specific annotations as one undo
    /// step.
    public func applyAnnotationEdits(_ edits: [Annotation]) {
        guard !edits.isEmpty else { return }
        document.update(edits)
    }

    /// Deletes every annotation in the selection.
    ///
    /// The document records the batch removal once, so a single undo
    /// restores the whole group.
    public func deleteSelection() {
        guard !selectionIDs.isEmpty else { return }
        document.remove(ids: selectionIDs)
        selectionIDs = []
    }

    /// Switches the session between the live overlay and a frozen frame of
    /// the screen.
    ///
    /// Only meaningful while a session is up: freezing captures every
    /// display in scope once and shows those frames instead of the live
    /// desktop, so the backdrop stands still while the apps underneath keep
    /// running. Annotations, the modifier gate and pausing behave exactly
    /// as with the board. Toggling the board ends the freeze and vice
    /// versa: one screen cannot be both a blank board and a frozen frame.
    public func toggleFreeze() async {
        guard mode != .idle else { return }
        if isFreezeActive {
            freezeImages = [:]
            isFreezeActive = false
            return
        }
        if isWhiteboardActive {
            // Same exclusion, the other way around: the still replaces the
            // blank board.
            isWhiteboardActive = false
        }
        let displays = overlay.scopeDisplayIDs ?? Self.attachedDisplayIDs()
        var images: [CGDirectDisplayID: CGImage] = [:]
        for displayID in displays {
            if let snapshot = try? await captureService.capture(displayID: displayID) {
                images[displayID] = snapshot.image
            }
        }
        guard !images.isEmpty else {
            // Nothing captured: the Screen Recording permission is missing
            // or no display answered. The overlay stays live instead of
            // silently freezing to black.
            lastError = L10n.tr("Overmark needs Screen Recording access to capture the screen.")
            return
        }
        freezeImages = images
        // Flipping the published flag last hands the frames to the overlays
        // from a complete dictionary.
        isFreezeActive = true
    }

    /// The frozen frame shown on a display, or `nil` when that display
    /// shows the plain see-through overlay.
    ///
    /// Screenshots exclude Overmark's own windows, so the frozen overlay
    /// never reaches the capture; answering here is what makes copies and
    /// saves match what the audience saw.
    private func frozenImage(for screen: ScreenFrame) -> CGImage? {
        guard isFreezeActive, mode != .paused else { return nil }
        let displayID = NSScreen.screens.first { candidate in
            abs(candidate.frame.origin.x - screen.origin.x) < 1
                && abs(candidate.frame.origin.y - screen.origin.y) < 1
        }.flatMap(Self.displayID(of:))
        guard let displayID else { return nil }
        if let allowed = overlay.scopeDisplayIDs, !allowed.contains(displayID) {
            return nil
        }
        return freezeImages[displayID]
    }

    /// The display ids of every attached screen, resolved without the
    /// Screen Recording permission (AppKit enumeration only).
    private static func attachedDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap(Self.displayID(of:)))
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
        // didSet observers do not fire during init, so a saved ⌃/⌘ choice
        // has to be pushed on the first overlay build of the launch.
        overlay.setDrawingModifier(drawingModifier)
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
        // A manual clear is a fresh canvas: restart the numbering too.
        stepNumberFloor = 0
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
            annotations: document.annotations,
            boardFill: { [self] screen in boardCGColor(for: screen) },
            frozenFill: { [self] screen in frozenImage(for: screen) }
        )
    }

    /// The whiteboard colour to composite over a display's capture, or `nil`
    /// when that display shows the plain see-through overlay.
    ///
    /// Screenshots exclude Overmark's own windows, so the board itself never
    /// reaches the capture; answering here is what makes copies and saves
    /// match what the audience saw.
    private func boardCGColor(for screen: ScreenFrame) -> CGColor? {
        guard isWhiteboardActive, mode != .paused else { return nil }
        // Resolve the display the frame belongs to, then clip to the
        // annotation scope the session was rebuilt with.
        let displayID = NSScreen.screens.first { candidate in
            abs(candidate.frame.origin.x - screen.origin.x) < 1
                && abs(candidate.frame.origin.y - screen.origin.y) < 1
        }.flatMap(Self.displayID(of:))
        if let allowed = overlay.scopeDisplayIDs, let displayID,
           !allowed.contains(displayID) {
            return nil
        }
        return CGColor(
            red: CGFloat(whiteboardStyle.color.red),
            green: CGFloat(whiteboardStyle.color.green),
            blue: CGFloat(whiteboardStyle.color.blue),
            alpha: 1
        )
    }

    /// Handles a global hot key action.
    private func handle(_ action: HotKeyAction) {
        switch action {
        case .toggleAnnotation:
            Task { await toggleAnnotationMode() }
        case .togglePause:
            togglePause()
        case .toggleWhiteboard:
            toggleWhiteboard()
        case .toggleFreezeScreen:
            Task { await toggleFreeze() }
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
        let isRight = event.type == .rightMouseDown
        effectController.triggerClick(point: point, isRight: isRight)
        let click = CursorClick(point: point, isRight: isRight)
        recordingEffects.appendClick(click)
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
                // Hold the window weakly: the hosting view chain reaches
                // these closures, so a strong capture here (to call close())
                // would cycle window → contentView → editor → window and
                // leak the panel after every edit.
                onCancel: { [weak self, weak window] in
                    window?.close()
                    self?.endTextEditing()
                },
                onCommit: { [weak self, weak window] (text: String) in
                    window?.close()
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
    /// or clearing annotations also rewinds the counter. The floor from the
    /// auto-erase timer keeps a stamp number from being reused after its
    /// annotation faded away (see `stepNumberFloor`).
    private func syncStepNumber() {
        let next = max(document.nextStepNumber, stepNumberFloor)
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
    /// setting later only affects annotations drawn afterwards. All drawn
    /// instruments fade, stamps included (`isFadeable`); the coordinator
    /// keeps the step counter ahead of the stamps that already faded.
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
            // Capture the stamp before it leaves the document: fades can
            // remove the stamp holding the highest issued number, and the
            // floor keeps the counter from reissuing that number later.
            let removee = self.document.annotations.first { $0.id == id }
            if let removee, removee.tool == .stepNumber {
                self.stepNumberFloor = max(self.stepNumberFloor, (removee.stepNumber ?? 0) + 1)
            }
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
            },
            effectsProvider: { [recordingEffects] in
                recordingEffects.current()
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

    /// Exports the composited session (annotations, whiteboard and frozen
    /// still included) as a PNG the user picks a path for.
    public func exportPNG() async {
        await exportSession(as: .png)
    }

    /// Exports the composited session (annotations, whiteboard and frozen
    /// still included) as a PDF the user picks a path for.
    public func exportPDF() async {
        await exportSession(as: .pdf)
    }

    private func exportSession(as format: GraphicsExportFormat) async {
        guard let image = await captureDesktopImage() else {
            lastError = L10n.tr("Could not capture the screen.")
            return
        }
        guard let data = format.encoded(from: image) else {
            lastError = L10n.tr("Overmark couldn't encode the export.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Overmark-\(Date.now.formatted(.iso8601.year().month().day()))"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = L10n.tr("Overmark couldn't save the export.")
        }
    }
}

/// Which file type the session export lands in.
private enum GraphicsExportFormat {
    case png
    case pdf

    var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        }
    }

    func encoded(from image: CGImage) -> Data? {
        switch self {
        case .png: GraphicsExport.pngData(from: image)
        case .pdf: GraphicsExport.pdfData(from: image)
        }
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
