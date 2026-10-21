import AppKit
import CoreGraphics
import Foundation
import PresentifyCore

/// Tracks the global cursor position.
///
/// `NSEvent.mouseLocation` only reports the position when an app is active,
/// so following the pointer while another app is frontmost needs a
/// `CGEventTap` on the mouse-moved event. That tap requires the Accessibility
/// permission, which the app checks before enabling it.
@MainActor
public final class CursorTracker {
    /// Called whenever the pointer moves.
    public var onMove: ((Point) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastLocation: Point?

    public init() {}

    deinit {
        // `deinit` cannot call actor-isolated code directly. The tracker is
        // always created and destroyed on the main actor, so the teardown is
        // safe to perform there.
        MainActor.assumeIsolated {
            stop()
        }
    }

    /// The most recently observed pointer location.
    public var location: Point? { lastLocation }

    /// Whether the tracker is currently receiving events.
    public var isRunning: Bool { eventTap != nil }

    /// Whether the app has the Accessibility permission needed for the tap.
    public nonisolated static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user for the Accessibility permission.
    @discardableResult
    public nonisolated static func requestAccessibilityPermission() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a mutable global in the SDK, which
        // Swift 6 rejects as concurrency-unsafe. The key is a stable string
        // constant, so it is written out literally to avoid touching the
        // global from a concurrent context.
        let promptOptions = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(promptOptions as CFDictionary)
    }

    /// Starts tracking the pointer.
    public func start() {
        guard eventTap == nil else { return }

        // `tapCreate` fails when the app is not trusted for Accessibility.
        // The tap is created once and never retried, so starting the tracker
        // before the permission is granted would leave it inert for the rest
        // of the session. Bailing out here lets the caller start it again
        // once the permission shows up.
        guard Self.hasAccessibilityPermission() else { return }

        // Mouse moved plus every drag variant: macOS stops emitting plain
        // `mouseMoved` while a button is held down, so without the dragged
        // events the spotlight, highlight ring and zoom lens would freeze
        // whenever the user drags something across the screen.
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDragged.rawValue)
                | (1 << CGEventType.rightMouseDragged.rawValue)
                | (1 << CGEventType.otherMouseDragged.rawValue)
        )
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            // Pass the event through untouched; we only observe it.
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<CursorTracker>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            // The tap's run loop source is installed on the main run loop, so
            // the callback always arrives on the main thread.
            MainActor.assumeIsolated {
                tracker.handleMouseEvent(event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    /// Stops tracking the pointer.
    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Private

    private func handleMouseEvent(_ event: CGEvent) {
        let location = event.location
        let point = Self.toAppKitSpace(CGPoint(x: location.x, y: location.y))
        lastLocation = point
        onMove?(point)
    }

    /// Converts a global Quartz point into the AppKit screen space used by
    /// the core module.
    ///
    /// Quartz puts the origin at the top-left of the primary display; AppKit
    /// puts it at the bottom-left. The flip is relative to the primary
    /// display's height, which is what the global coordinate spaces differ by.
    /// The primary display is the one anchored at (0, 0) — `NSScreen.screens`
    /// makes no guarantee about which screen comes first.
    static func toAppKitSpace(_ quartzPoint: CGPoint) -> Point {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == NSPoint(x: 0, y: 0) }) ?? NSScreen.screens.first else {
            return Point(x: Double(quartzPoint.x), y: Double(quartzPoint.y))
        }
        let primaryHeight = primary.frame.height
        return Point(
            x: Double(quartzPoint.x),
            y: Double(primaryHeight - quartzPoint.y)
        )
    }
}
