import AppKit
import Carbon.HIToolbox
import Foundation
import OvermarkCore
@preconcurrency import HotKey

/// The actions the user can trigger from anywhere in the system.
public enum HotKeyAction: String, CaseIterable, Sendable {
    /// Enter or leave annotation mode.
    case toggleAnnotation
    /// Pause the overlay so the app underneath can be used.
    case togglePause
    /// Replace the screen contents with a blank board to draw on.
    case toggleWhiteboard
    /// Show a captured still of the screen to annotate over and exclude the
    /// live world underneath.
    case toggleFreezeScreen
    /// Show or hide the spotlight effect.
    case toggleSpotlight
    /// Show or hide the cursor highlight.
    case toggleHighlight
    /// Show or hide the zoom lens.
    case toggleZoom
    /// Start or stop the presentation recording.
    case toggleRecording
    /// Undo the last annotation.
    case undo
    /// Redo the last undone annotation.
    case redo
    /// Copy the screenshot to the clipboard.
    case copyScreenshot
    /// Save the screenshot.
    case saveScreenshot
    /// Quit the app.
    case quit
}

/// Registers the global hot keys and reports the actions they trigger.
///
/// Hot keys are global, so they work no matter which app is frontmost. The
/// Carbon `RegisterEventHotKey` API is used through the `HotKey` package
/// because it is the only approach that does not require Accessibility
/// permission.
@MainActor
public final class HotKeyManager {
    /// A key and modifier combination.
    ///
    /// `Key` and `NSEvent.ModifierFlags` are not `Hashable`/`Sendable` in Swift
    /// 6, so the conformance is spelled out rather than synthesised.
    public struct Binding: Hashable {
        public var key: Key
        public var modifiers: NSEvent.ModifierFlags

        public init(key: Key, modifiers: NSEvent.ModifierFlags) {
            self.key = key
            self.modifiers = modifiers
        }

        public static func == (lhs: Binding, rhs: Binding) -> Bool {
            lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(modifiers.rawValue)
        }

        /// A readable rendering of the combination, modifier glyphs first
        /// ("⌃⌥⇧⌘A"), using the system convention.
        public var readableDescription: String {
            var glyphs = ""
            if modifiers.contains(.control) { glyphs += "⌃" }
            if modifiers.contains(.option) { glyphs += "⌥" }
            if modifiers.contains(.shift) { glyphs += "⇧" }
            if modifiers.contains(.command) { glyphs += "⌘" }
            return glyphs + key.description
        }
    }

    /// The default key bindings.
    ///
    /// Every binding combines `⌘` with at least one other modifier. Plain `⌘Z`,
    /// `⌘C` or `⌘Q` are deliberately avoided: hot keys are registered
    /// system-wide, so binding a bare command combination would silently
    /// break undo, copy and quit in every other application the user has
    /// open while presenting.
    public static let defaultBindings: [HotKeyAction: Binding] = [
        .toggleAnnotation: Binding(key: .a, modifiers: [.command, .shift]),
        .togglePause: Binding(key: .s, modifiers: [.command, .shift]),
        .toggleWhiteboard: Binding(key: .b, modifiers: [.command, .shift]),
        .toggleFreezeScreen: Binding(key: .p, modifiers: [.command, .shift]),
        .toggleSpotlight: Binding(key: .d, modifiers: [.command, .shift]),
        .toggleHighlight: Binding(key: .f, modifiers: [.command, .shift]),
        .toggleZoom: Binding(key: .g, modifiers: [.command, .shift]),
        .toggleRecording: Binding(key: .r, modifiers: [.command, .shift]),
        .undo: Binding(key: .z, modifiers: [.command, .option]),
        .redo: Binding(key: .z, modifiers: [.command, .option, .shift]),
        .copyScreenshot: Binding(key: .c, modifiers: [.command, .shift]),
        .saveScreenshot: Binding(key: .s, modifiers: [.command, .shift, .option]),
        .quit: Binding(key: .q, modifiers: [.command, .option]),
    ]

    /// Whether a combination is acceptable for a system-wide hot key.
    ///
    /// Bindings are global, so anything that omits `⌘` (or is made of pure
    /// modifiers alone) would collide with other applications or consume
    /// keys the presenter cannot reproduce. The default bindings all obey
    /// this rule, as must the user's custom ones.
    public static func isAcceptable(_ binding: Binding) -> Bool {
        binding.modifiers.contains(.command)
    }

    /// Builds a binding from a key-down event, or nil when the event cannot
    /// become one.
    ///
    /// Pure modifier keys (left/right ⌘⇧⌥⌃, fn, caps lock) carry no binding
    /// of their own, and any modifier noise outside the four regular flags
    /// is dropped so a registration never runs with device-dependent bits.
    public static func binding(fromKeyDown event: NSEvent) -> Binding? {
        guard !isModifierKeyCode(event.keyCode) else { return nil }
        guard let key = Key(carbonKeyCode: UInt32(event.keyCode)) else { return nil }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .shift, .option, .control])
        return Binding(key: key, modifiers: flags)
    }

    /// Whether a key code is one of the pure modifier keys (including the
    /// right-hand variants, fn and caps lock), which carry no binding.
    public static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        let codes: [UInt16] = [
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
            UInt16(kVK_Function), UInt16(kVK_CapsLock),
        ]
        return codes.contains(keyCode)
    }

    /// The action already bound to a given combination, if any.
    ///
    /// Scans in `HotKeyAction.allCases` order rather than dictionary order so
    /// the reported conflict is deterministic, and skipping `excluded` lets
    /// the settings UI re-assign an action's own combination safely.
    public static func conflict(
        for binding: Binding,
        in bindings: [HotKeyAction: Binding],
        for excluded: HotKeyAction
    ) -> HotKeyAction? {
        HotKeyAction.allCases.first { action in
            guard action != excluded else { return false }
            guard let current = bindings[action] else { return false }
            return current == binding
        }
    }

    /// Called when a hot key fires.
    public var onAction: ((HotKeyAction) -> Void)?

    private var hotKeys: [HotKeyAction: HotKey] = [:]

    public init() {}

    /// Registers every default binding.
    public func registerDefaults() {
        for (action, binding) in Self.defaultBindings {
            register(action, binding: binding)
        }
    }

    /// Registers a single hot key.
    ///
    /// - Parameters:
    ///   - action: The action to trigger.
    ///   - binding: The key combination that triggers it.
    public func register(_ action: HotKeyAction, binding: Binding) {
        // Release the previous registration for this action so the new
        // binding does not fight with the old one for the same key combo.
        unregister(action)

        let hotKey = HotKey(
            keyCombo: KeyCombo(key: binding.key, modifiers: binding.modifiers)
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.onAction?(action)
            }
        }

        hotKeys[action] = hotKey
    }

    /// Removes the hot key registered for an action.
    public func unregister(_ action: HotKeyAction) {
        hotKeys[action] = nil
    }

    /// Removes every registered hot key.
    public func unregisterAll() {
        hotKeys.removeAll()
    }

    /// Whether a hot key is currently registered for an action.
    public func isRegistered(_ action: HotKeyAction) -> Bool {
        hotKeys[action] != nil
    }

    // MARK: - Escape

    /// The ad-hoc Escape hot key, registered only while the overlays are up.
    ///
    /// A bare Escape held permanently would swallow the key in every other
    /// application, day to day. Registering it just for the duration of a
    /// presentation gives the presenter a guaranteed way out — even if the
    /// control bar fails to show or the overlays become unresponsive.
    private var escapeHotKey: HotKey?

    /// Registers Escape as a one-tap "end the presentation" key.
    public func registerEscape(_ handler: @escaping () -> Void) {
        // Replace any previous registration instead of doubling it.
        escapeHotKey = nil
        escapeHotKey = HotKey(
            keyCombo: KeyCombo(key: .escape, modifiers: [])
        ) {
            MainActor.assumeIsolated { handler() }
        }
    }

    /// Releases the Escape registration so the key returns to normal use.
    public func unregisterEscape() {
        escapeHotKey = nil
    }

    /// The binding currently in effect for an action.
    public func binding(for action: HotKeyAction) -> Binding? {
        guard let hotKey = hotKeys[action] else { return nil }
        return Binding(key: hotKey.keyCombo.key ?? .a, modifiers: hotKey.keyCombo.modifiers)
    }
}

