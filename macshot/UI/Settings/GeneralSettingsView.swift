import SwiftUI

/// The General settings pane.
///
/// `Form` + `.formStyle(.grouped)` is what produces the System Settings
/// appearance — grouped cards, row metrics, inset separators, trailing control
/// column, switch-style toggles. None of that is drawn here; the previous
/// AppKit pane had to hand-build every one of those and still did not match.
struct GeneralSettingsView: View {
    @ObservedObject var model: GeneralSettingsModel
    /// History retention lives here rather than under Output: Output holds where and how files
    /// are written, and with the recording library added there it no longer fit the window.
    @ObservedObject var capture: CaptureSettingsModel
    @ObservedObject var updater: SoftwareUpdater = .shared

    /// The running version, or the update a check found; the button shows Sparkle's update
    /// window for it (where Install relaunches into the new version) or checks again.
    @ViewBuilder
    private var updateRow: some View {
        LabeledContent {
            Button(updater.availableVersion == nil ? L("Check for Updates...") : L("Update")) {
                updater.checkForUpdates()
            }
        } label: {
            if let version = updater.availableVersion {
                Text(String(format: L("Version %@ is available"), version))
            } else {
                Text(String(format: L("Version %@ (%@)"),
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))
            }
        }
    }

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
                    updateRow
                    // No "Check for beta updates": this fork publishes no beta channel.
                    Toggle(L("Check for updates automatically"), isOn: $model.autoUpdate)
                }
            }

            Section(L("History")) {
                Toggle(L("Unlimited"), isOn: $capture.historyUnlimited)
                if !capture.historyUnlimited {
                    LabeledContent(L("History size")) {
                        HStack(spacing: 6) {
                            TextField("", value: $capture.historySize, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: $capture.historySize, in: 0...9999)
                                .labelsHidden()
                        }
                    }
                }
                Toggle(L("Order history by last edit"), isOn: $capture.historyOrderByLastEdit)
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
