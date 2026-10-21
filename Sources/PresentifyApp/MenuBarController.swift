import AppKit
import Foundation
import PresentifyCore

/// The menu bar item that controls Presentify.
///
/// The app lives in the menu bar rather than the Dock: it is a utility that
/// the user activates with a hot key, and a Dock icon would get in the way of
/// whatever they are presenting.
@MainActor
public final class MenuBarController {
    /// The status item shown in the menu bar.
    private let statusItem: NSStatusItem

    /// The actions the menu offers, forwarded to the app.
    public var onToggleAnnotation: (() -> Void)?
    public var onTogglePause: (() -> Void)?
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?
    public var onCopyScreenshot: (() -> Void)?
    public var onSaveScreenshot: (() -> Void)?
    public var onShowSettings: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle.angled",
                accessibilityDescription: "Presentify"
            )
            button.image?.isTemplate = true
            button.toolTip = "Presentify"
        }

        statusItem.menu = buildMenu()
    }

    /// Updates the menu to reflect the current app state.
    ///
    /// - Parameters:
    ///   - mode: The current app mode.
    ///   - canUndo: Whether an undo step is available.
    ///   - canRedo: Whether a redo step is available.
    public func update(mode: AppMode, canUndo: Bool, canRedo: Bool) {
        let menu = buildMenu(mode: mode, canUndo: canUndo, canRedo: canRedo)
        statusItem.menu = menu
    }

    // MARK: - Private

    private func buildMenu(
        mode: AppMode = .idle,
        canUndo: Bool = false,
        canRedo: Bool = false
    ) -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: mode == .idle ? L10n.tr("Start Annotating") : L10n.tr("Stop Annotating"),
            action: #selector(handleToggleAnnotation),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if mode != .idle {
            let pause = NSMenuItem(
                title: mode == .paused ? L10n.tr("Resume") : L10n.tr("Pause"),
                action: #selector(handleTogglePause),
                keyEquivalent: ""
            )
            pause.target = self
            menu.addItem(pause)
        }

        menu.addItem(.separator())

        let undo = NSMenuItem(title: L10n.tr("Undo"), action: #selector(handleUndo), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = canUndo
        menu.addItem(undo)

        let redo = NSMenuItem(title: L10n.tr("Redo"), action: #selector(handleRedo), keyEquivalent: "")
        redo.target = self
        redo.isEnabled = canRedo
        menu.addItem(redo)

        menu.addItem(.separator())

        let copy = NSMenuItem(
            title: L10n.tr("Copy Screenshot"),
            action: #selector(handleCopyScreenshot),
            keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(
            title: L10n.tr("Save Screenshot…"),
            action: #selector(handleSaveScreenshot),
            keyEquivalent: ""
        )
        save.target = self
        menu.addItem(save)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L10n.tr("Settings…"),
            action: #selector(handleShowSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: L10n.tr("Quit Presentify"),
            action: #selector(handleQuit),
            keyEquivalent: ""
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func handleToggleAnnotation() {
        onToggleAnnotation?()
    }

    @objc private func handleTogglePause() {
        onTogglePause?()
    }

    @objc private func handleUndo() {
        onUndo?()
    }

    @objc private func handleRedo() {
        onRedo?()
    }

    @objc private func handleCopyScreenshot() {
        onCopyScreenshot?()
    }

    @objc private func handleSaveScreenshot() {
        onSaveScreenshot?()
    }

    @objc private func handleShowSettings() {
        onShowSettings?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
