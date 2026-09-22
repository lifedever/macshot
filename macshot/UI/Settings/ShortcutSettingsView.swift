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

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyManager.HotkeySlot.allCases, id: \.rawValue) { slot in
                    HotkeyRow(slot: slot, model: model, onChange: onHotkeyChanged)
                }
            } header: {
                Text(L("Keyboard Shortcuts"))
            } footer: {
                Text(L("Click a shortcut and press a key combination with at least one modifier (⌘, ⌥, ⌃, ⇧). Esc cancels. Function keys work on their own."))
            }

            Section {
                ForEach(EditorCommandShortcutManager.Action.allCases, id: \.rawValue) { command in
                    EditorCommandRow(command: command, model: model)
                }
            } header: {
                Text(L("Overlay / Editor Shortcuts"))
            } footer: {
                Text(L("These apply inside the capture overlay and the editor window."))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
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
                Button { model.reset(command) } label: {
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
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            model.assign(command, modifiers: mods, character: chars.lowercased())
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
