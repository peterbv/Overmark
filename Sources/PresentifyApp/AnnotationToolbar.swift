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
    private let coordinator: AppCoordinator
    private var panel: OverlayPanel?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    /// Places the bar under the menu bar of the given screen.
    func show(on screen: NSScreen) {
        hide()

        let size = NSSize(width: 680, height: 104)
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
        panel.contentView = NSHostingView(rootView: AnnotationToolbarView(coordinator: coordinator))
        // `isMovableByWindowBackground` cannot move a window whose content
        // view is an NSHostingView — SwiftUI consumes the clicks — so a
        // dedicated grip strip drives the standard window-drag machinery.
        let handle = DragHandleView(
            frame: NSRect(x: size.width / 2 - 40, y: size.height - 16, width: 80, height: 12)
        )
        handle.toolTip = L10n.tr("Drag here to move the toolbar")
        panel.contentView?.addSubview(handle)
        panel.orderFrontRegardless()

        self.panel = panel
    }

    /// Removes the bar.
    func hide() {
        panel?.dismiss()
        panel?.contentView = nil
        panel?.close()
        panel = nil
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
            AnnotationControlButton(systemImage: "gearshape") {
                coordinator.onShowAppSettings?()
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
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSCursor.closedHand.set()
        // Runs its own nested event loop and returns as soon as the user
        // releases the button; AppKit handles all the tracking.
        window.performDrag(with: event)
        NSCursor.arrow.set()
        clampIntoVisibleArea()
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
