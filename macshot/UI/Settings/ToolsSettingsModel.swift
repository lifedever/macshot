import AppKit
import Combine
import SwiftUI

/// Backing store for the Tools pane.
///
/// All three lists are the same shape — a set of raw values stored under one
/// defaults key — so they share one implementation instead of three grids.
@MainActor
final class ToolsSettingsModel: ObservableObject {

    struct Item: Identifiable {
        let tag: Int
        let label: String
        var id: Int { tag }
    }

    enum Group: String, CaseIterable, Identifiable {
        case tools
        case bottomActions
        case rightActions
        /// The colour picker's preset swatches, edited as wells rather than toggles.
        case colors

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tools:         return L("Annotation Tools")
            case .bottomActions: return L("Bottom Toolbar Actions")
            case .rightActions:  return L("Right Toolbar Actions")
            case .colors:        return L("Default Colors")
            }
        }

        var footnote: String {
            switch self {
            case .tools:         return L("Hidden tools are removed from the bottom toolbar.")
            case .bottomActions: return L("Hidden actions are removed from the bottom toolbar.")
            case .rightActions:  return L("Hidden actions are removed from the right toolbar.")
            case .colors:        return L("The preset swatches in the color picker.")
            }
        }

        var defaultsKey: String {
            switch self {
            case .tools:                        return "enabledTools"
            case .bottomActions, .rightActions: return "enabledActions"
            case .colors:                       return PresetColorPalette.defaultsKey
            }
        }
    }

    @Published var group: Group = .tools

    /// No bottom strip or options row during a capture; tools are picked with
    /// their keyboard shortcuts. The right action strip is unaffected.
    @Published var hideBottomToolbar: Bool = UserDefaults.standard.bool(forKey: OverlayView.hideBottomToolbarKey) {
        didSet {
            guard hideBottomToolbar != oldValue else { return }
            UserDefaults.standard.set(hideBottomToolbar, forKey: OverlayView.hideBottomToolbarKey)
        }
    }

    /// A capture starts with no tool armed: dragging moves the selection
    /// until a tool is picked.
    @Published var startCapturesInMoveMode: Bool = OverlayView.startCapturesInMoveModeSetting {
        didSet {
            guard startCapturesInMoveMode != oldValue else { return }
            UserDefaults.standard.set(startCapturesInMoveMode, forKey: OverlayView.startCapturesInMoveModeKey)
        }
    }

    // MARK: Default colours

    /// The preset swatches at the top of the colour picker (`PresetColorPalette`).
    @Published private(set) var presetColors: [Color] = PresetColorPalette.colors.map { Color(nsColor: $0) }

    var canAddPresetColor: Bool { presetColors.count < PresetColorPalette.maxCount }

    func setPresetColor(_ color: Color, at index: Int) {
        guard presetColors.indices.contains(index) else { return }
        // Swatches are stored as opaque sRGB; a colour with no sRGB form (a
        // pattern) can't be, so the swatch keeps its saved colour instead.
        guard PresetColorPalette.hex(NSColor(color)) != nil else {
            presetColors = PresetColorPalette.colors.map { Color(nsColor: $0) }
            return
        }
        var colors = PresetColorPalette.colors
        guard colors.indices.contains(index) else { return }
        colors[index] = NSColor(color).withAlphaComponent(1)
        savePresetColors(colors)
    }

    func addPresetColor() {
        var colors = PresetColorPalette.colors
        guard colors.count < PresetColorPalette.maxCount else { return }
        colors.append(colors.last ?? .systemRed)
        savePresetColors(colors)
    }

    func removePresetColor(at index: Int) {
        var colors = PresetColorPalette.colors
        guard colors.indices.contains(index) else { return }
        colors.remove(at: index)
        savePresetColors(colors)
    }

    func resetPresetColors() {
        PresetColorPalette.reset()
        presetColors = PresetColorPalette.colors.map { Color(nsColor: $0) }
    }

    private func savePresetColors(_ colors: [NSColor]) {
        PresetColorPalette.save(colors)
        presetColors = PresetColorPalette.colors.map { Color(nsColor: $0) }
    }

    /// Bumped on every write so the toggles re-read `isEnabled`.
    @Published private var revision = 0

    var items: [Item] {
        switch group {
        case .tools:
            return Self.annotationTools.map { Item(tag: $0.0.rawValue, label: $0.1) }
        case .bottomActions:
            return ToolbarCustomAction.bottomSettingsActions.map {
                Item(tag: $0.rawValue, label: $0.settingsLabel)
            }
        case .rightActions:
            return ToolbarCustomAction.rightSettingsActions.map {
                Item(tag: $0.rawValue, label: $0.settingsLabel)
            }
        case .colors:
            return []
        }
    }

    func isEnabled(_ item: Item) -> Bool {
        _ = revision
        return enabledValues().contains(item.tag)
    }

    func setEnabled(_ enabled: Bool, for item: Item) {
        var values = Set(enabledValues())
        if enabled { values.insert(item.tag) } else { values.remove(item.tag) }
        UserDefaults.standard.set(Array(values), forKey: group.defaultsKey)
        revision += 1
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }

    /// The stored set, falling back to "everything" the first time — matching
    /// what the toolbars themselves assume when the key is absent.
    private func enabledValues() -> [Int] {
        let key = group.defaultsKey
        if let stored = UserDefaults.standard.array(forKey: key) as? [Int] { return stored }
        switch group {
        case .tools:
            return Self.annotationTools.map { $0.0.rawValue }
        case .bottomActions, .rightActions:
            return ToolbarActionPreferences.defaultEnabledRawValues
        case .colors:
            return []
        }
    }

    private static let annotationTools: [(AnnotationTool, String)] = [
        (.select, L("Select & Move")),
        (.pencil, L("Pencil")), (.line, L("Line")), (.arrow, L("Arrow")),
        (.rectangle, L("Rectangle")), (.ellipse, L("Ellipse")), (.marker, L("Marker")),
        (.text, L("Text")), (.number, L("Number / Counter")), (.pixelate, L("Censor")),
        (.highlight, L("Highlight (Spotlight)")), (.loupe, L("Magnify (Loupe)")),
        (.stamp, L("Stamp / Emoji")), (.colorSampler, L("Color Picker")), (.measure, L("Measure")),
    ]
}
