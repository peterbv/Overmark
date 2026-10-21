import AppKit
import Testing
@testable import PresentifyHotkeys

@Suite("Default hot key bindings")
@MainActor
struct HotKeyBindingTests {
    @Test("Every action has a default binding")
    func allActionsBound() {
        for action in HotKeyAction.allCases {
            #expect(HotKeyManager.defaultBindings[action] != nil)
        }
    }

    @Test("No two actions share the same combination")
    func noDuplicateCombinations() {
        var seen: Set<HotKeyManager.Binding> = []

        for binding in HotKeyManager.defaultBindings.values {
            #expect(!seen.contains(binding), "duplicate hot key combination")
            seen.insert(binding)
        }
    }

    /// Hot keys are registered system-wide, so a bare `⌘Z` or `⌘C` would
    /// break that shortcut in every other application the user has open.
    @Test("No binding steals a bare command shortcut")
    func noBareCommandShortcuts() {
        for (action, binding) in HotKeyManager.defaultBindings {
            let modifiers = binding.modifiers
            let isBareCommand = modifiers.contains(.command)
                && !modifiers.contains(.shift)
                && !modifiers.contains(.option)
                && !modifiers.contains(.control)

            #expect(!isBareCommand, "\(action) uses a bare command shortcut")
        }
    }

    @Test("Undo and redo are distinct combinations")
    func undoAndRedoDiffer() {
        let undo = HotKeyManager.defaultBindings[.undo]
        let redo = HotKeyManager.defaultBindings[.redo]

        #expect(undo != nil)
        #expect(redo != nil)
        #expect(undo != redo)
    }
}
