import AppKit
import Carbon
import SwiftUI

/// The Shortcuts pane.
///
/// Each row follows the project's shortcut-recorder convention: label on the
/// left, a key-cap pill on the right that starts recording when clicked, and a
/// round restore button that only appears once the shortcut differs from its
/// default. No fixed-width "Set" button, no ✕ to clear.
struct ShortcutSettingsView: View {
    @StateObject private var model = ShortcutSettingsModel()
    var onHotkeyChanged: () -> Void
    /// The main menu carries Undo/Redo as key equivalents; it is rebuilt when
    /// either changes, or the menu kept showing the old chord until relaunch.
    var onEditorCommandChanged: () -> Void

    @State private var showingToolKeys = false

    var body: some View {
        Form {
            // Two columns. Twelve of these stacked ran past the bottom of the
            // window on anything smaller than a desktop display, and the pane
            // cannot scroll. A shortcut row is a label and a key cap pinned to
            // opposite ends, so a single column was spending 400pt of the
            // window's width on the gap between them.
            Section {
                let slots = HotkeyManager.HotkeySlot.allCases
                let half = (slots.count + 1) / 2
                HStack(alignment: .top, spacing: 20) {
                    hotkeyColumn(Array(slots.prefix(half)))
                    hotkeyColumn(Array(slots.dropFirst(half)))
                }
                .padding(.vertical, 2)
            } header: {
                Text(L("Keyboard Shortcuts"))
            } footer: {
                Text(L("Click a shortcut and press a key combination with at least one modifier (⌘, ⌥, ⌃, ⇧). Esc cancels. Function keys work on their own."))
            }

            Section {
                ForEach(EditorCommandShortcutManager.Action.allCases, id: \.rawValue) { command in
                    EditorCommandRow(command: command, model: model, onChange: onEditorCommandChanged)
                }
                LabeledContent(L("Tools")) {
                    Button(L("Edit Keys…")) { showingToolKeys = true }
                }
                Toggle(L("Show shortcuts in tooltips"), isOn: $model.showToolShortcutsInTooltips)
            } header: {
                Text(L("Overlay / Editor Shortcuts"))
            } footer: {
                Text(L("These apply inside the capture overlay and the editor window."))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .sheet(isPresented: $showingToolKeys) {
            ToolKeysSheet(model: model)
        }
    }

    private func hotkeyColumn(_ slots: [HotkeyManager.HotkeySlot]) -> some View {
        VStack(spacing: 10) {
            ForEach(slots, id: \.rawValue) { slot in
                HotkeyRow(slot: slot, model: model, onChange: onHotkeyChanged)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One global-hotkey row.
private struct HotkeyRow: View {
    let slot: HotkeyManager.HotkeySlot
    @ObservedObject var model: ShortcutSettingsModel
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(slot.label)
            Spacer()
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? L("Press a shortcut…") : model.display(for: slot))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(model.isAssigned(slot) || recording ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.18)
                                            : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            if model.isCustomised(slot) && !recording {
                Button {
                    model.reset(slot)
                    onChange()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Reset to default"))
            }
        }
        // The monitor must not outlive the window, or it keeps swallowing keys
        // after the pane is gone.
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }   // Esc cancels
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let carbon = ShortcutSettingsModel.carbonModifiers(from: mods)
            // A bare key would fire while typing anywhere; function keys are the
            // documented exception because they carry no text.
            let isFunctionKey = HotkeyManager.isFunctionKey(UInt32(event.keyCode))
            guard isFunctionKey || !mods.intersection([.command, .control, .option]).isEmpty else {
                return nil
            }
            model.assign(slot, keyCode: UInt32(event.keyCode), modifiers: carbon)
            onChange()
            stop()
            return nil   // swallow the keystroke that was being recorded
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// One overlay/editor command row. These are plain characters — no modifier
/// requirement — so they record differently from the global hotkeys.
private struct EditorCommandRow: View {
    let command: EditorCommandShortcutManager.Action
    @ObservedObject var model: ShortcutSettingsModel
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(command.label)
            Spacer()
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? L("Press a shortcut…") : model.display(for: command))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.18)
                                            : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            if model.isCustomised(command) && !recording {
                Button {
                    model.reset(command)
                    onChange()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Reset to default"))
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            // These are menu key equivalents, so Command is required; Shift,
            // Option and Control may be added to tell chords apart. The
            // character goes through the matcher so it follows the keyboard
            // layout, and falls back to Latin on Russian or Arabic input —
            // the raw character would be stored as "я" and never match.
            let modifiers = KeyboardShortcutMatcher.modifiers(in: event)
            guard modifiers.contains(.command),
                  let character = KeyboardShortcutMatcher.semanticCharacter(for: event) else { return nil }
            model.assign(command, modifiers: modifiers, character: character)
            onChange()
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// The single-key tool shortcuts. Too many to fit the Shortcuts pane, which
/// cannot scroll, so they open in a sheet of their own.
private struct ToolKeysSheet: View {
    @ObservedObject var model: ShortcutSettingsModel
    @Environment(\.dismiss) private var dismiss

    /// One recorder for the whole list, so two rows can never both be
    /// listening for the same keystroke.
    @State private var recording: ToolShortcutManager.Action?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ToolShortcutManager.Action.allCases, id: \.rawValue) { tool in
                        row(tool)
                    }
                } footer: {
                    Text(L("Press a single key to assign it as the shortcut for that tool. These work when the overlay or editor is active."))
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
        .onDisappear { stop() }
    }

    private func row(_ tool: ToolShortcutManager.Action) -> some View {
        let isRecording = recording == tool
        return HStack(spacing: 8) {
            Text(tool.label)
            Spacer()
            Button {
                isRecording ? stop() : start(tool)
            } label: {
                Text(isRecording ? L("Press a shortcut…") : model.display(for: tool))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(model.isAssigned(tool) || isRecording ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.18)
                                              : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            if model.isCustomised(tool) && !isRecording {
                Button { model.reset(tool) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(L("Reset to default"))
            }
        }
    }

    private func start(_ tool: ToolShortcutManager.Action) {
        stop()
        recording = tool
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53:            // Esc cancels
                stop()
                return nil
            case 51, 117:       // Delete clears the shortcut
                model.assign(tool, key: "")
                stop()
                return nil
            default:
                break
            }
            // A tool key fires on its own while the overlay is up, so chords
            // are not accepted — and neither are Return, Tab, arrows or
            // function keys, which the overlay already uses.
            let modifiers = KeyboardShortcutMatcher.modifiers(in: event)
            guard modifiers.intersection([.command, .option, .control]).isEmpty,
                  let character = KeyboardShortcutMatcher.semanticCharacter(for: event),
                  Self.isAssignable(character) else { return nil }
            model.assign(tool, key: character)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    static func isAssignable(_ character: String) -> Bool {
        guard !character.isEmpty else { return false }
        if character == " " { return true }
        return !character.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
