import Cocoa

/// Grid of beautify gradient style swatches for use inside an NSPopover.
/// Index -1 = custom image background.
class GradientPickerView: NSView {

    var selectedIndex: Int = 0
    var onSelect: ((Int) -> Void)?
    /// Called when the user clicks the custom image swatch — caller shows file picker.
    var onCustomImage: (() -> Void)?
    /// Called when the user picks the wallpaper swatch — caller captures the desktop.
    var onUseWallpaper: (() -> Void)?

    private let styles = BeautifyRenderer.styles
    private let cols = 6
    private let swSize: CGFloat = 28
    private let padding: CGFloat = 8
    private let gap: CGFloat = 4
    /// Whether a custom background image is stored.
    private var hasCustomImage: Bool {
        UserDefaults.standard.data(forKey: "beautifyCustomBgImageData") != nil
    }
    /// Trailing action swatches, in the order they are laid out after the gradients (and
    /// after the custom-image thumbnail, when one exists). Kept as one list so `draw` and
    /// `mouseDown` can't drift apart on index arithmetic.
    private enum ActionSwatch: CaseIterable {
        case wallpaper
        case pickFile

        var symbolName: String {
            switch self {
            case .wallpaper: return "macwindow.on.rectangle"
            case .pickFile:  return "photo.badge.plus"
            }
        }
        var tooltip: String {
            switch self {
            case .wallpaper: return L("Use desktop wallpaper")
            case .pickFile:  return L("Choose image…")
            }
        }
    }

    /// Wallpaper capture needs `SCScreenshotManager` (macOS 14+); below that the swatch is
    /// omitted entirely rather than shown as a control that does nothing.
    private static var availableActions: [ActionSwatch] {
        if #available(macOS 14.0, *) { return ActionSwatch.allCases }
        return [.pickFile]
    }
    private var actions: [ActionSwatch] { Self.availableActions }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // One tooltip rect per action swatch — the gradients speak for
        // themselves, these two do not.
        let firstActionIndex = BeautifyRenderer.styles.count + (hasCustomImage ? 1 : 0)
        for (offset, action) in actions.enumerated() {
            addToolTip(rectForIndex(firstActionIndex + offset),
                       owner: action.tooltip as NSString, userData: nil)
        }
    }

    /// The grid's natural size, so hosts that lay it out themselves — an
    /// `NSPopover`, or SwiftUI via `NSViewRepresentable` — can ask for it
    /// instead of reading `frame`, which they may already have overwritten.
    static var gridSize: NSSize {
        let hasCustom = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData") != nil
        let total = BeautifyRenderer.styles.count + (hasCustom ? 1 : 0) + availableActions.count
        let rows = (total + 5) / 6
        return NSSize(
            width: 8 * 2 + CGFloat(6) * 28 + CGFloat(5) * 4,
            height: 8 * 2 + CGFloat(rows) * 28 + CGFloat(max(0, rows - 1)) * 4)
    }

    override var intrinsicContentSize: NSSize { Self.gridSize }

    init(selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        super.init(frame: NSRect(origin: .zero, size: Self.gridSize))
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { frame.size }

    private func rectForIndex(_ i: Int) -> NSRect {
        let col = i % cols
        let row = i / cols
        let sx = padding + CGFloat(col) * (swSize + gap)
        let sy = bounds.maxY - padding - swSize - CGFloat(row) * (swSize + gap)
        return NSRect(x: sx, y: sy, width: swSize, height: swSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        var idx = 0

        // Draw gradient swatches
        for (i, style) in styles.enumerated() {
            let sr = rectForIndex(idx)
            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            if #available(macOS 15.0, *), let mesh = style.meshDef,
               let img = BeautifyRenderer.renderMeshSwatch(mesh, size: swSize) {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                img.draw(in: sr, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
            } else if let grad = NSGradient(colors: style.stops.map { $0.0 }, atLocations: style.stops.map { $0.1 }, colorSpace: .deviceRGB) {
                grad.draw(in: path, angle: style.angle - 90)
            }
            // An edge for the pale styles, which otherwise melt into a light popover.
            NSColor.labelColor.withAlphaComponent(0.15).setStroke()
            let edge = NSBezierPath(roundedRect: sr.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            edge.lineWidth = 0.5
            edge.stroke()
            if i == selectedIndex {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
            idx += 1
        }

        // Custom image thumbnail swatch (only if a custom image is stored)
        if let thumb = customBackgroundThumbnail() {
            let sr = rectForIndex(idx)
            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            thumb.draw(in: sr, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            if selectedIndex == -1 {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
            idx += 1
        }

        // Action swatches — always present: grab the desktop wallpaper, or pick a file.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        for action in actions {
            let pr = rectForIndex(idx)
            let bgPath = NSBezierPath(roundedRect: pr, xRadius: 6, yRadius: 6)
            // Semantic colours, not the toolbar's: this grid is also shown in
            // Settings, whose popover follows the system appearance. The
            // toolbar's icon colour is white, which is invisible on the light
            // popover background.
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            bgPath.fill()
            if let icon = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.tooltip)?
                .withSymbolConfiguration(symbolConfig) {
                let tinted = icon.copy() as! NSImage
                tinted.lockFocus()
                NSColor.labelColor.set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                let iconSize = tinted.size
                let iconRect = NSRect(
                    x: pr.midX - iconSize.width / 2,
                    y: pr.midY - iconSize.height / 2,
                    width: iconSize.width, height: iconSize.height)
                tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.7)
            }
            idx += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        var idx = 0

        // Check gradient swatches
        for i in 0..<styles.count {
            let sr = rectForIndex(idx)
            if sr.insetBy(dx: -2, dy: -2).contains(pt) {
                selectedIndex = i
                onSelect?(i)
                needsDisplay = true
                return
            }
            idx += 1
        }

        // Check custom image thumbnail
        if hasCustomImage {
            let sr = rectForIndex(idx)
            if sr.insetBy(dx: -2, dy: -2).contains(pt) {
                selectedIndex = -1
                onSelect?(-1)
                needsDisplay = true
                return
            }
            idx += 1
        }

        // Check the action swatches, in the same order `draw` laid them out.
        for action in actions {
            let pr = rectForIndex(idx)
            if pr.insetBy(dx: -2, dy: -2).contains(pt) {
                switch action {
                case .wallpaper: onUseWallpaper?()
                case .pickFile:  onCustomImage?()
                }
                return
            }
            idx += 1
        }
    }

    private func customBackgroundThumbnail() -> NSImage? {
        guard let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let image = NSImage(data: data) else { return nil }
        return image
    }
}
