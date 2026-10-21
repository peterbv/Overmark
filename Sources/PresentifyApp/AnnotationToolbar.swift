import AppKit
import PresentifyCore
import PresentifyOverlay
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
    private static let barSize = NSSize(width: 680, height: 104)

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
        window.contentView = NSHostingView(rootView: ShortcutHelpView())
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
        .ellipse: "ellipse",
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
            ColorPalette(selection: $coordinator.settings.color)

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
struct ShortcutHelpView: View {
    private static let rows: [(String, [String])] = [
        (L10n.tr("Enter / end the presentation"), ["⌘⇧A"]),
        (L10n.tr("Pointer highlight"), ["⌘⇧F"]),
        (L10n.tr("Spotlight"), ["⌘⇧D"]),
        (L10n.tr("Zoom lens"), ["⌘⇧G"]),
        (L10n.tr("Pause"), ["⌘⇧S"]),
        (L10n.tr("Undo"), ["⌘⌥Z"]),
        (L10n.tr("Redo"), ["⌘⌥⇧Z"]),
        (L10n.tr("Copy Screenshot"), ["⌘⇧C"]),
        (L10n.tr("Save Screenshot…"), ["⌘⌥⇧S"]),
        (L10n.tr("Quit Presentify"), ["⌘⌥Q"]),
    ]

    private static let notes: [(String, String)] = [
        (L10n.tr("ESC always ends the presentation"), "ESC"),
        (L10n.tr("Draw with ⌥ held"), "⌥"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("Keyboard shortcuts"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            ForEach(Self.rows, id: \.0) { name, keys in
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(keys, id: \.self) { KeyCap(symbol: $0) }
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
