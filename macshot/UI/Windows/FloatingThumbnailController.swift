import Cocoa
import QuickLookUI

enum ImageContextTransform: Int {
    case rotateLeft
    case rotateRight
    case flipHorizontal
    case flipVertical

    var title: String {
        switch self {
        case .rotateLeft: return L("Rotate Left")
        case .rotateRight: return L("Rotate Right")
        case .flipHorizontal: return L("Flip Horizontal")
        case .flipVertical: return L("Flip Vertical")
        }
    }

    var symbolName: String {
        switch self {
        case .rotateLeft: return "rotate.left"
        case .rotateRight: return "rotate.right"
        case .flipHorizontal: return "flip.horizontal"
        case .flipVertical: return "flip.vertical"
        }
    }
}

extension NSImage {
    func macshotTransformed(_ transform: ImageContextTransform) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let sourceSize = size
        let outputSize: NSSize
        switch transform {
        case .rotateLeft, .rotateRight:
            outputSize = NSSize(width: sourceSize.height, height: sourceSize.width)
        case .flipHorizontal, .flipVertical:
            outputSize = sourceSize
        }

        return NSImage(size: outputSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high

            switch transform {
            case .rotateLeft:
                context.translateBy(x: sourceSize.height, y: 0)
                context.rotate(by: .pi / 2)
            case .rotateRight:
                context.translateBy(x: 0, y: sourceSize.width)
                context.rotate(by: -.pi / 2)
            case .flipHorizontal:
                context.translateBy(x: sourceSize.width, y: 0)
                context.scaleBy(x: -1, y: 1)
            case .flipVertical:
                context.translateBy(x: 0, y: sourceSize.height)
                context.scaleBy(x: 1, y: -1)
            }

            self.draw(
                in: NSRect(origin: .zero, size: sourceSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            return true
        }
    }
}

enum ImageContextMenu {
    static func item(
        title: String,
        symbolName: String?,
        action: Selector?,
        target: AnyObject?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            item.image = image
        }
        return item
    }

    static func addTransformItems(
        to menu: NSMenu,
        target: AnyObject,
        action: Selector,
        representedObject: Any? = nil
    ) {
        for transform in [ImageContextTransform.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical] {
            let item = item(
                title: transform.title,
                symbolName: transform.symbolName,
                action: action,
                target: target
            )
            item.tag = transform.rawValue
            item.representedObject = representedObject
            menu.addItem(item)
        }
    }

    static func openWithItem(fileURL: URL, target: AnyObject, action: Selector) -> NSMenuItem {
        let root = item(title: L("Open With"), symbolName: "arrow.up.right.square", action: nil, target: nil)
        let submenu = NSMenu()
        let appURLs = orderedApplicationURLs(for: fileURL)
        if appURLs.isEmpty {
            let empty = NSMenuItem(title: L("No Apps Available"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for appURL in appURLs {
                let appItem = NSMenuItem(title: applicationDisplayName(for: appURL), action: action, keyEquivalent: "")
                appItem.target = target
                appItem.representedObject = appURL
                appItem.image = NSWorkspace.shared.icon(forFile: appURL.path)
                appItem.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(appItem)
            }
        }
        root.submenu = submenu
        return root
    }

    static func shareItem(fileURL: URL, target: AnyObject, action: Selector) -> NSMenuItem {
        let root = item(title: L("Share"), symbolName: "square.and.arrow.up", action: nil, target: nil)
        let submenu = NSMenu()
        let services = NSSharingService.sharingServices(forItems: [fileURL])
        if services.isEmpty {
            let empty = NSMenuItem(title: L("No Share Services"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for service in services {
                let serviceItem = NSMenuItem(title: service.title, action: action, keyEquivalent: "")
                serviceItem.target = target
                serviceItem.representedObject = service
                serviceItem.image = service.image
                serviceItem.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(serviceItem)
            }
        }
        root.submenu = submenu
        return root
    }

    private static func orderedApplicationURLs(for fileURL: URL) -> [URL] {
        var result: [URL] = []
        if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL) {
            result.append(defaultApp)
        }
        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: fileURL) {
            if !result.contains(appURL) {
                result.append(appURL)
            }
        }
        return result
    }

    private static func applicationDisplayName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}

enum FloatingThumbnailCorner: String, CaseIterable {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    var isLeft: Bool {
        self == .bottomLeft || self == .topLeft
    }

    var isTop: Bool {
        self == .topLeft || self == .topRight
    }
}

/// The card's placement preferences, read and written in one place.
///
/// The corner is stored as the case's raw value and stacking as a Bool
/// (true = keep every card). The SwiftUI settings rebuild wrote both as the
/// picker's Int tag instead, which the card never understood: the corner fell
/// back to bottom right and stacking came out inverted. Those Int values are
/// still read here — an Int is told apart from a stored Bool by its CF type —
/// so nobody who changed the setting in the meantime loses the choice.
enum ThumbnailPlacementPreferences {
    static let cornerKey = "thumbnailCorner"
    static let stackingKey = "thumbnailStacking"

    static func corner(defaults: UserDefaults = .standard) -> FloatingThumbnailCorner {
        let stored = defaults.object(forKey: cornerKey)
        if let raw = stored as? String, let corner = FloatingThumbnailCorner(rawValue: raw) {
            return corner
        }
        if let number = stored as? NSNumber, !isBoolean(number),
           FloatingThumbnailCorner.allCases.indices.contains(number.intValue) {
            return FloatingThumbnailCorner.allCases[number.intValue]
        }
        return .bottomRight
    }

    static func setCorner(_ corner: FloatingThumbnailCorner, defaults: UserDefaults = .standard) {
        defaults.set(corner.rawValue, forKey: cornerKey)
    }

    /// True when every card is kept; false when a new card replaces the rest.
    static func stacks(defaults: UserDefaults = .standard) -> Bool {
        guard let number = defaults.object(forKey: stackingKey) as? NSNumber else { return true }
        // Rebuilt settings stored the picker tag: 0 = stack, 1 = replace.
        return isBoolean(number) ? number.boolValue : number.intValue == 0
    }

    static func setStacks(_ stacks: Bool, defaults: UserDefaults = .standard) {
        defaults.set(stacks, forKey: stackingKey)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

private enum ThumbnailDismissGesture {
    case mouseDrag
    case scroll
}

@MainActor
class FloatingThumbnailController: NSObject, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    private var window: NSPanel?
    private var dismissTask: DispatchWorkItem?
    private(set) var image: NSImage
    private var thumbnailView: ThumbnailView?
    private var corner: FloatingThumbnailCorner = .bottomRight
    /// History entry ID — used to match and update the thumbnail when the editor saves.
    var historyEntryID: String?
    /// Editable raw image + annotations for opening the thumbnail back in the editor.
    var annotationData: CaptureAnnotationData?
    /// The intended final frame — used instead of window.frame to avoid reading
    /// intermediate positions during slide-in or reflow animations.
    private var targetFrame: NSRect = .zero
    private var dismissDragStartFrame: NSRect?
    private var isInteractiveDismissActive = false
    private var isScrollDismissHostActive = false
    private var quickLookURL: URL?
    private var quickLookCloseObserver: NSObjectProtocol?
    var onDismiss: (() -> Void)?

    // Action callbacks
    var onCopy:     (() -> Void)?
    var onSave:     (() -> Void)?
    var onSaveAs:   (() -> Void)?
    var onPin:      (() -> Void)?
    var onEdit:     (() -> Void)?
    #if !OFFLINE
    var onUpload:   (() -> Void)?
    #endif
    var onDelete:   (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onSaveAll:  (() -> Void)?
    var onTransform: ((NSImage) -> Void)?
    var onOCR: (() -> Void)?

    /// Set when the card stands for a recording rather than a still: the shot
    /// is the poster frame, so the card carries a play badge, Quick Look
    /// previews the movie itself, and the actions operate on the file.
    private(set) var videoURL: URL?

    init(image: NSImage) {
        self.image = image
        super.init()
    }

    convenience init(videoURL: URL, poster: NSImage) {
        self.init(image: poster)
        self.videoURL = videoURL
    }

    /// Card size for a capture, following the capture's own aspect ratio.
    ///
    /// A fixed 240×160 card meant every shot that was not 3:2 sat inside it with
    /// a margin of card showing, which reads as a frame around the image. Sizing
    /// the card to the shot lets the shot fill it edge to edge.
    ///
    /// The short edge is floored so the hover controls still fit: two pills plus
    /// their gap need ~130pt, and the corner discs need room beside them.
    /// Transparent margin around the card, so the drop shadow has somewhere to
    /// land. The window's own `hasShadow` is off: it is computed from the
    /// window's opaque region, which for a translucent rounded card produced a
    /// bright seam along the edge instead of a shadow under it.
    static let shadowMargin: CGFloat = 22

    /// Window size for a capture: the card plus the shadow margin.
    static func windowSize(for image: NSImage) -> NSSize {
        let card = thumbnailSize(for: image)
        return NSSize(width: card.width + shadowMargin * 2,
                      height: card.height + shadowMargin * 2)
    }

    static func thumbnailSize(for image: NSImage) -> NSSize {
        let scale = CGFloat(UserDefaults.standard.object(forKey: "thumbnailScale") as? Double ?? 1.0)
        // Long edge stays at upstream's 240 — Settings › "preview size" is the
        // knob for this, and shrinking the base too would compound with it.
        let maxEdge = round(240 * scale)
        // Floor is what the hover controls need: two pills plus their gap, with
        // room for the corner discs beside them.
        let minEdge = round(126 * scale)
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return NSSize(width: maxEdge, height: round(160 * scale)) }

        var size = w >= h
            ? NSSize(width: maxEdge, height: round(maxEdge * h / w))
            : NSSize(width: round(maxEdge * w / h), height: maxEdge)
        // Panoramic or very tall shots would otherwise produce a card too thin to
        // hold the controls; those fall back to a clamped card and a filled crop.
        size.width = max(size.width, minEdge)
        size.height = max(size.height, minEdge)
        return size
    }

    // MARK: - Show

    func show(at origin: NSPoint, corner: FloatingThumbnailCorner) {
        self.corner = corner
        guard let screen = NSScreen.preferred else { return }
        let screenFrame = screen.visibleFrame

        // Fit image within max bounds preserving aspect ratio, then enforce
        // a minimum window size so hover buttons always fit (letterbox if needed).
        let padding: CGFloat = 16
        guard image.size.width > 0 && image.size.height > 0 else { return }

        // Fixed thumbnail size scaled by user preference (default 1.0 = 240x160)
        let thumbSize = Self.windowSize(for: image)

        // Clamp so the thumbnail always fits within the visible screen.
        let clampedX = min(origin.x, screenFrame.maxX - thumbSize.width - padding)
        let finalX = max(screenFrame.minX + padding, clampedX)
        let clampedY = min(origin.y, screenFrame.maxY - thumbSize.height - padding)
        let finalY   = max(screenFrame.minY + padding, clampedY)

        let startX = corner.isLeft ? screenFrame.minX - thumbSize.width - 10 : screenFrame.maxX + 10

        let panel = NSPanel(
            contentRect: NSRect(x: startX, y: finalY, width: thumbSize.width, height: thumbSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // drawn in the view so it follows the card's corners
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.acceptsMouseMovedEvents = true

        let view = ThumbnailView(image: image, thumbSize: thumbSize)
        view.frame = NSRect(origin: .zero, size: thumbSize)
        view.autoresizingMask = [.width, .height]
        view.dismissesTowardLeft = corner.isLeft

        view.onDragStarted = { [weak self] event in self?.startDrag(event: event) }
        view.onDismissDragStarted = { [weak self] kind in self?.beginDismissDrag(kind: kind) }
        view.onDismissDragChanged = { [weak self] offset in self?.updateDismissDrag(offset: offset) }
        view.onDismissDragEnded = { [weak self] offset in self?.endDismissDrag(offset: offset) }
        view.onDismissDragCancelled = { [weak self] in self?.cancelDismissDrag() }
        view.onContextMenu = { [weak self] event, view in self?.showContextMenu(event: event, in: view) }
        view.onClose    = { [weak self] in self?.dismiss() }
        // Handing the capture to another app ends this card's job, same as
        // uploading or saving does.
        view.onQuickLook = { [weak self] in self?.openInDefaultApp(); self?.dismiss() }
        view.onSave     = { [weak self] in self?.onSave?();     self?.dismiss() }
        view.onPin      = { [weak self] in self?.onPin?();      self?.dismiss() }
        view.onEdit     = { [weak self] in self?.onEdit?();     self?.dismiss() }
        #if !OFFLINE
        view.onUpload   = { [weak self] in self?.onUpload?();   self?.dismiss() }
        #endif
        view.onDelete   = { [weak self] in self?.onDelete?();   self?.dismiss() }
        view.onCloseAll = { [weak self] in self?.onCloseAll?() }
        view.onSaveAll  = { [weak self] in self?.onSaveAll?() }
        view.onHoverEnter = { [weak self] in self?.pauseAutoDismiss() }
        view.onHoverExit  = { [weak self] in self?.scheduleAutoDismiss() }

        panel.contentView = view
        self.window = panel
        self.thumbnailView = view

        let finalFrame = NSRect(x: finalX, y: finalY, width: thumbSize.width, height: thumbSize.height)
        targetFrame = finalFrame

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
        })

        scheduleAutoDismiss()
    }

    private func pauseAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        let seconds = UserDefaults.standard.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        guard seconds > 0 else { return }
        let task = DispatchWorkItem { [weak self] in self?.animateOut() }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds), execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        quickLookCloseObserver.map(NotificationCenter.default.removeObserver)
        quickLookCloseObserver = nil
        isInteractiveDismissActive = false
        isScrollDismissHostActive = false
        dismissDragStartFrame = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        thumbnailView = nil
        onDismiss?()
        onDismiss = nil
    }

    var windowFrame: NSRect { targetFrame }

    /// The CGWindowID of the thumbnail panel, used for ScreenCaptureKit exclusion.
    var windowNumber: CGWindowID? {
        guard let w = window else { return nil }
        return CGWindowID(w.windowNumber)
    }

    func hideWindow() { window?.orderOut(nil) }
    func showWindow() { window?.orderFront(nil) }

    /// Update the displayed image (e.g. after editor saves new annotations).
    func updateImage(_ newImage: NSImage, annotationData: CaptureAnnotationData? = nil) {
        image = newImage
        self.annotationData = annotationData
        thumbnailView?.updateImage(newImage)
    }

    private func makeCurrentImageFileURL() -> URL? {
        guard let encodedData = ImageEncoder.encode(image) else { return nil }
        let url = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        do {
            try encodedData.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func showContextMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()

        let copyItem = ImageContextMenu.item(title: L("Copy"), symbolName: "doc.on.doc", action: #selector(contextCopy), target: self, keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        menu.addItem(copyItem)

        menu.addItem(ImageContextMenu.item(title: L("Save"), symbolName: "square.and.arrow.down", action: #selector(contextSave), target: self))
        menu.addItem(ImageContextMenu.item(title: L("Save As..."), symbolName: "square.and.arrow.down.on.square", action: #selector(contextSaveAs), target: self))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(ImageContextMenu.item(title: L("Open in Editor"), symbolName: "pencil", action: #selector(contextOpenEditor), target: self, keyEquivalent: "e"))
        menu.addItem(ImageContextMenu.item(title: L("Pin to Screen"), symbolName: "pin.fill", action: #selector(contextPin), target: self))
        #if !OFFLINE
        menu.addItem(ImageContextMenu.item(title: L("Upload"), symbolName: "icloud.and.arrow.up", action: #selector(contextUpload), target: self))
        #endif
        let quickLookItem = ImageContextMenu.item(title: L("Quick Look"), symbolName: "eye", action: #selector(contextQuickLook), target: self, keyEquivalent: " ")
        quickLookItem.keyEquivalentModifierMask = []
        menu.addItem(quickLookItem)
        menu.addItem(ImageContextMenu.item(title: L("Run OCR & QR"), symbolName: "text.viewfinder", action: #selector(contextOCR), target: self))

        menu.addItem(NSMenuItem.separator())
        ImageContextMenu.addTransformItems(to: menu, target: self, action: #selector(contextTransform(_:)))

        if let fileURL = makeCurrentImageFileURL() {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(ImageContextMenu.openWithItem(fileURL: fileURL, target: self, action: #selector(contextOpenWith(_:))))
            menu.addItem(ImageContextMenu.shareItem(fileURL: fileURL, target: self, action: #selector(contextShare(_:))))
        }

        menu.addItem(NSMenuItem.separator())
        let deleteItem = ImageContextMenu.item(title: L("Delete"), symbolName: "trash", action: #selector(contextDelete), target: self, keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(ImageContextMenu.item(title: L("Close All"), symbolName: "xmark.circle", action: #selector(contextCloseAll), target: self))
        menu.addItem(ImageContextMenu.item(title: L("Save All to Folder…"), symbolName: "folder", action: #selector(contextSaveAll), target: self))

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func contextCopy() { onCopy?(); dismiss() }
    @objc private func contextSave() { onSave?(); dismiss() }
    @objc private func contextSaveAs() { onSaveAs?(); dismiss() }
    @objc private func contextPin() { onPin?(); dismiss() }
    #if !OFFLINE
    @objc private func contextUpload() { onUpload?(); dismiss() }
    #endif
    @objc private func contextOpenEditor() { onEdit?(); dismiss() }
    @objc private func contextDelete() { onDelete?(); dismiss() }
    @objc private func contextCloseAll() { onCloseAll?() }
    @objc private func contextSaveAll() { onSaveAll?() }
    @objc private func contextOCR() { onOCR?() }

    @objc private func contextTransform(_ sender: NSMenuItem) {
        guard let transform = ImageContextTransform(rawValue: sender.tag),
              let transformed = image.macshotTransformed(transform) else { return }
        updateImage(transformed)
        onTransform?(transformed)
    }

    @objc private func contextQuickLook() { showQuickLook() }

    /// Hand the capture to whatever app owns its type — Preview for a
    /// screenshot, the default player for a recording. This is what the card's
    /// corner button does; Quick Look is still on the context menu for a
    /// glance that does not leave the desktop.
    ///
    /// The file is the same scratch copy Quick Look used. It survives until
    /// the next launch, which sweeps that folder — long enough for the app
    /// that opened it.
    private func openInDefaultApp() {
        guard let url = videoURL ?? makeCurrentImageFileURL() else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open the capture in Quick Look, holding the thumbnail's auto-dismiss for
    /// as long as the preview is up — otherwise the thumbnail (and with it this
    /// controller, which is the panel's data source) can disappear mid-preview.
    private func showQuickLook() {
        // A recording previews from its own file — Quick Look plays it.
        quickLookURL = videoURL ?? makeCurrentImageFileURL()
        guard quickLookURL != nil, let panel = QLPreviewPanel.shared() else { return }
        pauseAutoDismiss()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)

        quickLookCloseObserver.map(NotificationCenter.default.removeObserver)
        quickLookCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.quickLookCloseObserver.map(NotificationCenter.default.removeObserver)
                self.quickLookCloseObserver = nil
                self.scheduleAutoDismiss()
            }
        }
    }

    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let fileURL = makeCurrentImageFileURL() else { return }
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func contextShare(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService,
              let fileURL = makeCurrentImageFileURL() else { return }
        service.perform(withItems: [fileURL])
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURL as NSURL?
    }

    /// Animate this thumbnail to a new Y position (used when a lower thumbnail is dismissed).
    func moveTo(origin: NSPoint) {
        guard let window = window else { return }
        guard !isInteractiveDismissActive else { return }
        guard targetFrame.origin != origin else { return }
        let newFrame = NSRect(x: origin.x, y: origin.y, width: targetFrame.width, height: targetFrame.height)
        targetFrame = newFrame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }

    private func animateOut() {
        guard let window = window else { return }
        isInteractiveDismissActive = true
        if isScrollDismissHostActive {
            animateScrollDismissHostOut()
            return
        }

        let frame = window.frame
        let offscreenX = offscreenX(for: frame)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(x: offscreenX, y: frame.minY, width: frame.width, height: frame.height),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.dismiss()
            }
        })
    }

    private var dismissDirection: CGFloat {
        corner.isLeft ? -1 : 1
    }

    private func visibleScreenFrame(for frame: NSRect) -> NSRect {
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) || $0.frame.intersects(frame) }) {
            return screen.visibleFrame
        }
        return NSScreen.preferredVisibleFrame
    }

    private func offscreenX(for frame: NSRect) -> CGFloat {
        let screenFrame = visibleScreenFrame(for: frame)
        return corner.isLeft ? screenFrame.minX - frame.width - 10 : screenFrame.maxX + 10
    }

    private func dismissCompletionThreshold(for frame: NSRect) -> CGFloat {
        min(max(frame.width * 0.05, 8), 16)
    }

    private func dismissProgressDistance(for frame: NSRect) -> CGFloat {
        dismissCompletionThreshold(for: frame) * 1.4
    }

    private func beginDismissDrag(kind: ThumbnailDismissGesture) {
        guard let window = window else { return }
        dismissTask?.cancel()
        dismissTask = nil
        isInteractiveDismissActive = true

        if dismissDragStartFrame == nil {
            let currentFrame = window.frame
            dismissDragStartFrame = currentFrame
            window.setFrame(currentFrame, display: true, animate: false)
        }

        if kind == .scroll {
            prepareScrollDismissHost()
        }
    }

    private func updateDismissDrag(offset: CGFloat) {
        guard let window = window else { return }
        if dismissDragStartFrame == nil {
            beginDismissDrag(kind: .mouseDrag)
        }
        let startFrame = dismissDragStartFrame ?? window.frame
        let clampedOffset = max(0, offset)
        let progress = min(1, clampedOffset / dismissProgressDistance(for: startFrame))

        if isScrollDismissHostActive {
            thumbnailView?.dismissContentOffsetX = clampedOffset * dismissDirection
            window.alphaValue = 1 - progress * 0.45
            return
        }

        let frame = NSRect(
            x: startFrame.minX + clampedOffset * dismissDirection,
            y: startFrame.minY,
            width: startFrame.width,
            height: startFrame.height
        )
        window.setFrame(frame, display: true)
        window.alphaValue = 1 - progress * 0.45
    }

    private func endDismissDrag(offset: CGFloat) {
        let startFrame = dismissDragStartFrame ?? targetFrame
        if offset >= dismissCompletionThreshold(for: startFrame) {
            dismissDragStartFrame = nil
            animateOut()
        } else {
            cancelDismissDrag()
        }
    }

    private func cancelDismissDrag() {
        guard let window = window else { return }
        let restoreFrame = dismissDragStartFrame ?? targetFrame
        let wasScrollDismissHostActive = isScrollDismissHostActive
        dismissDragStartFrame = nil
        isInteractiveDismissActive = false
        isScrollDismissHostActive = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if wasScrollDismissHostActive {
                thumbnailView?.animator().dismissContentOffsetX = 0
            } else {
                window.animator().setFrame(restoreFrame, display: true)
            }
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Task { @MainActor [self] in
                if wasScrollDismissHostActive, let window = self.window {
                    window.setFrame(self.targetFrame, display: true, animate: false)
                    self.thumbnailView?.resetDismissContentPosition()
                }
            }
        })
    }

    private func prepareScrollDismissHost() {
        guard let window = window, !isScrollDismissHostActive else { return }
        let startFrame = dismissDragStartFrame ?? window.frame
        let offscreenX = offscreenX(for: startFrame)
        let hostX = min(startFrame.minX, offscreenX)
        let hostMaxX = max(startFrame.maxX, offscreenX + startFrame.width)
        let hostFrame = NSRect(
            x: hostX,
            y: startFrame.minY,
            width: hostMaxX - hostX,
            height: startFrame.height
        )

        isScrollDismissHostActive = true
        window.setFrame(hostFrame, display: true, animate: false)
        thumbnailView?.dismissContentBaseX = startFrame.minX - hostFrame.minX
        thumbnailView?.dismissContentOffsetX = 0
    }

    private func animateScrollDismissHostOut() {
        guard let window = window else { return }
        let startFrame = dismissDragStartFrame ?? targetFrame
        let finalOffset = offscreenX(for: startFrame) - startFrame.minX

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            thumbnailView?.animator().dismissContentOffsetX = finalOffset
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.dismiss()
            }
        })
    }

    // MARK: - Drag as file

    private func startDrag(event: NSEvent) {
        guard let view = thumbnailView else { return }
        guard let encodedData = ImageEncoder.encode(image) else { return }

        let tempURL = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        do { try encodedData.write(to: tempURL) } catch { return }

        let draggingItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        draggingItem.setDraggingFrame(view.bounds, contents: image)
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
        dismissTask?.cancel()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dismiss() }
}

// MARK: - Thumbnail View

private class ThumbnailView: NSView {

    /// Hover-chrome palette, sampled from CleanShot X's thumbnail card. Every
    /// control on the card — the four corner discs and the two centre pills —
    /// shares one treatment: a light opaque fill carrying a dark glyph. Opaque
    /// rather than translucent-white so the buttons read the same over a bright
    /// shot as over a dark one instead of drifting with whatever is behind them.
    /// Control surface for the pre-Liquid-Glass fallback. Fixed, not semantic:
    /// these sit on the hover plate, which is mid grey to dark in either system
    /// theme, so the light-surface/dark-glyph pairing holds both ways.
    ///
    /// Near-white rather than light grey: at 0.847 the discs read as grey
    /// furniture against the plate instead of as buttons. The hover step stops
    /// short of pure white so there is still somewhere brighter to go.
    fileprivate static let buttonFill = NSColor(white: 0.94, alpha: 1)
    fileprivate static let buttonFillHover = NSColor(white: 0.99, alpha: 1)
    fileprivate static let buttonInk = NSColor(white: 0.16, alpha: 1)

    fileprivate var chromeHost: NSView?
    fileprivate var chromeButtons: [ChromeGlassButton] = []

    var onDragStarted: ((NSEvent) -> Void)?
    var onClose:    (() -> Void)?
    var onQuickLook: (() -> Void)?
    var onSave:     (() -> Void)?
    var onPin:      (() -> Void)?
    var onEdit:     (() -> Void)?
    #if !OFFLINE
    var onUpload:   (() -> Void)?
    #endif
    var onDelete:   (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onSaveAll:  (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?
    var onDismissDragStarted: ((ThumbnailDismissGesture) -> Void)?
    var onDismissDragChanged: ((CGFloat) -> Void)?
    var onDismissDragEnded: ((CGFloat) -> Void)?
    var onDismissDragCancelled: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    var dismissesTowardLeft: Bool = false
    @objc dynamic var dismissContentBaseX: CGFloat = 0 {
        didSet { needsDisplay = true; needsLayout = true }
    }
    @objc dynamic var dismissContentOffsetX: CGFloat = 0 {
        didSet { needsDisplay = true; needsLayout = true }
    }

    private var image: NSImage
    private let thumbSize: NSSize
    /// Show the whole capture inside the card rather than cropping it to fill. Defaults on:
    /// a cropped preview of a wide window is a meaningless strip of pixels, and the inset
    /// leaves room for the card to read as a surface the shot is sitting on.
    private let fitsImageInPreview = UserDefaults.standard.object(forKey: "thumbnailLetterbox") as? Bool ?? true
    // Note: the card surface is painted in `draw`, not by an NSVisualEffectView subview.
    // Subviews render above their superview's own drawing, so a vibrancy view here covers
    // the screenshot and the hover chrome entirely — the card comes out empty.
    private var dragStartScreenPoint: NSPoint?
    private var dragMode: DragMode = .idle
    private var dismissDragOffset: CGFloat = 0
    private var scrollDismissOffset: CGFloat = 0
    private var isScrollDismissing: Bool = false
    private var scrollGestureStartedOnButton: Bool = false
    private var scrollDismissEndTask: DispatchWorkItem?
    private var scrollDismissGlobalMonitor: Any?
    private var scrollDismissLocalMonitor: Any?
    private var isHovering: Bool = false
    private var trackingArea: NSTrackingArea?

    // Corner button hit rects (in view coords, updated in draw)
    private var closeBtnRect:  NSRect = .zero
    private var pinBtnRect:    NSRect = .zero
    private var editBtnRect:   NSRect = .zero
    #if !OFFLINE
    private var quickLookDiscRect: NSRect = .zero
    #endif
    private var uploadPillRect: NSRect = .zero
    private var saveBtnRect:   NSRect = .zero

    private var hoveredRect: NSRect = .zero

    private enum DragMode {
        case idle
        case button
        case pending
        case dismissing
        case exporting
    }

    private struct ScrollDismissSample {
        let rawDX: CGFloat
        let rawDY: CGFloat
        let didBegin: Bool
        let didEnd: Bool
        let hasGesturePhase: Bool
        let isTrackpadLike: Bool
    }

    deinit {
        removeScrollDismissMonitors()
    }

    func resetDismissContentPosition() {
        dismissContentBaseX = 0
        dismissContentOffsetX = 0
        frame = NSRect(origin: .zero, size: thumbSize)
        needsDisplay = true
    }

    fileprivate var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var controlScale: CGFloat {
        guard thumbSize.width > 0, thumbSize.height > 0 else { return 1 }
        let baseScale = min(bounds.width / 240, bounds.height / 160)
        return min(max(baseScale, 0.55), 2.0)
    }

    /// The card itself, inset from the view by the shadow margin.
    private var thumbnailDrawRect: NSRect {
        let m = FloatingThumbnailController.shadowMargin
        return NSRect(
            x: dismissContentBaseX + dismissContentOffsetX + m,
            y: m,
            width: thumbSize.width - m * 2,
            height: thumbSize.height - m * 2
        )
    }

    private func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(minimum, round(value * controlScale))
    }

    init(image: NSImage, thumbSize: NSSize) {
        self.image = image
        self.thumbSize = thumbSize
        super.init(frame: .zero)
        updateTrackingArea()
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateImage(_ newImage: NSImage) {
        image = newImage
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        syncChromeViews()
        onHoverEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoveredRect = .zero
        needsDisplay = true
        syncChromeViews()
        onHoverExit?()
    }

    override func layout() {
        super.layout()
        syncChromeViews()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var rects = [closeBtnRect, pinBtnRect, editBtnRect, uploadPillRect, saveBtnRect]
        #if !OFFLINE
        rects.insert(quickLookDiscRect, at: 3)
        #endif
        let hit = rects.first { $0.contains(p) } ?? .zero
        if hit != hoveredRect {
            hoveredRect = hit
            needsDisplay = true
            syncChromeViews()
        }
    }

    // MARK: - Drawing

    /// Card geometry. The shot sits inset on the card with its own corner radius and drop
    /// shadow, so it reads as a photo resting on a surface instead of a cropped fill.
    static let cardCornerRadius: CGFloat = 14
    /// The shot is the card, so it takes the card's corner radius and no inset.
    private var shotCornerRadius: CGFloat { Self.cardCornerRadius }
    private var shotInset: CGFloat { 0 }

    /// Rect the capture itself is drawn into, preserving aspect ratio.
    private var shotRect: NSRect {
        let content = thumbnailDrawRect.insetBy(dx: shotInset, dy: shotInset)
        guard image.size.width > 0, image.size.height > 0 else { return content }
        let scale = fitsImageInPreview
            ? min(content.width / image.size.width, content.height / image.size.height)
            : max(content.width / image.size.width, content.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        return NSRect(x: content.midX - w / 2, y: content.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = thumbnailDrawRect
        let cr = Self.cardCornerRadius

        // Drop shadow, drawn here rather than by the window: `hasShadow` derives
        // the shape from the window's opaque region, which for a rounded card
        // left a bright seam tracing the edge. Drawing it means it follows the
        // corner radius exactly.
        let path = NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDarkMode ? 0.55 : 0.22)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        // Opaque: a translucent card let the shadow show through its own fill.
        (isDarkMode ? NSColor(white: 0.16, alpha: 1) : NSColor.white).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        path.addClip()

        let shot = shotRect
        let shotPath = NSBezierPath(roundedRect: shot, xRadius: shotCornerRadius, yRadius: shotCornerRadius)

        NSGraphicsContext.saveGraphicsState()
        shotPath.addClip()
        image.draw(in: shot, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        // No outline on either the shot or the card: the drop shadow already separates the
        // capture from the card, and the card from the desktop. A rim on top of that reads
        // as a sticker cutout.

        guard isHovering else { return }

        // Hover turns the card into a near-solid plate rather than veiling the
        // shot: mid grey on a light Mac, #434343 on a dark one. Both values are
        // sampled from CleanShot, whose buttons read the same in either theme
        // because this plate — not the system background — is what they sit on.
        // The buttons themselves are real Liquid Glass views layered on top
        // (see `syncChromeViews`) — glass can only be produced by the compositor.
        (isDarkMode ? NSColor(white: 0.26, alpha: 0.94) : NSColor(white: 0.5, alpha: 0.94)).setFill()
        NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr).fill()

        let layout = chromeLayout()
        closeBtnRect = layout.discs.count > 0 ? layout.discs[0].rect : .zero
        pinBtnRect = layout.discs.count > 1 ? layout.discs[1].rect : .zero
        editBtnRect = layout.discs.count > 2 ? layout.discs[2].rect : .zero
        #if !OFFLINE
        quickLookDiscRect = layout.discs.count > 3 ? layout.discs[3].rect : .zero
        #endif
        uploadPillRect = layout.pills.count > 0 ? layout.pills[0].rect : .zero
        saveBtnRect = layout.pills.count > 1 ? layout.pills[1].rect : .zero
    }

    // MARK: - Hover chrome

    /// Geometry of the hover chrome. Computed in one place so the glass views
    /// and the hit-testing rects can never drift apart.
    fileprivate struct ChromeLayout {
        var discs: [(rect: NSRect, symbol: String)] = []
        var pills: [(rect: NSRect, title: String)] = []
        var symbolPointSize: CGFloat = 9
        var titleFont: NSFont = .systemFont(ofSize: 13, weight: .medium)
    }

    fileprivate func chromeLayout() -> ChromeLayout {
        var layout = ChromeLayout()
        let r = thumbnailDrawRect
        let pad = scaled(10, minimum: 5)
        // Floors matter more than the nominal size: on a small thumbnail the
        // control scale used to shrink these discs to 19pt with an 8pt glyph,
        // which is well past the point where the icon still says anything.
        let cornerD = scaled(24, minimum: 20)
        // ~38% of the disc. Sized against the disc rather than for maximum
        // legibility: a glyph filling most of its circle reads as a cramped icon
        // button instead of a soft control.
        layout.symbolPointSize = scaled(9, minimum: 8)

        var centres: [(NSPoint, String)] = [
            (NSPoint(x: r.minX + pad + cornerD/2, y: r.maxY - pad - cornerD/2), "xmark"),
            (NSPoint(x: r.maxX - pad - cornerD/2, y: r.maxY - pad - cornerD/2), "pin.fill"),
            // `pencil` alone is a bare diagonal stroke — at this size it reads
            // as a stray line rather than an action. `square.and.pencil` is the
            // standard macOS edit glyph and holds its shape when small.
            (NSPoint(x: r.minX + pad + cornerD/2, y: r.minY + pad + cornerD/2), "square.and.pencil"),
        ]
        #if !OFFLINE
        // Quick Look sits in the corner and upload takes a centre pill: uploading
        // is the consequential action of the two, and the pills are the ones that
        // read as primary.
        centres.append((NSPoint(x: r.maxX - pad - cornerD/2, y: r.minY + pad + cornerD/2), "eye"))
        #endif
        layout.discs = centres.map {
            (NSRect(x: $0.0.x - cornerD/2, y: $0.0.y - cornerD/2, width: cornerD, height: cornerD), $0.1)
        }

        // Proportions measured off CleanShot X's card: the pill is short and
        // stout (roughly 1.9:1) rather than a wide bar. Expressed against the
        // same 240x160 base the control scale uses.
        // Sized to the label rather than to a fixed bar: CJK titles are two
        // glyphs wide, so the old 74pt floor left them floating in a third of
        // the pill and the whole control read as bloated. Longer localisations
        // still widen it through the `max` below.
        let pillH = scaled(32, minimum: 22)
        let gap = scaled(12, minimum: 6)
        // ~30% of the pill height, matching the reference — 13pt left the label
        // nearly touching the capsule's curve.
        layout.titleFont = NSFont.systemFont(ofSize: scaled(12, minimum: 9), weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: layout.titleFont]
        // The offline build has no upload, so Quick Look keeps the primary pill
        // there rather than leaving the card with a single button.
        #if OFFLINE
        let primaryTitle = L("View")
        #else
        let primaryTitle = L("Upload")
        #endif
        let maxTitleW = max(
            (primaryTitle as NSString).size(withAttributes: attrs).width,
            (L("Save") as NSString).size(withAttributes: attrs).width
        )
        let pillW = min(r.width - pad * 2,
                        max(scaled(60, minimum: 52), ceil(maxTitleW + scaled(22, minimum: 14))))
        let totalH = pillH * 2 + gap
        let y0 = r.midY - totalH/2
        layout.pills = [
            (NSRect(x: r.midX - pillW/2, y: y0 + pillH + gap, width: pillW, height: pillH), primaryTitle),
            (NSRect(x: r.midX - pillW/2, y: y0, width: pillW, height: pillH), L("Save")),
        ]
        return layout
    }

    /// Create or update the Liquid Glass buttons that sit on top of the card.
    ///
    /// Glass is a compositor effect: it cannot be produced from `draw(_:)`, so
    /// the chrome lives in real subviews. They are parked in a host view that
    /// refuses hit testing, which keeps every click, drag and scroll landing on
    /// this view — the dismiss gestures and button dispatch below are unchanged.
    fileprivate func syncChromeViews() {
        guard isHovering, thumbnailDrawRect.width > 1 else {
            chromeHost?.isHidden = true
            return
        }
        let layout = chromeLayout()

        let host: NSView
        if let existing = chromeHost {
            host = existing
        } else {
            let created = ChromePassthroughView()
            // No pinned appearance: the scrim below follows the system theme, so
            // the glass and its `labelColor` glyphs should resolve against the
            // same theme rather than being forced dark on a light Mac.
            addSubview(created)
            chromeHost = created
            host = created
        }
        host.isHidden = false
        host.frame = bounds

        let specs: [(NSRect, CGFloat, NSImage?, String?)] =
            layout.discs.map { disc in
                let cfg = NSImage.SymbolConfiguration(pointSize: layout.symbolPointSize, weight: .semibold)
                let image = NSImage(systemSymbolName: disc.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg)
                return (disc.rect, disc.rect.height / 2, image, nil)
            }
            + layout.pills.map { ($0.rect, $0.rect.height / 2, nil, $0.title) }

        while chromeButtons.count < specs.count {
            let button = ChromeGlassButton()
            host.addSubview(button)
            chromeButtons.append(button)
        }
        while chromeButtons.count > specs.count {
            chromeButtons.removeLast().removeFromSuperview()
        }

        for (button, spec) in zip(chromeButtons, specs) {
            let (rect, radius, image, title) = spec
            button.frame = rect
            button.apply(cornerRadius: radius, image: image, title: title,
                         font: layout.titleFont, isHighlighted: rect == hoveredRect)
        }
    }

    private func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        let result = NSImage(size: img.size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            img.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        return result
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        dragStartScreenPoint = screenPoint(for: event)
        dismissDragOffset = 0
        let point = convert(event.locationInWindow, from: nil)
        dragMode = actionButtonRect(containing: point) == nil ? .pending : .button
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartScreenPoint else { return }
        let current = screenPoint(for: event)

        switch dragMode {
        case .button, .exporting:
            return
        case .dismissing:
            dismissDragOffset = max(0, (current.x - start.x) * dismissDirection)
            onDismissDragChanged?(dismissDragOffset)
            return
        case .idle, .pending:
            break
        }

        let dx = current.x - start.x
        let dy = current.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 4 else { return }

        let directionalOffset = dx * dismissDirection
        let isEdgewardDismiss = directionalOffset > 6 && abs(dx) >= max(6, abs(dy) * 0.35)
        if isEdgewardDismiss {
            dragMode = .dismissing
            dismissDragOffset = directionalOffset
            onDismissDragStarted?(.mouseDrag)
            onDismissDragChanged?(dismissDragOffset)
        } else if distance > 8 {
            dragMode = .exporting
            dragStartScreenPoint = nil
            onDragStarted?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .dismissing {
            onDismissDragEnded?(dismissDragOffset)
            resetMouseDragState()
            return
        }

        guard dragStartScreenPoint != nil else {
            resetMouseDragState()
            return
        }
        dragStartScreenPoint = nil
        let p = convert(event.locationInWindow, from: nil)
        defer { resetMouseDragState() }

        if closeBtnRect.contains(p)  { onClose?();  return }
        if pinBtnRect.contains(p)    { onPin?();    return }
        if editBtnRect.contains(p)   { onEdit?();   return }
        #if !OFFLINE
        if quickLookDiscRect.contains(p) { onQuickLook?(); return }
        #endif
        if uploadPillRect.contains(p) {
            #if OFFLINE
            onQuickLook?()
            #else
            onUpload?()
            #endif
            return
        }
        if saveBtnRect.contains(p)   { onSave?();   return }

        // Click anywhere else on the card opens it for editing, as clicking
        // the system screenshot thumbnail does. Closing has the × and the
        // swipe. The second click of a double-click is ignored so it doesn't
        // ask for the editor twice.
        if isHovering, event.clickCount <= 1 { onEdit?() }
    }

    override func scrollWheel(with event: NSEvent) {
        handleScrollDismiss(sample: Self.scrollDismissSample(from: event), isOverButton: false)
    }

    private func handleScrollDismiss(sample: ScrollDismissSample, isOverButton: Bool?) {
        guard sample.isTrackpadLike else { return }

        if sample.didBegin {
            scrollDismissOffset = 0
            isScrollDismissing = false
            scrollGestureStartedOnButton = isOverButton ?? false
            scrollDismissEndTask?.cancel()
            scrollDismissEndTask = nil
        } else if !isScrollDismissing && scrollDismissOffset == 0 && scrollDismissEndTask == nil {
            scrollGestureStartedOnButton = isOverButton ?? scrollGestureStartedOnButton
        }

        guard !scrollGestureStartedOnButton else {
            if sample.didEnd {
                scrollGestureStartedOnButton = false
            }
            return
        }
        guard isScrollDismissing || abs(sample.rawDX) > max(0.5, abs(sample.rawDY) * 0.35) else { return }

        let directionalDelta = sample.rawDX * dismissDirection
        if directionalDelta > 0 {
            if !isScrollDismissing {
                isScrollDismissing = true
                installScrollDismissMonitors()
                onDismissDragStarted?(.scroll)
            }
            scrollDismissOffset += directionalDelta
            onDismissDragChanged?(scrollDismissOffset)
            scheduleScrollDismissEnd(after: scrollDismissFallbackDelay(for: sample))
        } else if scrollDismissOffset > 0 {
            scheduleScrollDismissEnd(after: scrollDismissFallbackDelay(for: sample))
        }

        if sample.didEnd {
            scrollGestureStartedOnButton = false
            scheduleScrollDismissEnd(after: 0.04)
        }
    }

    override func swipe(with event: NSEvent) {
        let directionalDelta = event.deltaX * dismissDirection
        guard directionalDelta > 0 else { return }
        scrollDismissEndTask?.cancel()
        scrollDismissEndTask = nil
        scrollDismissOffset = 0
        isScrollDismissing = true
        scrollGestureStartedOnButton = false
        removeScrollDismissMonitors()
        onDismissDragStarted?(.scroll)
        onDismissDragChanged?(120)
        onDismissDragEnded?(120)
        isScrollDismissing = false
    }

    private var dismissDirection: CGFloat {
        dismissesTowardLeft ? -1 : 1
    }

    private func resetMouseDragState() {
        dragStartScreenPoint = nil
        dragMode = .idle
        dismissDragOffset = 0
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func actionButtonRect(containing point: NSPoint) -> NSRect? {
        var rects = [closeBtnRect, pinBtnRect, editBtnRect, uploadPillRect, saveBtnRect]
        #if !OFFLINE
        rects.insert(quickLookDiscRect, at: 3)
        #endif
        return rects.first { !$0.isEmpty && $0.contains(point) }
    }

    private static func scrollDismissSample(from event: NSEvent) -> ScrollDismissSample {
        let didEnd = event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
        let hasGesturePhase = event.phase != [] || event.momentumPhase != []
        return ScrollDismissSample(
            rawDX: event.scrollingDeltaX,
            rawDY: event.scrollingDeltaY,
            didBegin: event.phase.contains(.began),
            didEnd: didEnd,
            hasGesturePhase: hasGesturePhase,
            isTrackpadLike: hasGesturePhase || event.hasPreciseScrollingDeltas
        )
    }

    private func installScrollDismissMonitors() {
        guard scrollDismissGlobalMonitor == nil && scrollDismissLocalMonitor == nil else { return }

        scrollDismissGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let sample = Self.scrollDismissSample(from: event)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isScrollDismissing else { return }
                self.handleScrollDismiss(sample: sample, isOverButton: nil)
            }
        }

        scrollDismissLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isScrollDismissing else { return event }
            if let eventWindow = event.window, eventWindow === self.window { return event }
            self.handleScrollDismiss(sample: Self.scrollDismissSample(from: event), isOverButton: nil)
            return event
        }
    }

    private func removeScrollDismissMonitors() {
        if let monitor = scrollDismissGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            scrollDismissGlobalMonitor = nil
        }
        if let monitor = scrollDismissLocalMonitor {
            NSEvent.removeMonitor(monitor)
            scrollDismissLocalMonitor = nil
        }
    }

    private func scheduleScrollDismissEnd(after delay: TimeInterval = 0.12) {
        scrollDismissEndTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.finishScrollDismiss()
        }
        scrollDismissEndTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func scrollDismissFallbackDelay(for sample: ScrollDismissSample) -> TimeInterval {
        sample.hasGesturePhase ? 0.8 : 0.45
    }

    private func finishScrollDismiss() {
        scrollDismissEndTask?.cancel()
        scrollDismissEndTask = nil
        removeScrollDismissMonitors()
        guard scrollDismissOffset > 0 else {
            isScrollDismissing = false
            scrollGestureStartedOnButton = false
            return
        }
        let offset = scrollDismissOffset
        scrollDismissOffset = 0
        isScrollDismissing = false
        scrollGestureStartedOnButton = false
        onDismissDragEnded?(offset)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event, self)
    }
}

// MARK: - Liquid Glass chrome

/// Hosts the glass chrome without taking part in hit testing, so the thumbnail
/// view underneath keeps receiving every click, drag and scroll exactly as it
/// did when the buttons were painted in `draw(_:)`.
private final class ChromePassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One hover-chrome button.
///
/// On macOS 26+ the surface is a real `NSGlassEffectView`; the compositor gives
/// it the refraction and specular edge that no amount of hand-drawn fill can
/// reproduce. On 27 it also picks up `effectIsInteractive`, which adds the
/// system's own press response. Older systems fall back to the flat light disc
/// this used to draw.
private final class ChromeGlassButton: NSView {
    private let glyph = ChromeGlyphView()
    private var surface: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A solid surface, not `NSGlassEffectView`. These buttons sit on an
        // opaque hover plate, so there is nothing behind them worth refracting —
        // untinted glass just showed the grey plate through and read as a grey
        // slab, and tinting it only stains the same transparency. The reference
        // this is modelled on uses a flat light fill for exactly this reason.
        let fill = NSView()
        fill.wantsLayer = true
        fill.layer?.backgroundColor = ThumbnailView.buttonFill.cgColor
        fill.autoresizingMask = [.width, .height]
        glyph.autoresizingMask = [.width, .height]
        fill.addSubview(glyph)
        addSubview(fill)
        surface = fill
        glyph.ink = ThumbnailView.buttonInk
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(cornerRadius: CGFloat, image: NSImage?, title: String?,
               font: NSFont, isHighlighted: Bool) {
        surface?.frame = bounds
        glyph.frame = bounds
        surface?.layer?.cornerRadius = cornerRadius
        surface?.layer?.cornerCurve = .continuous
        surface?.layer?.backgroundColor = (isHighlighted
            ? ThumbnailView.buttonFillHover
            : ThumbnailView.buttonFill).cgColor
        glyph.image = image
        glyph.title = title
        glyph.font = font
        glyph.needsDisplay = true
    }
}

/// The content riding inside a glass button: either a symbol or a label.
private final class ChromeGlyphView: NSView {
    var image: NSImage?
    var title: String?
    var font: NSFont = .systemFont(ofSize: 13, weight: .medium)
    var ink: NSColor = .labelColor

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            // Draw at the symbol's natural size. Forcing it into a square
            // stretched every non-square glyph and thinned its strokes unevenly.
            let tintedImage = NSImage(size: image.size, flipped: false) { rect in
                self.ink.setFill()
                rect.fill()
                image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
                return true
            }
            let size = tintedImage.size
            tintedImage.draw(in: NSRect(x: (bounds.width - size.width) / 2,
                                        y: (bounds.height - size.height) / 2,
                                        width: size.width, height: size.height),
                             from: .zero, operation: .sourceOver, fraction: 1.0)
        } else if let title {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                 y: (bounds.height - size.height) / 2),
                                     withAttributes: attrs)
        }
    }
}
