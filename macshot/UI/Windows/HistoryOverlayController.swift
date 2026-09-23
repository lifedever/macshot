import Cocoa
import QuickLookUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Drop-down panel showing recent screenshot history as a horizontal scrolling strip.
/// Slides down from the top of the screen. Left-click to copy, right-click for more actions,
/// ESC or click outside to dismiss.
final class HistoryOverlayController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    private var panel: NSPanel?
    private var contentView: HistoryPanelView?
    private var backdropWindow: NSWindow?
    var onDismiss: (() -> Void)?

    // Quick Look state
    /// The file Quick Look is showing, resolved when it opened so later
    /// history writes cannot shift it onto a different capture.
    private var quickLookURL: URL?
    private var quickLookCloseObserver: NSObjectProtocol?
    /// Quick Look holds its data source and delegate unretained. The panel
    /// closes itself before the preview appears and the app then drops this
    /// controller, which left Quick Look messaging a freed object on the next
    /// key press or when it closed. Kept alive here until the preview closes.
    private static var quickLookOwner: HistoryOverlayController?
    /// The entry a context menu was opened on. Menu items used to carry its
    /// position, which a history write landing while the menu was open
    /// shifted onto a neighbouring capture — Delete removed the wrong one.
    private var contextMenuEntryID: String?

    private static let panelHeight: CGFloat = 240
    private static let animationDuration: TimeInterval = 0.12

    func show() {
        guard let screen = NSScreen.main else { return }

        // Transparent click-catching backdrop (dismisses on click)
        let backdrop = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(256)
        backdrop.isOpaque = false
        backdrop.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = false
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backdrop.isReleasedWhenClosed = false

        let backdropView = BackdropView(frame: screen.frame)
        backdropView.controller = self
        backdrop.contentView = backdropView
        backdrop.makeKeyAndOrderFront(nil)
        self.backdropWindow = backdrop

        // Panel window — starts above screen, slides down
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height
            - screen.visibleFrame.origin.y + screen.frame.origin.y
        let panelWidth = min(screen.frame.width - 40, 1200)
        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.maxY - menuBarHeight

        let startFrame = NSRect(x: panelX, y: panelY,
                                width: panelWidth, height: Self.panelHeight)
        let endFrame = NSRect(x: panelX, y: panelY - Self.panelHeight,
                              width: panelWidth, height: Self.panelHeight)

        let win = KeyablePanel(
            contentRect: startFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        win.level = NSWindow.Level(257)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = false
        win.alphaValue = 0.0

        let view = HistoryPanelView(
            frame: NSRect(origin: .zero, size: startFrame.size))
        view.controller = self
        win.contentView = view
        win.orderFront(nil)

        self.panel = win
        self.contentView = view

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(endFrame, display: true)
            win.animator().alphaValue = 1.0
        }, completionHandler: {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
        })

        view.loadEntries()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyDidChange),
            name: ScreenshotHistory.didChange, object: ScreenshotHistory.shared)
    }

    @objc private func historyDidChange() { contentView?.loadEntries() }

    @objc private func appDidResignActive() {
        dismiss()
    }

    /// Hide windows immediately so drag-and-drop can reach target apps.
    func hideForDrag() {
        backdropWindow?.orderOut(nil)
        panel?.alphaValue = 0.0
    }

    func confirmClearHistory() {
        dismiss()
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.confirmClearHistory()
        }
    }

    func dismiss() {
        dismiss(immediate: false)
    }

    private func dismiss(immediate: Bool) {
        NotificationCenter.default.removeObserver(self, name: ScreenshotHistory.didChange, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didResignActiveNotification, object: nil)

        // Always tear down the backdrop immediately so it never blocks input
        if let bd = backdropWindow {
            bd.orderOut(nil)
            bd.close()
            backdropWindow = nil
        }

        guard let win = panel else {
            contentView = nil
            onDismiss?()
            return
        }
        panel = nil

        if immediate {
            win.orderOut(nil)
            win.close()
            contentView = nil
            onDismiss?()
            return
        }

        let hiddenFrame = NSRect(
            x: win.frame.origin.x, y: win.frame.origin.y + Self.panelHeight,
            width: win.frame.width, height: Self.panelHeight)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(hiddenFrame, display: true)
            win.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            win.close()
            self?.contentView = nil
            self?.onDismiss?()
        })
    }

    // MARK: - Actions

    func copyAndDismiss(index: Int) {
        ScreenshotHistory.shared.copyEntry(at: index)
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            AppDelegate.captureSound?.stop()
            AppDelegate.captureSound?.play()
        }
        dismiss()
    }

    func deleteEntry(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        ScreenshotHistory.shared.removeEntry(id: entry.id)
        contentView?.loadEntries()
    }

    func openInEditor(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]

        // Try loading editable annotations + raw image first
        if entry.hasAnnotations,
           let editable = ScreenshotHistory.shared.loadEditableCapture(for: entry) {
            dismiss()
            let entryID = entry.id
            DispatchQueue.main.async {
                DetachedEditorWindowController.open(
                    image: editable.rawImage,
                    annotations: editable.annotations,
                    historyEntryID: entryID,
                    editState: editable.editState
                )
            }
            return
        }

        // Fall back to flattened image (old entries or missing files) — beautify already baked in
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }
        dismiss()
        let entryID = entry.id
        DispatchQueue.main.async {
            DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
        }
    }

    func pinToScreen(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        guard let image = ScreenshotHistory.shared.loadImage(for: entries[index]) else { return }
        dismiss()
        // Post notification so AppDelegate handles pin creation (it owns pinControllers)
        NotificationCenter.default.post(name: .init("macshot.pinFromHistory"), object: image)
    }

    func quickLook(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        quickLookURL = ScreenshotHistory.shared.fileURL(for: entries[index])
        dismiss()
        guard let qlPanel = QLPreviewPanel.shared() else { return }
        Self.quickLookOwner = self
        qlPanel.dataSource = self
        qlPanel.delegate = self
        qlPanel.reloadData()
        qlPanel.makeKeyAndOrderFront(nil)

        quickLookCloseObserver.map(NotificationCenter.default.removeObserver)
        quickLookCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: qlPanel, queue: .main
        ) { [weak self, weak qlPanel] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if qlPanel?.dataSource === self { qlPanel?.dataSource = nil }
                if qlPanel?.delegate === self { qlPanel?.delegate = nil }
                self.quickLookCloseObserver.map(NotificationCenter.default.removeObserver)
                self.quickLookCloseObserver = nil
                if Self.quickLookOwner === self { Self.quickLookOwner = nil }
            }
        }
    }

    func saveToFile(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }

        let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        let base = FilenameFormatter.format(template: template, date: entry.timestamp)
        ImageSaveService.showSavePanel(
            for: image,
            suggestedFilename: "\(base).\(ImageEncoder.fileExtension)",
            panelLevel: .floating
        )
    }

    #if !OFFLINE
    func uploadEntry(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        guard let image = ScreenshotHistory.shared.loadImage(for: entries[index]) else { return }
        dismiss()
        (NSApp.delegate as? AppDelegate)?.uploadImage(image)
    }
    #endif

    func runOCR(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        guard let image = ScreenshotHistory.shared.loadImage(for: entries[index]) else { return }
        dismiss()
        (NSApp.delegate as? AppDelegate)?.runOCR(on: image)
    }

    func transformEntry(index: Int, transform: ImageContextTransform) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        guard let image = ScreenshotHistory.shared.loadImage(for: entry),
              let transformed = image.macshotTransformed(transform) else { return }
        ScreenshotHistory.shared.updateEntry(id: entry.id, compositedImage: transformed, rawImage: nil, annotations: nil)
        contentView?.loadEntries()
    }

    func openEntry(index: Int, with appURL: URL) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let fileURL = ScreenshotHistory.shared.fileURL(for: entries[index])
        dismiss(immediate: true)
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func shareEntry(index: Int, service: NSSharingService) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let fileURL = ScreenshotHistory.shared.fileURL(for: entries[index])
        dismiss(immediate: true)
        service.perform(withItems: [fileURL])
    }

    // MARK: - Context Menu

    func showContextMenu(for globalIndex: Int, at point: NSPoint, in view: NSView) {
        let entries = ScreenshotHistory.shared.entries
        guard globalIndex >= 0, globalIndex < entries.count else { return }
        let fileURL = ScreenshotHistory.shared.fileURL(for: entries[globalIndex])
        contextMenuEntryID = entries[globalIndex].id

        let menu = NSMenu()

        let copyItem = ImageContextMenu.item(title: L("Copy"), symbolName: "doc.on.doc", action: #selector(contextCopy(_:)), target: self, keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.tag = globalIndex
        menu.addItem(copyItem)

        let saveItem = ImageContextMenu.item(title: L("Save As..."), symbolName: "square.and.arrow.down", action: #selector(contextSave(_:)), target: self, keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command]
        saveItem.tag = globalIndex
        menu.addItem(saveItem)

        menu.addItem(NSMenuItem.separator())

        let editorItem = ImageContextMenu.item(title: L("Open in Editor"), symbolName: "pencil", action: #selector(contextOpenEditor(_:)), target: self, keyEquivalent: "e")
        editorItem.keyEquivalentModifierMask = [.command]
        editorItem.tag = globalIndex
        menu.addItem(editorItem)

        let pinItem = ImageContextMenu.item(title: L("Pin to Screen"), symbolName: "pin.fill", action: #selector(contextPin(_:)), target: self)
        pinItem.tag = globalIndex
        menu.addItem(pinItem)

        #if !OFFLINE
        let uploadItem = ImageContextMenu.item(title: L("Upload"), symbolName: "icloud.and.arrow.up", action: #selector(contextUpload(_:)), target: self)
        uploadItem.tag = globalIndex
        menu.addItem(uploadItem)
        #endif

        let qlItem = ImageContextMenu.item(title: L("Quick Look"), symbolName: "eye", action: #selector(contextQuickLook(_:)), target: self, keyEquivalent: " ")
        qlItem.keyEquivalentModifierMask = []
        qlItem.tag = globalIndex
        menu.addItem(qlItem)

        let ocrItem = ImageContextMenu.item(title: L("Run OCR & QR"), symbolName: "text.viewfinder", action: #selector(contextOCR(_:)), target: self)
        ocrItem.tag = globalIndex
        menu.addItem(ocrItem)

        menu.addItem(NSMenuItem.separator())
        ImageContextMenu.addTransformItems(to: menu, target: self, action: #selector(contextTransform(_:)), representedObject: globalIndex)

        menu.addItem(NSMenuItem.separator())
        let openWith = ImageContextMenu.openWithItem(fileURL: fileURL, target: self, action: #selector(contextOpenWith(_:)))
        openWith.submenu?.items.forEach { $0.tag = globalIndex }
        menu.addItem(openWith)

        let share = ImageContextMenu.shareItem(fileURL: fileURL, target: self, action: #selector(contextShare(_:)))
        share.submenu?.items.forEach { $0.tag = globalIndex }
        menu.addItem(share)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = ImageContextMenu.item(title: L("Delete"), symbolName: "trash", action: #selector(contextDelete(_:)), target: self, keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        deleteItem.tag = globalIndex
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: view)
    }

    /// Where the context menu's entry is now; -1 once it has gone, which
    /// every action below treats as nothing to do.
    private var contextMenuIndex: Int {
        guard let id = contextMenuEntryID else { return -1 }
        return ScreenshotHistory.shared.entries.firstIndex { $0.id == id } ?? -1
    }

    @objc private func contextCopy(_ sender: NSMenuItem) { copyAndDismiss(index: contextMenuIndex) }
    @objc private func contextSave(_ sender: NSMenuItem) { saveToFile(index: contextMenuIndex) }
    @objc private func contextOpenEditor(_ sender: NSMenuItem) { openInEditor(index: contextMenuIndex) }
    @objc private func contextPin(_ sender: NSMenuItem) { pinToScreen(index: contextMenuIndex) }
    #if !OFFLINE
    @objc private func contextUpload(_ sender: NSMenuItem) { uploadEntry(index: contextMenuIndex) }
    #endif
    @objc private func contextQuickLook(_ sender: NSMenuItem) { quickLook(index: contextMenuIndex) }
    @objc private func contextOCR(_ sender: NSMenuItem) { runOCR(index: contextMenuIndex) }
    @objc private func contextDelete(_ sender: NSMenuItem) { deleteEntry(index: contextMenuIndex) }
    @objc private func contextTransform(_ sender: NSMenuItem) {
        guard let transform = ImageContextTransform(rawValue: sender.tag) else { return }
        transformEntry(index: contextMenuIndex, transform: transform)
    }
    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        openEntry(index: contextMenuIndex, with: appURL)
    }
    @objc private func contextShare(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService else { return }
        shareEntry(index: contextMenuIndex, service: service)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURL as NSURL?
    }
}

// MARK: - Backdrop View

private final class BackdropView: NSView {
    weak var controller: HistoryOverlayController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            controller?.dismiss()
        }
    }
}

// MARK: - Filter Tab

private enum HistoryFilter: String, CaseIterable {
    case all = "All"
    case screenshots = "Screenshots"
    case gifs = "GIFs"

    func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return entry.fileExtension == "png"
        case .gifs: return entry.fileExtension == "gif"
        }
    }
}

// MARK: - History Panel View

private final class HistoryPanelView: NSView, NSDraggingSource {

    weak var controller: HistoryOverlayController?

    private var entries: [HistoryEntry] = []
    private var filteredIndices: [Int] = []
    /// Bounded preview cache. Eager-loading every entry's preview was hammering
    /// memory for users with hundreds of history items (#mem-audit). Now we
    /// load only what's drawn, evict oldest beyond `previewCacheLimit`, and
    /// drop the whole thing on dismiss when the view is released.
    private var previews: [String: NSImage] = [:]
    /// Preview ids in MRU order — most recent at the end. Lookups bump the id
    /// to the end; eviction pops the front. Bounded so memory stays roughly
    /// constant regardless of total history size.
    private var previewLRU: [String] = []
    /// Tokens keep an obsolete revision's completion from replacing a newer
    /// preview (or clearing the newer revision's in-flight request).
    private var previewLoadsInFlight: [String: UUID] = [:]
    /// Soft cap on cached previews. Three screens of cards (~50 each) leaves
    /// headroom for fast back-scrolling without re-loading from disk, while
    /// keeping peak footprint bounded (~75 MB worst case at typical preview
    /// dimensions, but usually much less because previews are tiny PNGs).
    private static let previewCacheLimit = 150
    /// How many cards to lookahead in the scroll direction to pre-fetch so
    /// scrolling doesn't show empty cards before the load resolves.
    private static let previewPrefetchLookahead = 12
    private var cardRects: [NSRect] = []
    /// Filtered-index of the card the mouse is currently over, or -1.
    /// Only drives the darkened overlay + "Click to copy" hint now — the
    /// accent outline comes from `selectedIndex` so hover and keyboard
    /// navigation never fight over which card is highlighted.
    private var hoveredIndex: Int = -1
    /// Unified selection: updated by arrow keys AND by mouse hover. The
    /// outlined card is always `selectedIndex`, so arrow keys always step
    /// from whatever the mouse is pointing at. Hint overlay is keyed off
    /// `hoveredIndex` separately. -1 until loadEntries lands a default.
    private var selectedIndex: Int = -1
    private var activeFilter: HistoryFilter = .all
    private var filterTabRects: [NSRect] = []

    // Scroll state
    private var scrollOffset: CGFloat = 0
    private var contentWidth: CGFloat = 0

    // Drag state: track mouseDown origin to distinguish click vs drag
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownCardIndex: Int = -1 // filtered index
    private var isDragging = false
    private static let dragThreshold: CGFloat = 4

    // Layout constants
    private static let cardWidth: CGFloat = 200
    private static let cardHeight: CGFloat = 160
    private static let cardGap: CGFloat = 14
    private static let sidePadding: CGFloat = 24
    private static let topBarHeight: CGFloat = 50
    private static let cornerRadius: CGFloat = 14
    private var trashButtonRect: NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - Data Loading

    func loadEntries() {
        let updated = ScreenshotHistory.shared.entries
        let updatedByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        let changedIDs = Set(entries.compactMap { old -> String? in
            guard let new = updatedByID[old.id],
                  new.revision == old.revision else { return old.id }
            return nil
        })
        for id in changedIDs {
            previews.removeValue(forKey: id)
            previewLoadsInFlight.removeValue(forKey: id)
        }
        previewLRU.removeAll { changedIDs.contains($0) }
        let selectedID = globalIndexForSelected().map { entries[$0].id }
        let selectedPosition = selectedIndex
        entries = updated
        applyFilter(keepingSelectionOf: selectedID, near: selectedPosition)
        // Previews are loaded lazily as cards become visible — see
        // requestPreviewIfNeeded(for:) and prefetchPreviewsAroundVisible().
        // Kick off prefetch for the first screenful so the panel doesn't
        // open with empty placeholders.
        prefetchPreviewsAroundVisible()
    }

    // MARK: - Lazy Preview Loading

    /// Return the cached preview for `entry`, or trigger an async load and
    /// return nil. Keeps the cache bounded by evicting the oldest non-visible
    /// entry when over the soft cap.
    private func cachedPreview(for entry: HistoryEntry) -> NSImage? {
        if let img = previews[entry.id] {
            // Bump to MRU
            if let pos = previewLRU.firstIndex(of: entry.id) {
                previewLRU.remove(at: pos)
            }
            previewLRU.append(entry.id)
            return img
        }
        requestPreviewIfNeeded(for: entry)
        return nil
    }

    private func requestPreviewIfNeeded(for entry: HistoryEntry) {
        let id = entry.id
        guard previews[id] == nil, previewLoadsInFlight[id] == nil else { return }
        let token = UUID()
        previewLoadsInFlight[id] = token
        // Resolve the immutable revision URLs while history is main-isolated.
        // Only ImageIO decoding belongs on the worker, never shared NSImage or
        // the mutable history index.
        let urls = ScreenshotHistory.shared.previewURLs(for: entry)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pixels = HistoryImageSnapshot.preview(at: urls)
            DispatchQueue.main.async {
                guard let self, self.previewLoadsInFlight[id] == token else { return }
                self.previewLoadsInFlight.removeValue(forKey: id)
                guard let pixels else { return }
                self.previews[id] = NSImage(cgImage: pixels, size: .zero)
                self.previewLRU.append(id)
                self.evictPreviewsIfNeeded()
                self.needsDisplay = true
            }
        }
    }

    /// Pop oldest preview ids until cache is within `previewCacheLimit`.
    /// Visible-region ids are protected — we walk the LRU front-to-back and
    /// skip any id that's currently on screen (or within the lookahead zone)
    /// so we don't immediately re-load what we just evicted.
    private func evictPreviewsIfNeeded() {
        guard previewLRU.count > Self.previewCacheLimit else { return }
        let visibleIDs = currentVisibleAndPrefetchIDs()
        var i = 0
        while i < previewLRU.count && previews.count > Self.previewCacheLimit {
            let id = previewLRU[i]
            if visibleIDs.contains(id) { i += 1; continue }
            previews.removeValue(forKey: id)
            previewLRU.remove(at: i)
        }
    }

    /// Set of entry ids currently drawn on screen plus the lookahead window
    /// in either scroll direction. Used both to protect from eviction and to
    /// drive prefetch.
    private func currentVisibleAndPrefetchIDs() -> Set<String> {
        guard !filteredIndices.isEmpty else { return [] }
        var ids: Set<String> = []
        let look = Self.previewPrefetchLookahead
        // Find first/last visible filtered index.
        var firstVisible = -1
        var lastVisible = -1
        for (fi, _) in filteredIndices.enumerated() {
            guard fi < cardRects.count else { break }
            var rect = cardRects[fi]
            rect.origin.x -= scrollOffset
            if rect.maxX > 0 && rect.origin.x < bounds.width {
                if firstVisible == -1 { firstVisible = fi }
                lastVisible = fi
            }
        }
        if firstVisible == -1 {
            // Nothing visible yet (panel just opened, layout not done) —
            // seed with the first screenful.
            firstVisible = 0
            lastVisible = min(filteredIndices.count - 1, look * 2)
        }
        let lo = max(0, firstVisible - look)
        let hi = min(filteredIndices.count - 1, lastVisible + look)
        for fi in lo...hi {
            let globalIndex = filteredIndices[fi]
            if globalIndex < entries.count {
                ids.insert(entries[globalIndex].id)
            }
        }
        return ids
    }

    /// Kick off async loads for visible + lookahead-window entries. Cheap to
    /// call repeatedly — `requestPreviewIfNeeded` no-ops on cache hits and
    /// in-flight ids.
    private func prefetchPreviewsAroundVisible() {
        let ids = currentVisibleAndPrefetchIDs()
        guard !ids.isEmpty else { return }
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for id in ids {
            if let entry = entriesByID[id] {
                requestPreviewIfNeeded(for: entry)
            }
        }
    }

    /// Rebuild the visible cards. A new filter starts at the most recent card;
    /// a reload of the same list — after a delete, or any history write while
    /// the panel is open — keeps the selection and the scroll position.
    /// Resetting to the first card there meant a second ⌫ deleted the newest
    /// capture instead of the next one, with the list jumped back to the start.
    private func applyFilter(keepingSelectionOf selectedID: String? = nil, near position: Int? = nil) {
        filteredIndices = entries.enumerated().compactMap { (i, entry) in
            activeFilter.matches(entry) ? i : nil
        }
        let isReload = selectedID != nil || position != nil
        if !isReload {
            scrollOffset = 0
            // Default keyboard focus to the leftmost (most recent) card so the user
            // can immediately arrow/Enter without moving the mouse.
            selectedIndex = filteredIndices.isEmpty ? -1 : 0
        } else if let id = selectedID,
                  let kept = filteredIndices.firstIndex(where: { entries[$0].id == id }) {
            selectedIndex = kept
        } else {
            // The selected card went away: select what took its place.
            selectedIndex = filteredIndices.isEmpty ? -1 : min(max(position ?? 0, 0), filteredIndices.count - 1)
        }
        layoutCards()
        scrollOffset = min(scrollOffset, max(contentWidth - bounds.width, 0))
        if isReload { syncHoverWithPointer() }
        prefetchPreviewsAroundVisible()
        needsDisplay = true
    }

    /// After the cards move under a still pointer, the hovered card is the one
    /// now beneath it — and, as on a mouse move, that is the selection.
    private func syncHoverWithPointer() {
        guard let window else { hoveredIndex = -1; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredIndex = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1
        if hoveredIndex >= 0 { selectedIndex = hoveredIndex }
    }

    private func layoutCards() {
        let count = filteredIndices.count
        contentWidth = CGFloat(count) * Self.cardWidth
            + CGFloat(max(count - 1, 0)) * Self.cardGap + Self.sidePadding * 2
        cardRects = (0..<count).map { i in
            let x = Self.sidePadding + CGFloat(i) * (Self.cardWidth + Self.cardGap)
            let y = Self.topBarHeight + 8
            return NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(white: 0.10, alpha: 0.92)
        bg.setFill()
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        bgPath.fill()

        // Subtle border
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        borderPath.lineWidth = 1
        borderPath.stroke()

        drawFilterTabs()

        guard let context = NSGraphicsContext.current else { return }

        if filteredIndices.isEmpty {
            drawEmptyState()
            return
        }

        // Clip card area
        let cardClip = NSRect(x: 0, y: Self.topBarHeight,
                              width: bounds.width, height: bounds.height - Self.topBarHeight)
        context.saveGraphicsState()
        NSBezierPath(rect: cardClip).setClip()

        for (fi, globalIndex) in filteredIndices.enumerated() {
            guard fi < cardRects.count else { continue }
            var rect = cardRects[fi]
            rect.origin.x -= scrollOffset

            guard rect.maxX > 0, rect.origin.x < bounds.width else { continue }

            let entry = entries[globalIndex]
            let isHovered = (fi == hoveredIndex)
            // Hover and keyboard selection share one outline: `selectedIndex`
            // always follows the hovered card, so there's never a flicker
            // when the mouse moves over a different card than the arrow-key
            // selection.
            let isSelected = (fi == selectedIndex)
            drawCard(entry: entry, rect: rect, isHovered: isHovered, isSelected: isSelected)
        }

        drawScrollFades(in: cardClip)
        context.restoreGraphicsState()
    }

    private func localizedFilterLabel(_ filter: HistoryFilter) -> String {
        switch filter {
        case .all: return L("All")
        case .screenshots: return L("Screenshots")
        case .gifs: return L("GIFs")
        }
    }

    private func drawFilterTabs() {
        let filters = HistoryFilter.allCases
        let tabFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let tabY: CGFloat = 13
        let tabH: CGFloat = 26
        let tabPadH: CGFloat = 16
        let tabGap: CGFloat = 6

        var tabWidths: [CGFloat] = []
        for filter in filters {
            let str = localizedFilterLabel(filter) as NSString
            let w = str.size(withAttributes: [.font: tabFont]).width + tabPadH * 2
            tabWidths.append(w)
        }
        let totalW = tabWidths.reduce(0, +) + CGFloat(filters.count - 1) * tabGap
        var x = bounds.midX - totalW / 2

        filterTabRects = []
        for (i, filter) in filters.enumerated() {
            let tabRect = NSRect(x: x, y: tabY, width: tabWidths[i], height: tabH)
            filterTabRects.append(tabRect)

            let isActive = filter == activeFilter
            if isActive {
                ToolbarLayout.accentColor.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.10).setFill()
            }
            NSBezierPath(roundedRect: tabRect, xRadius: tabH / 2, yRadius: tabH / 2).fill()

            let textColor = isActive ? NSColor.white : NSColor.white.withAlphaComponent(0.55)
            let str = localizedFilterLabel(filter) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: tabFont,
                .foregroundColor: textColor,
            ]
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: tabRect.midX - size.width / 2,
                                 y: tabRect.midY - size.height / 2),
                     withAttributes: attrs)

            x += tabWidths[i] + tabGap
        }

        // Trash button (top-right)
        let trashSize: CGFloat = 22
        let trashRect = NSRect(
            x: bounds.maxX - Self.sidePadding - trashSize,
            y: tabY + (tabH - trashSize) / 2,
            width: trashSize, height: trashSize)
        trashButtonRect = trashRect
        if let trashIcon = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Clear History"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let tinted = trashIcon.copy() as! NSImage
            tinted.isTemplate = false
            tinted.lockFocus()
            NSColor.white.withAlphaComponent(0.45).set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let iconSize = tinted.size
            // Flip the icon since the view is flipped (isFlipped = true)
            NSGraphicsContext.saveGraphicsState()
            let xform = NSAffineTransform()
            xform.translateX(by: trashRect.midX, yBy: trashRect.midY)
            xform.scaleX(by: 1, yBy: -1)
            xform.translateX(by: -trashRect.midX, yBy: -trashRect.midY)
            xform.concat()
            tinted.draw(in: NSRect(
                x: trashRect.midX - iconSize.width / 2,
                y: trashRect.midY - iconSize.height / 2,
                width: iconSize.width, height: iconSize.height),
                from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawCard(entry: HistoryEntry, rect: NSRect, isHovered: Bool, isSelected: Bool) {
        // Card background — same slight lift for hover OR keyboard selection
        // so both states feel equivalent.
        let lifted = isHovered || isSelected
        let bgColor = lifted
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.white.withAlphaComponent(0.05)
        bgColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        // Accent outline for hover AND keyboard selection.
        if lifted {
            ToolbarLayout.accentColor.withAlphaComponent(0.7).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            border.lineWidth = 1.5
            border.stroke()
        }

        // Image area
        let imgPad: CGFloat = 8
        let labelH: CGFloat = 28
        let imgArea = NSRect(
            x: rect.minX + imgPad,
            y: rect.minY + imgPad,
            width: rect.width - imgPad * 2,
            height: rect.height - labelH - imgPad)

        if let img = cachedPreview(for: entry) {
            let aspect = img.size.width / max(img.size.height, 1)
            var drawRect: NSRect
            if aspect > imgArea.width / imgArea.height {
                let h = imgArea.width / aspect
                drawRect = NSRect(x: imgArea.minX, y: imgArea.midY - h / 2,
                                  width: imgArea.width, height: h)
            } else {
                let w = imgArea.height * aspect
                drawRect = NSRect(x: imgArea.midX - w / 2, y: imgArea.minY,
                                  width: w, height: imgArea.height)
            }

            let clipPath = NSBezierPath(roundedRect: drawRect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.current?.saveGraphicsState()
            clipPath.setClip()
            img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true,
                     hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            NSGraphicsContext.current?.restoreGraphicsState()

            // Dim overlay + hint on hover
            if isHovered {
                NSColor.black.withAlphaComponent(0.35).setFill()
                clipPath.fill()

                // Hint text
                let hint = L("Click to copy · Drag to app") as NSString
                let hintAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                ]
                let hintSize = hint.size(withAttributes: hintAttrs)
                hint.draw(at: NSPoint(x: drawRect.midX - hintSize.width / 2,
                                      y: drawRect.midY - hintSize.height / 2),
                          withAttributes: hintAttrs)
            }
        } else {
            // Loading placeholder
            NSColor.white.withAlphaComponent(0.03).setFill()
            NSBezierPath(roundedRect: imgArea, xRadius: 6, yRadius: 6).fill()
        }

        // Label
        let labelStr = "\(entry.pixelWidth) x \(entry.pixelHeight)  ·  \(entry.timeAgoString)" as NSString
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(lifted ? 0.85 : 0.45),
        ]
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        labelStr.draw(
            at: NSPoint(x: rect.midX - labelSize.width / 2,
                        y: rect.maxY - labelH + (labelH - labelSize.height) / 2),
            withAttributes: labelAttrs)
    }

    private func drawScrollFades(in clipRect: NSRect) {
        let fadeWidth: CGFloat = 30

        if scrollOffset > 0 {
            let fadeRect = NSRect(x: 0, y: clipRect.minY,
                                 width: fadeWidth, height: clipRect.height)
            let gradient = NSGradient(
                starting: NSColor(white: 0.10, alpha: 0.92),
                ending: NSColor(white: 0.10, alpha: 0.0))
            gradient?.draw(in: fadeRect, angle: 0)
        }

        let maxScroll = max(contentWidth - bounds.width, 0)
        if scrollOffset < maxScroll {
            let fadeRect = NSRect(x: bounds.width - fadeWidth, y: clipRect.minY,
                                 width: fadeWidth, height: clipRect.height)
            let gradient = NSGradient(
                starting: NSColor(white: 0.10, alpha: 0.0),
                ending: NSColor(white: 0.10, alpha: 0.92))
            gradient?.draw(in: fadeRect, angle: 0)
        }
    }

    private func drawEmptyState() {
        let str = L("No captures yet") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.3),
        ]
        let size = str.size(withAttributes: attrs)
        str.draw(
            at: NSPoint(x: bounds.midX - size.width / 2,
                        y: bounds.midY - size.height / 2 + Self.topBarHeight / 2),
            withAttributes: attrs)
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        let maxScroll = max(contentWidth - bounds.width, 0)
        guard maxScroll > 0 else { return }

        var delta = event.scrollingDeltaX
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            delta = event.scrollingDeltaY
        }

        if event.hasPreciseScrollingDeltas {
            scrollOffset = max(0, min(maxScroll, scrollOffset - delta))
        } else {
            scrollOffset = max(0, min(maxScroll, scrollOffset - delta * 8))
        }
        prefetchPreviewsAroundVisible()
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let newHovered = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1

        if newHovered != hoveredIndex {
            hoveredIndex = newHovered
            // Keep keyboard selection in sync with the hovered card so arrow
            // keys step from wherever the mouse last pointed. When the mouse
            // leaves all cards we keep the prior selection — otherwise arrow
            // nav would reset to -1 every time the cursor drifted off.
            if newHovered >= 0 {
                selectedIndex = newHovered
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != -1 {
            hoveredIndex = -1
            NSCursor.arrow.set()
            needsDisplay = true
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dismiss regardless of whether drop succeeded — panel is already hidden
        controller?.dismiss()
        isDragging = false
    }

    private func beginDragSession(filterIndex: Int, event: NSEvent) {
        // Both arrays are indexed below, and they're rebuilt by different
        // passes — a capture completing between mouse-down and the drag
        // threshold can leave cardRects shorter than filteredIndices.
        guard filterIndex >= 0,
              filterIndex < filteredIndices.count,
              filterIndex < cardRects.count else { return }
        let globalIndex = filteredIndices[filterIndex]
        guard entries.indices.contains(globalIndex) else { return }
        let entry = entries[globalIndex]
        let fileURL = ScreenshotHistory.shared.fileURL(for: entry) as NSURL

        // Use NSURL as the pasteboard writer — it automatically provides
        // the file URL in all standard pasteboard types that apps expect
        // (kPasteboardTypeFileURLPromise, NSFilenamesPboardType, public.file-url, etc.)
        let dragItem = NSDraggingItem(pasteboardWriter: fileURL)

        // Use the preview as the drag image
        var cardRect = cardRects[filterIndex]
        cardRect.origin.x -= scrollOffset
        if let preview = previews[entry.id] {
            dragItem.setDraggingFrame(cardRect, contents: preview)
        }

        // Hide the panel and backdrop so the drag can reach the target app
        // (our windows are above everything and would block drop targets otherwise)
        controller?.hideForDrag()

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    // MARK: - Click / Drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isDragging = false

        // Filter tabs — immediate action, no drag
        for (i, tabRect) in filterTabRects.enumerated() {
            if tabRect.contains(point) {
                let filters = HistoryFilter.allCases
                if i < filters.count {
                    activeFilter = filters[i]
                    hoveredIndex = -1
                    applyFilter()
                }
                mouseDownCardIndex = -1
                return
            }
        }

        // Trash button — clear all history with confirmation
        if trashButtonRect.insetBy(dx: -4, dy: -4).contains(point) {
            controller?.confirmClearHistory()
            mouseDownCardIndex = -1
            return
        }

        // Record for click/drag detection
        mouseDownPoint = point
        mouseDownCardIndex = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1

        // If clicked outside any card, dismiss immediately
        if mouseDownCardIndex < 0 {
            controller?.dismiss()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownCardIndex >= 0, !isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        if sqrt(dx * dx + dy * dy) >= Self.dragThreshold {
            isDragging = true
            beginDragSession(filterIndex: mouseDownCardIndex, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownCardIndex = -1 }
        guard !isDragging, mouseDownCardIndex >= 0,
              mouseDownCardIndex < filteredIndices.count else { return }

        // Click — copy to clipboard
        let globalIndex = filteredIndices[mouseDownCardIndex]
        controller?.copyAndDismiss(index: globalIndex)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let clickedCard = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1

        guard clickedCard >= 0, clickedCard < filteredIndices.count else { return }
        let globalIndex = filteredIndices[clickedCard]
        controller?.showContextMenu(for: globalIndex, at: point, in: self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) {
            activateSelectedForCopy()
            return
        }
        if KeyboardShortcutMatcher.matches(event, character: "s", modifiers: .command) {
            activateSelectedForSave()
            return
        }
        if KeyboardShortcutMatcher.matches(event, character: "e", modifiers: .command) {
            activateSelectedForOpenEditor()
            return
        }

        let cmd = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case 53: // ESC
            controller?.dismiss()
        case 123: // Left arrow
            moveSelection(by: -1)
        case 124: // Right arrow
            moveSelection(by: +1)
        case 36, 76: // Return / Enter
            activateSelectedForCopy()
        case 49 where !cmd: // Space
            activateSelectedForQuickLook()
        case 51, 117: // Delete / Forward-Delete
            activateSelectedForDelete()
        default:
            super.keyDown(with: event)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredIndices.isEmpty else { return }
        // If no selection yet, start at the leftmost (when moving right) or
        // the rightmost (when moving left).
        let current = selectedIndex
        let next: Int
        if current < 0 {
            next = delta > 0 ? 0 : filteredIndices.count - 1
        } else {
            next = max(0, min(filteredIndices.count - 1, current + delta))
        }
        guard next != current else { return }
        selectedIndex = next
        scrollSelectedCardIntoView()
        prefetchPreviewsAroundVisible()
        needsDisplay = true
    }

    /// Scrolls the card strip so the selected card is fully visible, with a
    /// small leading/trailing margin so it doesn't hug the fade edges.
    private func scrollSelectedCardIntoView() {
        guard selectedIndex >= 0, selectedIndex < cardRects.count else { return }
        let cardRect = cardRects[selectedIndex]
        let margin: CGFloat = 24
        let visibleMinX = scrollOffset + margin
        let visibleMaxX = scrollOffset + bounds.width - margin
        let maxScroll = max(contentWidth - bounds.width, 0)
        if cardRect.minX < visibleMinX {
            scrollOffset = max(0, cardRect.minX - margin)
        } else if cardRect.maxX > visibleMaxX {
            scrollOffset = min(maxScroll, cardRect.maxX - bounds.width + margin)
        }
    }

    private func globalIndexForSelected() -> Int? {
        guard selectedIndex >= 0, selectedIndex < filteredIndices.count else { return nil }
        return filteredIndices[selectedIndex]
    }

    private func activateSelectedForCopy() {
        guard let idx = globalIndexForSelected() else { return }
        controller?.copyAndDismiss(index: idx)
    }

    private func activateSelectedForOpenEditor() {
        guard let idx = globalIndexForSelected() else { return }
        controller?.openInEditor(index: idx)
    }

    private func activateSelectedForSave() {
        guard let idx = globalIndexForSelected() else { return }
        controller?.saveToFile(index: idx)
    }

    private func activateSelectedForQuickLook() {
        guard let idx = globalIndexForSelected() else { return }
        controller?.quickLook(index: idx)
    }

    private func activateSelectedForDelete() {
        guard let idx = globalIndexForSelected() else { return }
        // loadEntries (called from deleteEntry) moves the selection to the
        // card that takes this one's place, so repeated ⌫ works along the row.
        controller?.deleteEntry(index: idx)
    }
}
