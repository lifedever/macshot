import Cocoa

/// The menu list every toolbar button's secondary choices open in: rows with a
/// checkmark for the current choice, optional section headers, separators and
/// shortcut hints, drawn in the toolbar's own colours.
///
/// It replaces the native `NSMenu`s those buttons used to open, whose system
/// highlight and material sat oddly beside the themed toolbar. What a native
/// menu gives for free is kept: the arrow keys move a highlight, Return or
/// Space chooses, Esc closes, and typing jumps to the first matching row.
class ListPickerView: NSView {

    struct Item {
        enum Kind { case option, header, separator }

        var kind: Kind = .option
        let title: String
        let isSelected: Bool
        var icon: NSImage? = nil
        var isEnabled: Bool = true
        var subtitle: String? = nil
        /// Key equivalent shown at the trailing edge, e.g. "⌘+".
        var shortcut: String? = nil

        static let separator = Item(kind: .separator, title: "", isSelected: false, isEnabled: false)
        static func header(_ title: String) -> Item {
            Item(kind: .header, title: title, isSelected: false, isEnabled: false)
        }

        var isChoosable: Bool { kind == .option && isEnabled }
    }

    var items: [Item] = [] { didSet { highlightedIndex = nil; rebuildRows() } }
    /// Called with the index into `items` of the row that was chosen.
    var onSelect: ((Int) -> Void)?

    /// The row under the pointer or reached with the arrow keys.
    fileprivate(set) var highlightedIndex: Int? {
        didSet {
            guard oldValue != highlightedIndex else { return }
            for row in rowViews where row.index == oldValue || row.index == highlightedIndex {
                row.needsDisplay = true
            }
        }
    }

    static let optionHeight: CGFloat = 26
    /// Taller than a row, so a section reads as starting after the last one.
    static let headerHeight: CGFloat = 30
    static let separatorHeight: CGFloat = 9
    private static let verticalPadding: CGFloat = 5
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let shortcutFont = NSFont.systemFont(ofSize: 12)
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let textX: CGFloat = 30
    static let trailingPadding: CGFloat = 14

    private var rowViews: [ListPickerRowView] = []
    private var typeahead = ""
    private var typeaheadResetTask: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func height(of item: Item) -> CGFloat {
        switch item.kind {
        case .option: return optionHeight
        case .header: return headerHeight
        case .separator: return separatorHeight
        }
    }

    private func rebuildRows() {
        for rv in rowViews { rv.removeFromSuperview() }
        rowViews.removeAll()

        let width: CGFloat = max(frame.width, preferredSize.width)
        let totalH = items.reduce(Self.verticalPadding * 2) { $0 + Self.height(of: $1) }
        var y = totalH - Self.verticalPadding  // start from top

        for (i, item) in items.enumerated() {
            let h = Self.height(of: item)
            y -= h
            let rv = ListPickerRowView(frame: NSRect(x: 0, y: y, width: width, height: h))
            rv.item = item
            rv.index = i
            rv.list = self
            addSubview(rv)
            rowViews.append(rv)
        }
        frame.size = NSSize(width: width, height: totalH)
    }

    /// Preferred size for the popover, computed from content.
    var preferredSize: NSSize {
        var maxRowW: CGFloat = 120
        for item in items {
            switch item.kind {
            case .separator:
                continue
            case .header:
                let w = (item.title as NSString).size(withAttributes: [.font: Self.headerFont]).width
                maxRowW = max(maxRowW, w + 24)
            case .option:
                var w = Self.textX + (item.title as NSString).size(withAttributes: [.font: Self.titleFont]).width
                if item.icon != nil { w += 22 }
                if let subtitle = item.subtitle {
                    w += 6 + (subtitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
                }
                if let shortcut = item.shortcut {
                    w += 24 + (shortcut as NSString).size(withAttributes: [.font: Self.shortcutFont]).width
                }
                maxRowW = max(maxRowW, w + Self.trailingPadding)
            }
        }
        let h = items.reduce(Self.verticalPadding * 2) { $0 + Self.height(of: $1) }
        return NSSize(width: ceil(maxRowW), height: h)
    }

    // MARK: - Choosing

    fileprivate func choose(_ index: Int) {
        guard items.indices.contains(index), items[index].isChoosable else { return }
        onSelect?(index)
    }

    fileprivate func pointerEntered(_ index: Int) {
        highlightedIndex = items.indices.contains(index) && items[index].isChoosable ? index : nil
    }

    fileprivate func pointerExited(_ index: Int) {
        if highlightedIndex == index { highlightedIndex = nil }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveHighlight(by: 1)                  // ↓
        case 126: moveHighlight(by: -1)                 // ↑
        case 115: moveHighlight(toEnd: false)           // Home
        case 119: moveHighlight(toEnd: true)            // End
        case 36, 76, 49:                                // Return, Enter, Space
            if let index = highlightedIndex { choose(index) }
        case 53:                                        // Esc
            PopoverHelper.dismiss()
        default:
            if !typeaheadJump(with: event) { super.keyDown(with: event) }
        }
    }

    private var choosableIndices: [Int] { items.indices.filter { items[$0].isChoosable } }

    private func moveHighlight(by step: Int) {
        let choosable = choosableIndices
        guard !choosable.isEmpty else { return }
        let next: Int
        if let current = highlightedIndex, let pos = choosable.firstIndex(of: current) {
            next = choosable[max(0, min(choosable.count - 1, pos + step))]
        } else if let selected = choosable.first(where: { items[$0].isSelected }) {
            // Like a menu reopened on its current value.
            next = selected
        } else {
            next = step > 0 ? choosable[0] : choosable[choosable.count - 1]
        }
        highlightedIndex = next
        scrollHighlightIntoView()
    }

    private func moveHighlight(toEnd: Bool) {
        let choosable = choosableIndices
        guard let target = toEnd ? choosable.last : choosable.first else { return }
        highlightedIndex = target
        scrollHighlightIntoView()
    }

    /// Typing a few letters jumps to the first row starting with them, as in
    /// a native menu — the language list alone has over a hundred rows.
    private func typeaheadJump(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return false }
        typeahead += chars.lowercased()
        typeaheadResetTask?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.typeahead = "" }
        typeaheadResetTask = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reset)
        if let match = choosableIndices.first(where: { items[$0].title.lowercased().hasPrefix(typeahead) }) {
            highlightedIndex = match
            scrollHighlightIntoView()
        }
        return true
    }

    private func scrollHighlightIntoView() {
        guard let index = highlightedIndex, let row = rowViews.first(where: { $0.index == index }) else { return }
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -Self.optionHeight / 2))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollDidChange),
                name: NSView.boundsDidChangeNotification, object: enclosingScrollView?.contentView)
            enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
            // Take the keyboard once the popover window is key, so the arrow
            // keys and typing work straight away.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !(window.firstResponder is NSTextView) { window.makeFirstResponder(self) }
            }
        } else {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        }
    }

    @objc private func scrollDidChange(_ notification: Notification) {
        guard let mouseLocation = window?.mouseLocationOutsideOfEventStream else { return }
        let hovered = rowViews.first { $0.bounds.contains($0.convert(mouseLocation, from: nil)) }
        highlightedIndex = hovered.flatMap { items[$0.index].isChoosable ? $0.index : nil }
    }

    /// Scroll the enclosing scroll view so the selected item is visible.
    func scrollToSelected() {
        guard let scrollView = enclosingScrollView else { return }
        for rv in rowViews where rv.item.isSelected {
            scrollView.contentView.scrollToVisible(rv.frame.insetBy(dx: 0, dy: -Self.optionHeight))
            return
        }
    }

    /// Update row widths when placed in a scroll view that's wider.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for rv in rowViews {
            rv.frame.size.width = newSize.width
        }
    }
}

// MARK: - Row View

private class ListPickerRowView: NSView {
    var item = ListPickerView.Item(title: "", isSelected: false)
    var index: Int = 0
    weak var list: ListPickerView?

    private var trackingArea: NSTrackingArea?

    private var isHighlighted: Bool { list?.highlightedIndex == index }

    override func draw(_ dirtyRect: NSRect) {
        switch item.kind {
        case .separator:
            ToolbarLayout.surfaceBorderColor.setFill()
            NSRect(x: 10, y: floor(bounds.midY), width: bounds.width - 20, height: 1).fill()
        case .header:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: ListPickerView.headerFont,
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
            ]
            let size = (item.title as NSString).size(withAttributes: attrs)
            // Sit on the rows below it, with the extra height above.
            (item.title as NSString).draw(at: NSPoint(x: 12, y: bounds.minY + 3), withAttributes: attrs)
            _ = size
        case .option:
            drawOption()
        }
    }

    private func drawOption() {
        let enabledAlpha: CGFloat = item.isEnabled ? 1.0 : 0.35
        let highlighted = isHighlighted && item.isEnabled

        if highlighted {
            ToolbarLayout.accentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let ink = highlighted ? NSColor.white : ToolbarLayout.iconColor.withAlphaComponent(enabledAlpha)
        let secondaryInk = highlighted
            ? NSColor.white.withAlphaComponent(0.75)
            : ToolbarLayout.iconColor.withAlphaComponent(0.45 * enabledAlpha)

        if item.isSelected,
           let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            let tint = highlighted ? NSColor.white : ToolbarLayout.accentColor.withAlphaComponent(enabledAlpha)
            let tinted = NSImage(size: check.size, flipped: false) { r in
                check.draw(in: r)
                tint.setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: 12, y: bounds.midY - check.size.height / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }

        var x = ListPickerView.textX
        if let icon = item.icon {
            let side: CGFloat = 16
            let tinted = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
                icon.draw(in: r)
                ink.setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: bounds.midY - side / 2, width: side, height: side))
            x += side + 6
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: ListPickerView.titleFont, .foregroundColor: ink]
        let title = item.title as NSString
        let titleSize = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: x, y: bounds.midY - titleSize.height / 2), withAttributes: attrs)

        if let subtitle = item.subtitle {
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondaryInk,
            ]
            let subSize = (subtitle as NSString).size(withAttributes: subAttrs)
            (subtitle as NSString).draw(at: NSPoint(x: x + titleSize.width + 6, y: bounds.midY - subSize.height / 2),
                                        withAttributes: subAttrs)
        }

        if let shortcut = item.shortcut {
            let keyAttrs: [NSAttributedString.Key: Any] = [
                .font: ListPickerView.shortcutFont, .foregroundColor: secondaryInk,
            ]
            let keySize = (shortcut as NSString).size(withAttributes: keyAttrs)
            (shortcut as NSString).draw(
                at: NSPoint(x: bounds.maxX - ListPickerView.trailingPadding - keySize.width,
                            y: bounds.midY - keySize.height / 2),
                withAttributes: keyAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        list?.choose(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { list?.pointerEntered(index) }
    override func mouseExited(with event: NSEvent) { list?.pointerExited(index) }
}
