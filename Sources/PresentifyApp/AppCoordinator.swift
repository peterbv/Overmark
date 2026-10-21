import AppKit
import Foundation
import PresentifyCapture
import PresentifyCore
import PresentifyCursor
import PresentifyHotkeys
import PresentifyOverlay
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
            syncStepNumber()
        }
    }

    /// The selected tool, colour and width.
    @Published public var settings = ToolSettings() {
        didSet { overlay.apply(settings: settings) }
    }

    /// The cursor effects currently enabled.
    ///
    /// The effects are applied without rebuilding their windows unless the
    /// change genuinely needs one (see `CursorEffectController.apply`),
    /// which keeps the spotlight/zoom controls smooth while they change.
    @Published public var cursorEffects = CursorEffects() {
        didSet { Task { await effectController.apply(effects: cursorEffects) } }
    }

    /// The most recent error message, shown in the UI.
    @Published public var lastError: String?

    /// The app's user-facing language, shown in the General settings tab.
    ///
    /// Every window re-renders when this changes because all of them observe
    /// the coordinator; the status-bar menu rebuilds on the same signal.
    @Published public var language: L10n.Language = .spanish {
        didSet {
            guard language != oldValue else { return }
            L10n.selected = L10n.resolve(language)
            UserDefaults.standard.set(language.rawValue, forKey: "Presentify.language")
        }
    }

    /// The permission state.
    @Published public private(set) var permissions: PermissionState = PermissionState()

    private let captureService: ScreenCaptureService
    private let overlay: OverlayController
    private let effectController: CursorEffectController
    private let hotKeys: HotKeyManager
    private let cursorTracker: CursorTracker
    private let permissionService: PermissionService
    /// The floating control bar shown while annotating.

    /// Opens the app's settings window; wired by the app delegate, which
    /// owns that window.
    public var onShowAppSettings: (() -> Void)?

    /// The floating control bar shown while annotating.
    private var toolbar: AnnotationToolbarController?

    /// Retains the delegate of the text editor window.
    ///
    /// `NSWindow` holds its delegate weakly, so it has to be kept alive
    /// somewhere for as long as the editor is open.
    private var textEditorDelegate: TextEditorWindowDelegate?

    public init() {
        let captureService = ScreenCaptureService()
        let cursorTracker = CursorTracker()
        let overlay = OverlayController(captureService: captureService)

        self.captureService = captureService
        self.cursorTracker = cursorTracker
        self.overlay = overlay
        self.effectController = CursorEffectController(captureService: captureService)
        self.hotKeys = HotKeyManager()
        self.permissionService = PermissionService(
            captureService: captureService,
            cursorTracker: cursorTracker
        )

        hotKeys.onAction = { [weak self] action in
            self?.handle(action)
        }

        // The pointer position drives the cursor effects. The tracker only
        // runs while the Accessibility permission is granted.
        cursorTracker.onMove = { [weak self] point in
            self?.effectController.updateCursorLocation(point)
        }

        overlay.bind(
            onAnnotationCreated: { [weak self] annotation in
                self?.document.add(annotation)
            },
            onClick: { [weak self] point in
                self?.handleCanvasClick(at: point)
            }
        )

        hotKeys.registerDefaults()
        permissionService.refresh()
        permissions = permissionService.state

        // Restore the persisted language before any view is built so the
        // onboarding window and the status-bar menu come up translated.
        let stored = L10n.Language(
            rawValue: UserDefaults.standard.string(forKey: "Presentify.language") ?? ""
        ) ?? .spanish
        L10n.selected = L10n.resolve(stored)
        self.language = stored

        toolbar = AnnotationToolbarController(coordinator: self)
    }

    // MARK: - Lifecycle

    /// Starts the app: registers permissions refresh and enables cursor
    /// tracking when it is allowed.
    public func start() {
        permissionService.refresh()
        permissions = permissionService.state

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
        mode = .idle
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
        guard !permissions.screenRecording.isGranted else {
            await presentOverlays()
            return
        }

        let granted = await requestPermission(.screenRecording)
        guard granted else {
            lastError = L10n.tr("Presentify needs Screen Recording access to capture the screen.")
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

    /// Shows the overlays, capturing the screen first.
    private func presentOverlays() async {
        do {
            let snapshots = try await captureService.captureAllDisplays()
            guard !snapshots.isEmpty else {
                lastError = L10n.tr("No displays were available to annotate.")
                return
            }

            // The overlay renders on every display, and each panel shows the
            // screenshot of its own display so a multi-monitor setup does not
            // repeat the first screen on every panel.
            let backgrounds = Dictionary(
                uniqueKeysWithValues: snapshots.map { ($0.displayID, $0.image) }
            )
            await overlay.showOverlays(backgrounds: backgrounds)

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
        } catch {
            lastError = "\(L10n.tr("Could not capture the screen:")) \(error.localizedDescription)"
        }
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

    /// Captures the screen and returns the resulting image.
    ///
    /// The annotations are composited on top of the capture, because the
    /// overlay lives in the app's own windows and would not otherwise appear
    /// in the screenshot.
    ///
    /// Returns `nil` when the capture fails, for example because Screen
    /// Recording access has not been granted.
    private func captureCurrentScreenImage() async -> CGImage? {
        guard let snapshots = try? await captureService.captureAllDisplays(),
              let snapshot = snapshots.first else {
            return nil
        }
        return AnnotationCompositor.composited(
            image: snapshot.image,
            annotations: document.annotations,
            screen: snapshot.screen
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
        case .undo:
            undo()
        case .redo:
            redo()
        case .copyScreenshot:
            Task { await copyScreenshot() }
        case .saveScreenshot:
            Task { await saveScreenshot() }
        case .quit:
            NSApp.terminate(nil)
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

    /// Opens the text editor and adds the resulting annotation.
    private func presentTextEditor(at point: Point) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Add Text")
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
                color: settings.color,
                lineWidth: settings.lineWidth,
                onCancel: { [weak self] in
                    window.close()
                    self?.endTextEditing()
                },
                onCommit: { [weak self] text in
                    window.close()
                    self?.endTextEditing()
                    self?.addTextAnnotation(text, at: point)
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

        let size = Size(
            width: max(Double(trimmed.count) * 9, 12),
            height: 20
        )
        let annotation = Annotation(
            tool: .text,
            color: settings.color,
            lineWidth: settings.lineWidth,
            path: [point],
            bounds: Rect(origin: point, size: size),
            text: trimmed
        )
        document.add(annotation)
    }

    /// Copies a fresh screenshot of the screen to the clipboard.
    public func copyScreenshot() async {
        guard let image = await captureCurrentScreenImage() else {
            lastError = L10n.tr("Could not capture the screen.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // `NSImage` already conforms to `NSPasteboardWriting`, so no adapter
        // is needed to put a captured screen on the clipboard.
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    /// Saves a fresh screenshot to disk.
    public func saveScreenshot() async {
        guard let image = await captureCurrentScreenImage() else {
            lastError = L10n.tr("Could not capture the screen.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Presentify-\(Date.now.formatted(.iso8601.year().month().day()))"

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
