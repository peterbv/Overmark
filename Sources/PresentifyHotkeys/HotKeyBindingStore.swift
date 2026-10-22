import AppKit
import Foundation
import HotKey
import PresentifyCore

/// A serialized (Carbon key code, modifiers) pair for a hot key binding.
///
/// `Key` and `NSEvent.ModifierFlags` are not directly `Codable`, so the store
/// keeps the Carbon representation — the same numbers `KeyCombo` uses under
/// the hood — and rebuilds the binding when it loads.
public struct StoredHotKeyBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt

    public init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Persists the user's hot key bindings in `UserDefaults` as JSON data.
///
/// `load` always merges over `HotKeyManager.defaultBindings`: only actions
/// present in the store are overridden, so a corrupt or partial record can
/// never leave an action unregistered — undecodable entries are skipped and
/// fall back to the factory default.
public enum HotKeyBindingStore {
    /// `load` reads `HotKeyManager.defaultBindings`, so the whole store runs
    /// under the manager's main-actor isolation.
    @MainActor
    public static let defaultsKey = "Presentify.hotKeyBindings"

    /// Reads the stored overrides merged over the factory defaults.
    @MainActor
    public static func load(
        from defaults: UserDefaults = .standard
    ) -> [HotKeyAction: HotKeyManager.Binding] {
        var bindings = HotKeyManager.defaultBindings
        guard let data = defaults.data(forKey: defaultsKey) else { return bindings }
        guard
            let stored = try? JSONDecoder().decode(
                [String: StoredHotKeyBinding].self,
                from: data
            )
        else {
            return bindings
        }

        for (rawAction, entry) in stored {
            guard let action = HotKeyAction(rawValue: rawAction) else { continue }
            guard modifiersAreSane(entry.modifiers) else { continue }
            guard let key = Key(carbonKeyCode: entry.keyCode) else { continue }
            bindings[action] = HotKeyManager.Binding(
                key: key,
                modifiers: NSEvent.ModifierFlags(rawValue: entry.modifiers)
            )
        }
        return bindings
    }

    /// Writes only the entries that differ from the factory defaults, so the
    /// store holds real overrides: actions the user never touched keep
    /// following `HotKeyManager.defaultBindings` even if those defaults
    /// evolve, and a full reset leaves an empty record.
    @MainActor
    public static func save(
        _ bindings: [HotKeyAction: HotKeyManager.Binding],
        to defaults: UserDefaults = .standard
    ) {
        var stored: [String: StoredHotKeyBinding] = [:]
        for (action, binding) in bindings {
            guard binding != HotKeyManager.defaultBindings[action] else { continue }
            stored[action.rawValue] = StoredHotKeyBinding(
                keyCode: binding.key.carbonKeyCode,
                modifiers: binding.modifiers.rawValue
            )
        }

        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Drops anything beyond the four regular modifiers so a stale record
    /// cannot register combinations that carry event-device noise.
    private static func modifiersAreSane(_ raw: UInt) -> Bool {
        let allowed = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
        return raw != 0 && raw & ~allowed == 0
    }
}
