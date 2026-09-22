import Cocoa

/// App-wide toast surface: a floating pill at the bottom of the screen.
///
/// Visually a port of PasteMemo's `UnifiedToastView` / `ToastCenter` — same palette, metrics,
/// resting position and animation curves — rebuilt on AppKit because this project is pure
/// AppKit by convention (see CLAUDE.md; SwiftUI is confined to `BeautifyRenderer`).
///
/// Exists because the overlay's own `showOverlayError` is drawn *inside* the capture overlay:
/// any confirmation for an action that also closes the overlay (picking a colour, for
/// instance) disappears together with it. This panel outlives the overlay.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    enum Icon {
        case none
        case success
        case info

        var symbolName: String? {
            switch self {
            case .none: return nil
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        func tint(isDark: Bool) -> NSColor {
            switch self {
            case .none: return .clear
            case .success: return NSColor(srgbRed: 0.13, green: 0.63, blue: 0.35, alpha: 1)
            case .info:
                return isDark
                    ? NSColor(srgbRed: 0.50, green: 0.73, blue: 1.00, alpha: 1)
                    : NSColor(srgbRed: 0.00, green: 0.31, blue: 0.78, alpha: 1)
            }
        }
    }

    /// Resting distance from the bottom of the visible frame, matching PasteMemo.
    private static let bottomMargin: CGFloat = 72
    /// How far the pill travels — the same rise on the way in and drop on the way out, so
    /// the exit mirrors the entrance instead of merely resembling it.
    private static let slideDistance: CGFloat = 24
    private static let slideDuration: TimeInterval = 0.34
    /// Quick off the mark, settling at the end. Shared by both directions: giving the exit
    /// its own (ease-in) curve made it start slowly, which read as sluggish next to the
    /// entrance.
    private static var slideCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 1.02, 0.30, 1.0)
    }

    /// A trailing button on the toast — "Open" after a save or an upload.
    struct Action {
        let title: String
        let handler: () -> Void
    }

    /// Toasts carrying an action stay up longer: the user has to notice the
    /// button, move to it and click before it goes.
    static let actionDurationBonus: TimeInterval = 5

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?

    /// Show `message`, replacing anything currently on screen.
    /// - Parameter swatch: optional colour chip drawn after the text — used by the colour
    ///   picker so the confirmation shows *which* colour was taken, not just its hex.
    func show(_ message: String, icon: Icon = .success, swatch: NSColor? = nil,
              action: Action? = nil, duration: TimeInterval = 1.6) {
        dismissTask?.cancel()

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let content = ToastPillView(message: message, icon: icon, swatch: swatch,
                                    isDark: isDark, action: action) { [weak self] in
            self?.dismiss()
        }
        let size = content.intrinsicContentSize
        // Only the toasts with something to click take mouse events; the rest
        // stay click-through so they never swallow a click on what is behind.
        let effectiveDuration = action == nil ? duration : duration + Self.actionDurationBonus

        let frame = NSScreen.preferredVisibleFrame
        let restingY = frame.minY + Self.bottomMargin
        let x = frame.midX - size.width / 2

        let panel = existingPanel(size: size)
        panel.ignoresMouseEvents = action == nil
        panel.contentView = content
        panel.setFrame(NSRect(x: x, y: restingY - Self.slideDistance,
                              width: size.width, height: size.height),
                       display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Spring-ish rise, matching the feel of PasteMemo's
        // `.spring(response: 0.48, dampingFraction: 0.7)`.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = Self.slideCurve
            panel.animator().setFrame(NSRect(x: x, y: restingY, width: size.width, height: size.height),
                                      display: true)
            panel.animator().alphaValue = 1
        }

        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }
        // Exact mirror of the entrance: same distance, same duration, same curve.
        let sunk = panel.frame.offsetBy(dx: 0, dy: -Self.slideDistance)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.slideDuration
            ctx.timingFunction = Self.slideCurve
            panel.animator().setFrame(sunk, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func existingPanel(size: NSSize) -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.isExcludedFromWindowsMenu = true
        // Must survive deactivation: the toast usually appears exactly as the capture overlay
        // goes away and focus returns to another app.
        newPanel.hidesOnDeactivate = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false      // drawn in the view so it follows the capsule
        newPanel.ignoresMouseEvents = true
        panel = newPanel
        return newPanel
    }
}

/// The pill itself. Draws its own capsule, border and shadow so the shadow hugs the rounded
/// shape rather than the window's rectangle.
private final class ToastPillView: NSView {

    private let message: String
    private let icon: ToastCenter.Icon
    private let swatch: NSColor?
    private let isDark: Bool

    private let hPadding: CGFloat = 14
    private let vPadding: CGFloat = 8
    private let spacing: CGFloat = 10
    private let iconSide: CGFloat = 14
    private let swatchSide: CGFloat = 13
    /// Transparent margin around the capsule so the drop shadow isn't clipped by the window.
    private let shadowInset: CGFloat = 26

    private let action: ToastCenter.Action?
    private let onActionTapped: () -> Void
    private var actionButton: NSButton?

    init(message: String, icon: ToastCenter.Icon, swatch: NSColor?, isDark: Bool,
         action: ToastCenter.Action? = nil, onActionTapped: @escaping () -> Void = {}) {
        self.message = message
        self.icon = icon
        self.swatch = swatch
        self.isDark = isDark
        self.action = action
        self.onActionTapped = onActionTapped
        super.init(frame: .zero)
        guard let action else { return }
        let button = NSButton(title: action.title, target: self, action: #selector(runAction))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        actionButton = button
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func runAction() {
        action?.handler()
        onActionTapped()
    }

    private var actionWidth: CGFloat {
        guard let actionButton else { return 0 }
        return ceil(actionButton.intrinsicContentSize.width)
    }

    override func layout() {
        super.layout()
        guard let actionButton else { return }
        let pill = bounds.insetBy(dx: shadowInset, dy: shadowInset)
        let size = actionButton.intrinsicContentSize
        actionButton.frame = NSRect(x: pill.maxX - hPadding - size.width,
                                    y: pill.midY - size.height / 2,
                                    width: size.width, height: size.height)
    }

    private var font: NSFont { .systemFont(ofSize: 13, weight: .medium) }

    /// A save path or an upload link is long enough to stretch the pill past
    /// the screen edge. Cap it and truncate in the middle, which keeps both
    /// ends — the host and the filename are what identify a link.
    private var maxTextWidth: CGFloat {
        max(260, NSScreen.preferredVisibleFrame.width * 0.5)
    }

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }

    private var textSize: NSSize {
        let natural = (message as NSString).size(withAttributes: [.font: font])
        return NSSize(width: min(ceil(natural.width), maxTextWidth), height: natural.height)
    }

    override var intrinsicContentSize: NSSize {
        var w = hPadding * 2 + ceil(textSize.width)
        if icon.symbolName != nil { w += iconSide + spacing }
        if swatch != nil { w += swatchSide + spacing }
        if actionWidth > 0 { w += actionWidth + spacing }
        let h = max(22, ceil(textSize.height)) + vPadding * 2
        return NSSize(width: w + shadowInset * 2, height: h + shadowInset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: shadowInset, dy: shadowInset)
        let radius = pill.height / 2
        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.48 : 0.14)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        (isDark
            ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.98, alpha: 1)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        (isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.05))
            .setStroke()
        let border = NSBezierPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25),
                                  xRadius: radius, yRadius: radius)
        border.lineWidth = 0.5
        border.stroke()

        var x = pill.minX + hPadding

        if let symbol = icon.symbolName,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSide, weight: .medium)) {
            let tinted = image.copy() as! NSImage
            tinted.lockFocus()
            icon.tint(isDark: isDark).set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let r = NSRect(x: x, y: pill.midY - tinted.size.height / 2,
                           width: tinted.size.width, height: tinted.size.height)
            tinted.draw(in: r)
            x += iconSide + spacing
        }

        let color = isDark
            ? NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1)
        (message as NSString).draw(
            in: NSRect(x: x, y: pill.midY - textSize.height / 2,
                       width: textSize.width, height: textSize.height),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraphStyle])
        x += ceil(textSize.width)

        // Swatch trails the text: leading it would put two glyphs in a row before the
        // message (status icon, then chip), which reads as clutter.
        if let swatch {
            x += spacing
            let r = NSRect(x: x, y: pill.midY - swatchSide / 2, width: swatchSide, height: swatchSide)
            swatch.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            (isDark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.15))
                .setStroke()
            let edge = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            edge.lineWidth = 0.5
            edge.stroke()
        }
    }
}
