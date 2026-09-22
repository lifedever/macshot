import Cocoa

/// Floating image preview shown while a Recent Captures menu item is highlighted.
///
/// A menu item's own `image` is capped at a size that is useless for telling one
/// screenshot from another — the dimensions and the age in the title are all the
/// menu can really say. This panel sits beside the highlighted row and shows the
/// capture itself.
@MainActor
final class MenuPreviewController {

    static let shared = MenuPreviewController()
    private init() {}

    private var panel: NSPanel?
    private var imageView: NSImageView?

    /// Longest edge of the preview. Big enough to recognise a screenshot,
    /// small enough not to cover the menu it belongs to.
    private static let maxEdge: CGFloat = 320
    private static let padding: CGFloat = 6
    /// Horizontal distance from the pointer to the preview's near edge.
    private static let pointerClearance: CGFloat = 220

    /// Show `image` beside `point` (screen coordinates), which is the pointer:
    /// AppKit exposes no screen rect for a menu item, and the submenu can open
    /// on either side of the menu bar item depending on the room available, so
    /// the pointer is the only reliable anchor for where the row actually is.
    func show(image: NSImage, near point: NSPoint) {
        let fitted = Self.fit(image.size, within: Self.maxEdge)
        let size = NSSize(width: fitted.width + Self.padding * 2,
                          height: fitted.height + Self.padding * 2)

        let panel = existingPanel()
        imageView?.image = image

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: point, size: size)

        // Clear of the pointer on whichever side has room, so the preview never
        // lands on top of the row being previewed.
        var x = point.x + Self.pointerClearance
        if x + size.width > visible.maxX {
            x = point.x - Self.pointerClearance - size.width
        }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        // Vertically centred on the pointer, clamped to the screen.
        var y = point.y - size.height / 2
        y = max(visible.minY, min(y, visible.maxY - size.height))

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(contentRect: .zero,
                               styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered, defer: false)
        newPanel.isFloatingPanel = true
        // Above the menu, which itself sits at `.popUpMenu`.
        newPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.hidesOnDeactivate = false
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.ignoresMouseEvents = true

        let container = NSVisualEffectView()
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            image.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])

        newPanel.contentView = container
        imageView = image
        panel = newPanel
        return newPanel
    }

    private static func fit(_ size: NSSize, within edge: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: edge, height: edge) }
        let scale = min(edge / size.width, edge / size.height, 1)
        return NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }
}
