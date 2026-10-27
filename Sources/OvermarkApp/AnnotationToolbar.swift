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
    /// The vertical layout the side docks present: two slim columns
    /// instead of two full-width rows.
    private static let verticalBarSize = NSSize(width: 240, height: 700)
    /// The minimized layouts: only the essentials (tools, history,
    /// pause, the expansion toggle and Done), one row or one column. The
    /// defaults that keep the bar out of the way until everything is
    /// needed.
    private static let compactBarSize = NSSize(width: 580, height: 60)
    private static let compactVerticalBarSize = NSSize(width: 84, height: 540)

    /// Measured ideal sizes, keyed by layout variant. `dockRect` has to
    /// know the size before the hosting view exists, so each variant is
    /// measured once — a throwaway hosting view reports its
    /// `intrinsicContentSize`, the SwiftUI ideal, independent of any
    /// frame — and cached; later calls reuse it without laying out.
    private var measuredSizes: [SizeKey: NSSize] = [:]

    private struct SizeKey: Hashable {
        let vertical: Bool
        let minimized: Bool
    }

    /// The size the window must be to hold the given layout: measured
    /// from the SwiftUI content itself, with the designed constants as
    /// a floor. Measuring fixes the class of bugs where the layout
    /// gains a control and a frozen constant silently trims it off the
    /// window edge — the expanded bar kept losing its trailing tools
    /// that way.
    private func layoutSize(vertical: Bool, minimized: Bool) -> NSSize {
        let key = SizeKey(vertical: vertical, minimized: minimized)
        if let measured = measuredSizes[key] {
            return measured
        }

        let probe = hosting(isVertical: vertical, isMinimized: minimized)
        probe.sizingOptions = .intrinsicContentSize
        let ideal = probe.intrinsicContentSize
        let floor = Self.floorSize(vertical: vertical, minimized: minimized)
        let size = NSSize(
            width: max(ideal.width, floor.width),
            height: max(ideal.height, floor.height)
        )
        measuredSizes[key] = size
        return size
    }

    /// The designed minimum for each layout — the old frozen constants
    /// stay only as a floor, so a measure quirk (an odd ideal of `-1` or
    /// a metric hiccup) can never shrink a bar below a sane row.
    private static func floorSize(vertical: Bool, minimized: Bool) -> NSSize {
        switch (vertical, minimized) {
        case (true, true): return compactVerticalBarSize
        case (true, false): return verticalBarSize
        case (false, true): return compactBarSize
        case (false, false): return barSize
        }
    }

    private let coordinator: AppCoordinator
    private var panel: OverlayPanel?

    /// Expanded (all controls) vs collapsed into the dock tab by the
    /// auto-hide behaviour.
    private var isExpanded = true
    /// Pin button in the toolbar: collapse to a small tab when the
    /// cursor is away, expand on hover.
    private var isAutoHide = false
    /// The tab never drifts: it always waits in the dock slot of the
    /// configured edge. The dock itself lives in the coordinator, so a
    /// Settings change re-docks a live bar through `reapplyDock()`.
    private var autoCollapseTask: Task<Void, Never>?
    private var shortcutsWindow: HelpPanel?
    /// The orientation the expanded content was built for; a Settings
    /// change flips a horizontal dock to a side one, and the content
    /// must be rebuilt at the same time the panel gets its new frame.
    private var contentIsVertical = false
    /// Minimized (essentials only) vs full: starts minimized so the bar
    /// stays easy to manage; the chevron re-flows it in place.
    private var isMinimizedMode = true

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Places the bar under the menu bar of the given screen.
    func show(on screen: NSScreen) {
        hide()

        let rect = dockRect(for: screen)

        let panel = OverlayPanel(contentRect: rect)
        panel.setFrame(rect, display: true)
        // Above the overlay panels so the spotlight's dimming layer never
        // draws over the controls.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        // Drag anywhere on the toolbar background to reposition it; button
        // hits still take precedence over the window-move gesture.
        panel.isMovableByWindowBackground = true
        isExpanded = true
        panel.contentView = makeExpandedContent()
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

    /// Headless probe summary: the measured sizes for the full and the
    /// minimized layout of the current dock orientation — the sizes the
    /// windows are sized to. A drift (a layout outgrowing its window
    /// again) shows up right here in the probe transcript.
    func probeSummary() -> String {
        let vertical = !coordinator.toolbarDock.isHorizontal
        let full = layoutSize(vertical: vertical, minimized: false)
        let compact = layoutSize(vertical: vertical, minimized: true)
        return "full \(Int(full.width))×\(Int(full.height))"
            + ", minimized \(Int(compact.width))×\(Int(compact.height))"
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

    // MARK: Docking

    /// Re-docks the bar on the configured edge without rebuilding it:
    /// an expanded bar lands on the dock rect, a folded one on the dock
    /// tab slot. This is the live path when Settings changes the edge
    /// during a session.
    func reapplyDock() {
        guard let panel else { return }
        guard let screen = dockingScreen(for: panel.frame) else { return }

        // A horizontal dock and a side dock show different layouts: when
        // the expanded bar changes orientation, rebuild the content
        // before (or instead of) just moving the panel.
        let wantsVertical = !coordinator.toolbarDock.isHorizontal
        if isExpanded, contentIsVertical != wantsVertical {
            contentIsVertical = wantsVertical
            panel.contentView = makeExpandedContent()
        }

        let target = isExpanded ? dockRect(for: screen) : tabSlot(for: screen)
        panel.setFrame(target, display: true, animate: true)
    }

    /// The screen that should carry the bar: the one holding the frame's
    /// centre, falling back to the main screen.
    private func dockingScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The expanded bar's home for the configured dock edge, kept clear
    /// of the menu bar (top), the Dock (bottom) and the screen edges
    /// (sides).
    private func dockRect(for screen: NSScreen) -> NSRect {
        let size = layoutSize(
            vertical: !coordinator.toolbarDock.isHorizontal,
            minimized: isMinimizedMode
        )
        // A measured layout can outgrow a small display: cap it to the
        // visible frame so the bar still fits between menu bar and Dock
        // instead of poking out the other edge.
        let visible = screen.visibleFrame
        let capped = NSSize(
            width: min(size.width, visible.width - 24),
            height: min(size.height, visible.height - 24)
        )
        let frame = screen.frame
        let menuBarHeight = max(frame.height - screen.visibleFrame.height, 0)
        let margin: CGFloat = 12
        switch coordinator.toolbarDock {
        case .top:
            return NSRect(
                x: frame.midX - capped.width / 2,
                y: frame.maxY - menuBarHeight - capped.height - margin,
                width: capped.width,
                height: capped.height
            )
        case .bottom:
            return NSRect(
                x: frame.midX - capped.width / 2,
                y: screen.visibleFrame.minY + margin,
                width: capped.width,
                height: capped.height
            )
        case .leading:
            return NSRect(
                x: frame.minX + margin,
                // A tall bar on a short display could outgrow the visible
                // area: clamp it inside the visible frame.
                y: max(
                    screen.visibleFrame.minY + margin,
                    frame.minY + (frame.height - capped.height) / 2
                ),
                width: capped.width,
                height: capped.height
            )
        case .trailing:
            return NSRect(
                x: frame.maxX - capped.width - margin,
                y: max(
                    screen.visibleFrame.minY + margin,
                    frame.minY + (frame.height - capped.height) / 2
                ),
                width: capped.width,
                height: capped.height
            )
        }
    }

    /// The little tab's permanent waiting slot: glued to the docked edge
    /// and centred along it, so the presenter can find the tab blind. A
    /// horizontal dock parks a wide pill; a side dock parks a tall one.
    private func tabSlot(for screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let menuBarHeight = max(frame.height - screen.visibleFrame.height, 0)
        let margin: CGFloat = 6
        let horizontal = coordinator.toolbarDock.isHorizontal
        let tabSize = horizontal
            ? NSSize(width: 48, height: 12)
            : NSSize(width: 12, height: 48)
        switch coordinator.toolbarDock {
        case .top:
            return NSRect(
                x: frame.midX - tabSize.width / 2,
                y: frame.maxY - menuBarHeight - tabSize.height - margin,
                width: tabSize.width,
                height: tabSize.height
            )
        case .bottom:
            return NSRect(
                x: frame.midX - tabSize.width / 2,
                y: screen.visibleFrame.minY + margin,
                width: tabSize.width,
                height: tabSize.height
            )
        case .leading:
            return NSRect(
                x: frame.minX + margin,
                y: frame.minY + (frame.height - tabSize.height) / 2,
                width: tabSize.width,
                height: tabSize.height
            )
        case .trailing:
            return NSRect(
                x: frame.maxX - tabSize.width - margin,
                y: frame.minY + (frame.height - tabSize.height) / 2,
                width: tabSize.width,
                height: tabSize.height
            )
        }
    }

    // MARK: Auto-hide docking

    /// Rebuilds the expanded HUD: SwiftUI controls + a hover-tracking
    /// view + the drag handle. The layout follows the dock: horizontal
    /// rows on top/bottom docks, two slim columns on side docks.
    private func makeExpandedContent() -> NSView {
        let vertical = !coordinator.toolbarDock.isHorizontal
        let hosting = self.hosting(isVertical: vertical, isMinimized: isMinimizedMode)
        contentIsVertical = vertical

        let hover = HoverPassThruView(frame: .zero)
        hover.onEnter = { [weak self] in self?.handleHoverEnter() }
        hover.onExit = { [weak self] in self?.handleHoverExit() }
        hover.autoresizingMask = [.width, .height]
        hosting.addSubview(hover)

        // Horizontal bars get the grip strip on their top edge; vertical
        // bars get a tall strip on the screen-facing inner edge.
        let handleFrame: NSRect
        let handleMask: NSView.AutoresizingMask
        if vertical {
            let onRightEdge = coordinator.toolbarDock == .leading
            handleFrame = NSRect(
                x: onRightEdge ? hosting.bounds.width - 16 : 4,
                y: hosting.bounds.height / 2 - 40,
                width: 12,
                height: 80
            )
            handleMask = onRightEdge ? [.minXMargin] : [.maxXMargin]
        } else {
            handleFrame = NSRect(
                x: hosting.bounds.width / 2 - 40,
                y: hosting.bounds.height - 16,
                width: 80,
                height: 12
            )
            handleMask = [.minXMargin, .maxXMargin, .minYMargin]
        }

        let handle = DragHandleView(frame: handleFrame)
        handle.toolTip = L10n.tr("Drag here to move the toolbar")
        handle.onMouseEnter = { [weak self] in self?.handleHoverEnter() }
        handle.onMouseExit = { [weak self] in self?.handleHoverExit() }
        // Pinned to the screen-facing edge; sizing margins only so an
        // edge pass keeps the strip hugging that side.
        handle.autoresizingMask = handleMask
        hosting.addSubview(handle)

        return hosting
    }

    private func hosting(
        isVertical: Bool,
        isMinimized: Bool
    ) -> NSHostingView<AnnotationToolbarView> {
        NSHostingView(
            rootView: AnnotationToolbarView(
                coordinator: coordinator,
                isVertical: isVertical,
                isMinimized: isMinimized,
                isAutoHideEnabled: isAutoHide,
                onToggleAutoHide: { [weak self] in self?.toggleAutoHide() },
                onToggleMinimized: { [weak self] in self?.toggleMinimized() },
                onShowShortcuts: { [weak self] in self?.toggleShortcutsWindow() }
            )
        )
    }

    /// Compact-by-default toggle: rebuilding the only-expanded content
    /// and re-anchoring it on the dock rect so the resize reads as a
    /// re-flow instead of a jump.
    func toggleMinimized() {
        guard let panel else { return }
        isMinimizedMode.toggle()
        guard isExpanded, let screen = dockingScreen(for: panel.frame) else { return }
        panel.contentView = makeExpandedContent()
        panel.setFrame(dockRect(for: screen), display: true, animate: true)
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
            isVertical: contentIsVertical,
            isMinimized: isMinimizedMode,
            isAutoHideEnabled: isAutoHide,
            onToggleAutoHide: { [weak self] in self?.toggleAutoHide() },
            onToggleMinimized: { [weak self] in self?.toggleMinimized() },
            onShowShortcuts: { [weak self] in self?.toggleShortcutsWindow() }
        )
    }

    private func collapseToTab() {
        guard let panel, isExpanded else { return }
        isExpanded = false

        // The tab is a parked dock slot, not a glued-to-the-bar corner:
        // it always waits where the configured dock says, on the screen
        // the bar currently lives on. The presenter finds it blind no
        // matter where the bar itself was dragged.
        let frame = panel.frame
        guard let screen = dockingScreen(for: frame) else { return }
        let tab = tabSlot(for: screen)

        let tabView = DragHandleView(frame: NSRect(origin: .zero, size: tab.size))
        tabView.toolTip = L10n.tr("Show the controls")
        tabView.onMouseEnter = { [weak self] in self?.handleHoverEnter() }
        let tabContents = tabView
        panel.contentView = tabContents
        panel.setFrame(tab, display: true, animate: true)
    }

    private func showExpanded() {
        guard let panel, !isExpanded else { return }
        isExpanded = true

        // Expand into the dock, not around the tab: the tab already sits
        // in the dock slot, so the bar grows back to exactly the home the
        // dock prescribes. Growing around the tab's origin is what used
        // to walk the whole bar off the desktop one pin cycle at a time
        // (the 120 pt drag clamp let it, and the tab went with it).
        guard let screen = dockingScreen(for: panel.frame) else { return }
        let target = dockRect(for: screen)

        panel.contentView = makeExpandedContent()
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
    /// Side docks (leading/trailing) show a two-column layout instead of
    /// the two-row horizontal bar.
    var isVertical: Bool = false
    /// Minimized mode: only the essentials stay visible; the chevron
    /// re-flows the bar to the full (or vertical) layout.
    var isMinimized: Bool = false
    var isAutoHideEnabled: Bool = false
    var onToggleAutoHide: () -> Void = {}
    var onToggleMinimized: () -> Void = {}
    var onShowShortcuts: () -> Void = {}

    var body: some View {
        Group {
            if isMinimized {
                if isVertical {
                    minimalVerticalLayout
                } else {
                    minimalHorizontalLayout
                }
            } else if isVertical {
                verticalLayout
            } else {
                horizontalLayout
            }
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

    /// The classic layout for top/bottom docks: tool rows stacked over
    /// the style row.
    private var horizontalLayout: some View {
        VStack(spacing: 8) {
            mainRow
            styleRow
        }
    }

    /// Minimized horizontal bar: the essentials in one slim row — draw,
    /// fix (undo/redo/trash), pause and finish; the chevron brings the
    /// rest back.
    private var minimalHorizontalLayout: some View {
        HStack(spacing: 6) {
            ForEach(Self.renderableTools, id: \.self) { tool in
                ToolButton(
                    systemImage: Self.toolSymbols[tool] ?? "pencil",
                    isSelected: coordinator.settings.tool == tool
                ) {
                    if coordinator.isSelectionMode {
                        coordinator.isSelectionMode = false
                    }
                    coordinator.settings.tool = tool
                }
            }

            Divider()
                .frame(height: 22)

            historyControls

            Divider()
                .frame(height: 22)

            AnnotationControlButton(
                systemImage: coordinator.mode == .paused ? "play.fill" : "pause.fill"
            ) {
                coordinator.togglePause()
            }

            expansionToggle

            finishButton
        }
    }

    /// Minimized vertical bar: the essentials in one slim column.
    private var minimalVerticalLayout: some View {
        VStack(spacing: 6) {
            ForEach(Self.renderableTools, id: \.self) { tool in
                ToolButton(
                    systemImage: Self.toolSymbols[tool] ?? "pencil",
                    isSelected: coordinator.settings.tool == tool
                ) {
                    if coordinator.isSelectionMode {
                        coordinator.isSelectionMode = false
                    }
                    coordinator.settings.tool = tool
                }
            }

            Divider()
                .frame(height: 1)

            historyControls

            Divider()
                .frame(height: 1)

            AnnotationControlButton(
                systemImage: coordinator.mode == .paused ? "play.fill" : "pause.fill"
            ) {
                coordinator.togglePause()
            }

            expansionToggle

            Spacer(minLength: 0)

            finishButton
        }
    }

    /// Undo, redo and trash: shared verbatim by every layout.
    @ViewBuilder
    private var historyControls: some View {
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
                || !coordinator.selectionIDs.isEmpty,
            help: L10n.tr(
                coordinator.selectionIDs.isEmpty
                    ? "Clear the canvas"
                    : "Delete the selected annotations."
            )
        ) {
            if coordinator.selectionIDs.isEmpty {
                coordinator.clearAll()
            } else {
                coordinator.deleteSelection()
            }
        }
    }

    /// The minimized/full switch. Shared by all four layouts: it sits
    /// next to Done so the compact bar and the full bar swap with one
    /// click in the same corner.
    private var expansionToggle: some View {
        EffectButton(
            systemImage: isMinimized ? "chevron.up.2" : "chevron.down.2",
            isSelected: false,
            help: L10n.tr(
                isMinimized
                    ? "Show all controls"
                    : "Show only the essentials"
            )
        ) {
            onToggleMinimized()
        }
    }

    /// The side-dock layout: drawing controls in a slim first column,
    /// session controls and styling in the second.
    private var verticalLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                ForEach(Self.renderableTools, id: \.self) { tool in
                    ToolButton(
                        systemImage: Self.toolSymbols[tool] ?? "pencil",
                        isSelected: coordinator.settings.tool == tool
                    ) {
                        if coordinator.isSelectionMode {
                            coordinator.isSelectionMode = false
                        }
                        coordinator.settings.tool = tool
                    }
                }

                Divider()
                    .frame(height: 1)

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
                        || !coordinator.selectionIDs.isEmpty,
                    help: L10n.tr(
                        coordinator.selectionIDs.isEmpty
                            ? "Clear the canvas"
                            : "Delete the selected annotations."
                    )
                ) {
                    if coordinator.selectionIDs.isEmpty {
                        coordinator.clearAll()
                    } else {
                        coordinator.deleteSelection()
                    }
                }

                Divider()
                    .frame(height: 1)

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

                // Minimized keeps only this column's essence: the same
                // chevron that restores the second column here re-flows
                // the bar to one slim column.
                expansionToggle

                Spacer(minLength: 0)

                finishButton
            }

            Divider()

            VStack(spacing: 6) {
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
                EffectButton(
                    systemImage: "cursorarrow.rays",
                    isSelected: coordinator.cursorEffects.isLaserEnabled,
                    help: L10n.tr("Laser Pointer")
                ) {
                    coordinator.cursorEffects.isLaserEnabled.toggle()
                }

                Divider()
                    .frame(height: 1)

                ScreenScopeMenu(coordinator: coordinator)

                RecordButton(
                    state: coordinator.recordingState,
                    lastRecordingURL: coordinator.lastRecordingURL,
                    action: { coordinator.toggleRecording() },
                    reveal: { coordinator.revealLastRecording() }
                )

                Divider()
                    .frame(height: 1)

                EffectButton(
                    systemImage: "pencil.tip",
                    isSelected: !coordinator.settings.holdOptionToDraw,
                    help: L10n.tr(
                        !coordinator.settings.holdOptionToDraw
                            ? "The pencil is latched: every click draws on the overlay. Click again to require the drawing key again."
                            : "Latch the pencil: draw with every click instead of holding the drawing key."
                    )
                ) {
                    coordinator.settings.holdOptionToDraw.toggle()
                }
                EffectButton(
                    systemImage: "snowflake",
                    isSelected: coordinator.isFreezeActive,
                    help: L10n.tr(
                        coordinator.isFreezeActive
                            ? "The screen is frozen: the displays show a still frame. Click again to go back to the live desktop under the overlay."
                            : "Freeze the screen: draw over a still frame of the desktop while the apps underneath keep running."
                    )
                ) {
                    Task { await coordinator.toggleFreeze() }
                }
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
                EffectButton(
                    systemImage: "cursorarrow.and.square.on.square.dashed",
                    isSelected: coordinator.isSelectionMode,
                    help: L10n.tr(
                        coordinator.isSelectionMode
                            ? "Move annotations is on: gestures move instead of drawing. Click the button again to draw."
                            : "Move annotations: drag a marquee to select, drag a selection to move it, use the palette to recolor it, and the trash to delete it."
                    )
                ) {
                    coordinator.toggleSelectionMode()
                }

                Divider()
                    .frame(height: 1)

                ColorPalette(
                    selection: $coordinator.settings.color,
                    favorites: coordinator.favoriteColors,
                    onAddFavorite: { coordinator.showColorPanel() },
                    layout: .grid,
                    gridColumns: 3
                )

                Image(systemName: "lineweight")
                    .foregroundStyle(.white.opacity(0.7))

                // Layout bounds stay unrotated: size the slider flat, spin
                // it about its centre, then give the stack a tall, slim
                // slot that matches the rotated visual.
                Slider(value: $coordinator.settings.lineWidth, in: 1...24, step: 1)
                    .frame(width: 110, height: 18)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 110)

                VStack(spacing: 6) {
                    drawingModeChip
                }
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.renderableTools, id: \.self) { tool in
                ToolButton(
                    systemImage: Self.toolSymbols[tool] ?? "pencil",
                    isSelected: coordinator.settings.tool == tool
                ) {
                    // Picking a drawing tool leaves the selection mode: the
                    // next drag draws instead of marquee-ing.
                    if coordinator.isSelectionMode {
                        coordinator.isSelectionMode = false
                    }
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
                    || !coordinator.selectionIDs.isEmpty,
                help: L10n.tr(
                    coordinator.selectionIDs.isEmpty
                        ? "Clear the canvas"
                        : "Delete the selected annotations."
                )
            ) {
                if coordinator.selectionIDs.isEmpty {
                    coordinator.clearAll()
                } else {
                    coordinator.deleteSelection()
                }
            }

            Divider()
                .frame(height: 22)

            // The cursor effects live next to the drawing controls: the ring
            // (circle.dashed), the spotlight, the zoom lens and the laser
            // pointer, each filled while the effect is enabled — same state
            // the menu and hotkeys toggle.
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
            EffectButton(
                systemImage: "cursorarrow.rays",
                isSelected: coordinator.cursorEffects.isLaserEnabled,
                help: L10n.tr("Laser Pointer")
            ) {
                coordinator.cursorEffects.isLaserEnabled.toggle()
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
            // click and the hold-key-to-draw mode that the chips in the
            // style row describe. Same ToolSettings flag the Settings pane
            // toggles, so the overlay re-applies it live.
            EffectButton(
                systemImage: "pencil.tip",
                isSelected: !coordinator.settings.holdOptionToDraw,
                help: L10n.tr(
                    !coordinator.settings.holdOptionToDraw
                        ? "The pencil is latched: every click draws on the overlay. Click again to require the drawing key again."
                        : "Latch the pencil: draw with every click instead of holding the drawing key."
                )
            ) {
                coordinator.settings.holdOptionToDraw.toggle()
            }

            // The dedicated whiteboard: while it is up the screens in scope
            // show a blank surface instead of the desktop, and every click
            // draws — same overlay session, no mode switch.
            // The frozen frame: while it is up the screens show a captured
            // still instead of the live desktop, and every click draws on
            // it while the apps underneath keep running. Same overlay
            // session, no mode switch.
            EffectButton(
                systemImage: "snowflake",
                isSelected: coordinator.isFreezeActive,
                help: L10n.tr(
                    coordinator.isFreezeActive
                        ? "The screen is frozen: the displays show a still frame. Click again to go back to the live desktop under the overlay."
                        : "Freeze the screen: draw over a still frame of the desktop while the apps underneath keep running."
                )
            ) {
                Task { await coordinator.toggleFreeze() }
            }

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

            // Marquee selection: while it is on, gestures highlight or move
            // what is already drawn instead of creating new marks; the
            // palette recolors the selection and the trash deletes it.
            EffectButton(
                systemImage: "cursorarrow.and.square.on.square.dashed",
                isSelected: coordinator.isSelectionMode,
                help: L10n.tr(
                    coordinator.isSelectionMode
                        ? "Move annotations is on: gestures move instead of drawing. Click the button again to draw."
                        : "Move annotations: drag a marquee to select, drag a selection to move it, use the palette to recolor it, and the trash to delete it."
                )
            ) {
                coordinator.toggleSelectionMode()
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

            // Same chevron the compact bar carries: one click re-flows
            // this row down to the essentials.
            expansionToggle

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

            drawingModeChip
        }
        .padding(.horizontal, 4)
    }

    /// The click-mode chip of the style row: what a click does right
    /// now (draw key held, capture pending Accessibility, or capture
    /// everything by choice). Shared with the vertical layout.
    @ViewBuilder
    private var drawingModeChip: some View {
        if coordinator.settings.holdOptionToDraw {
            if coordinator.overlayPassthroughActive {
                Text("\(coordinator.drawingModifier.symbol) \(L10n.tr("draw"))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .help(
                        L10n.tr("While this chip is up, only clicks with the drawing key (⌥, ⌃ or ⌘) held draw on the overlay; every other click reaches the app underneath.")
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
                    L10n.tr("The overlay captures every click by choice. Pause (⌘⇧S) to interact with other apps, or tap here to require the drawing key again.")
                )
                .onTapGesture {
                    // The pencil latch button toggles the same flag; this
                    // tap flips back without the detour through Settings.
                    coordinator.settings.holdOptionToDraw = true
                }
        }
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
        // No corner snapping: free dragging plus the dock (the tab slot
        // where the collapsed bar waits, and the rect the bar expands
        // into) are the only magnets now.
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
