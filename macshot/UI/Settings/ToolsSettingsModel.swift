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

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tools:         return L("Annotation Tools")
            case .bottomActions: return L("Bottom Toolbar Actions")
            case .rightActions:  return L("Right Toolbar Actions")
            }
        }

        var footnote: String {
            switch self {
            case .tools:         return L("Hidden tools are removed from the bottom toolbar.")
            case .bottomActions: return L("Hidden actions are removed from the bottom toolbar.")
            case .rightActions:  return L("Hidden actions are removed from the right toolbar.")
            }
        }

        var defaultsKey: String {
            switch self {
            case .tools:                        return "enabledTools"
            case .bottomActions, .rightActions: return "enabledActions"
            }
        }
    }

    @Published var group: Group = .tools

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
        }
    }

    private static let annotationTools: [(AnnotationTool, String)] = [
        (.pencil, L("Pencil")), (.line, L("Line")), (.arrow, L("Arrow")),
        (.rectangle, L("Rectangle")), (.ellipse, L("Ellipse")), (.marker, L("Marker")),
        (.text, L("Text")), (.number, L("Number / Counter")), (.pixelate, L("Censor")),
        (.highlight, L("Highlight (Spotlight)")), (.loupe, L("Magnify (Loupe)")),
        (.stamp, L("Stamp / Emoji")), (.colorSampler, L("Color Picker")), (.measure, L("Measure")),
    ]
}
