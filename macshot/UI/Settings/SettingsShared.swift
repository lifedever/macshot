import AppKit
import SwiftUI

/// A named toolbar colour triple offered in the Appearance settings.
///
/// Lives at file scope (rather than nested inside the settings window) because
/// both the SwiftUI panes and the remaining AppKit panes select from it.
struct ThemePreset {
    let name: String
    let accent: NSColor
    let icon: NSColor
    let bg: NSColor

    static let all: [ThemePreset] = [
        ThemePreset(name: "Default",
                    accent: ToolbarLayout.defaultAccentColor,
                    icon:   ToolbarLayout.defaultIconColor,
                    bg:     ToolbarLayout.defaultBgColor),
        ThemePreset(name: "Classic",
                    accent: NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0),
                    icon:   .white,
                    bg:     NSColor(white: 0.12, alpha: 1.0)),
        ThemePreset(name: "Ocean",
                    accent: NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.75, alpha: 1.0),
                    icon:   .white,
                    bg:     NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1.0)),
        ThemePreset(name: "Sunset",
                    accent: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.20, alpha: 1.0),
                    icon:   .white,
                    bg:     NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.12, alpha: 1.0)),
        ThemePreset(name: "Forest",
                    accent: NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.45, alpha: 1.0),
                    icon:   .white,
                    bg:     NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.10, alpha: 1.0)),
        ThemePreset(name: "Mono",
                    accent: NSColor(white: 0.30, alpha: 1.0),
                    icon:   .white,
                    bg:     NSColor(white: 0.10, alpha: 1.0)),
    ]
}

/// SF Symbol names offered as one-click menu bar icons.
enum MenuBarIconPresets {
    static let symbols = [
        "camera.viewfinder", "camera", "camera.fill", "camera.aperture",
        "viewfinder", "crop", "crop.rotate", "scissors",
        "rectangle.dashed", "square.dashed", "photo", "record.circle",
    ]
}

/// Marks the views whose `fittingSize` reflects real content height — i.e. the
/// SwiftUI panes. `NSHostingView` is generic, so a plain `is NSHostingView`
/// test cannot be written without naming its root view type.
protocol NSHostingViewProtocolMarker: AnyObject {}

/// `NSHostingView` tagged so the window can tell a SwiftUI pane from a legacy
/// AppKit one when deciding whether to size itself to the content.
///
/// It also reports back whenever its intrinsic size changes, so a pane that
/// grows or shrinks on its own — the upload pane swapping provider fields, the
/// General pane revealing the custom-symbol row — resizes the window too,
/// rather than only doing so at the moment the tab is selected.
final class SettingsPaneHostingView<Content: View>: NSHostingView<Content>, NSHostingViewProtocolMarker {
    var onIntrinsicContentSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicContentSizeChange?()
    }
}

extension NSHostingView {
    /// Shared setup for a SwiftUI settings pane: no autoresizing mask, and an
    /// intrinsic size that reports the form's real height so the window can size
    /// itself to the content instead of leaving a stub scroller.
    func configuredAsSettingsPane() -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        sizingOptions = [.intrinsicContentSize]
        return self
    }
}

/// Hosts an AppKit view inside a SwiftUI settings pane, for the controls that
/// have no SwiftUI equivalent worth rebuilding — the drag-to-reorder menu list,
/// for instance. Per the project convention these are wrapped, not rewritten.
struct AppKitView: NSViewRepresentable {
    let make: () -> NSView

    func makeNSView(context: Context) -> NSView { make() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
