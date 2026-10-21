import AppKit
import Combine
import SwiftUI

/// The main application.
///
/// Presentify is a menu bar app: it has no Dock icon and no main window. The
/// annotation overlay and the cursor effects are drawn on top of whatever the
/// user is presenting, and a small settings window is available on demand.
@main
struct PresentifyApp: App {
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

        // The overlay and the document change in response to hot keys and to
        // the user's drawing, so the menu is refreshed whenever they change.
        statusObserver = coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenu()
            }

        showOnboardingIfNeeded()

        if ProcessInfo.processInfo.environment["PRESENTIFY_PROBE"] == "1" {
            runDiagnosticProbe()
        }
    }

    /// Runs a scripted stress pass over the known-crashy sequences.
    ///
    /// Every step prints to stderr once it completed, so a crash during the
    /// run points at the phase whose step line never appears. Enabled only
    /// by launching with `PRESENTIFY_PROBE=1`.
    private func runDiagnosticProbe() {
        let coordinator = coordinator
        func step(_ label: String) {
            FileHandle.standardError.write(Data("[PROBE] ok: \(label)\n".utf8))
        }

        Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch {}

            await coordinator.enterAnnotationMode()
            step("enterAnnotationMode")
            try? await Task.sleep(nanoseconds: 800_000_000)

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
        // effect without restarting Presentify.
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
        menuBar.onShowSettings = { [weak self] in
            self?.openSettings()
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func refreshMenu() {
        menuBar?.update(
            mode: coordinator.mode,
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.tr("Presentify Settings")
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
        window.title = L10n.tr("Presentify Setup")
        window.contentView = NSHostingView(
            rootView: OnboardingView(coordinator: coordinator)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
