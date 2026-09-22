import AppKit
import Carbon
import Combine
import SwiftUI

/// Backing store for the Shortcuts pane.
///
/// The two shortcut systems stay separate the way the managers do: global
/// hotkeys are Carbon key codes registered app-wide, editor commands are
/// character chords matched inside the overlay.
@MainActor
final class ShortcutSettingsModel: ObservableObject {

    /// Bumped on every write so the rows re-read their display strings.
    @Published private var revision = 0

    // MARK: Global hotkeys

    func display(for slot: HotkeyManager.HotkeySlot) -> String {
        _ = revision
        return HotkeyManager.displayString(for: slot)
    }

    func isAssigned(_ slot: HotkeyManager.HotkeySlot) -> Bool {
        _ = revision
        return HotkeyManager.displayString(for: slot) != L("None")
    }

    /// Whether the slot differs from its shipped default — the restore button
    /// only earns its place once there is something to restore.
    func isCustomised(_ slot: HotkeyManager.HotkeySlot) -> Bool {
        _ = revision
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: slot.disabledKey) { return true }
        let keyCode = defaults.object(forKey: slot.keyCodeKey) as? Int
        let modifiers = defaults.object(forKey: slot.modifiersKey) as? Int
        guard keyCode != nil || modifiers != nil else { return false }
        return keyCode != Int(slot.defaultKeyCode) || modifiers != Int(slot.defaultModifiers)
    }

    func assign(_ slot: HotkeyManager.HotkeySlot, keyCode: UInt32, modifiers: UInt32) {
        HotkeyManager.saveHotkey(for: slot, keyCode: keyCode, modifiers: modifiers)
        revision += 1
    }

    func reset(_ slot: HotkeyManager.HotkeySlot) {
        HotkeyManager.saveHotkey(for: slot,
                                 keyCode: slot.defaultKeyCode,
                                 modifiers: slot.defaultModifiers)
        revision += 1
    }

    /// AppKit modifier flags → the Carbon bitfield `RegisterEventHotKey` wants.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    // MARK: Editor commands

    func display(for action: EditorCommandShortcutManager.Action) -> String {
        _ = revision
        let value = EditorCommandShortcutManager.displayString(for: action)
        return value.isEmpty ? L("None") : value
    }

    func isCustomised(_ action: EditorCommandShortcutManager.Action) -> Bool {
        _ = revision
        return UserDefaults.standard.object(forKey: "editorCommandShortcuts.\(action.rawValue)") != nil
    }

    func assign(_ action: EditorCommandShortcutManager.Action,
                modifiers: NSEvent.ModifierFlags, character: String) {
        EditorCommandShortcutManager.setShortcut(
            .init(character: character, modifiers: modifiers), for: action)
        revision += 1
    }

    func reset(_ action: EditorCommandShortcutManager.Action) {
        EditorCommandShortcutManager.reset(action)
        revision += 1
    }
}
