import AppKit
import CoreGraphics
import Foundation

/// Watches the configured drawing modifier (⌥ by default, ⌃ or ⌘
/// selectable) system-wide while the overlays are up.
///
/// `NSView.hitTest` cannot hand a click to a *different* app: the window
/// server delivers the event to the topmost window under the cursor, and
/// returning `nil` only makes that window drop it. The reliable pass-through
/// mechanism is `NSWindow.ignoresMouseEvents`, which the window server honours
/// *before* any window receives the event. This monitor reports when the
/// drawing key goes down or up so the overlay panels can toggle that flag:
/// while the key is held the panels accept clicks (the user is drawing), and
/// the rest of the time they are transparent to the window server and every
/// other app stays fully usable — the Dock, the menu bar and the apps behind
/// the overlay.
///
/// Monitoring uses a listen-only `CGEventTap`, which requires the same
/// Accessibility permission the cursor tracker already needs.
@MainActor
final class ModifierKeyMonitor {
    /// Called on the main actor whenever the drawing key state changes.
    private let onChange: (Bool) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isModifierHeld = false
    /// The CGEvent flag bit this tap treats as down/up for the drawing key.
    private var mask: CGEventFlags

    init(mask: CGEventFlags = .maskAlternate, onChange: @escaping (Bool) -> Void) {
        self.mask = mask
        self.onChange = onChange
    }

    deinit {
        // `deinit` cannot call actor-isolated code directly. The monitor is
        // always created and destroyed on the main actor, so the teardown is
        // safe to perform there.
        MainActor.assumeIsolated {
            stop()
        }
    }

    /// Retargets the tracked modifier without rebuilding the tap.
    ///
    /// `flagsChanged` fires for every modifier chord, so switching the flag
    /// bit is enough. If the previously tracked key is still down at the
    /// switch, it is reported as released — the panels then fall back to
    /// passthrough until the new key is pressed.
    func setMask(_ mask: CGEventFlags) {
        guard mask != self.mask else { return }
        self.mask = mask
        if isModifierHeld {
            isModifierHeld = false
            onChange(false)
        }
    }

    /// Starts observing. Returns `false` when the tap cannot be created —
    /// in practice when the Accessibility permission is missing — so the
    /// caller can fall back to a non-pass-through mode.
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ModifierKeyMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            // The tap's run loop source is installed on the main run loop, so
            // the callback always arrives on the main thread.
            MainActor.assumeIsolated {
                monitor.handleEvent(event)
            }
            return Unmanaged.passUnretained(event)
        }

        // A listen-only tap observes the event without being able to swallow
        // it, which is all this monitor needs.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isModifierHeld = false
    }

    // MARK: - Private

    private func handleEvent(_ event: CGEvent) {
        let held = event.flags.contains(mask)
        guard held != isModifierHeld else { return }
        isModifierHeld = held
        onChange(held)
    }
}
