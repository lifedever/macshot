import SwiftUI

/// The Appearance pane: toolbar theming and the order of the menu bar's capture
/// commands.
///
/// Split out of General, which could not show its last group without the window
/// running past the screen. These belong together — both are about how the app
/// presents itself rather than what it captures.
@available(macOS 13.0, *)
struct AppearanceSettingsView: View {
    @ObservedObject var model: GeneralSettingsModel

    /// The picker writes through to `applyThemePreset`; the stored value is
    /// derived from the live colours so picking "Custom" (or nudging a colour
    /// well) leaves the selection where it belongs without a second source of
    /// truth.
    private var themeSelection: Binding<Int> {
        Binding(get: { model.selectedThemeIndex },
                set: { model.applyThemePreset(at: $0) })
    }

    var body: some View {
        Form {
            Section(L("Appearance")) {
                Picker(L("Theme"), selection: themeSelection) {
                    ForEach(Array(model.themePresetNames.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                ColorPicker(L("Accent"), selection: $model.accentColor, supportsOpacity: false)
                ColorPicker(L("Icon"), selection: $model.iconColor, supportsOpacity: false)
                ColorPicker(L("Background"), selection: $model.backgroundColor, supportsOpacity: false)
            }

            Section {
                MenuOrderList(model: model)
                HStack {
                    Spacer()
                    Button(L("Reset to default")) { model.resetMenuOrder() }
                }
            } header: {
                Text(L("Menu Bar Order"))
            } footer: {
                Text(L("Choose the order of capture actions in the macshot menu bar menu."))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
