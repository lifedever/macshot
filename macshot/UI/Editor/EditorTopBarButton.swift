import Cocoa

/// A button on the editor's top bar that looks pressable: the same hover and
/// press fill as the drag handle beside it, and the accent fill of a selected
/// toolbar tool while the mode it starts is on (crop).
///
/// A plain borderless `NSButton` shows nothing on hover and barely anything on
/// press, so the bar read as decoration and a click that only switched a mode
/// looked like it had done nothing. The cursor stays the arrow, as on every
/// other toolbar button: the pointing hand is for links.
final class EditorTopBarButton: NSButton {

    static let cornerRadius: CGFloat = 5

    /// The hover (and, stronger, press) fill shared with `EditorDragHandleView`.
    static func highlightFill(pressed: Bool) -> NSColor {
        let base: NSColor = ToolbarLayout.usesLightPalette ? .black : .white
        return base.withAlphaComponent(pressed ? 0.16 : 0.09)
    }

    /// Opacity of the glyph or title when the button is not active.
    var idleTintAlpha: CGFloat = 0.85 { didSet { applyTint() } }

    /// Room added on each side of a title, so the hover fill doesn't hug the text.
    var horizontalPadding: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding * 2
        return size
    }

    /// The mode this button starts is on.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyTint()
            needsDisplay = true
        }
    }

    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .recessed
        isBordered = false
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-read the theme colours (appearance or toolbar colour change).
    func applyTint() {
        contentTintColor = isActive
            ? ToolbarButtonView.onAccentColor
            : ToolbarLayout.iconColor.withAlphaComponent(idleTintAlpha)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if isActive {
            fill = ToolbarLayout.accentColor.withAlphaComponent(isHighlighted ? 0.75 : 1)
        } else if isHighlighted || isHovered {
            fill = Self.highlightFill(pressed: isHighlighted)
        } else {
            fill = nil
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
        }
        super.draw(dirtyRect)
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        // `.activeAlways`: the editor belongs to a menu-bar app that is often
        // not frontmost, and hover should still answer then.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    /// Several of these buttons open something over the editor (a capture
    /// overlay, a save panel), and the exit can be lost on the way. The window
    /// stops being key when that happens, so drop the hover then; the next
    /// entry brings it back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        observedWindow = window
        isHovered = false
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowDidResignKey() {
        isHovered = false
    }
}
