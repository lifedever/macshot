import SwiftUI

/// The General settings pane.
///
/// `Form` + `.formStyle(.grouped)` is what produces the System Settings
/// appearance — grouped cards, row metrics, inset separators, trailing control
/// column, switch-style toggles. None of that is drawn here; the previous
/// AppKit pane had to hand-build every one of those and still did not match.
struct GeneralSettingsView: View {
    @ObservedObject var model: GeneralSettingsModel

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: $model.languageCode) {
                    ForEach(model.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } footer: {
                Text(L("Restart the app to fully apply the new language."))
            }

            Section(L("Application")) {
                Toggle(L("Launch at login"), isOn: $model.launchAtLogin)
                Toggle(isOn: $model.hideMenuBarIcon) {
                    Text(L("Hide menu bar icon"))
                    Text(L("Hotkeys still work. To show the icon again, re-launch macshot."))
                }
                menuBarIconRows
                Toggle(L("Enable macshot:// URL scheme"), isOn: $model.urlSchemeEnabled)
                if model.softwareUpdatesAvailable {
                    Toggle(L("Check for updates automatically"), isOn: $model.autoUpdate)
                    Toggle(L("Check for beta updates"), isOn: $model.betaUpdates)
                }
            }

        }
        .formStyle(.grouped)
        // The window sizes itself to this form, so the form never needs to
        // scroll — and a scroller that can only ever travel a few points is
        // worse than none.
        .scrollDisabled(true)
    }

    @ViewBuilder
    private var menuBarIconRows: some View {
        Picker(L("Menu bar icon"), selection: $model.usesCustomMenuBarSymbol) {
            Text(L("Default")).tag(false)
            Text(L("Custom symbol")).tag(true)
        }
        if model.usesCustomMenuBarSymbol {
            LabeledContent(L("Symbol")) {
                HStack(spacing: 8) {
                    TextField("", text: $model.menuBarSymbolName,
                              prompt: Text("camera.viewfinder"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 170)
                    Menu(L("Presets")) {
                        ForEach(model.symbolPresets, id: \.self) { symbol in
                            Button {
                                model.menuBarSymbolName = symbol
                            } label: {
                                Label(symbol, systemImage: symbol)
                            }
                        }
                    }
                    .frame(width: 90)
                }
            }
            // Only surfaced once the name actually fails to resolve — a
            // permanent hint would just be noise for a field most people fill
            // from the presets menu.
            if !model.menuBarSymbolIsValid {
                Label(L("No SF Symbol by that name — the default icon is used."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}
