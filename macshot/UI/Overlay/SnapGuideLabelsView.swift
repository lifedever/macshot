import Cocoa

/// The labels naming where each snap guide comes from, drawn above the
/// overlay's toolbars and size box.
///
/// The overlay draws the guides themselves, but its toolbars and size box are
/// subviews and paint over anything it draws. They sit against the selection's
/// edges — exactly where a label goes while the selection is resized — so the
/// labels live in this view, kept as the overlay's topmost subview. It takes
/// no clicks: every point falls through to what is beneath.
final class SnapGuideLabelsView: NSView {

    struct Label: Equatable {
        var rect: NSRect
        var icon: NSImage?
        var text: String
    }

    var labels: [Label] = [] {
        didSet {
            guard labels != oldValue else { return }
            for rect in (oldValue + labels).map(\.rect) { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
        }
    }

    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let iconSide: CGFloat = 14

    /// Size of a label with this icon and text.
    static func size(icon: NSImage?, text: String) -> NSSize {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let iconWidth = icon == nil ? 0 : iconSide + 5
        return NSSize(width: ceil(7 + iconWidth + width + 8), height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        for label in labels where label.rect.intersects(dirtyRect) {
            let rect = label.rect
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            var x = rect.minX + 7
            if let icon = label.icon {
                let side = Self.iconSide
                icon.draw(in: NSRect(x: x, y: rect.midY - side / 2, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: 1)
                x += side + 5
            }
            let textSize = (label.text as NSString).size(withAttributes: attrs)
            (label.text as NSString).draw(at: NSPoint(x: x, y: rect.midY - textSize.height / 2), withAttributes: attrs)
        }
    }
}
