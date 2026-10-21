import AppKit
import CoreGraphics
import Foundation
import PresentifyCapture
import PresentifyCore

/// Manages the cursor effect windows, one per display.
///
/// The effect window sits above everything but ignores mouse events, so the
/// user keeps full control of the app underneath while the halo, spotlight or
/// zoom lens is visible.
@MainActor
public final class CursorEffectController {
    private struct WindowEntry {
        var window: NSWindow
        var view: CursorEffectView
    }

    private var entries: [CGDirectDisplayID: WindowEntry] = [:]
    private let captureService: ScreenCaptureService

    /// Whether a window rebuild is currently running.
    private var isRebuilding = false
    /// The newest settings that arrived while a rebuild was running.
    private var pendingEffects: CursorEffects?

    public init(captureService: ScreenCaptureService) {
        self.captureService = captureService
    }

    /// The effects currently rendered.
    public private(set) var effects = CursorEffects()

    /// Shows the effect windows on every display.
    ///
    /// Settings sliders fire one event per tick, so bursts of overlapping
    /// rebuilds are the norm rather than the exception. Overlapping builds
    /// would interleave their `await`s and litter the screen with orphaned
    /// windows; instead the running build coalesces the newest request and
    /// chains it.
    public func show(effects: CursorEffects) async {
        guard !isRebuilding else {
            pendingEffects = effects
            return
        }
        isRebuilding = true

        var current = effects
        repeat {
            pendingEffects = nil
            await rebuild(effects: current)
            if let pending = pendingEffects {
                current = pending
                continue
            }
            break
        } while true

        isRebuilding = false
    }

    /// Applies new effects, updating the windows in place when possible.
    ///
    /// A rebuild is only needed when no windows exist yet, when everything
    /// turns off, or when the zoom lens turns on without a background
    /// screenshot to magnify. Everything else — nudging the zoom factor,
    /// toggling the highlight on top of an already-built spotlight — only
    /// pushes values into the existing views, so sliders stay smooth.
    public func apply(effects: CursorEffects) async {
        let hadBackgrounds = entries.values.contains { $0.view.backgroundImage != nil }
        let needsRebuild = entries.isEmpty
            || effects == CursorEffects()
            || (effects.isZoomEnabled && !hadBackgrounds)

        guard !needsRebuild else {
            await show(effects: effects)
            return
        }
        update(effects: effects)
    }

    private func rebuild(effects: CursorEffects) async {
        self.effects = effects
        tearDown()

        guard effects != CursorEffects() else { return }
        guard let displays = try? await captureService.availableDisplays() else { return }

        // The zoom lens needs a picture of the screen to magnify. The
        // capture runs while no effect window is visible, so the lens does
        // not end up magnifying its own dimming layer.
        let background = await captureBackground(displays: displays)

        for display in displays {
            let frame = display.screen.frame
            let rect = NSRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )

            let window = NSWindow(
                contentRect: rect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            // tearDown() also drops the controller's strong reference, so the
            // window must not also self-release on close: close() defers an
            // autorelease, and popping that pool after the last strong
            // reference goes away over-releases freed memory (SIGSEGV inside
            // the enclosing Swift concurrency job's autorelease pool).
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isExcludedFromWindowsMenu = true

            let view = CursorEffectView(frame: rect)
            view.screen = display.screen
            view.effects = effects
            view.backgroundImage = background[display.displayID]

            window.contentView = view
            window.orderFrontRegardless()

            entries[display.displayID] = WindowEntry(window: window, view: view)
        }
    }

    /// Updates the effects without recreating the windows.
    public func update(effects: CursorEffects) {
        self.effects = effects
        for entry in entries.values {
            entry.view.effects = effects
        }
    }

    /// Moves the pointer position into the effect views.
    public func updateCursorLocation(_ point: Point) {
        for entry in entries.values {
            entry.view.cursorLocation = point
        }
    }

    /// Removes the effect windows.
    public func tearDown() {
        for entry in entries.values {
            entry.window.orderOut(nil)
            entry.window.close()
        }
        entries.removeAll()
    }

    // MARK: - Private

    /// Captures each display so the zoom lens has something to magnify.
    private func captureBackground(
        displays: [ScreenCaptureService.DisplayInfo]
    ) async -> [CGDirectDisplayID: CGImage] {
        guard effects.isZoomEnabled else { return [:] }

        var images: [CGDirectDisplayID: CGImage] = [:]
        for display in displays {
            guard let snapshot = try? await captureService.capture(displayID: display.displayID) else {
                continue
            }
            images[display.displayID] = snapshot.image
        }
        return images
    }
}
