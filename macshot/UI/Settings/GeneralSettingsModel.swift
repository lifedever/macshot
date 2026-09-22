import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Backing store for the General settings pane.
///
/// The pane is SwiftUI, but the effects each setting triggers already live in
/// the app (registering the login item, refreshing the menu bar icon, saving
/// toolbar colours). This type owns the `UserDefaults` round-trip and calls
/// those existing paths, so there is one implementation of each behaviour
/// rather than an AppKit copy and a SwiftUI copy.
@MainActor
final class GeneralSettingsModel: ObservableObject {

    // MARK: Language

    @Published var languageCode: String {
        didSet {
            guard languageCode != oldValue else { return }
            LanguageManager.shared.currentLanguage = languageCode
        }
    }

    var languages: [(code: String, name: String)] {
        LanguageManager.availableLanguages.map { ($0.code, $0.name) }
    }

    // MARK: Application

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            if #available(macOS 13.0, *) {
                do {
                    if launchAtLogin { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    #if DEBUG
                    NSLog("macshot: login item update failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }

    @Published var hideMenuBarIcon: Bool {
        didSet {
            guard hideMenuBarIcon != oldValue else { return }
            UserDefaults.standard.set(hideMenuBarIcon, forKey: "hideMenuBarIcon")
            (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hideMenuBarIcon)
        }
    }

    @Published var usesCustomMenuBarSymbol: Bool {
        didSet {
            guard usesCustomMenuBarSymbol != oldValue else { return }
            UserDefaults.standard.set(usesCustomMenuBarSymbol ? "symbol" : "default",
                                      forKey: AppDelegate.statusBarIconModeKey)
            (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
        }
    }

    @Published var menuBarSymbolName: String {
        didSet {
            guard menuBarSymbolName != oldValue else { return }
            UserDefaults.standard.set(menuBarSymbolName, forKey: AppDelegate.statusBarIconSymbolNameKey)
            (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
        }
    }

    /// Whether the typed symbol name actually resolves. Shown inline so an
    /// invalid name is obvious at the point of entry rather than only as a
    /// silently unchanged menu bar.
    var menuBarSymbolIsValid: Bool {
        menuBarSymbolName.isEmpty
            || NSImage(systemSymbolName: menuBarSymbolName, accessibilityDescription: nil) != nil
    }

    let symbolPresets: [String] = MenuBarIconPresets.symbols

    @Published var urlSchemeEnabled: Bool {
        didSet {
            guard urlSchemeEnabled != oldValue else { return }
            UserDefaults.standard.set(urlSchemeEnabled, forKey: "urlSchemeEnabled")
        }
    }

    @Published var autoUpdate: Bool {
        didSet {
            guard autoUpdate != oldValue else { return }
            UserDefaults.standard.set(autoUpdate, forKey: "SUEnableAutomaticChecks")
        }
    }

    @Published var betaUpdates: Bool {
        didSet {
            guard betaUpdates != oldValue else { return }
            UserDefaults.standard.set(betaUpdates, forKey: "betaUpdatesEnabled")
        }
    }

    var softwareUpdatesAvailable: Bool { BuildVariant.softwareUpdatesEnabled }

    // MARK: Appearance

    @Published var accentColor: Color {
        didSet { applyToolbarColour(accentColor, oldValue, ToolbarLayout.saveAccentColor) }
    }
    @Published var iconColor: Color {
        didSet { applyToolbarColour(iconColor, oldValue, ToolbarLayout.saveIconColor) }
    }
    @Published var backgroundColor: Color {
        didSet { applyToolbarColour(backgroundColor, oldValue, ToolbarLayout.saveBgColor) }
    }

    var themePresetNames: [String] { ThemePreset.all.map { L($0.name) } + [L("Custom")] }

    /// Index of the preset whose three colours match the current ones, or the
    /// trailing "Custom" entry when they match none.
    var selectedThemeIndex: Int {
        let current = (ToolbarLayout.accentColor, ToolbarLayout.iconColor, ToolbarLayout.bgColor)
        for (index, preset) in ThemePreset.all.enumerated() {
            if Self.sameColour(preset.accent, current.0),
               Self.sameColour(preset.icon, current.1),
               Self.sameColour(preset.bg, current.2) {
                return index
            }
        }
        return ThemePreset.all.count
    }

    func applyThemePreset(at index: Int) {
        guard index >= 0, index < ThemePreset.all.count else { return }  // "Custom" — no-op
        let preset = ThemePreset.all[index]
        ToolbarLayout.saveAccentColor(preset.accent)
        ToolbarLayout.saveIconColor(preset.icon)
        ToolbarLayout.saveBgColor(preset.bg)
        accentColor = Color(preset.accent)
        iconColor = Color(preset.icon)
        backgroundColor = Color(preset.bg)
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }

    private func applyToolbarColour(_ new: Color, _ old: Color, _ save: (NSColor) -> Void) {
        guard new != old else { return }
        save(NSColor(new))
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
        objectWillChange.send()   // the preset popup reflects the new colours
    }

    private static func sameColour(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB) else { return false }
        let tolerance = 0.01
        return abs(x.redComponent - y.redComponent) < tolerance
            && abs(x.greenComponent - y.greenComponent) < tolerance
            && abs(x.blueComponent - y.blueComponent) < tolerance
    }

    // MARK: Lifecycle

    init() {
        let defaults = UserDefaults.standard
        languageCode = LanguageManager.shared.currentLanguage
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        usesCustomMenuBarSymbol = (defaults.string(forKey: AppDelegate.statusBarIconModeKey) ?? "default") == "symbol"
        menuBarSymbolName = defaults.string(forKey: AppDelegate.statusBarIconSymbolNameKey) ?? ""
        urlSchemeEnabled = defaults.object(forKey: "urlSchemeEnabled") as? Bool ?? true
        autoUpdate = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        betaUpdates = defaults.bool(forKey: "betaUpdatesEnabled")
        accentColor = Color(ToolbarLayout.accentColor)
        iconColor = Color(ToolbarLayout.iconColor)
        backgroundColor = Color(ToolbarLayout.bgColor)
    }
}
