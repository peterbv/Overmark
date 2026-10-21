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

        // Enumerate displays from AppKit: building the windows must not
        // depend on the Screen Recording permission at all. Only the zoom
        // lens's background capture does, and it degrades per-display.
        let screens = NSScreen.screens.compactMap { screen -> ScreenIdentity? in
            guard let displayID = ScreenIdentity.displayID(of: screen) else { return nil }
            return ScreenIdentity(displayID: displayID, screen: screen)
        }
        guard !screens.isEmpty else { return }

        // The zoom lens needs a picture of the screen to magnify. The
        // capture runs while no effect window is visible, so the lens does
        // not end up magnifying its own dimming layer.
        var backgrounds: [CGDirectDisplayID: CGImage] = [:]
        if effects.isZoomEnabled {
            for screen in screens {
                if let snapshot = try? await captureService.capture(displayID: screen.displayID) {
                    backgrounds[screen.displayID] = snapshot.image
                }
            }
        }

        for screen in screens {
            let frame = screen.appKitFrame
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
            view.screen = screen.screenFrame
            view.effects = effects
            view.backgroundImage = backgrounds[screen.displayID]

            window.contentView = view
            window.orderFrontRegardless()

            entries[screen.displayID] = WindowEntry(window: window, view: view)
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

    /// One AppKit screen plus the identifiers the controller keys on.
    ///
    /// `NSScreen.screens` needs no permission, unlike ScreenCaptureKit's
    /// display enumeration, so the effect windows can be built (and torn
    /// down) regardless of what Screen Recording allows.
    private struct ScreenIdentity {
        var displayID: CGDirectDisplayID
        var appKitFrame: NSRect
        var screenFrame: ScreenFrame

        static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        init(displayID: CGDirectDisplayID, screen: NSScreen) {
            self.displayID = displayID
            self.appKitFrame = screen.frame
            let frame = screen.frame
            self.screenFrame = ScreenFrame(
                origin: Point(x: frame.origin.x, y: frame.origin.y),
                size: Size(width: frame.size.width, height: frame.size.height),
                scale: Double(screen.backingScaleFactor)
            )
        }
    }
}
