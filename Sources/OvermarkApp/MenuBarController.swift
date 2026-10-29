import AppKit
import Foundation
import OvermarkCore

/// The menu bar item that controls Overmark.
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
    public var onToggleWhiteboard: (() -> Void)?
    public var onToggleFreeze: (() -> Void)?
    public var onToggleRecording: (() -> Void)?
    public var onSelectPresentationScope: ((PresentationScope) -> Void)?
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?
    public var onCopyScreenshot: (() -> Void)?
    public var onSaveScreenshot: (() -> Void)?
    public var onExportPNG: (() -> Void)?
    public var onExportPDF: (() -> Void)?
    public var onShowSettings: (() -> Void)?
    public var onQuit: (() -> Void)?

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle.angled",
                accessibilityDescription: "Overmark"
            )
            button.image?.isTemplate = true
            button.toolTip = "Overmark"
        }

        statusItem.menu = buildMenu()
    }

    /// Updates the menu to reflect the current app state.
    ///
    /// - Parameters:
    ///   - mode: The current app mode.
    ///   - isRecording: Whether a presentation recording is active; it turns
    ///     the menu-bar badge red and offers the stop entry.
    ///   - scope: Which screens the annotation overlay currently covers; the
    ///     annotation-screen entry shows it with a checkmark.
    ///   - isWhiteboard: Whether the dedicated whiteboard is up; the
    ///     whiteboard entry shows it with a checkmark.
    ///   - isFreeze: Whether the screen still is up; the freeze entry shows
    ///     it with a checkmark.
    ///   - screenChoices: The attached screens, for the annotation submenu.
    ///   - canUndo: Whether an undo step is available.
    ///   - canRedo: Whether a redo step is available.
    public func update(
        mode: AppMode,
        isRecording: Bool = false,
        scope: PresentationScope = .all,
        isWhiteboard: Bool = false,
        isFreeze: Bool = false,
        screenChoices: [ScreenChoiceRow] = [],
        canUndo: Bool,
        canRedo: Bool
    ) {
        applyRecordingBadge(isRecording)
        let menu = buildMenu(
            mode: mode,
            isRecording: isRecording,
            scope: scope,
            isWhiteboard: isWhiteboard,
            isFreeze: isFreeze,
            screenChoices: screenChoices,
            canUndo: canUndo,
            canRedo: canRedo
        )
        statusItem.menu = menu
    }

    /// Tints the status icon red while a recording runs, so the presenter
    /// sees the state even from the menu bar alone.
    private func applyRecordingBadge(_ isRecording: Bool) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = isRecording ? NSColor.systemRed : nil
    }

    // MARK: - Private

    private func buildMenu(
        mode: AppMode = .idle,
        isRecording: Bool = false,
        scope: PresentationScope = .all,
        isWhiteboard: Bool = false,
        isFreeze: Bool = false,
        screenChoices: [ScreenChoiceRow] = [],
        canUndo: Bool = false,
        canRedo: Bool = false
    ) -> NSMenu {
        let menu = NSMenu()
        // Items carry hand-managed state in this menu (undo/redo
        // availability, the checkmarks). With auto-enabling left on, NSMenu
        // validation overrides every manual `isEnabled`, so disabled items
        // like undo-at-empty-history still looked clickable and no-oped.
        menu.autoenablesItems = false

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

            let record = NSMenuItem(
                title: isRecording ? L10n.tr("Stop Recording") : L10n.tr("Record the presentation"),
                action: #selector(handleToggleRecording),
                keyEquivalent: ""
            )
            record.target = self
            menu.addItem(record)

            let scopeItem = NSMenuItem(
                title: L10n.tr("Annotation screen"),
                action: nil,
                keyEquivalent: ""
            )
            let scopeMenu = NSMenu(title: L10n.tr("Annotation screen"))
            let allScreens = NSMenuItem(
                title: L10n.tr("All screens"),
                action: #selector(handleScopeAll),
                keyEquivalent: ""
            )
            allScreens.target = self
            allScreens.state = scope.screenName == nil ? .on : .off
            scopeMenu.addItem(allScreens)
            for row in screenChoices {
                let item = NSMenuItem(
                    title: row.label,
                    action: #selector(handleScopeNamed(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = row.value
                item.state = row.value == scope.screenName ? .on : .off
                scopeMenu.addItem(item)
            }
            scopeItem.submenu = scopeMenu
            menu.addItem(scopeItem)

            let whiteboard = NSMenuItem(
                title: L10n.tr("Whiteboard"),
                action: #selector(handleToggleWhiteboard),
                keyEquivalent: ""
            )
            whiteboard.target = self
            whiteboard.state = isWhiteboard ? .on : .off
            menu.addItem(whiteboard)

            let freeze = NSMenuItem(
                title: L10n.tr("Freeze the screen"),
                action: #selector(handleToggleFreeze),
                keyEquivalent: ""
            )
            freeze.target = self
            freeze.state = isFreeze ? .on : .off
            menu.addItem(freeze)
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

        let exportPNG = NSMenuItem(
            title: L10n.tr("Export PNG…"),
            action: #selector(handleExportPNG),
            keyEquivalent: ""
        )
        exportPNG.target = self
        menu.addItem(exportPNG)

        let exportPDF = NSMenuItem(
            title: L10n.tr("Export PDF…"),
            action: #selector(handleExportPDF),
            keyEquivalent: ""
        )
        exportPDF.target = self
        menu.addItem(exportPDF)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: L10n.tr("Settings…"),
            action: #selector(handleShowSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: L10n.tr("Quit Overmark"),
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

    @objc private func handleToggleWhiteboard() {
        onToggleWhiteboard?()
    }

    @objc private func handleToggleFreeze() {
        onToggleFreeze?()
    }

    @objc private func handleToggleRecording() {
        onToggleRecording?()
    }

    @objc private func handleScopeAll() {
        onSelectPresentationScope?(.all)
    }

    @objc private func handleScopeNamed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, !name.isEmpty else { return }
        onSelectPresentationScope?(.onlyScreen(name))
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

    @objc private func handleExportPNG() {
        onExportPNG?()
    }

    @objc private func handleExportPDF() {
        onExportPDF?()
    }

    @objc private func handleShowSettings() {
        onShowSettings?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
