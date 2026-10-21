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

        let size = NSSize(width: 576, height: 104)
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
        .padding(10)
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
