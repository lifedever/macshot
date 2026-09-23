import Cocoa

/// Shows the panels toolbar buttons open — pickers, lists, settings — in both
/// overlay and editor modes.
///
/// They used to be `NSPopover`s. The system popover is translucent glass with
/// a pointer arrow, a different material from the solid toolbar it hangs off,
/// and next to a light screenshot it read as a smear. Each is now a small
/// borderless panel on the toolbar's own surface — same fill, hairline edge,
/// shadow and corner radius — opened beside its button, with the same
/// dismissal a semitransient popover had: a click outside, Esc, or the button
/// again.
enum PopoverHelper {

    private static var activePanel: ToolbarPopoverPanel?
    private static var localMouseDownMonitor: Any?
    private static var globalMouseDownMonitor: Any?

    /// Space between the panel's edge and its content, so pickers are not
    /// pressed against the border.
    static let contentInset: CGFloat = 10
    /// Lists carry their own row padding and a full-width highlight; a wide
    /// inset on top of that left the highlight floating in the panel.
    static let listInset: CGFloat = 4

    /// Show `contentView` (of `size`) in a panel beside `rect` of `view`.
    static func show(_ contentView: NSView, size: NSSize, relativeTo rect: NSRect, of view: NSView,
                     preferredEdge: NSRectEdge = .minY, inset: CGFloat = contentInset) {
        dismiss()
        guard let window = view.window else { return }
        let anchorOnScreen = window.convertToScreen(view.convert(rect, to: nil))
        present(contentView, size: size, inset: inset, anchor: anchorOnScreen, parent: window,
                preferredEdge: preferredEdge)
    }

    /// Show a panel anchored to a point in a view (for anchors that are not real views).
    static func showAtPoint(_ contentView: NSView, size: NSSize, at point: NSPoint, in parentView: NSView, preferredEdge: NSRectEdge = .minY) {
        show(contentView, size: size, relativeTo: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2),
             of: parentView, preferredEdge: preferredEdge)
    }

    /// Show a menu list beside `view`, scrolling when it is taller than
    /// `maxHeight`. The one presentation every toolbar secondary menu uses.
    static func showList(_ list: ListPickerView, relativeTo rect: NSRect, of view: NSView,
                         preferredEdge: NSRectEdge = .maxY, maxHeight: CGFloat = 360) {
        let natural = list.preferredSize
        list.frame.size = NSSize(width: max(list.frame.width, natural.width), height: natural.height)
        guard natural.height > maxHeight else {
            show(list, size: list.frame.size, relativeTo: rect, of: view, preferredEdge: preferredEdge, inset: listInset)
            return
        }
        let size = NSSize(width: list.frame.width, height: maxHeight)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = list
        show(scrollView, size: size, relativeTo: rect, of: view, preferredEdge: preferredEdge, inset: listInset)
        DispatchQueue.main.async { list.scrollToSelected() }
    }

    /// Resize the open panel to fit new content — e.g. the emoji picker when
    /// its category changes. Keeps the edge nearest the anchor in place.
    static func resizeActive(toContentSize size: NSSize) {
        activePanel?.resize(toContentSize: size)
    }

    private static func present(_ contentView: NSView, size: NSSize, inset: CGFloat, anchor: NSRect,
                                parent: NSWindow, preferredEdge: NSRectEdge) {
        let panel = ToolbarPopoverPanel(content: contentView, contentSize: size, inset: inset)
        panel.anchor = anchor
        panel.preferredEdge = preferredEdge
        panel.collectionBehavior.formUnion(parent.collectionBehavior.intersection([.canJoinAllSpaces, .fullScreenAuxiliary]))
        panel.place(on: parent.screen ?? NSScreen.main)
        // A child window, so it moves with an editor window; then a level above
        // the window it opens from — the capture overlay sits far above normal
        // windows. The level is set after adding: adding resets it to the
        // parent's.
        parent.addChildWindow(panel, ordered: .above)
        panel.level = NSWindow.Level(max(parent.level.rawValue + 1, NSWindow.Level.floating.rawValue))
        panel.alphaValue = 0
        panel.orderFront(nil)
        // Key, so lists take the arrow keys and fields take typing, while the
        // overlay and macshot itself stay inactive (the panel is non-activating).
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        // The shadow follows the drawn shape, which exists only once the
        // surface has been displayed.
        DispatchQueue.main.async { panel.invalidateShadow() }
        activePanel = panel
        installOutsideClickMonitors()
    }

    /// Time the most recent panel was dismissed — used to implement
    /// click-the-anchor-to-toggle-closed (the outside click dismisses the
    /// panel before the button handler runs, so the handler checks "was one
    /// just dismissed?" instead of "is one visible?").
    private(set) static var lastDismissedAt: Date = .distantPast

    static func dismiss() {
        if let panel = activePanel {
            lastDismissedAt = Date()
            activePanel = nil
            let parent = panel.parent
            let hadKeyboard = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.close()
            // Hand the keyboard back to the overlay or editor the panel came
            // from, so its shortcuts and Esc work again straight away.
            if hadKeyboard, let parent, parent.isVisible { parent.makeKey() }
        }
        removeOutsideClickMonitors()
    }

    /// True if a panel was dismissed within the last `seconds` (default 0.25s).
    static func wasRecentlyDismissed(within seconds: TimeInterval = 0.25) -> Bool {
        Date().timeIntervalSince(lastDismissedAt) < seconds
    }

    /// Toggle helper for anchor buttons that open a panel. Clicking the same
    /// button that opened a panel should CLOSE it (and not reopen).
    ///
    /// The catch: the outside-click monitor fires on the same mouseDown and
    /// dismisses the panel BEFORE the button's action runs, so by the time the
    /// handler checks `isVisible` it's already false and the handler would
    /// reopen. So we also treat "a panel was just dismissed" as
    /// already-handled. Returns true if the click closed an open/just-closed
    /// panel — callers should `return` early when it does.
    static func toggleClosedIfOpen() -> Bool {
        if isVisible || wasRecentlyDismissed() {
            dismiss()
            return true
        }
        return false
    }

    static var isVisible: Bool { activePanel?.isVisible == true }

    static var isMouseInsidePopover: Bool {
        guard let panel = activePanel, panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    private static func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if shouldDismiss(forMouseDownAt: NSEvent.mouseLocation) {
                dismiss()
            }
            return event
        }
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            DispatchQueue.main.async {
                if shouldDismiss(forMouseDownAt: NSEvent.mouseLocation) {
                    dismiss()
                }
            }
        }
    }

    private static func removeOutsideClickMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private static func shouldDismiss(forMouseDownAt screenPoint: NSPoint) -> Bool {
        guard let panel = activePanel, panel.isVisible else { return false }
        return !panel.frame.contains(screenPoint)
    }
}

/// The borderless panel a toolbar picker opens in: the toolbar surface around
/// the content, with an even inset.
private final class ToolbarPopoverPanel: NSPanel {
    var anchor: NSRect = .zero
    var preferredEdge: NSRectEdge = .maxY
    private let surface: ArrowCursorView
    private let content: NSView
    private let inset: CGFloat

    init(content: NSView, contentSize: NSSize, inset: CGFloat) {
        self.content = content
        self.inset = inset
        let frame = NSRect(x: 0, y: 0, width: contentSize.width + inset * 2, height: contentSize.height + inset * 2)
        surface = ArrowCursorView(frame: frame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        // The window server's shadow follows the rounded surface.
        hasShadow = true
        appearance = ToolbarLayout.appearance
        surface.appearance = ToolbarLayout.appearance
        styleSurface()
        content.frame = NSRect(x: inset, y: inset, width: contentSize.width, height: contentSize.height)
        surface.addSubview(content)
        contentView = surface
    }

    private func styleSurface() {
        surface.applyToolbarSurface()
        // Clip the content to the rounded corners; the window casts the shadow.
        surface.layer?.masksToBounds = true
        surface.layer?.shadowOpacity = 0
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes, as it did a popover — for content that does not handle it
    /// (the lists do, and close too).
    override func cancelOperation(_ sender: Any?) {
        PopoverHelper.dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { PopoverHelper.dismiss(); return }
        super.keyDown(with: event)
    }

    /// Put the panel on `preferredEdge` of the anchor, flipping to the
    /// opposite edge when it does not fit, then keeping it inside the screen.
    func place(on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = frame.size
        let gap: CGFloat = 6

        func origin(for edge: NSRectEdge) -> NSPoint {
            switch edge {
            case .maxY: return NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
            case .minY: return NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
            case .minX: return NSPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
            case .maxX: return NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
            @unknown default: return NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
            }
        }
        func fits(_ o: NSPoint, along edge: NSRectEdge) -> Bool {
            switch edge {
            case .maxY: return o.y + size.height <= visible.maxY
            case .minY: return o.y >= visible.minY
            case .minX: return o.x >= visible.minX
            case .maxX: return o.x + size.width <= visible.maxX
            @unknown default: return true
            }
        }
        let opposite: [NSRectEdge: NSRectEdge] = [.maxY: .minY, .minY: .maxY, .minX: .maxX, .maxX: .minX]
        var o = origin(for: preferredEdge)
        if !fits(o, along: preferredEdge), let flipped = opposite[preferredEdge] {
            let alternative = origin(for: flipped)
            if fits(alternative, along: flipped) {
                o = alternative
                preferredEdge = flipped
            }
        }
        o.x = max(visible.minX + 4, min(o.x, visible.maxX - size.width - 4))
        o.y = max(visible.minY + 4, min(o.y, visible.maxY - size.height - 4))
        setFrameOrigin(o)
    }

    func resize(toContentSize size: NSSize) {
        let newSize = NSSize(width: size.width + inset * 2, height: size.height + inset * 2)
        content.frame = NSRect(x: inset, y: inset, width: size.width, height: size.height)
        var f = frame
        // Keep the edge facing the anchor where it is.
        f.origin.y = preferredEdge == .maxY ? frame.minY : frame.maxY - newSize.height
        f.origin.x = frame.midX - newSize.width / 2
        f.size = newSize
        setFrame(f, display: true)
        surface.frame = NSRect(origin: .zero, size: newSize)
        styleSurface()
        invalidateShadow()
    }
}

/// NSView that forces the arrow cursor over its entire bounds.
private class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
