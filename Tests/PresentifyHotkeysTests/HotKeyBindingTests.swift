import AppKit
import Carbon.HIToolbox
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

@Suite("Hot key binding store", .serialized)
@MainActor
struct HotKeyBindingStoreTests {
    /// An isolated defaults store so tests never touch the real app record.
    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test("Saved bindings round-trip")
    func roundTrip() {
        let defaults = makeDefaults()

        HotKeyBindingStore.save(HotKeyManager.defaultBindings, to: defaults)
        let loaded = HotKeyBindingStore.load(from: defaults)

        #expect(loaded == HotKeyManager.defaultBindings)
    }

    @Test("Stored overrides replace only their own actions")
    func overridesMergeOverDefaults() {
        let defaults = makeDefaults()
        var custom = HotKeyManager.defaultBindings
        custom[.toggleAnnotation] = HotKeyManager.Binding(
            key: .y,
            modifiers: [.command, .control, .option, .shift]
        )
        HotKeyBindingStore.save(custom, to: defaults)

        let loaded = HotKeyBindingStore.load(from: defaults)

        #expect(loaded[.toggleAnnotation] == custom[.toggleAnnotation])
        // Everything else stays at the factory default.
        #expect(loaded[.undo] == HotKeyManager.defaultBindings[.undo])
        #expect(loaded[.redo] == HotKeyManager.defaultBindings[.redo])
        #expect(loaded[.toggleRecording] == HotKeyManager.defaultBindings[.toggleRecording])
    }

    @Test("Corrupt records fall back to factory defaults")
    func corruptFallsBackToDefault() {
        let defaults = makeDefaults()
        // Invalid Carbon key code and an unknown action raw value are both
        // skipped; the rest of the record still applies.
        let stored: [String: StoredHotKeyBinding] = [
            HotKeyAction.toggleZoom.rawValue: StoredHotKeyBinding(keyCode: 99_999, modifiers: 0),
            "not-an-action": StoredHotKeyBinding(keyCode: 8, modifiers: 1),
        ]
        let data = try! JSONEncoder().encode(stored)
        defaults.set(data, forKey: HotKeyBindingStore.defaultsKey)

        let loaded = HotKeyBindingStore.load(from: defaults)

        #expect(loaded[.toggleZoom] == HotKeyManager.defaultBindings[.toggleZoom])
    }

    @Test("Load without a record returns the defaults")
    func emptyLoadReturnsDefaults() {
        let defaults = makeDefaults()

        #expect(HotKeyBindingStore.load(from: defaults) == HotKeyManager.defaultBindings)
    }
}

@Suite("Hot key helper behaviour", .serialized)
@MainActor
struct HotKeyHelperTests {
    @Test("readableDescription lists modifiers in system order")
    func readableDescriptionGlyphOrder() {
        // macOS menus render modifiers in the ⌃⌥⇧⌘ order, shift never
        // jumping ahead of command.
        let annotation = HotKeyManager.defaultBindings[.toggleAnnotation]!
        #expect(annotation.readableDescription == "⇧⌘A")

        let all = HotKeyManager.Binding(
            key: .y,
            modifiers: [.command, .control, .option, .shift]
        )
        #expect(all.readableDescription == "⌃⌥⇧⌘Y")

        let quit = HotKeyManager.defaultBindings[.quit]!
        #expect(quit.readableDescription == "⌥⌘Q")
    }

    @Test("Only command combinations are acceptable system-wide")
    func acceptableRequiresCommand() {
        let command = HotKeyManager.Binding(key: .k, modifiers: [.command, .shift])
        let plain = HotKeyManager.Binding(key: .k, modifiers: [.shift])
        let bare = HotKeyManager.Binding(key: .k, modifiers: [])

        #expect(HotKeyManager.isAcceptable(command))
        #expect(!HotKeyManager.isAcceptable(plain))
        #expect(!HotKeyManager.isAcceptable(bare))
    }

    @Test("Conflicts report the action holding the combination")
    func conflictDetection() {
        var bindings = HotKeyManager.defaultBindings
        // Reuse the annotation combination on pause: the same binding now
        // belongs to two actions.
        bindings[.togglePause] = HotKeyManager.defaultBindings[.toggleAnnotation]

        let reported = HotKeyManager.conflict(
            for: bindings[.toggleAnnotation]!,
            in: bindings,
            for: .toggleAnnotation
        )

        #expect(reported != nil)

        // Nothing is in conflict when the combination belongs to nobody.
        let none = HotKeyManager.conflict(
            for: HotKeyManager.Binding(key: .h, modifiers: [.command, .option]),
            in: bindings,
            for: .toggleSpotlight
        )
        #expect(none == nil)
    }

    @Test("A binding can be built from a key-down event")
    func bindingFromKeyDownEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cg = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: true
        )!
        cg.flags = [.maskCommand, .maskShift]
        let event = NSEvent(cgEvent: cg)!

        let binding = HotKeyManager.binding(fromKeyDown: event)

        #expect(binding?.key == .c)
        #expect(binding?.modifiers.contains(.command) == true)
        #expect(binding?.modifiers.contains(.shift) == true)
        #expect(binding?.modifiers.contains(.option) == false)
    }

    @Test("Modifier-only and unpresentable events carry no binding")
    func modifierEventsProduceNoBinding() {
        // ⌘ alone: never forms a binding.
        let command = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_Command),
            keyDown: true
        )!
        command.flags = .maskCommand
        #expect(NSEvent(cgEvent: command)! != nil)
        #expect(
            HotKeyManager.binding(fromKeyDown: NSEvent(cgEvent: command)!) == nil
        )

        // A key code with no `Key` mapping carries no binding either.
        let unmapped = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(200), keyDown: true)!
        #expect(
            HotKeyManager.binding(fromKeyDown: NSEvent(cgEvent: unmapped)!) == nil
        )
    }

    @Test("Pure modifier key codes are recognized")
    func modifierKeyCodeRecognition() {
        #expect(HotKeyManager.isModifierKeyCode(UInt16(kVK_Command)))
        #expect(HotKeyManager.isModifierKeyCode(UInt16(kVK_RightShift)))
        #expect(HotKeyManager.isModifierKeyCode(UInt16(kVK_Function)))
        #expect(!HotKeyManager.isModifierKeyCode(UInt16(kVK_ANSI_C)))
    }
}

