import AppKit
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
    private var statusObserver: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app is a menu bar utility: it stays out of the Dock and out of
        // the app switcher.
        NSApp.setActivationPolicy(.accessory)

        let menuBar = MenuBarController()
        self.menuBar = menuBar
        wire(menuBar)

        coordinator.start()
        refreshMenu()

        // The overlay and the document change in response to hot keys and to
        // the user's drawing, so the menu is refreshed whenever they change.
        statusObserver = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in coordinator.objectWillChange.values {
                self.refreshMenu()
            }
        }

        showOnboardingIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The permissions are granted in System Settings, which brings the
        // app to the front only after the user comes back to it. Re-reading
        // the state here is what makes a freshly granted permission take
        // effect without restarting Presentify.
        coordinator.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusObserver?.cancel()
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

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
        window.title = "Presentify Setup"
        window.contentView = NSHostingView(
            rootView: OnboardingView(coordinator: coordinator)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
