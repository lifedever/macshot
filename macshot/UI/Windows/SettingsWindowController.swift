import Cocoa
import Carbon
import SwiftUI
import ServiceManagement
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Settings window that intercepts Cmd+Q to close itself instead of quitting the app.
private class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyboardShortcutMatcher.matches(event, character: "q", modifiers: .command) {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    // MARK: - Toolbar tab definitions
    private struct TabDef {
        let id: String
        let label: String
        let symbolName: String
        let legacyImageName: String  // fallback for older macOS if needed
    }
    private static var tabDefs: [TabDef] {
        var tabs: [TabDef] = [
            // Grouped by domain: how the app presents itself, then what it
            // records, then what comes out, then customisation, then About.
            TabDef(id: "general",    label: "General",    symbolName: "gearshape",             legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "appearance", label: "Appearance", symbolName: "paintpalette",          legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "capture",    label: "Capture",    symbolName: "camera.viewfinder",     legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "recording",  label: "Recording",  symbolName: "record.circle",         legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "thumbnail",  label: "Thumbnail",  symbolName: "photo.on.rectangle",    legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "output",     label: "Output",     symbolName: "square.and.arrow.down", legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "beautify",   label: "Beautify",   symbolName: "sparkles",              legacyImageName: NSImage.preferencesGeneralName),
        ]
        #if !OFFLINE
        // Uploading is a destination, so it belongs with Output / Beautify.
        tabs.append(TabDef(id: "uploads", label: "Uploads", symbolName: "icloud.and.arrow.up", legacyImageName: NSImage.preferencesGeneralName))
        #endif
        tabs.append(contentsOf: [
            TabDef(id: "tools",     label: "Tools",     symbolName: "paintbrush",  legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "shortcuts", label: "Shortcuts", symbolName: "keyboard",    legacyImageName: NSImage.preferencesGeneralName),
            TabDef(id: "about",     label: "About",     symbolName: "info.circle", legacyImageName: NSImage.preferencesGeneralName),
        ])
        return tabs
    }

    private var tabContentContainer: NSView!
    private var tabContentViews: [String: NSView] = [:]
    private var currentTabID: String = "general"


    private var hotkeyFields: [HotkeyManager.HotkeySlot: NSTextField] = [:]
    private var hotkeyButtons: [HotkeyManager.HotkeySlot: NSButton] = [:]
    private var recordingSlot: HotkeyManager.HotkeySlot?
    private var commandShortcutFields: [EditorCommandShortcutManager.Action: NSTextField] = [:]
    private var commandShortcutButtons: [EditorCommandShortcutManager.Action: NSButton] = [:]
    private var recordingCommandAction: EditorCommandShortcutManager.Action?
    private var toolShortcutFields: [ToolShortcutManager.Action: NSTextField] = [:]
    private var toolShortcutButtons: [ToolShortcutManager.Action: NSButton] = [:]
    private var showToolShortcutsInTooltipsCheckbox: NSButton!
    private var recordingToolAction: ToolShortcutManager.Action?
    private var savePathField: NSTextField!
    private var saveActionPopup: NSPopUpButton!
    private var ocrActionPopup: NSPopUpButton!
    private var copySoundCheckbox: NSButton!
    // rememberSelectionCheckbox removed — selection is always saved for "Capture Last Area"
    private var rememberToolCheckbox: NSButton!
    private var thumbnailCheckbox: NSButton!
    private var thumbnailAutoDismissStepper: NSStepper!
    private var thumbnailAutoDismissField: NSTextField!
    private var thumbnailStackingPopup: NSPopUpButton!
    private var thumbnailCornerPopup: NSPopUpButton!
    private var thumbnailLetterboxCheckbox: NSButton!
    private var historyUnlimitedCheckbox: NSButton!
    private var historyOrderByLastEditCheckbox: NSButton!
    private var thumbnailScaleLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var hideMenuBarIconCheckbox: NSButton!
    private var menuBarIconModePopup: NSPopUpButton!
    private var menuBarIconPresetPopup: NSPopUpButton!
    private var menuBarIconSymbolField: NSTextField!

    /// Curated SF Symbol quick-picks for the menu bar icon. Free text is still allowed.
    private static let menuBarIconPresetSymbols = [
        "camera.viewfinder", "camera", "camera.fill", "camera.aperture",
        "viewfinder", "crop", "crop.rotate", "scissors",
        "rectangle.dashed", "square.dashed", "photo", "record.circle",
    ]
    private var historySizeField: NSTextField!
    private var historySizeStepper: NSStepper!
    private var snapGuidesCheckbox: NSButton!
    private var snapHapticsCheckbox: NSButton!
    private var boundarySnapCheckbox: NSButton!
    private var browserElementSnapCheckbox: NSButton!
    private var captureCursorCheckbox: NSButton!
    private var doubleClickToCopyCheckbox: NSButton!
    private var hideCaptureInstructionsCheckbox: NSButton!
    private var disableSelectionShadowCheckbox: NSButton!
    private var filenameTemplateField: NSTextField!
    private var filenameTemplatePreview: NSTextField!
    private var autoUpdateCheckbox: NSButton!
    private var betaUpdateCheckbox: NSButton!
    private var accentColorWell: NSColorWell!
    private var iconColorWell: NSColorWell!
    private var bgColorWell: NSColorWell!
    private var themePresetPopup: NSPopUpButton!
    private var quickModePopup: NSPopUpButton!
    private var quickCaptureOpenEditorCheckbox: NSButton!
    private var closeEditorAfterCopyCheckbox: NSButton!
    private var imageFormatPopup: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityLabel: NSTextField!
    private var qualityRowLabel: NSTextField!
    private var downscaleRetinaCheckbox: NSButton!
    // embedColorProfileCheckbox removed — native color profile is always embedded
    private var localMonitor: Any?
    #if !OFFLINE
    private var imgbbKeyField: NSTextField!
    private weak var uploadsStack: NSStackView?
    private var providerPopup: NSPopUpButton!
    private var gdriveSignInBtn: NSButton!
    private var gdriveStatusLabel: NSTextField!
    private var gdriveFolderField: NSTextField!
    // S3 tab controls
    private var s3EndpointField: NSTextField!
    private var s3RegionField: NSTextField!
    private var s3BucketField: NSTextField!
    private var s3AccessKeyField: NSTextField!
    private var s3SecretKeyField: NSSecureTextField!
    private var s3PublicURLField: NSTextField!
    private var s3PathPrefixField: NSTextField!
    private var s3PublicReadCheckbox: NSButton!
    private var s3TestBtn: NSButton!
    private var s3StatusLabel: NSTextField!
    #endif
    // Recording tab controls
    private var recordingFPSPopup: NSPopUpButton!
    private var recordingOnStopPopup: NSPopUpButton!
    // Webcam controls
    private var webcamPositionPopup: NSPopUpButton!
    private var webcamSizeSlider: NSSlider!
    private var webcamSizeLabel: NSTextField!
    private var webcamShapePopup: NSPopUpButton!
    // Scroll capture controls
    private var scrollAutoScrollCheckbox: NSButton!
    private var scrollSpeedPopup: NSPopUpButton!
    private var scrollMaxHeightField: NSTextField!
    private var scrollMaxHeightStepper: NSStepper!
    private var scrollFrozenDetectionCheckbox: NSButton!
    /// Shared by the Capture / Thumbnail / Output panes.
    private var captureSettingsModel: CaptureSettingsModel?
    /// Shared by the General and Appearance panes.
    private var generalSettingsModel: GeneralSettingsModel?

    var onHotkeyChanged: (() -> Void)?
    var onEditorCommandShortcutChanged: (() -> Void)?

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(BuildVariant.displayName) \(L("Settings"))"
        window.center()
        window.isReleasedWhenClosed = false
        // Window is non-resizable (no .resizable in styleMask), so content size
        // is locked. We also set the content size explicitly after the toolbar
        // is installed (in setupUI) to override NSToolbar's auto-sizing.
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Top-level layout

    private func setupUI() {
        guard let window = window, let cv = window.contentView else { return }

        // Toolbar (preference style — icon + label, Shottr-like)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier("general")
        // Re-apply content size after toolbar install, since NSToolbar can
        // resize the window to fit its items.
        //
        // Width is the narrowest that still fits every toolbar item: an
        // overflowing preference toolbar collapses items into a ">>" menu,
        // hiding whole panes behind a chevron. Wider than that is worse, not
        // better — the form rows are label-left / control-right, so surplus
        // width becomes dead space down the middle of every row.
        window.setContentSize(NSSize(width: 700, height: 520))

        buildPanes()

        // Container that swaps content views
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tabContentContainer = container

        cv.addSubview(container)

        NSLayoutConstraint.activate([
            // The pane fills the window. The attribution that used to sit in a
            // footer strip lives on the About pane, which is where macOS apps
            // put it — a permanent bar under every pane is chrome the settings
            // themselves have to pay for.
            container.topAnchor.constraint(equalTo: cv.topAnchor),
            container.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        // Show initial tab
        showTab(id: "general")
    }

    private func showTab(id: String) {
        guard let container = tabContentContainer, let view = tabContentViews[id] else { return }
        // Remove existing content
        for sub in container.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        currentTabID = id
        window?.title = "\(BuildVariant.displayName) \(L("Settings")) — \(L(Self.tabDefs.first(where: { $0.id == id })?.label ?? ""))"
        sizeWindowToPane(view)
        #if !OFFLINE
        if id == "uploads" {
            reloadUploadsTab()
        }
        #endif
    }


    /// Wire a SwiftUI pane's size changes back to the window, so the window
    /// tracks content that grows or shrinks after the tab is already showing.

    /// Build every settings pane.
    ///
    /// Every pane is SwiftUI: a settings window is a form, and `Form` +
    /// `.formStyle(.grouped)` is the System Settings appearance itself rather
    /// than an AppKit imitation of it.
    private func buildPanes() {
        let capture = CaptureSettingsModel()
        captureSettingsModel = capture

        let general = GeneralSettingsModel()
        generalSettingsModel = general
        tabContentViews["general"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: GeneralSettingsView(model: general))
                .configuredAsSettingsPane())
        tabContentViews["appearance"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: AppearanceSettingsView(model: general))
                .configuredAsSettingsPane())
        tabContentViews["capture"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: CaptureSettingsView(model: capture))
                .configuredAsSettingsPane())
        tabContentViews["thumbnail"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: ThumbnailSettingsView(model: capture))
                .configuredAsSettingsPane())
        tabContentViews["output"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: OutputSettingsView(model: capture))
                .configuredAsSettingsPane())
        tabContentViews["beautify"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: BeautifySettingsView(model: capture))
                .configuredAsSettingsPane())
        tabContentViews["shortcuts"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: ShortcutSettingsView(
                onHotkeyChanged: { [weak self] in self?.onHotkeyChanged?() }
            )).configuredAsSettingsPane())
        tabContentViews["tools"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: ToolsSettingsView(captureModel: capture))
                .configuredAsSettingsPane())
        tabContentViews["recording"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: RecordingSettingsView()).configuredAsSettingsPane())
        #if !OFFLINE
        tabContentViews["uploads"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: UploadSettingsView(
                onTestS3: { [weak self] in self?.s3TestTapped(NSButton()) }
            )).configuredAsSettingsPane())
        #endif
        tabContentViews["about"] = trackingPaneSize(
            SettingsPaneHostingView(rootView: AboutSettingsView(
                onCopyDiagnostics: { [weak self] in self?.copyScreenInfo() },
                onExport: { [weak self] in self?.exportSettings() },
                onImport: { [weak self] in self?.importSettings() },
                onRevealSettingsFile: { [weak self] in self?.revealSettingsFile() }
            )).configuredAsSettingsPane())
    }

    private func trackingPaneSize(_ pane: SettingsPaneHostingView) -> NSView {
        pane.onIntrinsicContentSizeChange = { [weak self, weak pane] in
            guard let self, let pane, pane.superview != nil else { return }
            // Deferred: this fires from inside layout, and resizing the window
            // synchronously from there re-enters it.
            DispatchQueue.main.async { self.sizeWindowToPane(pane) }
        }
        return pane
    }

    /// Grow or shrink the window to the pane's natural height, the way a macOS
    /// settings window does, so no pane ever needs a scroller.
    private func sizeWindowToPane(_ pane: NSView) {
        guard let window = window, pane is NSHostingViewProtocolMarker else { return }
        window.layoutIfNeeded()
        // `intrinsicContentSize` is the form's own height (see `sizingOptions`);
        // `fittingSize` is the fallback for anything that does not report one.
        let intrinsic = pane.intrinsicContentSize.height
        let fitting = intrinsic > 1 ? intrinsic : pane.fittingSize.height
        guard fitting > 1 else { return }
        let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        // A little air under the last row: the intrinsic height stops exactly at
        // the final footnote's baseline box, which reads as clipped.
        let target = min(fitting + 14, maxHeight - 120)
        var frame = window.frame
        let current = window.contentRect(forFrameRect: frame).height
        guard abs(target - current) > 1 else { return }
        let delta = target - current
        frame.size.height += delta
        // Keep the title bar where it is rather than growing downward.
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: false)
    }

    @objc private func toolbarTabSelected(_ sender: NSToolbarItem) {
        showTab(id: sender.itemIdentifier.rawValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.tabDefs.map { NSToolbarItem.Identifier($0.id) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let def = Self.tabDefs.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L(def.label)
        item.paletteLabel = L(def.label)
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: def.symbolName, accessibilityDescription: def.label)
        } else {
            item.image = NSImage(named: def.legacyImageName)
        }
        item.target = self
        item.action = #selector(toolbarTabSelected(_:))
        return item
    }

    // MARK: - General Tab

    /// NSStackView subclass with flipped coordinates so content pins to the top
    /// of its scroll view (default AppKit origin is bottom-left, which would
    /// push short content to the bottom of a tall clip view).
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    /// Small SF Symbol icon that reports hover enter/exit via callback. Used for
    /// hover-to-show info popovers next to settings controls.
    fileprivate final class HoverPopoverIconView: NSImageView {
        /// Called with (the view, true) on hover enter and (view, false) on exit.
        var onHover: ((NSView, Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        init(image: NSImage?, tintColor: NSColor, toolTip: String?) {
            super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            self.image = image
            self.contentTintColor = tintColor
            self.toolTip = toolTip
            self.imageScaling = .scaleProportionallyDown
            self.translatesAutoresizingMaskIntoConstraints = false
            self.widthAnchor.constraint(equalToConstant: 16).isActive = true
            self.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
        override func mouseExited(with event: NSEvent)  { onHover?(self, false) }
    }

    /// Creates a scrollable vertical stack matching the layout used by all settings tabs.
    private func makeSettingsScrollStack() -> (NSScrollView, NSStackView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return (scroll, stack)
    }

    /// Finalizes a settings tab by wiring the stack into the scroll view.
    private func finalizeSettingsStack(scroll: NSScrollView, stack: NSStackView) {
        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            // no bottom constraint — stack grows to fit content, scroll handles overflow
        ])
    }

    // MARK: - Settings Backup actions

    @objc private func exportSettingsClicked(_ sender: NSButton) { exportSettings() }

    fileprivate func exportSettings() {
        guard let window = window else { return }
        let result: SettingsPortability.ExportResult
        do {
            result = try SettingsPortability.exportData()
        } catch {
            presentBackupError(error, title: L("Export failed"))
            return
        }

        let panel = NSSavePanel()
        panel.title = L("Export Settings")
        panel.nameFieldStringValue = SettingsPortability.suggestedExportFilename()
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try result.data.write(to: url)
                if !result.skippedLargeKeys.isEmpty {
                    let message: String
                    if result.skippedLargeKeys == ["beautifyCustomBgImageData"] {
                        message = L("Your custom Beautify background image was too large to include. Everything else was saved.")
                    } else {
                        message = L("A few large items were too big to include. Everything else was saved.")
                    }
                    self?.presentBackupInfo(title: L("Settings exported"), message: message)
                }
            } catch {
                self?.presentBackupError(error, title: L("Export failed"))
            }
        }
    }

    @objc private func importSettingsClicked(_ sender: NSButton) { importSettings() }

    fileprivate func importSettings() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = L("Import Settings")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.confirmAndImport(from: url)
        }
    }

    private func confirmAndImport(from url: URL) {
        guard let window = window else { return }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentBackupError(error, title: L("Import failed"))
            return
        }

        let confirm = NSAlert()
        confirm.messageText = L("Replace your current settings?")
        confirm.informativeText = L("Importing will replace your current preferences with the ones in this file. Your save folder, upload credentials, and screenshot history are kept. This cannot be undone.")
        confirm.addButton(withTitle: L("Import"))
        confirm.addButton(withTitle: L("Cancel"))
        confirm.alertStyle = .warning
        confirm.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.performImport(data)
        }
    }

    private func performImport(_ data: Data) {
        let result: SettingsPortability.ImportResult
        do {
            result = try SettingsPortability.importData(data)
        } catch {
            presentBackupError(error, title: L("Import failed"))
            return
        }

        // Re-apply the cheap live side-effects immediately; everything else takes effect on relaunch.
        (NSApp.delegate as? AppDelegate)?.reapplySettingsAfterImport()

        // Rebuild this window's controls so the visible tabs reflect the imported values.
        rebuildAllTabsAfterImport()

        let alert = NSAlert()
        alert.messageText = L("Settings imported")
        alert.informativeText = String(format: L("%d settings were applied. Relaunch macshot to apply all changes."), result.appliedCount)
        alert.addButton(withTitle: L("Relaunch Now"))
        alert.addButton(withTitle: L("Later"))
        guard let window = window else { return }
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            AppDelegate.relaunchApp()
        }
    }

    private func rebuildAllTabsAfterImport() {
        let previouslySelected = currentTabID
        tabContentViews.removeAll()
        // Each pane's model reads `UserDefaults` once, when it is constructed,
        // so an import has to rebuild the panes rather than refresh them.
        buildPanes()
        showTab(id: previouslySelected)
    }

    @objc private func revealSettingsFileClicked(_ sender: NSButton) { revealSettingsFile() }

    fileprivate func revealSettingsFile() {
        let prefsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Preferences", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sw33tlie.macshot.macshot"
        let plist = prefsDir.appendingPathComponent("\(bundleID).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            NSWorkspace.shared.activateFileViewerSelecting([plist])
        } else {
            NSWorkspace.shared.open(prefsDir)
        }
    }

    private func presentBackupError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("OK"))
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    private func presentBackupInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    // MARK: - Shortcuts Tab

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }

        // If already recording this slot, stop
        if recordingSlot == slot {
            stopShortcutRecording()
            return
        }
        // Stop any previous recording.
        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()

        recordingSlot = slot
        sender.title = L("Press keys...")
        hotkeyFields[slot]?.stringValue = L("Waiting...")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 {
                self.stopShortcutRecording()
                return nil
            }
            let modifiers = event.modifierFlags
            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)
            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) { return nil }
            HotkeyManager.saveHotkey(for: slot, keyCode: keyCode, modifiers: carbonMods)
            self.hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
            self.stopShortcutRecording()
            self.onHotkeyChanged?()
            return nil
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.disableHotkey(for: slot)
        hotkeyFields[slot]?.stringValue = L("None")
        onHotkeyChanged?()
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.saveHotkey(for: slot, keyCode: slot.defaultKeyCode, modifiers: slot.defaultModifiers)
        hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        onHotkeyChanged?()
    }

    private func stopShortcutRecording() {
        if let slot = recordingSlot {
            hotkeyButtons[slot]?.title = L("Set")
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        recordingSlot = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Editor Command Shortcuts

    @objc private func recordCommandShortcut(_ sender: NSButton) {
        let actions = EditorCommandShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        if recordingCommandAction == action {
            stopCommandShortcutRecording()
            return
        }

        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()
        recordingCommandAction = action
        sender.title = L("Press keys...")
        commandShortcutFields[action]?.stringValue = L("Waiting...")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stopCommandShortcutRecording()
                return nil
            }
            let modifiers = KeyboardShortcutMatcher.modifiers(in: event)
            // Editor commands are menu key equivalents, so require Command;
            // Shift/Option/Control may be added to distinguish the chord.
            guard modifiers.contains(.command),
                  let character = KeyboardShortcutMatcher.semanticCharacter(for: event) else {
                return nil
            }
            let shortcut = EditorCommandShortcutManager.Shortcut(
                character: character,
                modifiers: modifiers)
            EditorCommandShortcutManager.setShortcut(shortcut, for: action)
            self.stopCommandShortcutRecording()
            self.refreshShortcutDisplaysForKeyboardLayout()
            self.onEditorCommandShortcutChanged?()
            return nil
        }
    }

    @objc private func clearCommandShortcut(_ sender: NSButton) {
        let actions = EditorCommandShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        stopCommandShortcutRecording()
        EditorCommandShortcutManager.disable(action)
        commandShortcutFields[action]?.stringValue = L("None")
        onEditorCommandShortcutChanged?()
    }

    @objc private func resetCommandShortcut(_ sender: NSButton) {
        let actions = EditorCommandShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]
        stopCommandShortcutRecording()
        EditorCommandShortcutManager.reset(action)
        commandShortcutFields[action]?.stringValue = EditorCommandShortcutManager.displayString(for: action)
        onEditorCommandShortcutChanged?()
    }

    private func stopCommandShortcutRecording() {
        if let action = recordingCommandAction {
            commandShortcutFields[action]?.stringValue = EditorCommandShortcutManager.displayString(for: action)
            commandShortcutButtons[action]?.title = L("Set")
        }
        recordingCommandAction = nil
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
    }

    // MARK: - Overlay Tool Shortcuts

    @objc private func recordToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]

        // If already recording this action, stop
        if recordingToolAction == action {
            stopToolShortcutRecording()
            return
        }
        // Stop any other recording.
        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()

        recordingToolAction = action
        sender.title = L("Press...")
        toolShortcutFields[action]?.stringValue = "…"

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Only accept single keys without modifiers (or allow Escape to cancel)
            if event.keyCode == 53 { // Escape — cancel
                self.stopToolShortcutRecording()
                return nil
            }
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control),
                  let char = KeyboardShortcutMatcher.semanticCharacter(for: event) else { return nil }

            ToolShortcutManager.setKey(char, for: action)
            self.toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            self.stopToolShortcutRecording()
            return nil
        }
    }

    @objc private func clearToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey("", for: action)
        toolShortcutFields[action]?.stringValue = L("None")
    }

    @objc private func resetToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey(action.defaultKey, for: action)
        toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
    }

    @objc private func showToolShortcutsInTooltipsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showToolShortcutsInTooltips")
    }

    private func stopToolShortcutRecording() {
        if let action = recordingToolAction {
            toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            toolShortcutButtons[action]?.title = L("Set")
        }
        recordingToolAction = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Tools Tab

    // MARK: - Recording Tab

    // MARK: - Uploads Tab

    // MARK: - About Tab

    @objc private func copyScreenInfo() {
        if #available(macOS 14.0, *) {
            Task { @MainActor in
                var lines: [String] = []
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                lines.append("macshot \(version) (\(build))")
                lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                lines.append("")
                lines.append("=== NSScreen Info ===")
                for (i, screen) in NSScreen.screens.enumerated() {
                    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                    let cs = screen.colorSpace?.cgColorSpace
                    // CGDisplayCopyColorSpace reads the display ICC profile directly,
                    // bypassing NSScreen — helps diagnose DisplayLink/driver issues.
                    let cgCS = CGDisplayCopyColorSpace(id)
                    lines.append("Screen \(i): \(screen.localizedName) (ID: \(id))")
                    lines.append("  frame: \(screen.frame)")
                    lines.append("  backingScale: \(screen.backingScaleFactor)")
                    lines.append("  NSScreen.colorSpace: \(cs?.name as String? ?? "nil")")
                    lines.append("  CGDisplayCopyColorSpace: \(cgCS.name as String? ?? "nil")")
                    lines.append("  cs model: \(cs?.model.rawValue ?? -1)")
                    lines.append("")
                }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    lines.append("=== ScreenCaptureKit Capture Info ===")
                    for display in content.displays {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = display.width
                        config.height = display.height
                        config.captureResolution = .best
                        config.colorSpaceName = CGColorSpace.sRGB as CFString
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            lines.append("Display \(display.displayID) (\(display.width)x\(display.height)):")
                            lines.append("  CGImage size: \(img.width)x\(img.height)")
                            lines.append("  bitsPerComponent: \(img.bitsPerComponent)")
                            lines.append("  bitsPerPixel: \(img.bitsPerPixel)")
                            lines.append("  bytesPerRow: \(img.bytesPerRow)")
                            lines.append("  bitmapInfo: \(img.bitmapInfo.rawValue)")
                            lines.append("  alphaInfo: \(img.alphaInfo.rawValue)")
                            lines.append("  colorSpace: \(img.colorSpace?.name as String? ?? "nil")")
                            lines.append("  cs model: \(img.colorSpace?.model.rawValue ?? -1)")
                            lines.append("")
                        }
                    }
                } catch {
                    lines.append("Capture error: \(error.localizedDescription)")
                }
                let result = lines.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                // Flash the button title to confirm
                if let btn = self.window?.contentView?.viewWithTag(9999) as? NSButton {
                    btn.title = L("Copied!")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { btn.title = L("Copy Screen Info") }
                }
            }
        }
    }

    #if !OFFLINE
    private func updateGDriveStatus() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveStatusLabel?.stringValue = GoogleDriveUploader.shared.userEmail ?? L("Signed in")
            gdriveStatusLabel?.textColor = .labelColor
        } else {
            gdriveStatusLabel?.stringValue = L("Not signed in")
            gdriveStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    private func updateGDriveButton() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveSignInBtn?.title = L("Sign Out")
        } else {
            gdriveSignInBtn?.title = L("Sign In with Google")
        }
    }

    @objc private func uploadProviderChanged(_ sender: NSPopUpButton) {
        let provider: String
        switch sender.indexOfSelectedItem {
        case 1: provider = "gdrive"
        case 2: provider = "s3"
        default: provider = "imgbb"
        }
        UserDefaults.standard.set(provider, forKey: "uploadProvider")
    }

    @objc private func gdriveSignInTapped(_ sender: NSButton) {
        if GoogleDriveUploader.shared.isSignedIn {
            GoogleDriveUploader.shared.signOut()
            updateGDriveStatus()
            updateGDriveButton()
        } else {
            GoogleDriveUploader.shared.signIn(from: window) { [weak self] success in
                guard let self = self, success else {
                    self?.updateGDriveStatus()
                    self?.updateGDriveButton()
                    return
                }
                self.window?.makeKeyAndOrderFront(nil)
                self.updateGDriveButton()
                // Fetch email then update status label
                GoogleDriveUploader.shared.fetchUserEmail { [weak self] in
                    self?.updateGDriveStatus()
                }
            }
        }
    }

    @objc private func gdriveFolderChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(gdriveFolderField.stringValue, forKey: "gdriveFolderName")
    }

    @objc private func s3FieldChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(s3EndpointField.stringValue, forKey: "s3Endpoint")
        UserDefaults.standard.set(s3RegionField.stringValue, forKey: "s3Region")
        UserDefaults.standard.set(s3BucketField.stringValue, forKey: "s3Bucket")
        UserDefaults.standard.set(s3AccessKeyField.stringValue, forKey: "s3AccessKeyID")
        UserDefaults.standard.set(s3SecretKeyField.stringValue, forKey: "s3SecretAccessKey")
        UserDefaults.standard.set(s3PublicURLField.stringValue, forKey: "s3PublicURLBase")
        UserDefaults.standard.set(s3PathPrefixField.stringValue, forKey: "s3PathPrefix")
    }

    @objc private func s3PublicReadChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "s3PublicRead")
    }

    @objc private func s3TestTapped(_ sender: NSButton) {
        // Save current field values first
        s3FieldChanged(s3EndpointField)

        guard S3Uploader.shared.isConfigured else {
            s3StatusLabel.stringValue = L("Fill in endpoint, bucket, and credentials first")
            s3StatusLabel.textColor = .systemOrange
            return
        }

        s3TestBtn.isEnabled = false
        s3StatusLabel.stringValue = L("Testing...")
        s3StatusLabel.textColor = .secondaryLabelColor

        // Upload a tiny test file
        let testData = Data("macshot connection test".utf8)
        let testKey = ".macshot_test_\(UUID().uuidString.prefix(8)).txt"
        S3Uploader.shared.upload(data: testData, filename: testKey, contentType: "text/plain") { [weak self] result in
            guard let self = self else { return }
            self.s3TestBtn.isEnabled = true
            switch result {
            case .success:
                self.s3StatusLabel.stringValue = L("Connection successful!")
                self.s3StatusLabel.textColor = .systemGreen
            case .failure(let error):
                self.s3StatusLabel.stringValue = error.localizedDescription
                self.s3StatusLabel.textColor = .systemRed
            }
        }
    }

    private func reloadUploadsTab() {
        guard let stack = uploadsStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        let uploads = ((UserDefaults.standard.array(forKey: "imgbbUploads") as? [[String: String]]) ?? [])
            .reversed() as [[String: String]]

        if uploads.isEmpty {
            let lbl = NSTextField(labelWithString: L("No uploads yet."))
            lbl.font = NSFont.systemFont(ofSize: 13)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .center
            lbl.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(lbl)
        } else {
            for (i, upload) in uploads.enumerated() {
                let row = makeUploadRow(index: uploads.count - i,
                                        link: upload["link"] ?? "",
                                        deleteURL: upload["deleteURL"] ?? "")
                stack.addArrangedSubview(row)
            }
        }
    }

    private func makeUploadRow(index: Int, link: String, deleteURL: String) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        box.addSubview(inner)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        inner.addArrangedSubview(urlRow(tag: "URL", value: link, copyKey: "link::\(link)"))
        inner.addArrangedSubview(urlRow(tag: "DEL", value: deleteURL, copyKey: "link::\(deleteURL)"))

        return box
    }

    private func urlRow(tag: String, value: String, copyKey: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let tagLbl = NSTextField(labelWithString: tag)
        tagLbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        tagLbl.textColor = .secondaryLabelColor
        tagLbl.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(labelWithString: value)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = tag == "URL" ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let btn = NSButton(title: L("Copy"), target: self, action: #selector(copyUploadURL(_:)))
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 11)
        btn.identifier = NSUserInterfaceItemIdentifier(copyKey)
        btn.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(tagLbl)
        row.addSubview(field)
        row.addSubview(btn)

        NSLayoutConstraint.activate([
            tagLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tagLbl.widthAnchor.constraint(equalToConstant: 34),
            tagLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            btn.widthAnchor.constraint(equalToConstant: 52),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: tagLbl.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }
    #endif

    // MARK: - Layout helpers

    private func sectionHeader(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    /// Width of the right-aligned label column for `labeledRow`. Wide
    /// enough to fit the longest localized string in practice — Polish's
    /// "Szybkie przechwycenie:" (issue #130) used to get clipped at the
    /// old 140pt column. 180pt covers every shipping locale with a bit
    /// of headroom.
    private static let labelColumnWidth: CGFloat = 180

    /// A horizontal row: right-aligned label on the left, controls on the right.
    private func labeledRow(_ labelText: String, controls: [NSView]) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true

        let row = NSStackView(views: [lbl] + controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Indents a view to align with the control column.
    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // Label column + row spacing (8pt).
        spacer.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth + 8).isActive = true

        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Two-column grid of checkboxes in a rounded box, fills parent width.
    private func makeToggleGrid(items: [(tag: Int, label: String)],
                                 defaultsKey: String,
                                 enabledValues: [Int]?) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        // Build rows of 2 columns using horizontal stack views inside a vertical stack
        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(vStack)

        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: box.topAnchor, constant: pad),
            vStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
            vStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
            vStack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
        ])

        let cols = 2
        let rows = Int(ceil(Double(items.count) / Double(cols)))

        for row in 0..<rows {
            let hStack = NSStackView()
            hStack.orientation = .horizontal
            hStack.distribution = .fillEqually
            hStack.spacing = 0
            hStack.translatesAutoresizingMaskIntoConstraints = false
            // Row must be AT LEAST 28pt so single-line checkboxes still look
            // consistent, but can grow if a translated label wraps to two
            // lines. Without this relaxation, long locale strings get
            // horizontally clipped (issue #130).
            hStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

            for col in 0..<cols {
                let idx = row * cols + col
                if idx < items.count {
                    let item = items[idx]
                    let isEnabled = enabledValues == nil || enabledValues!.contains(item.tag)
                    let cb = NSButton(checkboxWithTitle: item.label, target: self, action: #selector(toggleItemChanged(_:)))
                    cb.state = isEnabled ? .on : .off
                    cb.tag = item.tag
                    cb.identifier = NSUserInterfaceItemIdentifier(defaultsKey)
                    cb.translatesAutoresizingMaskIntoConstraints = false
                    // Let the title wrap when it doesn't fit the column —
                    // the native NSButton checkbox truncates by default.
                    // Word-wrap is graceful; the cell takes a second line
                    // of text when needed instead of swallowing characters.
                    cb.cell?.wraps = true
                    cb.cell?.isScrollable = false
                    cb.cell?.lineBreakMode = .byWordWrapping
                    if let cell = cb.cell as? NSButtonCell {
                        cell.usesSingleLineMode = false
                    }
                    hStack.addArrangedSubview(cb)
                } else {
                    let filler = NSView()
                    filler.translatesAutoresizingMaskIntoConstraints = false
                    hStack.addArrangedSubview(filler)
                }
            }
            vStack.addArrangedSubview(hStack)
            // Stretch row to fill the vStack's width (must be after addArrangedSubview
            // so both views share a common ancestor)
            hStack.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        }

        return box
    }

    // MARK: - Load settings

    func refreshShortcutDisplaysForKeyboardLayout() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        for action in EditorCommandShortcutManager.Action.allCases {
            commandShortcutFields[action]?.stringValue = EditorCommandShortcutManager.displayString(for: action)
        }
    }

    private func updateQualityVisibility() {
        let raw = imageFormatPopup.selectedItem?.representedObject as? String
        let hasQuality = raw.flatMap(ImageEncoder.Format.init(rawValue:))?.hasQuality ?? false
        qualitySlider.isEnabled = hasQuality
        qualityLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
        qualityRowLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
    }

    private func selectImageFormat(_ format: ImageEncoder.Format) {
        for item in imageFormatPopup.itemArray {
            if item.representedObject as? String == format.rawValue {
                imageFormatPopup.select(item)
                return
            }
        }
        imageFormatPopup.selectItem(at: 0)
    }

    private func selectSaveAction(_ action: SaveActionPreference) {
        for item in saveActionPopup.itemArray {
            if item.representedObject as? Int == action.rawValue {
                saveActionPopup.select(item)
                return
            }
        }
        saveActionPopup.selectItem(at: 0)
    }

    // MARK: - Actions

    @objc private func browseSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.save(url: url)
            self?.savePathField.stringValue = url.path
        }
    }

    @objc private func ocrActionChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "ocrAction")
    }
    @objc private func saveActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? Int,
              let action = SaveActionPreference(rawValue: raw) else { return }
        SaveActionPreference.current = action
    }
    @objc private func copySoundChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "playCopySound")
    }
    @objc private func rememberToolChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "rememberLastTool")
        if !enabled {
            OverlayView.resetRememberedTool()
        }
    }
    @objc private func thumbnailChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showFloatingThumbnail")
    }
    @objc private func thumbnailAutoDismissChanged(_ sender: NSStepper) {
        thumbnailAutoDismissField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "thumbnailAutoDismiss")
    }
    @objc private func thumbnailScaleChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "thumbnailScale")
        thumbnailScaleLabel?.stringValue = scalePercentString(sender.doubleValue)
    }
    @objc private func thumbnailLetterboxChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "thumbnailLetterbox")
    }

    private func scalePercentString(_ scale: Double) -> String {
        "\(Int(round(scale * 100)))%"
    }

    @objc private func thumbnailStackingChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 0, forKey: "thumbnailStacking")
    }
    @objc private func thumbnailCornerChanged(_ sender: NSPopUpButton) {
        let values = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "thumbnailCorner")
    }
    @objc private func quickModeChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "quickCaptureMode")
    }
    @objc private func quickCaptureOpenEditorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "quickCaptureOpenEditor")
    }
    @objc private func closeEditorAfterCopyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "closeEditorAfterCopy")
    }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let languages = LanguageManager.availableLanguages
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < languages.count else { return }
        LanguageManager.shared.currentLanguage = languages[idx].code
    }
    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/sw33tLie/macshot") { NSWorkspace.shared.open(url) }
    }
    @objc private func imageFormatChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let format = ImageEncoder.Format(rawValue: raw),
              ImageEncoder.isFormatAvailable(format)
        else { return }
        UserDefaults.standard.set(raw, forKey: "imageFormat")
        updateQualityVisibility()
    }
    @objc private func qualityChanged(_ sender: NSSlider) {
        qualityLabel.stringValue = String(format: L("%d%%"), sender.integerValue)
        UserDefaults.standard.set(Double(sender.integerValue) / 100.0, forKey: "imageQuality")
    }
    @objc private func downscaleRetinaChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "downscaleRetina")
    }
    #if !OFFLINE
    @objc private func imgbbKeyChanged(_ sender: NSTextField) {
        let key = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { UserDefaults.standard.removeObject(forKey: "imgbbAPIKey") }
        else { UserDefaults.standard.set(key, forKey: "imgbbAPIKey") }
    }
    #endif
    @objc private func historySizeChanged(_ sender: NSStepper) {
        historySizeField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "historySize")
        UserDefaults.standard.set(false, forKey: "historyUnlimited")
        historyUnlimitedCheckbox.state = .off
        updateHistoryControlsEnabled()
        ScreenshotHistory.shared.pruneToMax()
    }

    @objc private func historyUnlimitedChanged(_ sender: NSButton) {
        let unlimited = sender.state == .on
        UserDefaults.standard.set(unlimited, forKey: "historyUnlimited")
        updateHistoryControlsEnabled()
    }

    @objc private func historyOrderByLastEditChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "historyOrderByLastEdit")
        // Re-sort existing entries to reflect the new preference immediately and
        // persist the new order so it survives a restart.
        ScreenshotHistory.shared.applyHistoryOrderPreference(persist: true)
    }

    private func updateHistoryControlsEnabled() {
        let unlimited = UserDefaults.standard.bool(forKey: "historyUnlimited")
        historySizeField.alphaValue = unlimited ? 0.35 : 1.0
        historySizeStepper.isEnabled = !unlimited
    }
    @objc private func recordingFPSChanged(_ sender: NSPopUpButton) {
        let fpsOptions = [15, 24, 30, 60, 120]
        let fps = fpsOptions[min(sender.indexOfSelectedItem, fpsOptions.count - 1)]
        UserDefaults.standard.set(fps, forKey: "recordingFPS")
    }
    @objc private func recordingOnStopChanged(_ sender: NSPopUpButton) {
        let values = ["editor", "finder", "clipboard"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "recordingOnStop")
    }
    @objc private func hideRecordingHUDChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideRecordingHUD")
    }

    @objc private func webcamPositionChanged(_ sender: NSPopUpButton) {
        let values = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamPosition")
    }

    @objc private func webcamSizeChanged(_ sender: NSSlider) {
        WebcamSize.save(points: CGFloat(sender.doubleValue))
        sender.doubleValue = Double(WebcamSize.savedPoints)
        updateWebcamSizeLabel()
    }

    private func updateWebcamSizeLabel() {
        webcamSizeLabel?.stringValue = "\(Int(WebcamSize.savedPoints)) px"
    }

    @objc private func webcamShapeChanged(_ sender: NSPopUpButton) {
        let values = ["circle", "roundedRect"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamShape")
    }

    @objc private func scrollAutoScrollChanged(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "scrollAutoScrollEnabled")
        scrollSpeedPopup.isEnabled = on
    }
    @objc private func scrollSpeedChanged(_ sender: NSPopUpButton) {
        // 0=Slow(1), 1=Medium(2), 2=Fast(3), 3=VeryFast(4)
        UserDefaults.standard.set(sender.indexOfSelectedItem + 1, forKey: "scrollAutoScrollSpeed")
    }
    @objc private func scrollMaxHeightChanged(_ sender: NSStepper) {
        scrollMaxHeightField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "scrollMaxHeight")
    }
    @objc private func scrollFrozenDetectionChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "scrollFrozenDetection")
    }
    @objc private func toggleItemChanged(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? "enabledTools"
        let allTools: [AnnotationTool] = [.pencil, .line, .arrow, .rectangle,
                                          .ellipse, .marker, .text, .number, .pixelate, .highlight, .loupe, .stamp, .measure]
        let defaultValues: [Int] = key == "enabledTools" ? allTools.map { $0.rawValue } : ToolbarActionPreferences.defaultEnabledRawValues
        var enabled = UserDefaults.standard.array(forKey: key) as? [Int] ?? defaultValues
        if sender.state == .on { if !enabled.contains(sender.tag) { enabled.append(sender.tag) } }
        else { enabled.removeAll { $0 == sender.tag } }
        UserDefaults.standard.set(enabled, forKey: key)
    }
    @objc private func accentColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveAccentColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func iconColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveIconColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func bgColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveBgColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    // MARK: - Theme presets

    private struct ThemePreset {
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

    private func makeColorColumn(well: NSColorWell, caption: String) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let col = NSStackView(views: [well, label])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }

    @objc private func themePresetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        // indexOfSelectedItem is -1 with no selection, which passes "< count".
        guard idx >= 0, idx < ThemePreset.all.count else { return } // "Custom" — no-op
        applyThemePreset(ThemePreset.all[idx])
    }

    private func applyThemePreset(_ preset: ThemePreset) {
        ToolbarLayout.saveAccentColor(preset.accent)
        ToolbarLayout.saveIconColor(preset.icon)
        ToolbarLayout.saveBgColor(preset.bg)
        accentColorWell.color = preset.accent
        iconColorWell.color = preset.icon
        bgColorWell.color = preset.bg
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }

    private func updateThemePresetSelection() {
        guard let popup = themePresetPopup else { return }
        let current = (ToolbarLayout.accentColor, ToolbarLayout.iconColor, ToolbarLayout.bgColor)
        for (i, preset) in ThemePreset.all.enumerated() {
            if colorsClose(current.0, preset.accent) &&
               colorsClose(current.1, preset.icon) &&
               colorsClose(current.2, preset.bg) {
                popup.selectItem(at: i)
                return
            }
        }
        // No match — select "Custom" (the last item)
        popup.selectItem(at: ThemePreset.all.count)
    }

    /// Compare two NSColors in sRGB with a small tolerance (color picker rounding).
    private func colorsClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let tol: CGFloat = 0.01
        return abs(x.redComponent - y.redComponent) < tol
            && abs(x.greenComponent - y.greenComponent) < tol
            && abs(x.blueComponent - y.blueComponent) < tol
            && abs(x.alphaComponent - y.alphaComponent) < tol
    }
    private func notifyToolbarColorChange() {
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }
    @objc private func copyUploadURL(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("link::") else { return }
        let url = String(id.dropFirst(6))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        let orig = sender.title
        sender.title = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sender.title = orig }
    }
    @objc private func snapGuidesChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "snapGuidesEnabled")
    }
    @objc private func boundarySnapChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "boundarySnapEnabled")
    }
    @objc private func snapHapticsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: SnapHapticFeedback.enabledKey)
    }
    @objc private func browserElementSnapChanged(_ sender: NSButton) {
        UserDefaults.standard.set(
            sender.state == .on,
            forKey: OverlayView.browserElementSnapEnabledKey)
    }
    @objc private func captureCursorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "captureCursor")
    }
    @objc private func doubleClickToCopyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "doubleClickToCopy")
    }
    @objc private func hideCaptureInstructionsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideCaptureInstructions")
    }
    @objc private func disableSelectionShadowChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "disableSelectionOutsideShadow")
    }
    @objc private func filenameTemplateCommitted(_ sender: NSTextField) {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? FilenameFormatter.defaultTemplate : sender.stringValue
        if trimmed.isEmpty {
            sender.stringValue = FilenameFormatter.defaultTemplate
        }
        UserDefaults.standard.set(value, forKey: FilenameFormatter.userDefaultsKey)
        updateFilenamePreview()
    }

    @objc private func filenameTemplateReset(_ sender: NSButton) {
        filenameTemplateField.stringValue = FilenameFormatter.defaultTemplate
        UserDefaults.standard.set(FilenameFormatter.defaultTemplate, forKey: FilenameFormatter.userDefaultsKey)
        updateFilenamePreview()
    }

    fileprivate func updateFilenamePreview() {
        guard let field = filenameTemplateField, let preview = filenameTemplatePreview else { return }
        let raw = field.stringValue
        let template = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FilenameFormatter.defaultTemplate : raw
        let sampleDate = sampleFilenameDate()
        let sampleWindow = template.contains("{window}") ? "Example Window" : nil
        let sampleIndex = template.contains("{index}") ? 1 : nil
        let base = FilenameFormatter.format(template: template, windowTitle: sampleWindow, index: sampleIndex, date: sampleDate)
        preview.stringValue = "\(L("Preview:")) \(base).\(ImageEncoder.fileExtension)"
    }

    private func sampleFilenameDate() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 17
        comps.hour = 14; comps.minute = 22; comps.second = 5
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }
    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                #if DEBUG
                print("Failed to update login item: \(error)")
                #endif
            }
        }
    }

    @objc private func urlSchemeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "urlSchemeEnabled")
    }

    fileprivate var urlSchemeInfoPopover: NSPopover?
    fileprivate var filenameTemplateInfoPopover: NSPopover?

    fileprivate func showURLSchemeInfoPopover(near sourceView: NSView) {
        if let existing = urlSchemeInfoPopover, existing.isShown { return }

        let commands: [(String, String)] = [
            ("macshot://capture",             L("Start area capture")),
            ("macshot://capture-fullscreen",  L("Capture the full screen")),
            ("macshot://capture-last",        L("Re-capture the last selected area")),
            ("macshot://quick-capture",       L("Quick capture (uses your Enter action)")),
            ("macshot://ocr",                 L("Capture area and read text/QR codes")),
            ("macshot://ocr-translate?target=zh-CN", L("Capture, translate, and overlay the text on the image")),
            ("macshot://record",              L("Start area recording")),
            ("macshot://record-fullscreen",   L("Start full-screen recording")),
            ("macshot://stop-recording",      L("Stop the current recording")),
            ("macshot://scroll-capture",      L("Start scroll capture")),
            ("macshot://history",             L("Open the recent captures overlay")),
            ("macshot://settings",            L("Open this settings window")),
            ("macshot://open?file=/path.png", L("Open an image file in the editor")),
            ("macshot://edit?id=<id>",        L("Open a history entry in the editor (keeps annotations editable)")),
        ]

        let title = NSTextField(labelWithString: L("Supported URL Scheme Commands"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("Trigger macshot from Raycast, Alfred, Shortcuts, or any tool that opens URLs."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 440
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // NSGridView for perfect column alignment — each row's cmd column and
        // desc column line up precisely regardless of text width.
        let grid = NSGridView(numberOfColumns: 2, rows: commands.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in commands.enumerated() {
            let cmdLabel = NSTextField(labelWithString: entry.0)
            cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cmdLabel.textColor = .labelColor
            cmdLabel.isSelectable = true

            let descLabel = NSTextField(labelWithString: entry.1)
            descLabel.font = NSFont.systemFont(ofSize: 11)
            descLabel.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = cmdLabel
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = descLabel
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container

        // Compute fitting size for the popover
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = fitting
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        urlSchemeInfoPopover = popover
    }

    @objc private func hideMenuBarIconChanged(_ sender: NSButton) {
        let hidden = sender.state == .on
        UserDefaults.standard.set(hidden, forKey: "hideMenuBarIcon")
        (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hidden)
    }

    @objc private func menuBarIconModeChanged(_ sender: NSPopUpButton) {
        let mode = sender.indexOfSelectedItem == 1 ? "symbol" : "default"
        UserDefaults.standard.set(mode, forKey: AppDelegate.statusBarIconModeKey)
        updateMenuBarIconControlsEnabled()
        (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
    }

    @objc private func menuBarIconPresetChanged(_ sender: NSPopUpButton) {
        // Pull-down: index 0 is the "Presets" label; real symbols start at 1.
        guard sender.indexOfSelectedItem >= 1,
              let symbol = sender.titleOfSelectedItem, !symbol.isEmpty else { return }
        menuBarIconSymbolField.stringValue = symbol
        applyMenuBarIconSymbol(symbol)
    }

    @objc private func menuBarIconSymbolChanged(_ sender: NSTextField) {
        applyMenuBarIconSymbol(sender.stringValue)
    }

    private func applyMenuBarIconSymbol(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppDelegate.statusBarIconSymbolNameKey)
        } else {
            UserDefaults.standard.set(name, forKey: AppDelegate.statusBarIconSymbolNameKey)
        }
        (NSApp.delegate as? AppDelegate)?.refreshStatusBarIcon()
    }

    /// Enables the symbol field + preset picker only in "Custom symbol" mode.
    private func updateMenuBarIconControlsEnabled() {
        let custom = menuBarIconModePopup.indexOfSelectedItem == 1
        menuBarIconSymbolField.isEnabled = custom
        menuBarIconPresetPopup.isEnabled = custom
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "SUEnableAutomaticChecks")
    }

    @objc private func betaUpdateChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "betaUpdatesEnabled")
    }

    @objc private func translationProviderChanged(_ sender: NSPopUpButton) {
        TranslationService.provider = sender.indexOfSelectedItem == 0 ? .apple : .google
    }

    @objc private func openTranslationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization.Settings.extension?Translation") {
            NSWorkspace.shared.open(url)
        }
    }

    func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopShortcutRecording()
        stopCommandShortcutRecording()
        stopToolShortcutRecording()
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}

// MARK: - NSTextFieldDelegate (live filename preview)

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === filenameTemplateField {
            // Save on every keystroke so closing the window without pressing
            // Enter doesn't silently lose the edit. Empty value resets to
            // the default template at commit time (see controlTextDidEndEditing).
            UserDefaults.standard.set(field.stringValue, forKey: FilenameFormatter.userDefaultsKey)
            updateFilenamePreview()
        } else if field === menuBarIconSymbolField {
            applyMenuBarIconSymbol(field.stringValue)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // On commit, replace empty/whitespace-only values with the default so
        // the user never ends up with a blank template saved.
        guard let field = obj.object as? NSTextField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if field === filenameTemplateField, trimmed.isEmpty {
            field.stringValue = FilenameFormatter.defaultTemplate
            UserDefaults.standard.set(FilenameFormatter.defaultTemplate, forKey: FilenameFormatter.userDefaultsKey)
            updateFilenamePreview()
        }
    }
}

// MARK: - Filename template info popover

extension SettingsWindowController {
    fileprivate func showFilenameTemplateInfoPopover(near sourceView: NSView) {
        if let existing = filenameTemplateInfoPopover, existing.isShown { return }

        let tokens: [(String, String)] = [
            ("{date}",      "2026-04-17"),
            ("{time}",      "14-22-05"),
            ("{timestamp}", "2026-04-17_14-22-05"),
            ("{unix}",      "1745592125"),
            ("{window}",    L("Screenshots only — captured window title (blank otherwise)")),
            ("{index}",     L("Counter for multi-screen captures")),
            ("{random}",    L("8-character random string (e.g. k3j7x9q2)")),
        ]

        let title = NSTextField(labelWithString: L("Filename Template Tokens"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("The file extension is appended automatically. Slashes and colons in {window} become dashes."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 380
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(numberOfColumns: 2, rows: tokens.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in tokens.enumerated() {
            let tok = NSTextField(labelWithString: entry.0)
            tok.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tok.textColor = .labelColor
            tok.isSelectable = true

            let desc = NSTextField(labelWithString: entry.1)
            desc.font = NSFont.systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = tok
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = desc
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container
        container.layoutSubtreeIfNeeded()
        vc.preferredContentSize = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        filenameTemplateInfoPopover = popover
    }
}
