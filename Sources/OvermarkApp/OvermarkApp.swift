import AppKit
import Combine
import SwiftUI

/// The main application.
///
/// Overmark is a menu bar app: it has no Dock icon and no main window. The
/// annotation overlay and the cursor effects are drawn on top of whatever the
/// user is presenting, and a small settings window is available on demand.
@main
struct OvermarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(coordinator: delegate.coordinator)
        }
    }
}

/// Wires the coordinator to the menu bar and manages the app lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared coordinator. Also reachable from the settings scene.
    let coordinator = AppCoordinator()

    private var menuBar: MenuBarController?
    /// Observes coordinator changes to rebuild the menu.
    ///
    /// This used to be a `for await _ in coordinator.objectWillChange.values`
    /// loop, which dropped the app with a Combine backpressure fatal error
    /// ("Received an output without requesting demand") whenever the publisher
    /// fired in bursts — for example while toggling the zoom lens or entering
    /// annotation mode. A plain Combine subscription has no such race.
    private var statusObserver: AnyCancellable?
    /// Retains the settings window so repeated "Settings…" clicks reuse it.
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is a menu bar utility: it stays out of the Dock and out of
        // the app switcher.
        NSApp.setActivationPolicy(.accessory)

        let menuBar = MenuBarController()
        self.menuBar = menuBar
        wire(menuBar)

        coordinator.start()
        refreshMenu()
        coordinator.onShowAppSettings = { [weak self] in
            self?.openSettings()
        }
        // The settings and onboarding windows belong to the delegate, so it
        // is the one that knows which window numbers must stay off tape.
        coordinator.onRecordingExcludedWindows = { [weak self] in
            var numbers: [Int] = []
            if let number = self?.settingsWindow?.windowNumber {
                numbers.append(number)
            }
            return numbers
        }

        // The overlay and the document change in response to hot keys and to
        // the user's drawing, so the menu is refreshed whenever they change.
        statusObserver = coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenu()
            }

        showOnboardingIfNeeded()

        if ProcessInfo.processInfo.environment["OVERMARK_PROBE"] == "1" {
            runDiagnosticProbe()
        }
    }

    /// Runs a scripted stress pass over the known-crashy sequences.
    ///
    /// Every step prints to stderr once it completed, so a crash during the
    /// run points at the phase whose step line never appears. Enabled only
    /// by launching with `OVERMARK_PROBE=1`.
    private func runDiagnosticProbe() {
        let coordinator = coordinator
        func step(_ label: String) {
            FileHandle.standardError.write(Data("[PROBE] ok: \(label)\n".utf8))
        }

        Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch {}

            let screenReport = """
            [SCREEN] count=\(NSScreen.screens.count) frames=[\(NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: ", "))] \
            mode=\(coordinator.mode) holdOpt=\(coordinator.settings.holdOptionToDraw) key=\(coordinator.drawingModifier.symbol)
            """
            FileHandle.standardError.write(Data((screenReport + "\n").utf8))

            await coordinator.enterAnnotationMode()
            step("enterAnnotationMode")
            try? await Task.sleep(nanoseconds: 800_000_000)
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))

            coordinator.cursorEffects.isHighlightEnabled = true
            try? await Task.sleep(nanoseconds: 800_000_000)
            step("highlight on")
            coordinator.cursorEffects.isHighlightEnabled = false
            try? await Task.sleep(nanoseconds: 800_000_000)
            step("highlight off (rebuild → tearDown → close)")

            coordinator.cursorEffects.isSpotlightEnabled = true
            try? await Task.sleep(nanoseconds: 800_000_000)
            step("spotlight on")

            coordinator.cursorEffects.isZoomEnabled = true
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            step("zoom on (apply → captureBackground → rebuild)")

            coordinator.cursorEffects.isZoomEnabled = false
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            step("zoom off (apply → update in place)")

            for _ in 1...12 {
                coordinator.cursorEffects.isZoomEnabled.toggle()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            step("zoom churn ×12")

            coordinator.cursorEffects.isSpotlightEnabled = false
            try? await Task.sleep(nanoseconds: 500_000_000)
            step("spotlight off")

            coordinator.toggleWhiteboard()
            try? await Task.sleep(nanoseconds: 800_000_000)
            step("whiteboard on")
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))
            coordinator.whiteboardStyle = .black
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("whiteboard tone switch in place")
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))

            coordinator.togglePause()
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("pause folds the board")
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))
            coordinator.togglePause()
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("resume restores the board")

            coordinator.toggleWhiteboard()
            try? await Task.sleep(nanoseconds: 300_000_000)
            step("whiteboard off")

            // The screen freeze captures the displays in scope and paints
            // the stills behind the canvases; both states exclude each
            // other, so freezing right after the whiteboard round-trips the
            // handoff in both directions. Unfreezing drops the stills for
            // the remainder of the session.
            await coordinator.toggleFreeze()
            try? await Task.sleep(nanoseconds: 800_000_000)
            step("freeze on (captures and paints stills)")
            FileHandle.standardError.write(Data(
                "[PROBE] freeze: active=\(coordinator.isFreezeActive) (inactive means this build lacks the Screen Recording grant; still-frame plumbing is verified by the compositing tests)\n".utf8
            ))
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))
            coordinator.toggleWhiteboard()
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("board replaces the freeze")
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))
            await coordinator.toggleFreeze()
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("freeze replaces the board")
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))
            await coordinator.toggleFreeze()
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("freeze off (still frame dropped)")

            coordinator.drawingModifier = .control
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("drawing key switched to control in place")
            FileHandle.standardError.write(Data("\(coordinator.debugOverlayState())\n".utf8))
            coordinator.drawingModifier = .option
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("drawing key back to option")

            // The laser pointer toggles like the other cursor effects: apply
            // keeps the existing windows instead of rebuilding, and turning
            // it off forgets the tail (box and views drop their trails).
            coordinator.cursorEffects.isLaserEnabled = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            step("laser pointer on")
            FileHandle.standardError.write(Data(
                "[PROBE] laser: \(coordinator.cursorEffects.isLaserEnabled), radius \(coordinator.cursorEffects.laserRadius)\n".utf8
            ))
            coordinator.cursorEffects.isLaserEnabled = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("laser pointer off")

            // The selection mode: gestures highlight or move what is already
            // drawn. Toggling pushes the state to the canvases (and back off
            // leaves a drawing-first gesture set).
            coordinator.isSelectionMode = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("selection mode on")
            FileHandle.standardError.write(Data(
                "[PROBE] selection: \(coordinator.isSelectionMode), state \(coordinator.debugOverlayState())\n".utf8
            ))
            coordinator.isSelectionMode = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("selection mode off")

            // The configured dock: moving the edge re-docks a live bar in
            // place, so a right-hand session keeps its tab on the right
            // even when the presenter re-pins.
            coordinator.toolbarDock = .trailing
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("toolbar re-docked trailing")
            coordinator.toolbarDock = .bottom
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("toolbar re-docked bottom")
            FileHandle.standardError.write(Data(
                "[PROBE] dock: \(coordinator.toolbarDock)\n".utf8
            ))
            coordinator.toolbarDock = .top
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("toolbar re-docked top")

            // The configurable lens exercises the in-place update path:
            // resizing, then the quick refresh cadence, then mirroring (a
            // toggle the refresh loop starts pushing to other displays on
            // the next tick), and finally everything back off.
            coordinator.cursorEffects.isZoomEnabled = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("zoom back on for lens settings")
            coordinator.cursorEffects.zoomSize = 380
            try? await Task.sleep(nanoseconds: 300_000_000)
            step("lens resized in place")
            FileHandle.standardError.write(Data(
                "[PROBE] lens size: \(coordinator.cursorEffects.zoomSize), rate: \(coordinator.cursorEffects.lensRefreshRate)\n".utf8
            ))
            coordinator.cursorEffects.lensRefreshRate = .responsive
            try? await Task.sleep(nanoseconds: 500_000_000)
            step("lens refresh quick")
            coordinator.cursorEffects.isLensMirrored = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            step("lens mirrored")
            coordinator.cursorEffects.isLensMirrored = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("lens unmirrored (rebuild hands back own snapshots)")
            coordinator.cursorEffects.isZoomEnabled = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            step("zoom off after lens settings")

            await coordinator.toggleAnnotationMode()
            step("exitAnnotationMode")
            try? await Task.sleep(nanoseconds: 400_000_000)

            await coordinator.toggleAnnotationMode()
            step("re-enterAnnotationMode")
            try? await Task.sleep(nanoseconds: 800_000_000)

            coordinator.exitAnnotationMode()
            step("final exitAnnotationMode")

            FileHandle.standardError.write(Data("[PROBE] all steps done, exiting cleanly\n".utf8))
            exit(0)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The permissions are granted in System Settings, which brings the
        // app to the front only after the user comes back to it. Re-reading
        // the state here is what makes a freshly granted permission take
        // effect without restarting Overmark.
        coordinator.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusObserver = nil
        coordinator.stop()
    }

    // MARK: - Private

    private func wire(_ menuBar: MenuBarController) {
        menuBar.onToggleAnnotation = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.toggleAnnotationMode() }
        }
        menuBar.onTogglePause = { [weak self] in
            self?.coordinator.togglePause()
        }
        menuBar.onToggleWhiteboard = { [weak self] in
            self?.coordinator.toggleWhiteboard()
        }
        menuBar.onToggleFreeze = { [weak self] in
            Task { await self?.coordinator.toggleFreeze() }
        }
        menuBar.onUndo = { [weak self] in
            self?.coordinator.undo()
        }
        menuBar.onRedo = { [weak self] in
            self?.coordinator.redo()
        }
        menuBar.onCopyScreenshot = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.copyScreenshot() }
        }
        menuBar.onSaveScreenshot = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.saveScreenshot() }
        }
        menuBar.onExportPNG = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.exportPNG() }
        }
        menuBar.onExportPDF = { [weak self] in
            guard let self else { return }
            Task { await self.coordinator.exportPDF() }
        }
        menuBar.onShowSettings = { [weak self] in
            self?.openSettings()
        }
        menuBar.onToggleRecording = { [weak self] in
            self?.coordinator.toggleRecording()
        }
        menuBar.onSelectPresentationScope = { [weak self] scope in
            self?.coordinator.setPresentationScope(scope)
        }
        menuBar.onQuit = { [weak self] in
            self?.coordinator.quitOvermark()
        }
    }

    private func refreshMenu() {
        menuBar?.update(
            mode: coordinator.mode,
            isRecording: coordinator.recordingState.isActive,
            scope: coordinator.presentationScope,
            isWhiteboard: coordinator.isWhiteboardActive,
            isFreeze: coordinator.isFreezeActive,
            screenNames: coordinator.screenNames,
            canUndo: coordinator.document.canUndo,
            canRedo: coordinator.document.canRedo
        )
    }

    /// Opens the app's settings window.
    ///
    /// The SwiftUI `Settings` scene places its window at the normal level,
    /// which sits *below* the annotation panels: while annotating, the
    /// window would open behind the overlays and selecting Settings would
    /// look like nothing happened. Hosting the view in a window the
    /// delegate owns lets this window float above the panels instead, so it
    /// is reachable at any time — mid-presentation included.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Overmark Settings")
        window.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator))
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// Shows the onboarding window the first time the app is launched.
    ///
    /// The window is only presented when a permission is missing, so a user
    /// who has already granted them never sees it again.
    private func showOnboardingIfNeeded() {
        coordinator.refreshPermissions()
        guard !coordinator.permissions.isFullyGranted else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Overmark Setup")
        // Not strongly retained by the delegate, so it must not self-release
        // on close (same over-release risk as the text editor window).
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OnboardingView(coordinator: coordinator)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
