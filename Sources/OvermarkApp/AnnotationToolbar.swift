import AppKit
import OvermarkCore
import OvermarkHotkeys
import OvermarkOverlay
import SwiftUI

/// The floating control bar shown while the user annotates the screen.
///
/// The overlay panels are see-through drawing surfaces; this bar is the only
/// real control surface: tools, colours, width, undo/redo and the pause /
/// finish buttons, so a presenter can work without memorising hot keys. It
/// floats just above the overlay panels and sits below the menu bar, clear
/// of the Dock, and the capture service excludes the app's own windows by
/// id so the bar never leaks into exported screenshots.
@MainActor
final class AnnotationToolbarController {
    private static let barSize = NSSize(width: 760, height: 104)

    private let coordinator: AppCoordinator
    private var panel: OverlayPanel?

    /// Expanded (all controls) vs collapsed into a corner tab by the
    /// auto-hide behaviour.
    private var isExpanded = true
    /// Pin button in the toolbar: collapse to a small tab when the
    /// cursor is away, expand on hover.
    private var isAutoHide = false
    private var autoCollapseTask: Task<Void, Never>?
    private var shortcutsWindow: HelpPanel?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Places the bar under the menu bar of the given screen.
    func show(on screen: NSScreen) {
        hide()

        let size = Self.barSize
        let frame = screen.frame
        let menuBarHeight = max(frame.height - screen.visibleFrame.height, 0)
        let rect = NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - menuBarHeight - size.height - 12,
            width: size.width,
            height: size.height
        )

        let panel = OverlayPanel(contentRect: rect)
        panel.setFrame(rect, display: true)
        // Above the overlay panels so the spotlight's dimming layer never
        // draws over the controls.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Drag anywhere on the toolbar background to reposition it; button
        // hits still take precedence over the window-move gesture.
        panel.isMovableByWindowBackground = true
        isExpanded = true
        panel.contentView = makeExpandedContent(
            handleFrame: NSRect(x: size.width / 2 - 40, y: size.height - 16, width: 80, height: 12)
        )
        panel.orderFrontRegardless()

        self.panel = panel
    }

    /// The window numbers that must never appear in a recording: the bar
    /// itself and the cheat-sheet. The recorder excludes these by id while
    /// the annotation canvases and cursor-effect windows stay on tape.
    func chromeWindowNumbers() -> [Int] {
        var numbers: [Int] = []
        if let number = panel?.windowNumber {
            numbers.append(number)
        }
        if let number = shortcutsWindow?.windowNumber {
            numbers.append(number)
        }
        return numbers
    }

    /// Removes the bar (and the shortcut cheat-sheet).
    func hide() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        closeShortcutsWindow()
        panel?.dismiss()
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    /// The system rearranged displays: keep the bar (and any open
    /// cheat-sheet) on a screen that still exists instead of going off
    /// desktop with an unplugged display.
    func handleScreensChanged() {
        if let panel, panel.isVisible {
            clampIntoScreens(panel)
        }
        if let shortcutsWindow, shortcutsWindow.isVisible {
            clampIntoScreens(shortcutsWindow)
        }
    }

    /// Clamps a window into the union of the current screens, leaving at
    /// least a grabbable strip visible — the same rule the drag uses.
    private func clampIntoScreens(_ window: NSWindow) {
        guard !NSScreen.screens.isEmpty else { return }
        var union = NSScreen.screens[0].frame
        for screen in NSScreen.screens.dropFirst() {
            union = union.union(screen.frame)
        }

        let frame = window.frame
        var origin = frame.origin
        origin.x = min(max(origin.x, union.minX - frame.width + 120), union.maxX - 120)
        origin.y = min(max(origin.y, union.minY - frame.height + 80), union.maxY - 80)
        window.setFrameOrigin(origin)
    }

    // MARK: Auto-hide docking

    /// Rebuilds the expanded HUD: SwiftUI controls + a hover-tracking
    /// view + the drag handle.
    private func makeExpandedContent(handleFrame: NSRect) -> NSView {
        let hosting = self.hosting(for: handleFrame)

        let hover = HoverPassThruView(frame: .zero)
        hover.onEnter = { [weak self] in self?.handleHoverEnter() }
        hover.onExit = { [weak self] in self?.handleHoverExit() }
        hover.autoresizingMask = [.width, .height]
        hosting.addSubview(hover)

        let handle = DragHandleView(frame: NSRect(
            x: hosting.bounds.width / 2 - 40,
            y: hosting.bounds.height - 16,
            width: 80,
            height: 12
        ))
        handle.toolTip = L10n.tr("Drag here to move the toolbar")
        handle.onMouseEnter = { [weak self] in self?.handleHoverEnter() }
        handle.onMouseExit = { [weak self] in self?.handleHoverExit() }
        // Centered strip pinned to the top edge when the panel changes
        // size.
        handle.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        hosting.addSubview(handle)

        return hosting
    }

    private func hosting(for handleFrame: NSRect) -> NSHostingView<AnnotationToolbarView> {
        NSHostingView(
            rootView: AnnotationToolbarView(
                coordinator: coordinator,
                isAutoHideEnabled: isAutoHide,
                onToggleAutoHide: { [weak self] in self?.toggleAutoHide() },
                onShowShortcuts: { [weak self] in self?.toggleShortcutsWindow() }
            )
        )
    }

    private func handleHoverEnter() {
        autoCollapseTask?.cancel()
        autoCollapseTask = nil
        guard isAutoHide, !isExpanded else { return }
        showExpanded()
    }

    private func handleHoverExit() {
        guard isAutoHide, isExpanded else { return }
        autoCollapseTask?.cancel()
        autoCollapseTask = Task { [weak self] in
            // A grace period so a quick pass does not snap the bar away.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.collapseToTab()
        }
    }

    /// Pin toggle: the expanded HUD is rebuilt so the button reflects
    /// the new state.
    func toggleAutoHide() {
        isAutoHide.toggle()
        guard let panel, isExpanded,
              let hosting = panel.contentView as? NSHostingView<AnnotationToolbarView> else { return }
        hosting.rootView = AnnotationToolbarView(
            coordinator: coordinator,
            isAutoHideEnabled: isAutoHide,
            onToggleAutoHide: { [weak self] in self?.toggleAutoHide() },
            onShowShortcuts: { [weak self] in self?.toggleShortcutsWindow() }
        )
    }

    private func collapseToTab() {
        guard let panel, isExpanded else { return }
        isExpanded = false

        let frame = panel.frame
        let screenFrame = NSScreen.screens.first { $0.frame.intersects(frame) }?.frame
            ?? NSScreen.main?.frame ?? frame
        let tabSize = NSSize(width: 48, height: 12)
        var origin = frame.origin
        // Keep the tab anchored on whichever side of the screen the bar
        // was closest to.
        if frame.midX >= screenFrame.midX {
            origin.x = frame.maxX - tabSize.width
        }
        if frame.midY >= screenFrame.midY {
            origin.y = frame.maxY - tabSize.height
        } else {
            origin.y = frame.minY
        }
        let tab = NSRect(origin: origin, size: tabSize)

        let tabView = DragHandleView(frame: NSRect(origin: .zero, size: tabSize))
        tabView.toolTip = L10n.tr("Show the controls")
        tabView.onMouseEnter = { [weak self] in self?.handleHoverEnter() }
        let tabContents = tabView
        panel.contentView = tabContents
        panel.setFrame(tab, display: true, animate: true)
    }

    private func showExpanded() {
        guard let panel, !isExpanded else { return }
        isExpanded = true

        // Grow back around the tab's anchor corner, kept on screen.
        let current = panel.frame
        let union = NSScreen.screens.dropFirst().reduce(
            NSScreen.screens.first?.frame ?? current
        ) { $0.union($1.frame) }
        var origin = current.origin
        origin.x = min(max(origin.x, union.minX - Self.barSize.width + 120), union.maxX - 120)
        origin.y = min(max(origin.y, union.minY - Self.barSize.height + 80), union.maxY - 80)
        let target = NSRect(origin: origin, size: Self.barSize)

        panel.contentView = makeExpandedContent(
            handleFrame: NSRect(
                x: target.width / 2 - 40,
                y: target.height - 16,
                width: 80,
                height: 12
            )
        )
        panel.setFrame(target, display: true, animate: false)
    }

    // MARK: Shortcut cheat-sheet

    func toggleShortcutsWindow() {
        if shortcutsWindow?.isVisible == true {
            closeShortcutsWindow()
            return
        }
        guard let panel else { return }

        let size = NSSize(width: 300, height: 356)
        let frame = panel.frame
        let screenFrame = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? frame

        let gap: CGFloat = 8
        var x = frame.maxX + gap
        if x + size.width > screenFrame.maxX {
            x = max(frame.minX - size.width - gap, screenFrame.minX)
        }
        // Top-align with the bar, then keep it on screen.
        let y = min(max(frame.maxY - size.height, screenFrame.minY), screenFrame.maxY - size.height)

        let window = HelpPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size))
        window.contentView = NSHostingView(
            rootView: ShortcutHelpView(bindings: coordinator.hotKeyBindings)
        )
        window.orderFrontRegardless()
        shortcutsWindow = window
    }

    private func closeShortcutsWindow() {
        shortcutsWindow?.orderOut(nil)
        shortcutsWindow?.close()
        shortcutsWindow = nil
    }
}

/// The SwiftUI content of the control bar.
struct AnnotationToolbarView: View {
    private static let renderableTools: [AnnotationTool] = [
        .pen, .highlighter, .arrow, .rectangle, .ellipse, .text, .stepNumber,
    ]

    private static let toolSymbols: [AnnotationTool: String] = [
        .pen: "pencil",
        .highlighter: "highlighter",
        .arrow: "arrow.up.right",
        .rectangle: "rectangle",
        .ellipse: "oval",
        .text: "textformat",
        .stepNumber: "number.circle",
    ]

    @ObservedObject var coordinator: AppCoordinator
    var isAutoHideEnabled: Bool = false
    var onToggleAutoHide: () -> Void = {}
    var onShowShortcuts: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            mainRow
            styleRow
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        // A toolbar that changes look when the system appearance flips is
        // distracting mid-presentation; the HUD stays dark either way.
        .environment(\.colorScheme, .dark)
    }

    private var mainRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.renderableTools, id: \.self) { tool in
                ToolButton(
                    systemImage: Self.toolSymbols[tool] ?? "pencil",
                    isSelected: coordinator.settings.tool == tool
                ) {
                    coordinator.settings.tool = tool
                }
            }

            Divider()
                .frame(height: 22)

            AnnotationControlButton(
                systemImage: "arrow.uturn.backward",
                isEnabled: coordinator.document.canUndo
            ) {
                coordinator.undo()
            }
            AnnotationControlButton(
                systemImage: "arrow.uturn.forward",
                isEnabled: coordinator.document.canRedo
            ) {
                coordinator.redo()
            }
            AnnotationControlButton(
                systemImage: "trash",
                isEnabled: !coordinator.document.annotations.isEmpty
            ) {
                coordinator.clearAll()
            }

            Divider()
                .frame(height: 22)

            // The cursor effects live next to the drawing controls: the ring
            // (circle.dashed), the spotlight and the zoom lens, each filled
            // while the effect is enabled — same state the menu and hotkeys
            // toggle.
            EffectButton(
                systemImage: "circle.dashed",
                isSelected: coordinator.cursorEffects.isHighlightEnabled,
                help: L10n.tr("Pointer highlight")
            ) {
                coordinator.cursorEffects.isHighlightEnabled.toggle()
            }
            EffectButton(
                systemImage: "sun.max.fill",
                isSelected: coordinator.cursorEffects.isSpotlightEnabled,
                help: L10n.tr("Spotlight")
            ) {
                coordinator.cursorEffects.isSpotlightEnabled.toggle()
            }
            EffectButton(
                systemImage: "plus.magnifyingglass",
                isSelected: coordinator.cursorEffects.isZoomEnabled,
                help: L10n.tr("Zoom lens")
            ) {
                coordinator.cursorEffects.isZoomEnabled.toggle()
            }

            Divider()
                .frame(height: 22)

            // Where the overlay draws: every screen or one of them.
            ScreenScopeMenu(coordinator: coordinator)

            RecordButton(
                state: coordinator.recordingState,
                lastRecordingURL: coordinator.lastRecordingURL,
                action: { coordinator.toggleRecording() },
                reveal: { coordinator.revealLastRecording() }
            )

            // The pencil latch: one click flips between drawing with every
            // click (no modifier) and the hold-⌥-to-draw mode that the chips
            // in the style row describe. Same ToolSettings flag the Settings
            // pane toggles, so the overlay re-applies it live.
            EffectButton(
                systemImage: "pencil.tip",
                isSelected: !coordinator.settings.holdOptionToDraw,
                help: L10n.tr(
                    !coordinator.settings.holdOptionToDraw
                        ? "The pencil is latched: every click draws on the overlay. Click again to require ⌥ (Option) again."
                        : "Latch the pencil: draw with every click instead of holding ⌥ (Option)."
                )
            ) {
                coordinator.settings.holdOptionToDraw.toggle()
            }

            // The dedicated whiteboard: while it is up the screens in scope
            // show a blank surface instead of the desktop, and every click
            // draws — same overlay session, no mode switch.
            EffectButton(
                systemImage: "rectangle.inset.filled",
                isSelected: coordinator.isWhiteboardActive,
                help: L10n.tr(
                    coordinator.isWhiteboardActive
                        ? "The whiteboard is up: the screens show a blank board to draw on. Click again to go back to the see-through overlay over your apps."
                        : "Whiteboard: cover the screens with a blank board to draw on, without an app underneath."
                )
            ) {
                coordinator.toggleWhiteboard()
            }

            AnnotationControlButton(
                systemImage: coordinator.mode == .paused ? "play.fill" : "pause.fill"
            ) {
                coordinator.togglePause()
            }
            AnnotationControlButton(
                systemImage: "questionmark.circle",
                help: L10n.tr("Keyboard shortcuts")
            ) {
                onShowShortcuts()
            }
            AnnotationControlButton(systemImage: "gearshape") {
                coordinator.onShowAppSettings?()
            }
            EffectButton(
                systemImage: "pin.fill",
                isSelected: isAutoHideEnabled,
                help: L10n.tr("Auto-hide")
            ) {
                onToggleAutoHide()
            }

            finishButton
        }
    }

    private var styleRow: some View {
        HStack(spacing: 10) {
            ColorPalette(
                selection: $coordinator.settings.color,
                favorites: coordinator.favoriteColors,
                onAddFavorite: { coordinator.showColorPanel() }
            )

            Divider()
                .frame(height: 22)

            Image(systemName: "lineweight")
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 16)

            Slider(value: $coordinator.settings.lineWidth, in: 1...24, step: 1)
                .frame(width: 110)

            if coordinator.settings.holdOptionToDraw {
                if coordinator.overlayPassthroughActive {
                    Text(L10n.tr("⌥ draw"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .help(
                            L10n.tr("While this says \"⌥ draw\", only clicks with ⌥ (Option) held draw on the overlay; every other click reaches the app underneath.")
                        )
                } else {
                    Text(L10n.tr("capture mode"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.yellow.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.yellow.opacity(0.12)))
                        .help(
                            L10n.tr("The overlay captures every click until Accessibility is granted (System Settings → Privacy & security → Accessibility). Press here to open it.")
                        )
                        .onTapGesture {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                }
            } else {
                // Capturing every click is a *chosen* mode; without a chip it
                // reads as "broken" from the toolbar and the escape hatches
                // (pause, the toggle back on) stay hidden.
                Text(L10n.tr("capture all"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.22)))
                    .help(
                        L10n.tr("The overlay captures every click by choice. Pause (⌘⇧S) to interact with other apps, or tap here to require ⌥ (Option) again.")
                    )
                    .onTapGesture {
                        // The pencil latch button toggles the same flag; this
                        // tap flips back without the detour through Settings.
                        coordinator.settings.holdOptionToDraw = true
                    }
            }
        }
        .padding(.horizontal, 4)
    }

    private var finishButton: some View {
        Button {
            Task { await coordinator.toggleAnnotationMode() }
        } label: {
            Label(L10n.tr("Done"), systemImage: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.red.opacity(0.85)))
        .help(L10n.tr("Finish annotating"))
    }
}

/// One of the round tool buttons at the left of the bar.
private struct ToolButton: View {
    var systemImage: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.08)))
                )
        }
        .buttonStyle(.plain)
    }
}

/// A toggle button for the cursor effects (highlight ring, spotlight,
/// zoom lens). Same shape as a tool button, but the state reads as
/// "enabled" via a tinted icon on a subtle tinted tile instead of the
/// solid fill that marks the selected tool.
private struct EffectButton: View {
    var systemImage: String
    var isSelected: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            isSelected
                                ? AnyShapeStyle(.tint.opacity(0.24))
                                : AnyShapeStyle(Color.white.opacity(0.08))
                        )
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The annotation-scope picker of the control bar: one display or all of
/// them.
///
/// The pill shows the active choice — "All screens" or the chosen screen's
/// localized name — and the menu lists whatever displays are attached at
/// that moment. `screensEpoch` is read here so displays plugged in or out
/// mid-session refresh the list without any manual reopen.
private struct ScreenScopeMenu: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Menu {
            Button {
                coordinator.setPresentationScope(.all)
            } label: {
                Label(L10n.tr("All screens"), systemImage: "rectangle.on.rectangle")
            }
            ForEach(coordinator.screenNames, id: \.self) { name in
                Button {
                    coordinator.setPresentationScope(.onlyScreen(name))
                } label: {
                    Label(name, systemImage: "display")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: coordinator.presentationScope.screenName == nil
                    ? "rectangle.on.rectangle"
                    : "display")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(isScopedToOneScreen ? Color.white : Color.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(
                    isScopedToOneScreen
                        ? AnyShapeStyle(Color.accentColor.opacity(0.85))
                        : AnyShapeStyle(Color.white.opacity(0.08))
                )
            )
        }
        .menuStyle(.button)
        .menuIndicator(.visible)
        .fixedSize()
        .help(L10n.tr("Choose which screens the annotation overlay covers"))
    }

    /// A single-screen annotation pipeline is a deliberate state the bar
    /// should flag at a glance, so that tile gets the accent treatment
    /// while "every screen" stays with the quiet default look.
    private var isScopedToOneScreen: Bool {
        coordinator.presentationScope.screenName != nil
    }

    /// The scope name kept in sync with the attached screens — the epoch
    /// read only exists so SwiftUI re-renders on display changes.
    private var title: String {
        _ = coordinator.screensEpoch
        if let name = coordinator.presentationScope.screenName {
            return name
        }
        return L10n.tr("All screens")
    }
}

/// The recording toggle of the control bar.
///
/// Idle it reads as an empty red record circle; while recording the icon
/// flips to a stop symbol, the tile tints red and a pill counts the elapsed
/// time so the presenter always knows the session is on tape. While the
/// file is finishing the tile rejects clicks; once a session has banked a
/// `.mov`, a green chip names the file and clicking it reveals the file in
/// Finder until the next recording starts. The pills tick on `TimelineView`
/// — no timer plumbing of their own.
private struct RecordButton: View {
    var state: RecordingState
    var lastRecordingURL: URL?
    var action: () -> Void
    var reveal: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 4) {
                Button(action: isFinishing ? {} : action) {
                    Image(systemName: state.isActive ? "stop.fill" : "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tileTint)
                        .frame(width: 32, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(tileFill)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isFinishing)
                .help(tileHelp)

                if case .recording(let startedAt) = state {
                    Text(elapsed(startedAt))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.red.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                        .help(L10n.tr("Recording in progress"))
                } else if isFinishing {
                    // The writer is closing the file: nothing clickable,
                    // just a quiet acknowledgement that work is queued.
                    Text(L10n.tr("Finishing the recording…"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                } else if let lastRecordingURL {
                    Button {
                        reveal()
                    } label: {
                        Text(String(
                            format: L10n.tr("Recording saved: %@"),
                            arguments: [lastRecordingURL.lastPathComponent]
                        ))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Color.green.opacity(0.95))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Click to show the file in Finder"))
                }
            }
        }
    }

    private var isFinishing: Bool {
        if case .finishing = state { return true }
        return false
    }

    private var tileTint: SwiftUI.Color {
        isFinishing
            ? Color.white.opacity(0.45)
            : state.isActive ? Color.red : Color.white
    }

    private var tileFill: AnyShapeStyle {
        state.isActive && !isFinishing
            ? AnyShapeStyle(Color.red.opacity(0.20))
            : AnyShapeStyle(Color.white.opacity(0.08))
    }

    private var tileHelp: String {
        isFinishing
            ? L10n.tr("Finishing the recording…")
            : state.isActive
                ? L10n.tr("Stop recording")
                : L10n.tr("Record the presentation")
    }

    /// Minutes:seconds since the recording started, ticking with the
    /// surrounding `TimelineView`.
    private func elapsed(_ startedAt: Date) -> String {
        let interval = max(0, Date.now.timeIntervalSince(startedAt))
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// A generic icon button with an optional enabled state.
private struct AnnotationControlButton: View {
    var systemImage: String
    var isEnabled = true
    var help = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.08))
                )
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}

/// The grip strip at the top-centre of the bar that moves the whole bar.
///
/// AppKit's `isMovableByWindowBackground` is of no use here: the content
/// view is an `NSHostingView`, and SwiftUI consumes the mouse events
/// before the window's move-on-background logic runs. So the handle
/// starts the standard, system window drag itself and then keeps the
/// bar within a visible screen.
private final class DragHandleView: NSView {
    /// Hooked up by the controller: fires when the cursor enters/leaves
    /// the handle (it drives the auto-hide expand/collapse too).
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .activeAlways so the hand cursor works even though the panel
        // never becomes key.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onMouseExit?()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSCursor.closedHand.set()
        // Runs its own nested event loop and returns as soon as the user
        // releases the button; AppKit handles all the tracking.
        window.performDrag(with: event)
        NSCursor.arrow.set()
        clampIntoVisibleArea()
        snapToNearestCorner()
    }

    /// Keeps the bar from being dragged completely off the desktop.
    private func clampIntoVisibleArea() {
        guard let window, let first = NSScreen.screens.first else { return }
        var union = first.frame
        for screen in NSScreen.screens.dropFirst() {
            union = union.union(screen.frame)
        }

        let frame = window.frame
        var origin = frame.origin
        // Always leave at least 120pt of the bar horizontally on screen
        // and 80pt vertically, on some display.
        origin.x = min(max(origin.x, union.minX - frame.width + 120), union.maxX - 120)
        origin.y = min(max(origin.y, union.minY - frame.height + 80), union.maxY - 80)
        window.setFrameOrigin(origin)
    }

    /// Magnetically glues the bar to a screen corner when the drop
    /// happens near one. `visibleFrame` keeps it clear of the menu bar
    /// and the Dock. When the bar is collapsed into its tab it snaps as
    /// a tab.
    private func snapToNearestCorner() {
        guard let window else { return }
        let frame = window.frame
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let margin: CGFloat = 6
        let width = frame.width
        let height = frame.height
        let candidates: [(x: CGFloat, y: CGFloat)] = [
            (visible.minX + margin, visible.maxY - height - margin),
            (visible.maxX - width - margin, visible.maxY - height - margin),
            (visible.minX + margin, visible.minY + margin),
            (visible.maxX - width - margin, visible.minY + margin),
        ]

        let current = frame.origin
        let best = candidates
            .map { candidate -> (NSPoint, CGFloat) in
                let target = NSPoint(x: candidate.x, y: candidate.y)
                return (target, abs(candidate.x - current.x) + abs(candidate.y - current.y))
            }
            .filter { $0.1 < 90 }
            .min { $0.1 < $1.1 }
        guard let snapped = best else { return }
        window.setFrameOrigin(snapped.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        // A macOS-style dot grip: two rows of three dots.
        let dot = NSBezierPath()
        let radius: CGFloat = 1.5
        let spacing: CGFloat = 5
        for row in [CGFloat(-1), 1] {
            for column in [CGFloat(-1), 0, 1] {
                let x = bounds.midX + column * spacing - radius
                let y = bounds.midY + row * 2.5 - radius
                dot.appendOval(in: NSRect(x: x, y: y, width: radius * 2, height: radius * 2))
            }
        }
        NSColor.white.withAlphaComponent(0.30).setFill()
        dot.fill()
    }
}

/// Invisible hover-tracking view over the whole bar: never responds to
/// clicks (SwiftUI keeps control of them) but reports enter/exit so the
/// auto-hide can collapse/expand the bar.
private final class HoverPassThruView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}

/// The floating cheat-sheet listing the keyboard shortcuts.
private final class HelpPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the toolbar itself.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        isReleasedWhenClosed = false
        // Floating panels auto-hide as soon as another app becomes
        // active, so clicking outside the app dismisses the sheet.
        hidesOnDeactivate = true
        isOpaque = false
        backgroundColor = .clear
    }
}

/// The SwiftUI contents of the shortcut cheat-sheet.
///
/// The rows come from the coordinator's live bindings, so the sheet always
/// matches what the user configured in the shortcuts settings tab.
struct ShortcutHelpView: View {
    let bindings: [HotKeyAction: HotKeyManager.Binding]

    private static let notes: [(String, String)] = [
        (L10n.tr("ESC always ends the presentation"), "ESC"),
        (L10n.tr("Draw with ⌥ held"), "⌥"),
        (L10n.tr("Right-click deletes an annotation"), "🖱"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("Keyboard shortcuts"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            ForEach(HotKeyAction.allCases, id: \.rawValue) { action in
                if let binding = bindings[action] {
                    HStack(spacing: 8) {
                        Text(HotKeyLabels.name(for: action))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        KeyCap(symbol: binding.readableDescription)
                    }
                }
            }

            Divider()
                .background(Color.white.opacity(0.2))

            ForEach(Self.notes, id: \.1) { name, key in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    KeyCap(symbol: key, accent: true)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// A little rounded key badge ("⌘⇧A") used in the cheat-sheet.
private struct KeyCap: View {
    var symbol: String
    var accent = false

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? Color.yellow.opacity(0.9) : Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    accent ? Color.yellow.opacity(0.14) : Color.white.opacity(0.14)
                )
            )
    }
}
