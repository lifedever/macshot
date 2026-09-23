import Cocoa
import Carbon
import Sparkle
import ServiceManagement
import UniformTypeIdentifiers
import AVFoundation
import Vision
import WebP

enum CaptureMenuItemID: String, CaseIterable {
    case captureArea = "captureArea"
    case captureScreen = "captureScreen"
    case captureOCR = "captureOCR"
    case quickCapture = "quickCapture"
    case captureLastArea = "captureLastArea"
    case scrollCapture = "scrollCapture"

    static let userDefaultsKey = "captureMenuItemOrder"
    static let defaultOrder: [CaptureMenuItemID] = [
        .captureArea,
        .captureScreen,
        .captureOCR,
        .quickCapture,
        .captureLastArea,
        .scrollCapture,
    ]

    var title: String {
        switch self {
        case .captureArea: return L("Capture Area")
        case .captureScreen: return L("Capture Screen")
        case .captureOCR: return L("Capture OCR & QR")
        case .quickCapture: return L("Quick Capture")
        case .captureLastArea: return L("Capture Last Area")
        case .scrollCapture: return L("Scroll Capture")
        }
    }

    var symbolName: String {
        switch self {
        case .captureArea: return "crop"
        case .captureScreen: return "desktopcomputer"
        case .captureOCR: return "text.viewfinder"
        case .quickCapture: return "square.and.arrow.down"
        case .captureLastArea: return "arrow.counterclockwise.circle"
        case .scrollCapture: return "scroll"
        }
    }

    var hotkeySlot: HotkeyManager.HotkeySlot {
        switch self {
        case .captureArea: return .captureArea
        case .captureScreen: return .captureFullScreen
        case .captureOCR: return .captureOCR
        case .quickCapture: return .quickCapture
        case .captureLastArea: return .captureLastArea
        case .scrollCapture: return .scrollCapture
        }
    }

    static func orderedItems(defaults: UserDefaults = .standard) -> [CaptureMenuItemID] {
        let saved = defaults.stringArray(forKey: userDefaultsKey) ?? []
        var result: [CaptureMenuItemID] = []
        for rawValue in saved {
            guard let item = CaptureMenuItemID(rawValue: rawValue), !result.contains(item) else { continue }
            result.append(item)
        }
        for item in defaultOrder where !result.contains(item) {
            result.append(item)
        }
        return result
    }

    static func saveOrder(_ items: [CaptureMenuItemID], defaults: UserDefaults = .standard) {
        let sanitized = items.filter { defaultOrder.contains($0) }
        let completed = sanitized + defaultOrder.filter { !sanitized.contains($0) }
        defaults.set(completed.map(\.rawValue), forKey: userDefaultsKey)
    }

    static func resetOrder(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
    }
}

import os.log

private let timingLog = OSLog(subsystem: "com.sw33tlie.macshot.macshot", category: "capture-timing")

// MARK: - Signal-safe diagnostic logging

/// Async-signal-safe write(2)-only log fd for Jetsam/SIGTERM diagnostics.
/// Opened at launch in `AppDelegate.setupSignalHandlers()` and written to
/// by `sigtermHandler` when the system sends SIGTERM before SIGKILL.
private var macshotSignalLogFd: Int32 = -1

/// Async-signal-safe SIGTERM handler. Writes a one-line diagnostic to the
/// pre-opened `macshotSignalLogFd`, then resets the handler to default and
/// re-raises so `applicationWillTerminate` runs the normal cleanup path.
private let sigtermHandler: @convention(c) (Int32) -> Void = { _ in
    guard macshotSignalLogFd >= 0 else {
        signal(SIGTERM, SIG_DFL)
        return
    }
    // Only async-signal-safe operations below.
    let msg: StaticString = "SIGTERM received — likely Jetsam memory-pressure kill\n"
    _ = write(macshotSignalLogFd, msg.utf8Start, msg.utf8CodeUnitCount)
    _ = close(macshotSignalLogFd)
    macshotSignalLogFd = -1
    // Re-raise with default handler so applicationWillTerminate runs.
    signal(SIGTERM, SIG_DFL)
    kill(getpid(), SIGTERM)
}

private final class CaptureTimingTrace: @unchecked Sendable {
    private struct Entry {
        let label: String
        let elapsed: TimeInterval
        let delta: TimeInterval
        let thread: String
    }

    private let lock = NSLock()
    private let startTime: CFAbsoluteTime
    private var lastTime: CFAbsoluteTime
    private var entries: [Entry] = []

    init(startAbsoluteTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.startTime = startAbsoluteTime
        self.lastTime = startAbsoluteTime
        os_log("=== TRACE START ===", log: timingLog, type: .info)
    }

    func mark(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let entry = Entry(
            label: label,
            elapsed: now - startTime,
            delta: now - lastTime,
            thread: Thread.isMainThread ? "main" : "bg")
        entries.append(entry)
        lastTime = now
        lock.unlock()
        os_log("%{public}.1fms (+%{public}.1f) [%{public}@] %{public}@",
               log: timingLog, type: .info,
               entry.elapsed * 1000, entry.delta * 1000, entry.thread, label)
    }

    func measure<T>(_ label: String, _ work: () -> T) -> T {
        mark("\(label) begin")
        let result = work()
        mark("\(label) end")
        return result
    }

    func report(finalLabel: String) -> String {
        mark(finalLabel)

        lock.lock()
        let snapshot = entries
        lock.unlock()

        let total = snapshot.last?.elapsed ?? 0
        var lines: [String] = []
        lines.append("macshot capture timing — total: \(Self.format(total))")
        lines.append("")
        lines.append(" elapsed    delta  thread  event")
        lines.append("-----------------------------------------------")
        for entry in snapshot {
            lines.append(String(
                format: "%8.1f  %7.1f  %-6@  %@",
                entry.elapsed * 1000,
                entry.delta * 1000,
                entry.thread as NSString,
                entry.label as NSString))
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.1f ms", interval * 1000)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

    private var statusItem: NSStatusItem!
    private var updaterController: SPUStandardUpdaterController!
    private var overlayControllers: [OverlayWindowController] = []
    private var settingsController: SettingsWindowController?
    private var onboardingController: PermissionOnboardingController?
    private var pinControllers: [PinWindowController] = []
    private var thumbnailControllers: [FloatingThumbnailController] = []
    private var ocrController: OCRResultController?
    private var historyMenu: NSMenu?
    private var historyOverlayController: HistoryOverlayController?
    private var isCapturing = false
    private var delayCountdownWindow: NSWindow?
    private var delayTimer: Timer?
    private var delayEscMonitor: Any?
    private var recordingEngine: RecordingEngine?
    private var terminatingAfterRecording = false
    private let terminationCoordinator = ApplicationTerminationCoordinator()
    private var recordingTerminationWaiter: CheckedContinuation<Void, Never>?
    private var audioMergeControllers: [UUID: AudioMergeController] = [:]
    private var recordingOverlayController: OverlayWindowController?
    private var recordingHUDPanel: RecordingHUDPanel?
    private var recordingScreenRect: NSRect = .zero  // screen-space capture rect
    private var recordingScreen: NSScreen?
    private var mouseHighlightOverlay: MouseHighlightOverlay?
    private var keystrokeOverlay: KeystrokeOverlay?
    private var webcamOverlay: WebcamOverlay?
    private var selectionBorderOverlay: SelectionBorderOverlay?
    private var menuBarIconWasHidden: Bool = false  // restore after recording if user had it hidden
    private var scrollCaptureController: ScrollCaptureController?
    /// The overlay controller whose selection is being scroll-captured.
    private var scrollCaptureOverlayController: OverlayWindowController?
    private var scrollCapturePreviewPanel: ScrollCapturePreviewPanel?
    private var statusBarMenu: NSMenu?
    private var captureSessionID: UInt = 0
    private var captureTimingTrace: CaptureTimingTrace?
    /// Launch Services can deliver file/URL open requests before
    /// `applicationDidFinishLaunching`. Defer them until launch setup and the
    /// initial overlay-pool prewarm have completed; otherwise a cold-launch
    /// capture can be torn down by `rebuildOverlayPool()` later in startup.
    private var isReadyForOpenRequests = false
    private var pendingOpenURLs: [URL] = []
    /// Capture/record URL actions additionally wait for Screen Recording
    /// permission. Non-capture actions (settings, history, file opens, etc.)
    /// remain usable while the onboarding window is shown.
    private var isReadyForScreenCaptureURLs = false
    private var pendingScreenCaptureURLs: [URL] = []
    /// App Nap suppression assertion. Held for the app's lifetime so global
    /// hotkeys respond instantly instead of paying a wake-up penalty when
    /// macshot has been idle. Use the idle-sleep-safe variant: plain
    /// `.userInitiated` creates a `PreventUserIdleSystemSleep` assertion and
    /// keeps Macs awake indefinitely.
    private var appNapAssertion: NSObjectProtocol?

    /// Shared capture sound — loaded once, reused everywhere.
    static let captureSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Prevent multiple instances — if already running, activate the existing one and quit
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sw33tlie.macshot.macshot"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            // Tell the existing instance to show its icon and open Settings
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.sw33tlie.macshot.showAndOpenPrefs"),
                object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        // Clear image-effect state written by a pre-June-2026 build, which
        // otherwise leaves Vivid silently applied to every capture (#345).
        EffectsMigration.runIfNeeded()
        ToolbarLayout.migrateStoredDefaultTheme()

        // Surface save failures — otherwise a capture that can't be written
        // (full disk, unmounted volume) disappears without a word.
        ImageSaveService.onFailure = { [weak self] message in
            self?.showFailureToast(message)
        }

        // Disable App Nap. macshot is LSUIElement with no visible windows
        // when idle, so macOS can add wake-up latency to global hotkey
        // captures. The "allowing idle system sleep" variant keeps the
        // responsiveness hint without creating a PreventUserIdleSystemSleep
        // assertion that blocks normal sleep.
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Global hotkey responsiveness")

        // Open a signal-safe log fd and register the SIGTERM handler.
        // When macOS Jetsam kills the process, any SIGTERM sent before
        // SIGKILL is captured here, and the re-raise ensures
        // applicationWillTerminate also fires — giving us two diagnostic
        // traces to distinguish Jetsam kills from normal termination.
        setupSignalHandlers()

        // Offer to move to /Applications if running from a DMG or translocated path
        promptToMoveToApplicationsIfNeeded()

        migrateFilenameTemplateIfNeeded()

        // Reclaim disk from stale tmp leftovers (cancelled recordings,
        // legacy clipboard PNGs, share-sheet scratch). Runs off the main
        // thread so it can't delay launch.
        LaunchCleanup.runAll()

        // Force-init the history singleton so its launch-time orphan
        // prune runs even if the user doesn't take a screenshot this
        // session. Without this, the prune only fires the first time
        // something references ScreenshotHistory.shared.
        _ = ScreenshotHistory.shared

        if BuildVariant.softwareUpdatesEnabled {
            updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
            // Disable silent update downloads — updates should only apply
            // via explicit user action ("Check for Updates..." / Install),
            // so an automatic update can't be mistaken for a silent crash.
            updaterController.updater.automaticallyDownloadsUpdates = false
        }
        setupMainMenu()
        setupStatusBar()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(keyboardInputSourceDidChange),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            setMenuBarIconVisible(false)
        }
        registerHotkey()
        // Pre-warm CoreAudio so the first capture sound doesn't stall ~1s.
        if let sound = Self.captureSound {
            sound.volume = 0
            sound.play()
            sound.stop()
            sound.volume = 1
        }

        // Listen for duplicate-launch notification to restore icon
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowAndOpenPrefs),
            name: .init("com.sw33tlie.macshot.showAndOpenPrefs"), object: nil
        )

        // Dismiss overlays when the user switches spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Pin from history panel
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinFromHistory(_:)),
            name: .init("macshot.pinFromHistory"), object: nil
        )

        // Check screen recording permission. If not yet granted, show the
        // custom onboarding window instead of letting macOS throw its own dialogs.
        PermissionOnboardingController.checkPermissionSync { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.markScreenCaptureURLsReady()
            } else {
                self.showOnboarding()
            }
        }

        // Replay requests on the next run-loop turn so AppKit has completely
        // finished its launch lifecycle before an action presents UI or starts
        // a capture. Keep accepting requests into the queue until this runs so
        // their delivery order is preserved.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isReadyForOpenRequests = true
            let urls = self.pendingOpenURLs
            self.pendingOpenURLs.removeAll()
            self.handleOpenURLs(urls)
        }
    }

    private func showOnboarding() {
        // If already open, just bring it to front
        if let existing = onboardingController {
            existing.show()
            return
        }
        let oc = PermissionOnboardingController()
        oc.onPermissionGranted = { [weak self] in
            guard let self = self else { return }
            self.onboardingController = nil
            self.markScreenCaptureURLsReady()
        }
        oc.onClose = { [weak self, weak oc] in
            guard let self = self, self.onboardingController === oc else { return }
            self.onboardingController = nil
            // Closing onboarding abandons any action that was waiting for its
            // permission; never surprise the user by replaying it much later.
            self.pendingScreenCaptureURLs.removeAll()
        }
        onboardingController = oc
        oc.show()
    }

    private func prewarmCapturePath() {
        // Warm the SCShareableContent cache (cheap, async).
        ScreenCaptureManager.prewarm()
        // Build (or rebuild) the per-screen overlay controller pool. Each
        // controller owns a permanent NSPanel; on hotkey we reuse it rather
        // than creating fresh. This is what keeps captures fast — WindowServer
        // caches composition state per-window, and reused windows stay hot.
        rebuildOverlayPool()
    }

    private func markScreenCaptureURLsReady() {
        guard !isReadyForScreenCaptureURLs else { return }
        // Do not rebuild underneath a capture started through another entry
        // point. A later capture can create any missing pooled controller on
        // demand.
        if !isCapturing && recordingEngine == nil {
            prewarmCapturePath()
        }
        isReadyForScreenCaptureURLs = true
        let urls = pendingScreenCaptureURLs
        pendingScreenCaptureURLs.removeAll()
        handleOpenURLs(urls)
    }

    /// Persistent per-screen overlay controller pool. Held for the app's
    /// lifetime so each panel's CGSWindow stays alive in WindowServer.
    /// Rebuilt on screen-config change.
    private var overlayControllerPool: [ObjectIdentifier: OverlayWindowController] = [:]

    private func rebuildOverlayPool() {
        // Tear down stale controllers (screens removed, etc.) before rebuilding.
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        for screen in NSScreen.screens {
            let controller = OverlayWindowController(screen: screen)
            overlayControllerPool[ObjectIdentifier(screen)] = controller
            // Warm the panel: brief invisible orderFront so WindowServer
            // allocates the surface + composes one frame. This is what the
            // first real capture would otherwise pay.
            controller.warmPanel()
        }
    }

    private func pooledController(for screen: NSScreen) -> OverlayWindowController {
        if let existing = overlayControllerPool[ObjectIdentifier(screen)] {
            return existing
        }
        // New screen showed up between prewarms — create on demand.
        let controller = OverlayWindowController(screen: screen)
        overlayControllerPool[ObjectIdentifier(screen)] = controller
        controller.warmPanel()
        return controller
    }

    @objc private func systemDidWake() {
        guard !isCapturing, recordingEngine == nil else { return }
        prewarmCapturePath()
    }

    @objc private func screenParametersDidChange() {
        guard !isCapturing, recordingEngine == nil else { return }
        prewarmCapturePath()
    }

    /// Captured at the very start of every hotkey callback (before main thread
    /// dispatch hop). Lets the trace include runloop wake-up delay that
    /// happens BEFORE startCapture runs.
    var pendingCaptureEntryTime: CFAbsoluteTime?

    private func makeCaptureTimingTrace() -> CaptureTimingTrace? {
        let start = pendingCaptureEntryTime ?? CFAbsoluteTimeGetCurrent()
        pendingCaptureEntryTime = nil
        // Always-on while we hunt the cold-hotkey latency bug.
        return CaptureTimingTrace(startAbsoluteTime: start)
    }

    private func measureCaptureTiming<T>(_ label: String, _ work: () -> T) -> T {
        if let trace = captureTimingTrace {
            return trace.measure(label, work)
        }
        return work()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-launching macshot while it's running: show the menu bar icon
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        // Only open settings if no windows are visible (e.g. pure menu-bar state).
        // If editor/video editor is already open, just bring the app to the front.
        if !flag {
            openSettings()
        }
        return false
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Dock menu shown on right-click of the Dock icon.
    ///
    /// macOS only auto-populates the Dock menu's window list for document-based
    /// apps (apps using `NSDocumentController`). Our editor windows aren't
    /// documents, so we build the list ourselves: each visible titled window
    /// gets an entry that brings that specific window forward when clicked.
    /// Without this users only see "Show All Windows" and can't jump directly
    /// to a particular editor session.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let windows = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !windows.isEmpty else { return nil }
        let menu = NSMenu()
        // Sort by title so the menu order is stable across dock-menu openings.
        for window in windows.sorted(by: { $0.title < $1.title }) {
            let item = NSMenuItem(
                title: window.title.isEmpty ? L("Untitled") : window.title,
                action: #selector(activateWindowFromDockMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = window
            if window.isMiniaturized {
                // Visual cue so users know clicking will also de-minimize.
                item.state = .mixed
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func activateWindowFromDockMenu(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One-shot migration from the legacy `useWindowTitleInFilename` checkbox
    /// to the new `filenameTemplate` string. Runs once — seeds the template
    /// from the old bool then clears the legacy key.
    private func migrateFilenameTemplateIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: FilenameFormatter.userDefaultsKey) == nil else { return }
        let hadWindowTitle = d.bool(forKey: "useWindowTitleInFilename")
        let template = hadWindowTitle
            ? "Screenshot {date} at {time} — {window}"
            : FilenameFormatter.defaultTemplate
        d.set(template, forKey: FilenameFormatter.userDefaultsKey)
        d.removeObject(forKey: "useWindowTitleInFilename")
    }

    /// If the app is running from a DMG volume or a translocated path,
    /// offer to move it to /Applications for proper operation (auto-updates,
    /// persistent preferences, no translocation issues).
    private func promptToMoveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let isOnDMG = bundlePath.hasPrefix("/Volumes/")
        let isTranslocated = bundlePath.contains("/AppTranslocation/")
        guard isOnDMG || isTranslocated else { return }
        guard !UserDefaults.standard.bool(forKey: "suppressMoveToApplications") else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "\(BuildVariant.displayName) is running from a disk image. Move it to your Applications folder for auto-updates and best experience."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "suppressMoveToApplications")
        }
        guard response == .alertFirstButtonReturn else { return }

        let dest = URL(fileURLWithPath: "/Applications/\(BuildVariant.displayName).app")
        let src = URL(fileURLWithPath: bundlePath)
        do {
            // Remove old version if present
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            // Relaunch from /Applications
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            // Preserve any cold-launch request that arrived before the user
            // accepted this move prompt. `-a` makes the copied bundle the
            // explicit recipient of both custom URLs and file URLs.
            task.arguments = ["-n", "-a", dest.path]
                + pendingOpenURLs.map(\.absoluteString)
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Could not move to Applications"
            errAlert.informativeText = "Please drag macshot to your Applications folder manually.\n\n\(error.localizedDescription)"
            errAlert.runModal()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationCoordinator.request(hasActiveWork: recordingEngine != nil || MediaExportCoordinator.shared.hasActiveJobs || ScreenshotHistory.shared.hasPendingWrites,
            drain: { [weak self] in
                if let self, let engine = self.recordingEngine {
                    self.terminatingAfterRecording = true
                    await withCheckedContinuation { continuation in
                        self.recordingTerminationWaiter = continuation
                        engine.stopRecording()
                    }
                }
                await MediaExportCoordinator.shared.waitUntilIdle()
                await ScreenshotHistory.shared.waitUntilIdle()
            }, terminate: { sender.terminate(nil) })
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        os_log(.fault, log: timingLog, "macshot terminating — thermalState=%d", ProcessInfo.processInfo.thermalState.rawValue)
        // Normal quit drains the recording writer and coordinated exports.
        // A force quit leaves the durable take in place.
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        HotkeyManager.shared.unregister()
        DistributedNotificationCenter.default().removeObserver(self)
        if macshotSignalLogFd >= 0 {
            close(macshotSignalLogFd)
            macshotSignalLogFd = -1
        }
    }

    // MARK: - Signal Handlers

    /// Opens a write-only log fd and registers the SIGTERM handler.
    /// The fd is used by the signal handler (which can only call
    /// async-signal-safe functions; os_log is NOT safe in that context).
    private func setupSignalHandlers() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/macshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("termination.log")
        macshotSignalLogFd = open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        signal(SIGTERM, sigtermHandler)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu (required when no storyboard)

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About macshot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit macshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        // Standard Close Window (Cmd+W) — routes to NSWindow.performClose(_:) via the
        // responder chain, so it closes whichever window is key (editor, settings, etc.)
        // without any window-specific handling.
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "")
        EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .undo, to: undoItem)
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "")
        EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .redo, to: redoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()
    }

    // User-customizable menu bar icon (see Settings → General → Appearance).
    // Mode is "default" (bundled StatusBarIcon asset) or "symbol" (a user-chosen SF Symbol).
    static let statusBarIconModeKey = "statusBarIconMode"
    static let statusBarIconSymbolNameKey = "statusBarIconSymbolName"

    /// Point size for SF Symbol menu bar icons. Symbols carry their own internal padding,
    /// so they can fill the 22pt status bar slot without looking oversized.
    private static let statusBarSymbolSize: CGFloat = 18
    /// The bundled `StatusBarIcon` asset carries its own padding inside a 22pt viewBox, the
    /// same way an SF Symbol does, so it takes the symbol size — at the old, smaller size its
    /// artwork ended up shorter than every neighbouring item's.
    private static let statusBarAssetSize: CGFloat = 18

    private func applyNormalStatusBarIcon() {
        if let button = statusItem.button {
            applyPreferredIconImage(to: button)
            // Use the NATIVE status-item menu (no custom click action). Showing
            // the menu by synthesizing a click from the button's mouse-down
            // action re-enters AppKit's mouse-tracking loop and can hang the main
            // thread (which also kills the global hotkey). The menu's delegate
            // handles modal dismissal + prewarm in menuWillOpen instead.
            button.target = nil
            button.action = nil
            statusItem.menu = statusBarMenu
        }
    }

    /// Sets the button image/title from the user's icon preference. "symbol" mode renders
    /// the chosen SF Symbol as a 22pt template image; anything else — including an empty or
    /// invalid symbol name — falls back to the bundled icon so the item is never blank.
    private func applyPreferredIconImage(to button: NSStatusBarButton) {
        let mode = UserDefaults.standard.string(forKey: Self.statusBarIconModeKey) ?? "default"
        let symbolName = UserDefaults.standard.string(forKey: Self.statusBarIconSymbolNameKey) ?? ""

        if mode == "symbol", !symbolName.isEmpty,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "macshot") {
            symbol.isTemplate = true
            let side = Self.statusBarSymbolSize
            symbol.size = NSSize(width: side, height: side)
            button.image = symbol
            button.title = ""
        } else if let img = NSImage(named: "StatusBarIcon")?.copy() as? NSImage {
            // Copy first: `NSImage(named:)` hands back a shared cached instance, and resizing
            // it in place would mutate the asset for every other consumer.
            img.isTemplate = true
            let side = Self.statusBarAssetSize
            img.size = NSSize(width: side, height: side)
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "macshot"
        }
    }

    /// Re-applies the menu bar icon to reflect the user's current preference. Invoked live
    /// from Settings so changes take effect without a relaunch. No-op while recording — the
    /// recording state owns the icon then and restores the preferred one when it ends.
    func refreshStatusBarIcon() {
        guard recordingEngine == nil, let button = statusItem.button else { return }
        applyPreferredIconImage(to: button)
    }

    /// Re-apply the live side-effects of settings that were just bulk-imported
    /// (SettingsPortability). Cheap, well-defined effects are applied immediately;
    /// everything read once at launch takes effect after the relaunch prompt.
    func reapplySettingsAfterImport() {
        // Hotkeys: re-register every slot with the imported keycodes/modifiers.
        HotkeyManager.shared.unregisterAll()
        registerHotkey()

        // Launch-at-login: sync the login item to the imported value.
        if #available(macOS 13.0, *) {
            let enabled = UserDefaults.standard.bool(forKey: "launchAtLogin")
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                #if DEBUG
                print("reapplySettingsAfterImport: login item update failed: \(error)")
                #endif
            }
        }

        // Menu bar icon visibility + appearance.
        setMenuBarIconVisible(!UserDefaults.standard.bool(forKey: "hideMenuBarIcon"))
        refreshStatusBarIcon()
        rebuildStatusBarMenu()
    }

    /// Relaunch the app so settings read once at launch take effect. Launches a fresh
    /// instance via NSWorkspace (no shell, no sleep), then terminates this one once the
    /// new copy is up. `createsNewApplicationInstance` lets the replacement start before
    /// this process exits, so there's no window where no instance is running.
    static func relaunchApp() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Internal, like its siblings `refreshStatusBarIcon` and
    /// `setMenuBarIconVisible`: the settings models call it directly when a
    /// preference changes the menu.
    func rebuildStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for itemID in CaptureMenuItemID.orderedItems() {
            menu.addItem(makeCaptureMenuItem(itemID))
        }

        // Capture Delay submenu
        let delayItem = NSMenuItem(title: L("Capture Delay"), action: nil, keyEquivalent: "")
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let delaySubmenu = NSMenu()
        delaySubmenu.autoenablesItems = false
        let currentDelay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        for seconds in [0, 3, 5, 10, 30] {
            let title = seconds == 0 ? L("None") : String(format: L("%d seconds"), seconds)
            let item = NSMenuItem(title: title, action: #selector(setDelaySeconds(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = seconds == currentDelay ? .on : .off
            delaySubmenu.addItem(item)
        }
        delayItem.submenu = delaySubmenu
        menu.addItem(delayItem)

        menu.addItem(NSMenuItem.separator())

        let recordAreaItem = NSMenuItem(title: L("Record Area"), action: #selector(recordArea), keyEquivalent: "")
        recordAreaItem.target = self
        recordAreaItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .recordArea, to: recordAreaItem)
        menu.addItem(recordAreaItem)

        let recordScreenItem = NSMenuItem(title: L("Record Screen"), action: #selector(recordFullScreen), keyEquivalent: "")
        recordScreenItem.target = self
        recordScreenItem.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .recordScreen, to: recordScreenItem)
        menu.addItem(recordScreenItem)

        menu.addItem(NSMenuItem.separator())

        // Recent Captures submenu
        let historyItem = NSMenuItem(title: L("Recent Captures"), action: nil, keyEquivalent: "")
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let historySubmenu = NSMenu()
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        self.historyMenu = historySubmenu
        menu.addItem(historyItem)

        let historyOverlayItem = NSMenuItem(title: L("Show History Panel"), action: #selector(showHistoryOverlay), keyEquivalent: "")
        historyOverlayItem.target = self
        historyOverlayItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .historyOverlay, to: historyOverlayItem)
        menu.addItem(historyOverlayItem)

        menu.addItem(NSMenuItem.separator())

        let openImageItem = NSMenuItem(title: L("Open Image..."), action: #selector(openImageFromMenu), keyEquivalent: "")
        openImageItem.target = self
        openImageItem.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        menu.addItem(openImageItem)

        let openVideoItem = NSMenuItem(title: L("Open Video..."), action: #selector(openVideoFromMenu), keyEquivalent: "")
        openVideoItem.target = self
        openVideoItem.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        menu.addItem(openVideoItem)

        let recordingsItem = NSMenuItem(title: L("Show Recordings in Finder"),
            action: #selector(showRecordingsInFinder), keyEquivalent: "")
        recordingsItem.target = self
        recordingsItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(recordingsItem)

        let pasteImageItem = NSMenuItem(title: L("Open from Clipboard"), action: #selector(openImageFromClipboard), keyEquivalent: "")
        pasteImageItem.target = self
        pasteImageItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .openFromClipboard, to: pasteImageItem)
        menu.addItem(pasteImageItem)

        let pinClipboardTitle = L("Pin from Clipboard")
        let pinClipboardItem = NSMenuItem(title: pinClipboardTitle, action: #selector(pinFromClipboard), keyEquivalent: "")
        pinClipboardItem.target = self
        pinClipboardItem.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: pinClipboardTitle)
        HotkeyManager.applyMenuShortcut(for: .pinFromClipboard, to: pinClipboardItem)
        menu.addItem(pinClipboardItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: L("Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        prefsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(prefsItem)

        if BuildVariant.softwareUpdatesEnabled {
            let updateItem = NSMenuItem(title: L("Check for Updates..."), action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(updateItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L("Quit macshot"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self  // menuWillOpen dismisses any modal + prewarms capture
        statusBarMenu = menu
        // Re-attach to the status item unless we're in recording mode (which owns
        // the icon and uses a custom stop action with no menu).
        if recordingEngine == nil {
            statusItem?.menu = menu
        }
    }

    private func makeCaptureMenuItem(_ itemID: CaptureMenuItemID) -> NSMenuItem {
        let action: Selector
        switch itemID {
        case .captureArea: action = #selector(captureScreen)
        case .captureScreen: action = #selector(captureFullScreen)
        case .captureOCR: action = #selector(captureOCR)
        case .quickCapture: action = #selector(quickCapture)
        case .captureLastArea: action = #selector(captureLastArea)
        case .scrollCapture: action = #selector(scrollCapture)
        }

        let item = NSMenuItem(title: itemID.title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: itemID.symbolName, accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: itemID.hotkeySlot, to: item)
        return item
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        // Stamp entry time at the very FIRST instruction of each callback so
        // any runloop wake-up cost before startCapture is attributed.
        let stamp: () -> Void = { [weak self] in
            let now = CFAbsoluteTimeGetCurrent()
            self?.pendingCaptureEntryTime = now
            os_log("HOTKEY CALLBACK FIRED at abs=%{public}.6f", log: timingLog, type: .info, now)
        }
        HotkeyManager.shared.registerAll(
            captureArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureScreenFromHotkey))
            },
            captureFullScreen: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureFullScreenFromHotkey))
            },
            recordArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.recordAreaFromHotkey))
            },
            recordScreen: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.recordFullScreenFromHotkey))
            },
            historyOverlay: { [weak self] in
                DispatchQueue.main.async { self?.showHistoryOverlay() }
            },
            captureOCR: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureOCRFromHotkey))
            },
            quickCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.quickCaptureFromHotkey))
            },
            scrollCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.scrollCaptureFromHotkey))
            },
            openFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.openImageFromClipboard() }
            },
            captureLastArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureLastAreaFromHotkey))
            },
            pinFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.pinFromClipboard() }
            },
            clearHistory: { [weak self] in
                DispatchQueue.main.async { self?.clearHistorySilently() }
            }
        )
    }

    private var pendingRecordMode: Bool = false
    private var pendingFullScreen: Bool = false
    private var pendingFullScreenRecord: Bool = false
    private var pendingFullScreenRecordAutoStart: Bool = false
    private var pendingOCRMode: Bool = false
    private var pendingTranslateOverlayMode: Bool = false
    private var pendingTranslateOverlayLang: String?
    private var pendingQuickCaptureMode: Bool = false
    private var pendingScrollCaptureMode: Bool = false
    private var capturedWindowTitle: String?
    /// The app that was active before the overlay appeared — re-activated on dismiss.
    /// The app that was active before macshot showed its overlay.
    private var previousApp: NSRunningApplication?

    /// Titled macshot windows (editors, preferences, Sparkle, etc.) that were
    /// visible when capture started. We `orderOut` them so `NSApp.activate`
    /// during capture can't drag them in front of the user's frontmost app,
    /// then `orderFront` them when the overlay dismisses. Kept in the order
    /// they appeared so restoring preserves relative z-order.
    private var backgroundWindowRestoration = DeferredRestoration<NSWindow>()
    private var stashedBackgroundWindows: [NSWindow] { backgroundWindowRestoration.pending }
    private var backgroundWindowRestoreObserver: NSObjectProtocol?
    private var stashedWindowCloseObserver: NSObjectProtocol?

    /// True when floating thumbnails or pin windows are visible.
    var hasVisibleFloatingPanels: Bool {
        !thumbnailControllers.isEmpty || !pinControllers.isEmpty
    }

    /// Call when a macshot window closes. If no titled windows remain,
    /// switches to accessory activation policy and returns focus to
    /// the previous app (or the next regular app in line).
    func returnFocusIfNeeded() {
        captureTimingTrace?.mark("returnFocusIfNeeded entered")
        let appToActivate = previousApp
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            // Don't hide the app while a recording is in progress — the HUD
            // and selection border are non-titled panels that would be killed.
            if self?.recordingEngine != nil { return }
            let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            // Windows we hid for the screenshot count as "visible" for
            // activation-policy purposes — they're coming back as soon as
            // the previous app regains focus, so we mustn't downgrade.
            let hasStashedWindows = !(self?.stashedBackgroundWindows.isEmpty ?? true)
            guard !hasVisibleWindows else { return }
            if !hasStashedWindows {
                NSApp.setActivationPolicy(.accessory)
            }
            if let prev = appToActivate, !prev.isTerminated,
               prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.captureTimingTrace?.mark("activate previous app")
                Self.activateApp(prev)
            } else {
                // No known previous app — yield focus to whatever is frontmost.
                // Avoid NSApp.hide(nil) which can suspend the Carbon event loop
                // and break global hotkeys until the app is reactivated.
                self?.captureTimingTrace?.mark("activate fallback app")
                Self.activateApp(
                    NSWorkspace.shared.runningApplications.first {
                        $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    } ?? NSWorkspace.shared.frontmostApplication ?? NSRunningApplication.current
                )
            }
        }
    }

    /// Activate another app using the modern cooperative activation API.
    static func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    // MARK: - Capture

    @objc private func captureScreen() {
        beginCaptureArea(fromMenu: true)
    }

    @objc private func captureScreenFromHotkey() {
        beginCaptureArea(fromMenu: false)
    }

    private func beginCaptureArea(fromMenu: Bool) {
        startCapture(fromMenu: fromMenu)
    }

    @objc private func captureFullScreen() {
        beginCaptureFullScreen(fromMenu: true)
    }

    @objc private func captureFullScreenFromHotkey() {
        beginCaptureFullScreen(fromMenu: false)
    }

    private func beginCaptureFullScreen(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingFullScreen = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func showHistoryOverlay() {
        if let existing = historyOverlayController {
            existing.dismiss()
            historyOverlayController = nil
            return
        }
        let controller = HistoryOverlayController()
        controller.onDismiss = { [weak self] in
            self?.historyOverlayController = nil
        }
        controller.show()
        historyOverlayController = controller
    }

    @objc private func captureOCR() {
        beginCaptureOCR(fromMenu: true)
    }

    @objc private func captureOCRFromHotkey() {
        beginCaptureOCR(fromMenu: false)
    }

    private func beginCaptureOCR(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingOCRMode = true
        startCapture(fromMenu: fromMenu)
    }

    /// Region-capture → OCR → translate → draw the translation in place over the
    /// original text on the screenshot (macshot://ocr-translate). `target` nil
    /// uses the saved default language.
    private func beginCaptureTranslate(target: String?, fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingTranslateOverlayMode = true
        pendingTranslateOverlayLang = target
        startCapture(fromMenu: fromMenu)
    }

    @objc private func quickCapture() {
        beginQuickCapture(fromMenu: true)
    }

    @objc private func quickCaptureFromHotkey() {
        beginQuickCapture(fromMenu: false)
    }

    private func beginQuickCapture(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingQuickCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func scrollCapture() {
        beginScrollCapture(fromMenu: true)
    }

    @objc private func scrollCaptureFromHotkey() {
        beginScrollCapture(fromMenu: false)
    }

    private func beginScrollCapture(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingScrollCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    /// Open the capture overlay with the last selection area pre-applied.
    /// If no previous selection exists, falls back to a normal capture.
    @objc private func captureLastArea() {
        beginCaptureLastArea(fromMenu: true)
    }

    @objc private func captureLastAreaFromHotkey() {
        beginCaptureLastArea(fromMenu: false)
    }

    private func beginCaptureLastArea(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingRestoreLastArea = true
        startCapture(fromMenu: fromMenu)
    }
    private var pendingRestoreLastArea: Bool = false

    @objc private func recordArea() {
        beginRecordArea(fromMenu: true)
    }

    @objc private func recordAreaFromHotkey() {
        beginRecordArea(fromMenu: false)
    }

    private func beginRecordArea(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingRecordMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func recordFullScreen() {
        beginRecordFullScreen(fromMenu: true)
    }

    @objc private func recordFullScreenFromHotkey() {
        beginRecordFullScreen(fromMenu: false)
    }

    private func beginRecordFullScreen(fromMenu: Bool) {
        guard canStartCapture else { return }
        pendingFullScreenRecord = true
        if UserDefaults.standard.integer(forKey: "captureDelaySeconds") > 0 {
            pendingFullScreenRecordAutoStart = true
        }
        startCapture(fromMenu: fromMenu)
    }

    @objc private func setDelaySeconds(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "captureDelaySeconds")
        // Update checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = item.tag == sender.tag ? .on : .off
            }
        }
    }

    /// Whether a new capture can start right now. The `begin*` entry points set
    /// their pending mode flag (pendingOCRMode, pendingRecordMode, …) BEFORE
    /// calling `startCapture`. If `startCapture` were to bail at its guards after
    /// the flag was set, the flag would strand and get applied to the *next*
    /// capture — e.g. a stranded `pendingOCRMode` makes a later screenshot spawn
    /// an unexpected OCR window (issue #276). So each `begin*` checks this FIRST
    /// and only sets its flag when a capture will actually run. We must not clear
    /// the flags inside `startCapture`'s `!isCapturing` guard, because during a
    /// delay-capture countdown `isCapturing` is already true and the pending mode
    /// belongs to that accepted (not-yet-consumed) capture.
    private var canStartCapture: Bool {
        !isCapturing && recordingEngine == nil
    }

    private func startCapture(fromMenu: Bool = false) {
        guard !isCapturing else { return }
        // Don't allow captures while recording
        guard recordingEngine == nil else { return }
        let trace = makeCaptureTimingTrace()
        captureTimingTrace = trace
        trace?.mark("startCapture entered fromMenu=\(fromMenu)")
        isCapturing = true
        captureSessionID &+= 1
        let sessionID = captureSessionID
        trace?.mark("capture session created id=\(sessionID)")
        previousApp = NSWorkspace.shared.frontmostApplication
        trace?.mark("frontmost application captured")
        capturedWindowTitle = nil
        let focusedWindowPID = previousApp?.processIdentifier
        resolveFocusedWindowTitleAsync(for: focusedWindowPID, sessionID: sessionID)

        // When "remember last tool" is off, clear persisted effects/beautify
        // so new OverlayView instances start clean.
        let rememberTool = UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
        if !rememberTool {
            OverlayView.resetRememberedTool()
            UserDefaults.standard.removeObject(forKey: "effectsPreset")
            UserDefaults.standard.removeObject(forKey: "effectsBrightness")
            UserDefaults.standard.removeObject(forKey: "effectsContrast")
            UserDefaults.standard.removeObject(forKey: "effectsSaturation")
            UserDefaults.standard.removeObject(forKey: "effectsSharpness")
            // Beautify is a setting of its own now, not a leftover of the last
            // capture, so "remember last tool" no longer clears it.
        }

        // Clean up stale overlays without consuming previousApp — we just set it.
        measureCaptureTiming("dismiss stale overlays") {
            dismissOverlays(refocusPreviousApp: false)
        }
        isCapturing = true

        // Hide non-overlay titled windows so they don't end up in the screenshot.
        // Restored in dismissOverlays once capture is over.
        measureCaptureTiming("stash background windows") {
            stashBackgroundWindows()
        }

        // Hide floating thumbnails so they don't appear in the captured image.
        measureCaptureTiming("hide thumbnails before capture") {
            for tc in thumbnailControllers { tc.hideWindow() }
        }

        let delay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        trace?.mark("capture delay read delay=\(delay)")

        if delay > 0 {
            captureTimingTrace?.mark("showPreCaptureCountdown requested")
            showPreCaptureCountdown(seconds: delay)
            return
        }

        performCapture(fromMenu: fromMenu)
    }

    private func showPreCaptureCountdown(seconds: Int) {
        // No display to show a countdown on (all asleep, or headless).
        guard let screen = NSScreen.preferred else { return }
        let size = NSSize(width: 140, height: 140)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        // Listen for Escape to cancel countdown — use both local and global monitors
        // Local catches keys when macshot is active; global catches when another app has focus
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelPreCaptureCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.removeDelayEscMonitors()
                self?.performCapture(fromMenu: false)
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func removeDelayEscMonitors() {
        if let m = delayEscMonitor { NSEvent.removeMonitor(m); delayEscMonitor = nil }
    }

    private func cancelPreCaptureCountdown() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        removeDelayEscMonitors()
        isCapturing = false
        pendingRecordMode = false
        pendingFullScreen = false
        pendingFullScreenRecord = false
        pendingFullScreenRecordAutoStart = false
        pendingOCRMode = false
        pendingTranslateOverlayMode = false
        pendingTranslateOverlayLang = nil
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        pendingRestoreLastArea = false
    }

    private func performCapture(fromMenu: Bool) {
        captureTimingTrace?.mark("performCapture entered fromMenu=\(fromMenu)")
        let screens = measureCaptureTiming("NSScreen.screens") {
            NSScreen.screens
        }
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = screens.first { $0.frame.contains(mouseLocation) }

        // Kick off the screenshot capture on a background queue. Window
        // creation runs on main concurrently — both costs are paid in parallel.
        // CGWindowListCreateImage is used because it preserves transient UI
        // (menu extras, app menus, Raycast-style panels) that disappears once
        // anything steals focus. Overlay windows haven't been ordered-front yet
        // so they won't appear in the capture.
        let captureContext = measureCaptureTiming("makeImmediateCaptureContext") {
            ScreenCaptureManager.makeImmediateCaptureContext()
        }
        let trace = captureTimingTrace
        let sessionID = captureSessionID

        // Pull (don't construct) overlay controllers from the persistent pool.
        // Each controller's NSPanel was created and warmed at launch / pool
        // rebuild, so WindowServer's per-window cache is already hot.
        var controllers: [OverlayWindowController] = []
        for screen in screens {
            let controller = measureCaptureTiming("acquire pooled overlay") {
                pooledController(for: screen)
            }
            controller.overlayDelegate = self
            if let trace = captureTimingTrace {
                controller.timingMark = { label in trace.mark(label) }
            }
            controller.capturedWindowTitle = capturedWindowTitle
            if pendingRecordMode { controller.setAutoRecordMode() }
            if pendingOCRMode { controller.setAutoOCRMode() }
            if pendingTranslateOverlayMode { controller.setAutoTranslateOverlayMode(targetLang: pendingTranslateOverlayLang) }
            if pendingQuickCaptureMode { controller.setAutoQuickSaveMode() }
            if pendingScrollCaptureMode { controller.setAutoScrollCaptureMode() }
            controllers.append(controller)
        }
        overlayControllers.append(contentsOf: controllers)

        pendingRecordMode = false
        let didApplyFullScreenRecord = pendingFullScreenRecord
        let didApplyFullScreenRecordAutoStart = pendingFullScreenRecordAutoStart
        let didApplyFullScreen = pendingFullScreen
        pendingFullScreenRecordAutoStart = false
        pendingOCRMode = false
        pendingTranslateOverlayMode = false
        pendingTranslateOverlayLang = nil
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        pendingFullScreen = false
        pendingFullScreenRecord = false

        // Run the screenshot capture now and dispatch back to main when done.
        // Window creation above already ran in parallel with the prep that the
        // background work still has to do.
        //
        // Prefer SCScreenshotManager: it honors the "Capture mouse cursor"
        // toggle even for the enlarged shake-to-find / accessibility cursor,
        // which CGWindowListCreateImage cannot exclude (the cursor is a
        // WindowServer layer, not a window). On macOS 26+, use the rect-based
        // screenshot API to avoid SCShareableContent enumeration in the hot
        // path. Older SCK fallback still fetches fresh shareable content so
        // transient UI (menus, Spotlight) is preserved. If SCK fails or can't
        // cover every display, fall back to the synchronous CGWindowListCreateImage
        // path (which manually composites the cursor from the prebuilt context).
        Task { [weak self] in
            trace?.mark("background screenshot begin")
            var captures: [ScreenCapture]? = nil
            if #available(macOS 14.0, *) {
                captures = await ScreenCaptureManager.captureAllScreensImmediatelySCK(
                    timing: { label in trace?.mark(label) })
            }
            let finalCaptures = captures ?? ScreenCaptureManager.captureAllScreensImmediately(
                context: captureContext,
                timing: { label in trace?.mark(label) })
            trace?.mark("background screenshot end count=\(finalCaptures.count)")
            await MainActor.run {
                guard let self = self, self.isCapturing,
                      self.captureSessionID == sessionID else { return }
                self.installAndShowOverlays(
                    captures: finalCaptures,
                    controllers: controllers,
                    mouseScreen: mouseScreen,
                    applyFullScreen: didApplyFullScreen,
                    applyFullScreenRecord: didApplyFullScreenRecord,
                    autoStartRecord: didApplyFullScreenRecordAutoStart)
            }
        }
    }

    /// Install screenshots into the pre-built overlay controllers and order
    /// them front. This is the single moment the overlay becomes visible.
    private func installAndShowOverlays(
        captures: [ScreenCapture],
        controllers: [OverlayWindowController],
        mouseScreen: NSScreen?,
        applyFullScreen: Bool,
        applyFullScreenRecord: Bool,
        autoStartRecord: Bool
    ) {
        if captures.isEmpty {
            captureTimingTrace?.mark("no captures returned — bailing out")
            // This accepted capture is ending without a selection, so nothing
            // consumes the remaining pending flags. Clear them here so they don't
            // strand into the next capture (e.g. pendingRestoreLastArea, which
            // performCapture doesn't clear). See issue #276.
            pendingRestoreLastArea = false
            dismissOverlays(refocusPreviousApp: true)
            showOnboarding()
            return
        }

        let capturesByScreen = Dictionary(uniqueKeysWithValues: captures.map { ($0.screen, $0.image) })

        for controller in controllers {
            if let image = capturesByScreen[controller.screen] {
                measureCaptureTiming("set screenshot") {
                    controller.setScreenshot(image)
                }
            }
            measureCaptureTiming("show overlay") {
                controller.showOverlay()
            }
            let isMouseScreen = (controller.screen == mouseScreen)
                || (mouseScreen == nil && controller.screen == NSScreen.main)
            if (applyFullScreen || applyFullScreenRecord) && isMouseScreen {
                measureCaptureTiming("apply full screen selection") {
                    controller.applyFullScreenSelection()
                }
            }
            if applyFullScreenRecord && isMouseScreen {
                controller.enterRecordingMode()
                if autoStartRecord {
                    controller.autoStartRecording()
                }
            }
        }

        // Every overlay made itself key as it was shown, so the last screen in
        // the list kept the keyboard — whichever screen the pointer was on.
        // F then selected the wrong display, and after "Capture Full Screen"
        // Return went to an idle overlay and did nothing. The screen being
        // captured from is the one that takes keys.
        if let keyController = controllers.first(where: { $0.screen == mouseScreen })
            ?? controllers.first(where: { $0.screen == NSScreen.main }),
           controllers.count > 1 {
            keyController.makeKey()
        }

        captureTimingTrace?.mark("overlays installed and shown — INTERACTIVE")
        // Beacon: schedule periodic main-runloop marks so we can see if the
        // runloop is alive between INTERACTIVE and the first user event.
        // Fires every 50ms for 3 seconds, then auto-cancels.
        if let trace = captureTimingTrace {
            let report = trace.report(finalLabel: "INTERACTIVE-checkpoint")
            os_log("=== TRACE @ INTERACTIVE ===\n%{public}@", log: timingLog, type: .info, report)
            startRunloopBeacon()
        }
        applyPendingRestoredSelectionIfNeeded()
    }

    private var runloopBeaconTimer: Timer?
    private func startRunloopBeacon() {
        stopRunloopBeacon()
        var ticks = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            ticks += 1
            self?.captureTimingTrace?.mark("BEACON tick=\(ticks)")
            if ticks >= 60 {  // 3 seconds
                t.invalidate()
                self?.runloopBeaconTimer = nil
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        runloopBeaconTimer = timer
    }
    private func stopRunloopBeacon() {
        runloopBeaconTimer?.invalidate()
        runloopBeaconTimer = nil
    }

    private func applyPendingRestoredSelectionIfNeeded() {
        guard pendingRestoreLastArea else { return }
        pendingRestoreLastArea = false
        restoreLastSelection(controllers: overlayControllers)
    }

    /// Apply the stored last selection rect to the matching overlay controller.
    private func restoreLastSelection(controllers: [OverlayWindowController]) {
        guard let rectStr = UserDefaults.standard.string(forKey: "lastSelectionRect"),
              let screenStr = UserDefaults.standard.string(forKey: "lastSelectionScreenFrame") else { return }
        let savedRect = NSRectFromString(rectStr)
        let savedScreenFrame = NSRectFromString(screenStr)
        guard savedRect.width > 1, savedRect.height > 1 else { return }
        for controller in controllers where controller.screen.frame == savedScreenFrame {
            controller.applySelection(savedRect)
            // The install loop made the LAST overlay it showed the key window,
            // but keyboard handling (Cmd+C, F, Enter) is per-window and gated
            // on that window's own selection state — so key focus must follow
            // the overlay that received the restored selection (#281).
            controller.showOverlay()
            break
        }
    }

    /// Returns the title of the frontmost window via CGWindowList (requires Screen Recording permission).
    nonisolated private static func focusedWindowTitle(forPID pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    private func resolveFocusedWindowTitleAsync(for pid: pid_t?, sessionID: UInt) {
        guard let pid = pid else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let title = Self.focusedWindowTitle(forPID: pid)
            DispatchQueue.main.async {
                guard let self = self, self.isCapturing, self.captureSessionID == sessionID else { return }
                self.capturedWindowTitle = title
                for controller in self.overlayControllers {
                    controller.capturedWindowTitle = title
                }
            }
        }
    }


    @objc private func handleShowAndOpenPrefs() {
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        openSettings()
    }

    @objc private func keyboardInputSourceDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildStatusBarMenu()
            self.settingsController?.refreshShortcutDisplaysForKeyboardLayout()
        }
    }

    @objc private func spaceDidChange() {
        guard !overlayControllers.isEmpty else { return }
        // A scroll capture has to be cancelled, not just have its overlay
        // taken away: the session, its HUD and its event tap would otherwise
        // carry on with nothing on screen to stop them.
        if let controller = scrollCaptureOverlayController, scrollCaptureController != nil {
            overlayDidRequestCancelScrollCapture(controller)
            return
        }
        dismissOverlays()
    }

    private func dismissOverlays(refocusPreviousApp: Bool = true) {
        captureTimingTrace?.mark("dismissOverlays entered refocus=\(refocusPreviousApp)")
        autoreleasepool {
            for controller in overlayControllers {
                controller.dismiss()
            }
            overlayControllers.removeAll()
        }
        captureTimingTrace?.mark("overlay controllers dismissed")
        isCapturing = false
        // Restore hidden thumbnails
        measureCaptureTiming("restore thumbnails") {
            for tc in thumbnailControllers { tc.showWindow() }
        }
        if refocusPreviousApp {
            // Restore AFTER another app takes focus so the stashed windows
            // come back behind it instead of on top. See
            // `scheduleBackgroundWindowRestore` for the timing logic.
            captureTimingTrace?.mark("schedule focus restore")
            scheduleBackgroundWindowRestore()
            returnFocusIfNeeded()
        } else {
            // No focus switch coming — just bring them back immediately.
            captureTimingTrace?.mark("restore background windows immediately")
            restoreBackgroundWindowsNow()
        }
        captureTimingTrace?.mark("dismissOverlays completed")
        if refocusPreviousApp, let trace = captureTimingTrace {
            let report = trace.report(finalLabel: "OVERLAY DISMISSED")
            os_log("=== FINAL TRACE ===\n%{public}@", log: timingLog, type: .info, report)
            Self.appendTimingReport(report)
            captureTimingTrace = nil
        }
    }

    /// Path to the rolling timing log inside the sandbox container.
    /// Real path on disk:
    ///   ~/Library/Containers/com.sw33tlie.macshot.macshot/Data/Library/Application Support/macshot/timing.log
    static let timingLogURL: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("macshot", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timing.log")
    }()

    /// Append a timing report to the rolling log file. Each entry is prefixed
    /// with a wall-clock timestamp so cold vs warm runs are easy to compare.
    /// Runs synchronously on whatever queue calls it — file writes are fast.
    static func appendTimingReport(_ report: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "\n========== \(ts) ==========\n\(report)\n"
        let url = timingLogURL
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try entry.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            os_log("appendTimingReport failed: %{public}@", log: timingLog, type: .error, "\(error)")
        }
    }

    /// Hide non-overlay titled macshot windows so they can't be dragged in
    /// front of the user's frontmost app when the overlay activates.
    ///
    /// We only stash when another app was frontmost — that means the user is
    /// trying to screenshot something *other than* macshot, and any macshot
    /// windows still on screen are unintended background clutter. When
    /// macshot itself is frontmost the user presumably wants to capture one
    /// of its own windows, so we leave everything alone.
    private func stashBackgroundWindows() {
        clearBackgroundRestoreObservers()
        let macshotWasFrontmost = previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let additions = macshotWasFrontmost ? [] : NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled)
        }
        // Keep windows hidden by the preceding capture until this one can
        // restore them. Clearing the list here loses those windows permanently.
        backgroundWindowRestoration.begin(adding: additions)
        for window in additions { window.orderOut(nil) }
        guard !stashedBackgroundWindows.isEmpty else { return }
        stashedWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self = self, let window = note.object as? NSWindow else { return }
                    self.backgroundWindowRestoration.remove(window)
                    if self.stashedBackgroundWindows.isEmpty { self.clearBackgroundRestoreObservers() }
                }
            }
    }

    /// Restore only after another app regains focus, with a short fallback.
    /// Both callbacks belong to the scheduled generation, never a later stash.
    private func scheduleBackgroundWindowRestore() {
        if let observer = backgroundWindowRestoreObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            backgroundWindowRestoreObserver = nil
        }
        guard let token = backgroundWindowRestoration.schedule() else { return }
        backgroundWindowRestoreObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                    self?.restoreBackgroundWindows(ifCurrent: token)
                }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.restoreBackgroundWindows(ifCurrent: token)
        }
    }

    private func restoreBackgroundWindows(ifCurrent token: UInt64) {
        guard let windows = backgroundWindowRestoration.take(ifCurrent: token) else { return }
        clearBackgroundRestoreObservers()
        for window in windows { window.orderBack(nil) }
    }

    private func restoreBackgroundWindowsNow() {
        let windows = backgroundWindowRestoration.takeNow()
        clearBackgroundRestoreObservers()
        for window in windows { window.orderBack(nil) }
    }

    private func clearBackgroundRestoreObservers() {
        if let observer = backgroundWindowRestoreObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        backgroundWindowRestoreObserver = nil
        if let observer = stashedWindowCloseObserver { NotificationCenter.default.removeObserver(observer) }
        stashedWindowCloseObserver = nil
    }

    private func finishCaptureTimingReport(_ finalLabel: String) -> String? {
        #if DEBUG
        guard let trace = captureTimingTrace else { return nil }
        let report = trace.report(finalLabel: finalLabel)
        captureTimingTrace = nil
        return report
        #else
        captureTimingTrace = nil
        return nil
        #endif
    }

    private func showCaptureTimingDialog(_ report: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Capture Timing"
        alert.informativeText = "Timing for the last screenshot capture."
        alert.addButton(withTitle: "OK")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = report
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.runModal()
    }

    /// Where the next card goes, and in which corner. Screenshots and
    /// recordings share it so they stack in one column rather than landing on
    /// top of each other.
    ///
    /// Cards follow their shot's aspect ratio, so the stacking maths uses the
    /// real height. Padding and gap describe the *card*, but the window is
    /// larger by the transparent shadow margin on every side — counting that
    /// would push the card off the screen edge and space the stack too far
    /// apart. Lay out in card terms, then expand to the window.
    private func nextThumbnailSlot(for image: NSImage)
        -> (x: CGFloat, y: CGFloat, corner: FloatingThumbnailCorner)? {
        guard let screen = NSScreen.preferred else { return nil }
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let corner = thumbnailCorner()
        let margin = FloatingThumbnailController.shadowMargin
        let cardSize = FloatingThumbnailController.thumbnailSize(for: image)
        let xOrigin = thumbnailX(for: cardSize.width, in: screenFrame, corner: corner, padding: padding) - margin

        // Bottom corners stack upward, top corners stack downward.
        var yOrigin = corner.isTop
            ? screenFrame.maxY - cardSize.height - padding - margin
            : screenFrame.minY + padding - margin
        if let topController = thumbnailControllers.last {
            let topCard = topController.windowFrame.insetBy(dx: margin, dy: margin)
            yOrigin = corner.isTop
                ? topCard.minY - gap - cardSize.height - margin
                : topCard.maxY + gap - margin
        }
        return (xOrigin, yOrigin, corner)
    }

    /// The card for a finished recording: poster frame with a play badge, and
    /// actions that operate on the movie rather than on a still.
    private func showRecordingThumbnail(url: URL) {
        let enabled = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        guard enabled else { return }

        Task { @MainActor [weak self] in
            guard let self, let poster = await Self.posterFrame(for: url) else { return }

            let stacking = ThumbnailPlacementPreferences.stacks()
            if !stacking {
                self.thumbnailControllers.forEach { $0.dismiss() }
                self.thumbnailControllers.removeAll()
            }
            guard let slot = self.nextThumbnailSlot(for: poster) else { return }

            let controller = FloatingThumbnailController(videoURL: url, poster: poster)
            controller.onDismiss = { [weak self] in
                self?.thumbnailControllers.removeAll { $0 === controller }
                self?.reflowThumbnails()
            }
            controller.onCopy = { [weak self] in self?.copyRecordingToClipboard(url: url) }
            // The take is already in the save folder by the time this card
            // appears, so Save means "put a copy somewhere else".
            controller.onSave = { [weak self] in self?.promptToSaveRecording(tmpURL: url) }
            controller.onSaveAs = { [weak self] in self?.promptToSaveRecording(tmpURL: url) }
            // Pin takes the poster frame: there is nothing else about a movie
            // that can sit still on the screen.
            controller.onPin = { [weak self] in self?.showPin(image: poster) }
            controller.onEdit = { VideoEditorWindowController.open(url: url) }
            #if !OFFLINE
            controller.onUpload = { [weak self] in self?.uploadRecording(url: url) }
            #endif
            controller.onCloseAll = { [weak self] in
                guard let self else { return }
                // Slide them all out; each leaves the list as it finishes.
                for c in self.thumbnailControllers { c.dismissAnimated() }
            }
            self.thumbnailControllers.append(controller)
            controller.show(at: NSPoint(x: slot.x, y: slot.y), corner: slot.corner)
        }
    }

    /// First frame of a recording, for the thumbnail card. Nil when the movie
    /// has no readable video track — a mic-only take, or a file still being
    /// finalized.
    private static func posterFrame(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        // Not frame zero: a recording often starts on a frame the capture
        // pipeline has not filled in yet, which reads as a black card.
        let time = CMTime(seconds: 0.15, preferredTimescale: 600)
        do {
            let cgImage = try await generator.image(at: time).image
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            // Worth logging: a nil here means the card silently never appears,
            // and the cause is usually a path the sandbox cannot read.
            NSLog("macshot: no poster frame for %@ — %@",
                  url.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData? = nil, historyEntryID: String? = nil) {
        let enabled = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        guard enabled else { return }

        let stacking = ThumbnailPlacementPreferences.stacks()
        if !stacking {
            // Replace mode: dismiss all existing thumbnails
            thumbnailControllers.forEach { $0.dismiss() }
            thumbnailControllers.removeAll()
        }

        guard let slot = nextThumbnailSlot(for: image) else { return }
        let (xOrigin, yOrigin, corner) = slot

        let controller = FloatingThumbnailController(image: image)
        controller.historyEntryID = historyEntryID
        controller.annotationData = annotationData
        controller.onDismiss = { [weak self] in
            self?.thumbnailControllers.removeAll { $0 === controller }
            self?.reflowThumbnails()
        }
        controller.onCopy = { [weak controller] in
            guard let image = controller?.image else { return }
            ImageEncoder.copyToClipboard(image)
        }
        controller.onSave = { [weak self, weak controller] in
            guard let self = self, let image = controller?.image else { return }
            self.saveThumbnailImage(image)
        }
        controller.onSaveAs = { [weak self, weak controller] in
            guard let self = self, let image = controller?.image else { return }
            self.saveThumbnailImageAs(image)
        }
        controller.onPin = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            self.recordThumbnailInHistory(controller)
            self.showPin(image: controller.image)
        }
        controller.onEdit = { [weak controller] in
            guard let controller else { return }
            let image = controller.image
            let id = controller.historyEntryID ?? historyEntryID
            if let data = controller.annotationData {
                DetachedEditorWindowController.open(
                    image: data.rawImage,
                    annotations: data.annotations,
                    historyEntryID: id,
                    editState: data.editState
                )
                return
            }
            if let id,
               let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == id }),
               let editable = ScreenshotHistory.shared.loadEditableCapture(for: entry) {
                DetachedEditorWindowController.open(
                    image: editable.rawImage,
                    annotations: editable.annotations,
                    historyEntryID: id,
                    editState: editable.editState
                )
                return
            }
            // Image already has beautify/effects baked in — disable to avoid double-applying
            DetachedEditorWindowController.open(image: image, historyEntryID: id, disableBeautify: true)
        }
        #if !OFFLINE
        controller.onUpload = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            self.recordThumbnailInHistory(controller)
            self.showUploadProgress(image: controller.image)
        }
        #endif
        controller.onTransform = { [weak controller] transformed in
            if let id = controller?.historyEntryID ?? historyEntryID {
                ScreenshotHistory.shared.updateEntry(id: id, compositedImage: transformed, rawImage: nil, annotations: nil)
            }
        }
        controller.onOCR = { [weak self, weak controller] in
            guard let image = controller?.image else { return }
            self?.runOCR(on: image)
        }
        controller.onDelete = {
            if let id = historyEntryID {
                ScreenshotHistory.shared.removeEntry(id: id)
            }
        }
        controller.onCloseAll = { [weak self] in
            guard let self = self else { return }
            // Slide them all out; each leaves the list as it finishes.
            for c in self.thumbnailControllers { c.dismissAnimated() }
        }
        controller.onSaveAll = { [weak self] in
            self?.saveAllThumbnailsToFolder()
        }
        thumbnailControllers.append(controller)
        controller.show(at: NSPoint(x: xOrigin, y: yOrigin), corner: corner)
    }

    private func saveAllThumbnailsToFolder() {
        let images = thumbnailControllers.map { $0.image }
        guard !images.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder to save \(images.count) screenshot\(images.count == 1 ? "" : "s")"
        panel.level = .floating

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            panel.begin { [weak self] response in
                guard response == .OK, let dirURL = panel.url else { return }
                let rawTemplate = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
                // Ensure batch writes don't collide when the template lacks {index}.
                let template = rawTemplate.contains("{index}") ? rawTemplate : "\(rawTemplate)-{index}"
                let batchDate = Date()

                DispatchQueue.global(qos: .userInitiated).async {
                    for (i, image) in images.enumerated() {
                        guard let data = ImageEncoder.encode(image) else { continue }
                        let base = FilenameFormatter.format(template: template, index: i + 1, date: batchDate)
                        let filename = "\(base).\(ImageEncoder.fileExtension)"
                        let fileURL = dirURL.appendingPathComponent(filename)
                        try? data.write(to: fileURL)
                    }
                    DispatchQueue.main.async {
                        self?.playCopySound()
                        let all = self?.thumbnailControllers ?? []
                        self?.thumbnailControllers.removeAll()
                        for c in all { c.dismiss() }
                    }
                }
            }
        }
    }

    private func reflowThumbnails() {
        // Thumbnails reflow from a timer, which can fire while displays sleep.
        guard let screen = NSScreen.preferred else { return }
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let frame = screen.visibleFrame
        let corner = thumbnailCorner()
        // Positions are card-relative; the window extends past the card by the
        // transparent shadow margin on each side.
        let margin = FloatingThumbnailController.shadowMargin
        var y = corner.isTop ? frame.maxY - padding : frame.minY + padding
        // A card sliding out keeps its place until it is gone; moving it would
        // yank it back into the stack mid-slide.
        for c in thumbnailControllers where !c.isLeaving {
            let card = c.windowFrame.insetBy(dx: margin, dy: margin).size
            let x = thumbnailX(for: card.width, in: frame, corner: corner, padding: padding) - margin
            let yOrigin: CGFloat
            if corner.isTop {
                y -= card.height
                yOrigin = y - margin
                y -= gap
            } else {
                yOrigin = y - margin
                y += card.height + gap
            }
            c.moveTo(origin: NSPoint(x: x, y: yOrigin))
        }
    }

    private func thumbnailCorner() -> FloatingThumbnailCorner {
        ThumbnailPlacementPreferences.corner()
    }

    private func thumbnailX(
        for width: CGFloat,
        in frame: NSRect,
        corner: FloatingThumbnailCorner,
        padding: CGFloat
    ) -> CGFloat {
        corner.isLeft ? frame.minX + padding : frame.maxX - width - padding
    }

    /// Pin and Upload keep what they act on in history. A card from a normal
    /// capture already has its entry; writing another one listed the same shot
    /// twice in Recent Captures. Only a card without a live entry gets one.
    private func recordThumbnailInHistory(_ controller: FloatingThumbnailController) {
        if let id = controller.historyEntryID, ScreenshotHistory.shared.containsEntry(id: id) { return }
        let data = controller.annotationData
        controller.historyEntryID = ScreenshotHistory.shared.add(
            image: controller.image,
            rawImage: data?.rawImage,
            annotations: data?.annotations,
            editState: data?.editState
        )
    }

    /// Update a floating thumbnail's image if it matches the given history entry.
    func refreshThumbnail(for entryID: String, image: NSImage, annotationData: CaptureAnnotationData? = nil) {
        for tc in thumbnailControllers where tc.historyEntryID == entryID {
            tc.updateImage(image, annotationData: annotationData)
        }
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        Self.captureSound?.stop()
        Self.captureSound?.play()
    }

    func runOCR(on image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
                    let shouldCopy = ocrAction == 0 || ocrAction == 2
                    let shouldShowWindow = ocrAction == 0 || ocrAction == 1

                    if shouldCopy && !result.copyText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.copyText, forType: .string)
                    }

                    if shouldShowWindow {
                        self.ocrController?.close()
                        let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
                        // Drop our reference when the window closes (incl. red-X),
                        // but only if it's still this controller (a newer OCR run
                        // may have replaced it).
                        ocr.onClose = { [weak self, weak ocr] in
                            if self?.ocrController === ocr { self?.ocrController = nil }
                        }
                        self.ocrController = ocr
                        ocr.show()
                    }
                }
            }
        }
    }

    private func saveThumbnailImage(_ image: NSImage) {
        ImageSaveService.save(image, panelLevel: .floating, activateApp: true) { [weak self] url in
            guard let url else { return }
            self?.playCopySound()
            Self.showSavedToast(for: url)
        }
    }

    private func saveThumbnailImageAs(_ image: NSImage) {
        ImageSaveService.showSavePanel(for: image, panelLevel: .floating, activateApp: true) { [weak self] url in
            guard let url else { return }
            self?.playCopySound()
            Self.showSavedToast(for: url)
        }
    }

    /// Confirmation for a completed save: where the file went, plus a way to go
    /// there. The path is tilde-abbreviated — a bare filename does not say which
    /// folder it landed in, and the full absolute path is mostly home directory.
    ///
    /// Reveals in Finder rather than opening the file: the app is sandboxed and
    /// reached the save folder through a security-scoped bookmark it has already
    /// relinquished, so `NSWorkspace.open` on that path is refused. Revealing is
    /// performed by Finder, which needs no grant of ours.
    static func showSavedToast(for url: URL) {
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        ToastCenter.shared.show(
            String(format: L("Saved to %@"), path),
            action: .init(title: L("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
    }

    private func saveImageToConfiguredFolder(_ image: NSImage) {
        ImageSaveService.saveToConfiguredFolder(image, panelLevel: .floating, activateApp: true)
    }

    #if !OFFLINE
    // MARK: - Upload

    func uploadImage(_ image: NSImage) {
        showUploadProgress(image: image)
    }
    #endif

    @objc private func pinFromHistory(_ notification: Notification) {
        guard let image = notification.object as? NSImage else { return }
        showPin(image: image)
    }

    /// Reports a failure the user needs to know about. Losing a capture without
    /// any indication is worse than any error message.
    func showFailureToast(_ message: String) {
        ToastCenter.shared.show(message, icon: .info, duration: 6)
    }

    func showPin(image: NSImage) {
        let pin = PinWindowController(image: image)
        pin.delegate = self
        pin.show()
        pinControllers.append(pin)
    }

    #if !OFFLINE
    /// Upload a finished recording, mirroring `showUploadProgress(image:)`.
    /// imgbb takes images only, so it is not offered a movie.
    func uploadRecording(url: URL) {
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"

        func fail(_ message: String) {
            ToastCenter.shared.show(message, icon: .info, duration: 3.5)
        }
        func succeed(_ link: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            ToastCenter.shared.show(
                String(format: L("Link copied: %@"), link),
                action: URL(string: link).map { target in
                    .init(title: L("Open")) { NSWorkspace.shared.open(target) }
                },
                duration: 2.2)
        }
        func finish(_ result: Result<String, Error>) {
            switch result {
            case .success(let link): succeed(link)
            case .failure(let error): fail(error.localizedDescription)
            }
        }

        switch provider {
        case "gdrive":
            guard GoogleDriveUploader.shared.isSignedIn else {
                fail(L("Google Drive not signed in")); return
            }
            ToastCenter.shared.show(L("Uploading…"), icon: .info, duration: 120)
            GoogleDriveUploader.shared.uploadVideo(url: url, completion: finish)
        case "s3":
            guard S3Uploader.shared.isConfigured else {
                fail(L("S3 not configured — check Settings")); return
            }
            ToastCenter.shared.show(L("Uploading…"), icon: .info, duration: 120)
            S3Uploader.shared.uploadVideo(url: url, completion: finish)
        case "github":
            guard GitHubUploader.shared.isConfigured else {
                fail(L("GitHub upload is not configured — check Settings.")); return
            }
            ToastCenter.shared.show(L("Uploading…"), icon: .info, duration: 120)
            GitHubUploader.shared.uploadVideo(url: url, completion: finish)
        default:
            fail(L("Video upload requires Google Drive, S3 or GitHub"))
        }
    }

    private func showUploadProgress(image: NSImage) {
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"

        // Every upload state goes through the app-wide toast, the same surface
        // saving and copying use. The bespoke upload panel it replaces was the
        // only piece of chrome in the app with its own progress bar and layout.
        func fail(_ message: String) {
            ToastCenter.shared.show(message, icon: .info, duration: 3.5)
        }
        func succeed(_ link: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(link, forType: .string)
            // Show the link itself: it is the result of the upload, and seeing
            // it is how the user checks it went to the right host and path.
            ToastCenter.shared.show(
                String(format: L("Link copied: %@"), link),
                action: URL(string: link).map { target in
                    .init(title: L("Open")) { NSWorkspace.shared.open(target) }
                },
                duration: 2.2)
        }

        if provider == "gdrive" && !GoogleDriveUploader.shared.isSignedIn {
            fail(L("Google Drive not signed in")); return
        }
        if provider == "s3" && !S3Uploader.shared.isConfigured {
            fail(L("S3 not configured — check Settings")); return
        }
        if provider == "github" && !GitHubUploader.shared.isConfigured {
            fail(L("GitHub upload is not configured — check Settings.")); return
        }

        // Held open until a result replaces it — the toast has no progress bar,
        // so the duration is just "long enough not to vanish mid-upload".
        ToastCenter.shared.show(L("Uploading…"), icon: .info, duration: 120)

        switch provider {
        case "gdrive":
            GoogleDriveUploader.shared.uploadImage(image) { result in
                switch result {
                case .success(let link): succeed(link)
                case .failure(let error): fail(error.localizedDescription)
                }
            }
        case "github":
            GitHubUploader.shared.uploadImage(image) { result in
                switch result {
                case .success(let link): succeed(link)
                case .failure(let error): fail(error.localizedDescription)
                }
            }
        case "s3":
            S3Uploader.shared.uploadImage(image) { result in
                switch result {
                case .success(let link): succeed(link)
                case .failure(let error): fail(error.localizedDescription)
                }
            }
        default:
            ImageUploader.upload(image: image) { result in
                switch result {
                case .success(let uploadResult):
                    var uploads = UserDefaults.standard.array(forKey: "imgbbUploads") as? [[String: String]] ?? []
                    uploads.append([
                        "deleteURL": uploadResult.deleteURL,
                        "link": uploadResult.link,
                    ])
                    UserDefaults.standard.set(uploads, forKey: "imgbbUploads")
                    succeed(uploadResult.link)
                case .failure(let error):
                    fail(error.localizedDescription)
                }
            }
        }
    }
    #endif

    // MARK: - Open Image

    @objc private func openImageFromMenu() {
        openImageWithPanel()
    }

    @objc private func openImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            let alert = NSAlert()
            alert.messageText = L("No Image on Clipboard")
            alert.informativeText = L("Copy an image to the clipboard first, then try again.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }
        DetachedEditorWindowController.open(image: image)
    }

    @objc private func pinFromClipboard() {
        guard let item = NSPasteboard.general.pasteboardItems?.first else {
            showNoPinClipboardContentAlert()
            return
        }

        switch ClipboardPinService.image(from: item) {
        case .image(let image):
            showPin(image: image)
        case .unsupported:
            showNoPinClipboardContentAlert()
        }
    }

    private func showNoPinClipboardContentAlert() {
        let alert = NSAlert()
        alert.messageText = L("No Image or Text on Clipboard")
        alert.informativeText = L("Copy an image or text to the clipboard first, then try again.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    private func openImageWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .webP, .image]
        panel.message = "Choose an image to open in macshot editor"

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openImageFile(url: url)
            }
        }
    }

    private func openImageFile(url: URL) {
        let image: NSImage
        if url.pathExtension.lowercased() == "webp",
           let data = try? Data(contentsOf: url),
           let decoded = try? WebPDecoder().decode(toNSImage: data, options: WebPDecoderOptions()) {
            image = decoded
        } else if let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            return
        }
        DetachedEditorWindowController.open(image: image)
    }

    /// Open a history entry in the editor by its id, restoring editable annotations when
    /// available (falls back to the flattened image, like the history overlay does). Lets
    /// external tools re-open a specific capture for editing — `macshot://edit?id=<id>` —
    /// without flattening it, which `open?file=` cannot do.
    private func openHistoryEntryInEditor(id: String) {
        guard let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == id }) else { return }

        if entry.hasAnnotations,
           let editable = ScreenshotHistory.shared.loadEditableCapture(for: entry) {
            DetachedEditorWindowController.open(
                image: editable.rawImage,
                annotations: editable.annotations,
                historyEntryID: id,
                editState: editable.editState
            )
            return
        }

        // Fall back to the flattened image — beautify already baked in.
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }
        DetachedEditorWindowController.open(image: image, historyEntryID: id, disableBeautify: true)
    }

    @objc private func showRecordingsInFinder() {
        let folder = RecordingSessionStore.rootURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            showFailureToast(error.localizedDescription)
        }
    }

    // MARK: - Open Video

    @objc private func openVideoFromMenu() {
        openVideoWithPanel()
    }

    private func openVideoWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie, .video, .gif]
        panel.message = L("Choose a video to open in macshot editor")

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openVideoFile(url: url)
            }
        }
    }

    private func openVideoFile(url: URL) {
        // Never let the editor delete the user's source file on close.
        VideoEditorWindowController.open(url: url, deleteOnClose: false)
    }

    /// Handle files opened via Finder "Open With", drag-to-dock, or command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReadyForOpenRequests else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        handleOpenURLs(urls)
    }

    private func handleOpenURLs(_ urls: [URL]) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "heif", "webp", "icns"]
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        for url in urls {
            if url.scheme == "macshot" {
                let urlSchemeEnabled = UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true
                guard urlSchemeEnabled else { continue }
                if Self.screenCaptureURLActions.contains(url.host ?? "") {
                    if !isReadyForScreenCaptureURLs,
                       PermissionOnboardingController.hasScreenRecordingPermission() {
                        markScreenCaptureURLsReady()
                    }
                    if !isReadyForScreenCaptureURLs {
                        pendingScreenCaptureURLs.append(url)
                        showOnboarding()
                        continue
                    }
                }
                handleURLSchemeAction(url)
                continue
            }
            let ext = url.pathExtension.lowercased()
            // GIFs can be opened in either the image editor or the video
            // editor. Default to image editor (matches prior behavior) — users
            // wanting to trim a GIF use "Open Video..." explicitly.
            if imageExtensions.contains(ext) {
                openImageFile(url: url)
            } else if videoExtensions.contains(ext) {
                openVideoFile(url: url)
            }
        }
    }

    /// Handle macshot:// URL scheme actions from external tools (Raycast, Alfred, etc.).
    /// Usage: `open macshot://capture`, `open macshot://ocr`, etc.
    private static let screenCaptureURLActions: Set<String> = [
        "capture", "capture-fullscreen", "capture-last", "quick-capture",
        "ocr", "ocr-translate", "record", "record-fullscreen", "scroll-capture",
    ]

    private func handleURLSchemeAction(_ url: URL) {
        guard let action = url.host else { return }
        switch action {
        case "capture":             captureScreen()
        case "capture-fullscreen":  captureFullScreen()
        case "quick-capture":       quickCapture()
        case "ocr":                 captureOCR()
        case "ocr-translate":
            // ?target=<lang code, e.g. zh-CN>; omitted → saved default language.
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "target" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            beginCaptureTranslate(target: (target?.isEmpty == false) ? target : nil, fromMenu: true)
        case "record":              recordArea()
        case "record-fullscreen":   recordFullScreen()
        case "scroll-capture":      scrollCapture()
        case "history":             showHistoryOverlay()
        case "settings":            openSettings()
        case "stop-recording":      stopRecording()
        case "capture-last":        captureLastArea()
        case "open":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "file" })?.value {
                openImageFile(url: URL(fileURLWithPath: path))
            }
        case "edit":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let id = components.queryItems?.first(where: { $0.name == "id" })?.value {
                openHistoryEntryInEditor(id: id)
            }
        default: break
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
            settingsController?.onHotkeyChanged = { [weak self] in
                self?.registerHotkey()
                self?.rebuildStatusBarMenu()
            }
            settingsController?.onEditorCommandShortcutChanged = { [weak self] in
                self?.setupMainMenu()
            }
        }
        settingsController?.showWindow()
    }

    // MARK: - Quit

    @objc private func checkForUpdates() {
        // `updaterController` is nil when updates are off; the menu item is hidden then, but
        // the URL-scheme handler can also reach this.
        guard BuildVariant.softwareUpdatesEnabled, let updaterController else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "betaUpdatesEnabled") ? ["beta"] : []
    }
}

// MARK: - OverlayWindowControllerDelegate

extension AppDelegate: OverlayWindowControllerDelegate {
    func overlayDidCancel(_ controller: OverlayWindowController) {
        // If the user cancels while in recording setup (before capture started),
        // just dismiss. If recording is actively capturing, stop it.
        if controller === recordingOverlayController, let engine = recordingEngine {
            engine.stopRecording()
            // stopRecordingUI() will be called by onCompletion callback
        }
        dismissOverlays()

        // Focus is returned to the previous app by dismissOverlays() above.
    }

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?) {
        captureTimingTrace?.mark("overlayDidConfirm entered image=\(capturedImage != nil)")
        dismissOverlays()
        captureTimingTrace?.mark("overlayDidConfirm after dismissOverlays")
        if let image = capturedImage {
            let entryID = ScreenshotHistory.shared.add(
                image: image,
                rawImage: annotationData?.rawImage,
                annotations: annotationData?.annotations,
                editState: annotationData?.editState,
                windowTitle: capturedWindowTitle)
            captureTimingTrace?.mark("screenshot added to history")
            // Defer thumbnail to next runloop cycle so overlay teardown completes first
            // and the main thread is free for the next capture trigger
            let annData = annotationData
            DispatchQueue.main.async { [weak self] in
                self?.showFloatingThumbnail(image: image, annotationData: annData, historyEntryID: entryID)
            }

            // "Also open in Editor" preference — open with history entry ID so Done saves back
            if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
                if let data = annotationData {
                    DetachedEditorWindowController.open(
                        image: data.rawImage,
                        annotations: data.annotations,
                        historyEntryID: entryID,
                        editState: data.editState
                    )
                } else {
                    DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
                }
            }

            if let report = finishCaptureTimingReport("timing report generated") {
                DispatchQueue.main.async { [weak self] in
                    self?.showCaptureTimingDialog(report)
                }
            }
        }
    }

    private func stitchCrossScreenCapture(primary: OverlayWindowController, others: [OverlayWindowController]) -> NSImage? {
        let primaryOrigin = primary.screen.frame.origin
        let primarySelRect = primary.selectionRect
        // Global selection rect
        let globalRect = NSRect(x: primarySelRect.origin.x + primaryOrigin.x,
                                y: primarySelRect.origin.y + primaryOrigin.y,
                                width: primarySelRect.width, height: primarySelRect.height)

        // Determine scale from primary screen
        let scale: CGFloat
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = primary.screen.backingScaleFactor
        }

        let pixelW = Int(globalRect.width * scale)
        let pixelH = Int(globalRect.height * scale)
        // Use the source image's color space to avoid expensive conversion
        let cs: CGColorSpace
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard let cgCtx = CGContext(data: nil, width: pixelW, height: pixelH,
                                     bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        cgCtx.scaleBy(x: scale, y: scale)

        // Draw each screen's contribution
        let allControllers = [primary] + others
        for controller in allControllers {
            guard let screenshot = controller.screenshotImage else { continue }
            let screenFrame = controller.screen.frame
            // Where this screen sits relative to the global selection rect
            let drawX = screenFrame.origin.x - globalRect.origin.x
            let drawY = screenFrame.origin.y - globalRect.origin.y
            let drawRect = NSRect(x: drawX, y: drawY, width: screenFrame.width, height: screenFrame.height)

            cgCtx.saveGState()
            // Clip to only the portion within our output bounds
            cgCtx.clip(to: CGRect(x: 0, y: 0, width: globalRect.width, height: globalRect.height))
            let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            cgCtx.restoreGState()
        }

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?) {
        ScreenshotHistory.shared.add(
            image: image,
            rawImage: annotationData?.rawImage,
            annotations: annotationData?.annotations,
            editState: annotationData?.editState,
            windowTitle: capturedWindowTitle
        )
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        let pin = PinWindowController(image: image)
        pin.delegate = self
        pin.show()
        pinControllers.append(pin)
        // Return focus to previous app — pin stays visible (hidesOnDeactivate=false, orderFrontRegardless)
        if let app = appToRefocus, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }

    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?) {
        // OCR & QR action: 0 = window + copy (default), 1 = window only, 2 = copy only
        let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
        let shouldCopy = ocrAction == 0 || ocrAction == 2
        let shouldShowWindow = ocrAction == 0 || ocrAction == 1
        dismissOverlays(refocusPreviousApp: !shouldShowWindow)

        if shouldCopy && !result.copyText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.copyText, forType: .string)
        }

        if shouldShowWindow {
            ocrController?.close()
            let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
            ocr.onClose = { [weak self, weak ocr] in
                if self?.ocrController === ocr { self?.ocrController = nil }
            }
            ocrController = ocr
            ocr.show()
        }
    }

    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?) {
        #if !OFFLINE
        ScreenshotHistory.shared.add(
            image: image,
            rawImage: annotationData?.rawImage,
            annotations: annotationData?.annotations,
            editState: annotationData?.editState,
            windowTitle: capturedWindowTitle
        )
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        showUploadProgress(image: image)
        // Return focus — upload toast stays visible (hidesOnDeactivate=false)
        if let app = appToRefocus, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
        #endif
    }

    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        recordingScreenRect = rect
        recordingScreen = screen

        // Capture session overrides before dismissing overlays (which destroys the overlay view)
        let fpsOverride = controller.sessionRecordingFPS
        let onStopOverride = controller.sessionRecordingOnStop
        let delayOverride = controller.sessionRecordingDelay
        let hideHUD = controller.sessionHideRecordingHUD ?? UserDefaults.standard.bool(forKey: "hideRecordingHUD")

        // Detach webcam preview before dismissing overlays so we can reuse the live session
        let existingWebcam = controller.detachWebcamPreview()

        let delay = delayOverride ?? UserDefaults.standard.integer(forKey: "captureDelaySeconds")

        // Put the region marker up BEFORE the overlay comes down. Both draw
        // the same scrim outside the selection; dismissing first and building
        // the marker a run loop later left one frame with no scrim at all,
        // which reads as the whole screen flashing just as recording starts.
        //
        // Safe to do ahead of the dismiss: the marker is a non-titled panel
        // with hidesOnDeactivate off, so neither the activation-policy change
        // nor activating the previous app disturbs it. The countdown path
        // builds its own marker, so skip it when there is a delay.
        if delay == 0 {
            selectionBorderOverlay?.close()
            let border = SelectionBorderOverlay(screen: screen)
            border.setSelectionRect(rect)
            border.orderFrontRegardless()
            selectionBorderOverlay = border
        }

        // Use the same focus return path as normal screenshot confirm:
        // dismissOverlays with refocus → returnFocusIfNeeded.
        // This reliably transfers focus AND mouse event routing.
        // Then create the rest of the recording UI on the next run loop — all
        // non-activating panels, so they appear without stealing focus back.
        dismissOverlays()  // refocusPreviousApp: true (default) — handles focus
        previousApp = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if delay > 0 {
                existingWebcam?.stopPreview()
                existingWebcam?.close()
                self.startRecordingCountdown(seconds: delay, rect: rect, screen: screen,
                                        fpsOverride: fpsOverride,
                                        onStopOverride: onStopOverride)
            } else {
                self.beginRecording(rect: rect, screen: screen,
                               fpsOverride: fpsOverride,
                               onStopOverride: onStopOverride,
                               existingWebcam: existingWebcam,
                               hideHUD: hideHUD)
            }
        }
    }

    private func startRecordingCountdown(seconds: Int, rect: NSRect, screen: NSScreen,
                                          fpsOverride: Int?,
                                          onStopOverride: String?) {
        let size = NSSize(width: 140, height: 140)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        // Show selection border during countdown so user sees what area will be recorded
        let border = SelectionBorderOverlay(screen: screen)
        border.setSelectionRect(rect)
        border.orderFrontRegardless()
        selectionBorderOverlay = border

        // Escape to cancel
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelRecordingCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.removeDelayEscMonitors()
                self?.beginRecording(rect: rect, screen: screen,
                                     fpsOverride: fpsOverride,
                                     onStopOverride: onStopOverride)
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func cancelRecordingCountdown() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        removeDelayEscMonitors()
    }

    private func beginRecording(rect: NSRect, screen: NSScreen,
                                 fpsOverride: Int?,
                                 onStopOverride: String?,
                                 existingWebcam: WebcamOverlay? = nil,
                                 hideHUD: Bool = false) {
        let engine = RecordingEngine()
        engine.onProgress = { [weak self] seconds in
            self?.updateRecordingHUD(seconds: seconds)
        }
        // Capture audio settings before recording starts (they may change during)
        let hadSystemAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio")
        let hadMicAudio = UserDefaults.standard.bool(forKey: "recordMicAudio")

        engine.onCompletion = { [weak self] url, error in
            guard let self = self else { return }
            self.stopRecordingUI()
            if self.terminatingAfterRecording {
                self.terminatingAfterRecording = false
                self.recordingTerminationWaiter?.resume()
                self.recordingTerminationWaiter = nil
                return
            }

            if let error = error {
                // Interrupted capture can still have a playable partial file.
                // Explain the interruption while delivering that file below.
                self.showFailureToast(String(format: L("Recording failed: %@"), error.localizedDescription))
            }

            if let url = url {
                let deliverRecording: (URL) -> Void = { [weak self] finalURL in
                    guard let self = self else { return }
                    let onStop = onStopOverride ?? UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
                    // Publish first, whatever happens next: a recording belongs
                    // in the save folder the same way a screenshot does. The
                    // original take stays in the recording library either way.
                    self.publishRecording(finalURL) { [weak self] publishedURL in
                        guard let self = self else { return }
                        // Everything macshot opens itself reads the library
                        // original. The published copy sits outside the
                        // sandbox, reachable only through the save's
                        // security-scoped lease — and that lease dies with the
                        // save. Anything asynchronous (the card's poster frame
                        // is generated with `await`) finds it unreadable and
                        // silently gives up. Finder needs no scope from us, so
                        // it is the one thing pointed at the published copy.
                        self.showRecordingThumbnail(url: finalURL)
                        switch onStop {
                        case "finder":
                            NSWorkspace.shared.activateFileViewerSelecting([publishedURL])
                        case "clipboard":
                            self.copyRecordingToClipboard(url: finalURL)
                        default:
                            VideoEditorWindowController.open(url: finalURL)
                        }
                    }
                }

                // Offer audio merge when both mic + system audio were recorded
                if hadSystemAudio && hadMicAudio {
                    let merger = AudioMergeController()
                    let mergeID = UUID()
                    self.audioMergeControllers[mergeID] = merger
                    merger.show(url: url) { [weak self] finalURL in
                        self?.audioMergeControllers.removeValue(forKey: mergeID)
                        deliverRecording(finalURL)
                    }
                } else {
                    deliverRecording(url)
                }
            }
        }
        recordingEngine = engine

        // Always show selection border so user knows what area is being recorded.
        // Reuse the one already up — from the countdown, or from the start of
        // this request — rather than closing and rebuilding it, which would
        // blink the scrim off and on again for a frame.
        if let existing = selectionBorderOverlay {
            existing.setSelectionRect(rect)
            existing.orderFrontRegardless()
        } else {
            let border = SelectionBorderOverlay(screen: screen)
            border.setSelectionRect(rect)
            border.orderFrontRegardless()
            selectionBorderOverlay = border
        }

        if !hideHUD {
            // Show the floating timer HUD
            let hud = RecordingHUDPanel()
            hud.update(elapsedSeconds: 0)
            hud.positionOnScreen(relativeTo: rect, screen: screen)
            hud.onStopRecording = { [weak self] in
                self?.stopRecording()
            }
            hud.onPauseRecording = { [weak self] in
                self?.recordingEngine?.pauseRecording()
            }
            hud.onResumeRecording = { [weak self] in
                self?.recordingEngine?.resumeRecording()
            }
            hud.orderFrontRegardless()
            recordingHUDPanel = hud

            engine.onPauseChanged = { [weak self] paused in
                self?.recordingHUDPanel?.setPaused(paused)
            }
        }

        // Start mouse highlight overlay if enabled (requires Input Monitoring permission)
        if UserDefaults.standard.bool(forKey: "recordMouseHighlight") && CGPreflightListenEventAccess() {
            let overlay = MouseHighlightOverlay(screen: screen)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            mouseHighlightOverlay = overlay
        }

        // Start keystroke overlay if enabled
        if UserDefaults.standard.bool(forKey: "recordKeystroke") && KeystrokeOverlay.hasInputMonitoringPermission {
            let overlay = KeystrokeOverlay(screen: screen)
            overlay.setRecordingRect(rect)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            keystrokeOverlay = overlay
        }

        // Start webcam overlay if enabled — reuse existing session to avoid camera restart flash
        if UserDefaults.standard.bool(forKey: "recordWebcam") &&
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            if let existing = existingWebcam {
                // Reuse the live preview — just lock it in place
                existing.setDraggable(false)
                existing.orderFrontRegardless()
                webcamOverlay = existing
            } else {
                let overlay = WebcamOverlay(screen: screen)
                let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
                let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle
                overlay.configure(
                    position: position, size: WebcamSize.savedPoints,
                    shape: shape, recordingRect: rect)
                overlay.startPreview(deviceUID: UserDefaults.standard.string(forKey: "selectedCameraDeviceUID"))
                overlay.setDraggable(false)
                overlay.orderFrontRegardless()
                webcamOverlay = overlay
            }
        } else {
            // Webcam not enabled — clean up any detached preview
            existingWebcam?.stopPreview()
            existingWebcam?.close()
        }

        // Turn menu bar icon into a stop button (ensure it's visible even if user hid it)
        enterRecordingMenuBarMode()

        // Collect window IDs of UI chrome to exclude from the recording
        // (selection border + HUD). Webcam, mouse highlight, and keystroke
        // overlays are intentionally captured.
        var excludeIDs: [CGWindowID] = []
        if let w = selectionBorderOverlay { excludeIDs.append(CGWindowID(w.windowNumber)) }
        if let w = recordingHUDPanel { excludeIDs.append(CGWindowID(w.windowNumber)) }

        // Start recording
        engine.startRecording(rect: rect, screen: screen, fpsOverride: fpsOverride, excludeWindowNumbers: excludeIDs)
    }

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {
        if let engine = recordingEngine {
            engine.stopRecording()
        } else {
            // Recording mode was entered but capture never started — just dismiss
            dismissOverlays()
        }
    }

    // MARK: - Recording UI

    @objc private func stopRecording() {
        guard let engine = recordingEngine else { return }
        engine.stopRecording()
    }

    private func updateRecordingHUD(seconds: Int) {
        recordingHUDPanel?.update(elapsedSeconds: seconds)
        if let screen = recordingScreen, !(recordingHUDPanel?.userHasDragged ?? false) {
            recordingHUDPanel?.positionOnScreen(relativeTo: recordingScreenRect, screen: screen)
        }
    }

    private func enterRecordingMenuBarMode() {
        menuBarIconWasHidden = UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        if menuBarIconWasHidden {
            setMenuBarIconVisible(true)
        }
        // Replace menu with a single stop action, change icon to stop symbol
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.image?.isTemplate = true
            let side = Self.statusBarSymbolSize
            button.image?.size = NSSize(width: side, height: side)
        }
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(stopRecording)
    }

    private func exitRecordingMenuBarMode() {
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()

        // Hide icon again if user had it hidden before recording
        if menuBarIconWasHidden {
            setMenuBarIconVisible(false)
            menuBarIconWasHidden = false
        }
    }

    /// Copy a recording to a user-visible directory
    /// and reveal it in Finder. Used by the `recordingOnStop = "finder"`
    /// flow so the user doesn't end up staring at a deep sandbox path.
    ///
    /// Resolution order:
    ///   1. The save folder from Settings (if its bookmark is still valid)
    ///   2. Save panel — user picks a location explicitly
    ///
    /// On a collision at the destination, we append " (N)" to the filename
    /// so nothing gets silently overwritten.
    private func revealRecordingInFinder(tmpURL: URL) {
        publishRecording(tmpURL) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Copy a finished recording into the configured save folder, the way a
    /// screenshot is saved, and report where it landed.
    ///
    /// Every recording goes through here, not just "Show in Finder". A take
    /// used to stay in the recording library — a UUID directory under
    /// Application Support — unless that one option was picked, so the folder
    /// set under Output did nothing for the other two.
    ///
    /// With no folder configured, or if the copy fails, the completion still
    /// runs with the library URL: the take is never lost, it just has not been
    /// published anywhere the user can see.
    private func publishRecording(_ source: URL, completion: @escaping (URL) -> Void) {
        guard let directory = SaveDirectoryAccess.resolveIfAccessible() else {
            promptToSaveRecording(tmpURL: source)
            completion(source)
            return
        }
        let access = SaveDirectoryLease(alreadyAccessing: directory)
        saveRecordingCopy(source: source,
                          destination: directory.appendingPathComponent(source.lastPathComponent),
                          avoidCollisions: true, access: access,
                          onSuccess: { url in
                              AppDelegate.showSavedToast(for: url)
                              completion(url)
                          },
                          onFailure: { [weak self] error in
                              guard !(error is CancellationError) else { return }
                              if self?.terminationCoordinator.isWaiting != true {
                                  self?.promptToSaveRecording(tmpURL: source)
                              } else {
                                  self?.showFailureToast(L("Save failed") + ": " + error.localizedDescription)
                              }
                              completion(source)
                          })
    }

    /// Cancelling Save leaves the original in the recording library.
    private func promptToSaveRecording(tmpURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tmpURL.lastPathComponent
        panel.title = L("Save Recording")
        panel.prompt = L("Save")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.saveRecordingCopy(source: tmpURL, destination: destination, avoidCollisions: false) { [weak self] error in
                guard !(error is CancellationError) else { return }
                self?.showFailureToast(L("Save failed") + ": " + error.localizedDescription)
            }
        }
    }

    private func saveRecordingCopy(source: URL, destination: URL, avoidCollisions: Bool,
                                   access: SaveDirectoryLease? = nil,
                                   onSuccess: ((URL) -> Void)? = nil,
                                   onFailure: @escaping (Error) -> Void) {
        var publishedURL = destination
        let job = MediaExportCoordinator.shared.start(title: destination.lastPathComponent, status: L("Saving..."),
            operation: { cancellation, progress in
                publishedURL = try await MediaExportIO.perform {
                    try cancellation.check()
                    var selectedURL = destination
                    if avoidCollisions {
                        let base = destination.deletingPathExtension().lastPathComponent
                        let ext = destination.pathExtension
                        var counter = 2
                        while FileManager.default.fileExists(atPath: selectedURL.path), counter <= 1000 {
                            selectedURL = destination.deletingLastPathComponent()
                                .appendingPathComponent("\(base) (\(counter)).\(ext)")
                            counter += 1
                        }
                    }
                    let save = try AtomicMediaSave(destinationURL: selectedURL)
                    try save.copySource(source, checkCancellation: cancellation.check, progress: progress)
                    // Exclusive publication also protects a file created after
                    // the name check. Every failure retains the durable take.
                    try save.commit(overwritingExisting: !avoidCollisions,
                                    beforePublish: cancellation.beginPublication)
                    return selectedURL
                }
            }, completion: { result in
                withExtendedLifetime(access) {}
                switch result {
                case .success:
                    if let onSuccess {
                        onSuccess(publishedURL)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([publishedURL])
                    }
                case .failure(let error): onFailure(error)
                }
            })
        MediaExportProgressController.show(for: job)
    }

    private func copyRecordingToClipboard(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Each take has a durable, unique URL. A later copy must not replace
        // the bytes behind an earlier clipboard/history reference.
        let ext = url.pathExtension.lowercased()
        let pasteURL = url
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max

        if ext == "gif", byteCount <= 32_000_000, let data = try? Data(contentsOf: pasteURL) {
            // Write raw GIF data so apps can render the animation inline
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            // Also add file URL for Finder compatibility
            item.setString(pasteURL.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            // MP4: write file URL (apps like Slack/Discord accept file drops)
            pasteboard.writeObjects([pasteURL as NSURL])
        }
        playCopySound()
    }

    private func stopRecordingUI() {
        recordingHUDPanel?.close()
        recordingHUDPanel = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        mouseHighlightOverlay?.stopMonitoring()
        mouseHighlightOverlay?.close()
        mouseHighlightOverlay = nil
        keystrokeOverlay?.stopMonitoring()
        keystrokeOverlay?.close()
        keystrokeOverlay = nil
        webcamOverlay?.stopPreview()
        webcamOverlay?.close()
        webcamOverlay = nil
        recordingEngine = nil
        recordingOverlayController = nil
        recordingScreenRect = .zero
        recordingScreen = nil
        exitRecordingMenuBarMode()
    }

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        // One session at a time; a second would orphan the first's HUD, event
        // tap and key monitor. (Other screens' overlays are dismissed when a
        // session starts, so this is a backstop.)
        guard scrollCaptureController == nil else { return }
        if !AXIsProcessTrusted() {
            dismissOverlays()
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            let alert = NSAlert()
            alert.messageText = L("Accessibility Access Required")
            alert.informativeText = L("macshot needs Accessibility permission for scroll capture. Please grant access in System Settings, then try again.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Open Settings"))
            alert.addButton(withTitle: L("Cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        scrollCaptureOverlayController = controller

        // The other screens' overlays stayed up — frozen, dimmed, clickable,
        // and still in scroll-capture mode — so a click on one started a
        // second session over this one. The first session's HUD, its event
        // tap (which swallows mouse-moved system-wide) and its Esc monitor
        // were then never removed until quit. The capture happens on this
        // screen only; the rest go back to the live desktop.
        for other in overlayControllers where other !== controller {
            other.dismiss()
        }
        overlayControllers.removeAll { $0 !== controller }

        let scc = ScrollCaptureController(captureRect: rect, screen: screen)
        scc.excludedWindowIDs = overlayControllers.map { $0.windowNumber }
        scrollCaptureController = scc

        // Read max height for the overlay HUD progress bar
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? ScrollCaptureController.defaultMaxScrollHeight

        // Tell the triggering overlay to enter scroll capture mode
        controller.setScrollCaptureState(isActive: true, maxHeight: maxH)

        // Create live preview panel if there's space beside the capture region
        let overlayLevel = 257  // matches overlay window level
        if let previewPanel = ScrollCapturePreviewPanel(captureRect: rect, screen: screen, overlayLevel: overlayLevel) {
            previewPanel.orderFront(nil)
            scrollCapturePreviewPanel = previewPanel
        }

        scc.onStripAdded = { [weak self, weak controller] count in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: count, pixelSize: scc.stitchedPixelSize,
                autoScrolling: scc.autoScrollActive)
        }
        scc.onPreviewUpdated = { [weak self] image in
            self?.scrollCapturePreviewPanel?.updatePreview(image: image)
        }
        scc.onAutoScrollStarted = { [weak self, weak controller] in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
                autoScrolling: true)
        }
        scc.onSessionDone = { [weak self] finalImage in
            self?.handleScrollCaptureCompleted(finalImage: finalImage)
        }

        Task { await scc.startSession() }
    }

    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {
        scrollCaptureController?.stopSession()
        // onSessionDone fires asynchronously via handleScrollCaptureCompleted
    }

    func overlayDidRequestCancelScrollCapture(_ controller: OverlayWindowController) {
        // Esc cancels scroll capture: tear down WITHOUT delivering an image
        // (cancelSession never fires onSessionDone), so nothing is saved, copied,
        // or added to history. Mirrors the Accessibility-denied teardown block.
        let captureController = scrollCaptureController
        scrollCaptureController = nil
        // Detach callbacks first so even an already-in-flight initial capture
        // cannot report completion after cancellation.
        captureController?.onStripAdded = nil
        captureController?.onPreviewUpdated = nil
        captureController?.onAutoScrollStarted = nil
        captureController?.onSessionDone = nil
        captureController?.cancelSession()
        scrollCapturePreviewPanel?.close()
        scrollCapturePreviewPanel = nil
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        dismissOverlays()
    }

    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        let alert = NSAlert()
        alert.messageText = L("Accessibility Access Required")
        alert.informativeText = L("macshot needs Accessibility permission to snap to individual interface elements. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        KeystrokeOverlay.requestInputMonitoringPermission()
        let alert = NSAlert()
        alert.messageText = L("Input Monitoring Required")
        alert.informativeText = L("macshot needs Input Monitoring permission to highlight mouse clicks or show keystrokes during recording. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {
        guard let scc = scrollCaptureController else { return }

        // If turning on, check Accessibility permission first
        if !scc.autoScrollActive {
            if !AXIsProcessTrusted() {
                // Cancel session without delivering a result, then dismiss overlays
                scc.cancelSession()
                scrollCaptureController = nil
                scrollCapturePreviewPanel?.close()
                scrollCapturePreviewPanel = nil
                scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
                scrollCaptureOverlayController = nil
                dismissOverlays()

                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
                let alert = NSAlert()
                alert.messageText = L("Accessibility Access Required")
                alert.informativeText = L("macshot needs Accessibility permission to auto-scroll other apps. Please grant access in System Settings, then try again.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: L("Open Settings"))
                alert.addButton(withTitle: L("Cancel"))
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                return
            }
        }

        scc.toggleAutoScroll()
        let autoScrolling = scc.isActive && scc.autoScrollActive
        controller.updateScrollCaptureProgress(
            stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
            autoScrolling: autoScrolling)
    }

    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        captureTimingTrace?.mark("user began selection")
        // The user committed to one screen. Also drop the auto-translate flag on
        // the other overlays: this mode leaves overlays open, so a still-set flag
        // there would auto-translate again if the user later drew on that screen.
        pendingTranslateOverlayMode = false
        pendingTranslateOverlayLang = nil
        for other in overlayControllers where other !== controller {
            other.clearSelection()
            other.setRemoteSelection(.zero)
            other.clearAutoTranslateOverlayMode()
        }
    }

    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in overlayControllers where other !== controller {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Update the primary screen's actual selection
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)

        // Update other secondary screens (not the caller — it manages its own remoteSelectionRect during drag)
        for other in overlayControllers where other !== controller && other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Final sync after remote resize — update primary, re-sync ALL secondaries, transfer focus
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)
        primary.makeKey()

        // Re-sync ALL secondary screens (including the caller) from the primary's authoritative rect
        let primarySel = primary.selectionRect
        let primaryGlobal = NSRect(x: primarySel.origin.x + primaryOrigin.x,
                                   y: primarySel.origin.y + primaryOrigin.y,
                                   width: primarySel.width, height: primarySel.height)
        for other in overlayControllers where other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: primaryGlobal.origin.x - otherOrigin.x,
                                   y: primaryGlobal.origin.y - otherOrigin.y,
                                   width: primaryGlobal.width, height: primaryGlobal.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        let others = overlayControllers.filter { $0 !== controller && $0.remoteSelectionRect.width >= 1 && $0.remoteSelectionRect.height >= 1 }
        guard !others.isEmpty else { return nil }
        return stitchCrossScreenCapture(primary: controller, others: others)
    }

    func overlayDidChangeSnapMode(_ controller: OverlayWindowController) {
        // Notify all other overlays to redraw (for multi-monitor setups)
        // When snap mode changes via Tab, all overlays need to update their helper text.
        for other in overlayControllers where other !== controller {
            other.refreshSnapMode()
        }
    }

    /// Copy the colour under the pointer, then end the capture.
    ///
    /// The overlay that received the keystroke is whichever one is key — on a multi-display
    /// setup that is frequently *not* the one the pointer is over, and only that one holds
    /// the right screenshot. So ask each overlay in turn to sample the global pointer
    /// position and let the one that owns that screen answer.
    func overlayDidRequestWholeScreenAtPointer(_ controller: OverlayWindowController) -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let target = overlayControllers.first(where: { $0.screen.frame.contains(pointer) }),
              target !== controller else { return false }
        target.selectWholeScreen()
        return true
    }

    func overlayDidRequestPointerColorPick(_ controller: OverlayWindowController) {
        let pointer = NSEvent.mouseLocation
        var picked = controller.copyColorAtGlobalPoint(pointer)
        if !picked {
            for other in overlayControllers where other !== controller {
                if other.copyColorAtGlobalPoint(pointer) {
                    picked = true
                    break
                }
            }
        }
        // Only tear down the capture once a colour was actually read — otherwise a miss
        // (pointer between displays, screenshot not ready) would silently cancel the capture
        // and leave the user with neither a colour nor a screenshot.
        guard picked else { return }
        // The confirmation is a ToastCenter panel, which outlives the overlay — so the
        // capture can come down immediately instead of being held open to keep a message
        // visible.
        dismissOverlays()
    }

    private func handleScrollCaptureCompleted(finalImage: NSImage?) {
        scrollCapturePreviewPanel?.close()
        scrollCapturePreviewPanel = nil
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        scrollCaptureController = nil

        dismissOverlays()

        guard let image = finalImage else { return }

        let entryID = ScreenshotHistory.shared.add(image: image)
        // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing (thumbnail only)
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
        if mode == 1 || mode == 2 {
            ImageEncoder.copyToClipboard(image)
        }
        if mode == 0 || mode == 2 {
            saveImageToConfiguredFolder(image)
        }
        playCopySound()
        showFloatingThumbnail(image: image, historyEntryID: entryID)

        if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
            DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
        }
    }

}

// MARK: - PinWindowControllerDelegate

extension AppDelegate: PinWindowControllerDelegate {
    func pinWindowDidClose(_ controller: PinWindowController) {
        pinControllers.removeAll { $0 === controller }
    }
}

// MARK: - NSMenuDelegate (status bar menu + Recent Captures submenu)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Only for the main status-bar menu (the history submenu rebuilds via
        // menuNeedsUpdate). Dismiss any active modal before the menu shows, and
        // pre-warm ScreenCaptureKit content while the user browses.
        guard menu === statusBarMenu else { return }
        ScreenCaptureManager.prewarm()
        if let modalWin = NSApp.modalWindow {
            NSApp.stopModal()
            modalWin.close()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only rebuild the history submenu, not the main status bar menu
        guard menu === historyMenu else { return }

        menu.removeAllItems()

        let entries = ScreenshotHistory.shared.entries
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: L("No recent captures"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for entry in entries {
            // Lead with where the shot came from when we know: a column of
            // dimensions and ages gives no way to tell one capture from another.
            let source = entry.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dimensions = "\(entry.pixelWidth) \u{00D7} \(entry.pixelHeight)"
            let title = (source?.isEmpty == false)
                ? "\(source!)  —  \(dimensions)  —  \(entry.timeAgoString)"
                : "\(dimensions)  —  \(entry.timeAgoString)"
            let item = NSMenuItem(title: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            // Identify the entry, not its row: a history write landing while
            // the menu is open shifts every position by one.
            item.representedObject = entry.id
            item.image = ScreenshotHistory.shared.loadThumbnail(for: entry)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: L("Clear History"), action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        clearItem.tag = 9000
        menu.addItem(clearItem)
    }

    /// Preview the highlighted capture beside the menu.
    ///
    /// `menu(_:willHighlight:)` is the only hook AppKit gives for menu hover —
    /// menu items do not deliver mouse-tracking events of their own.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === historyMenu else { return }
        guard let item, item.action == #selector(copyHistoryEntry(_:)) else {
            MenuPreviewController.shared.hide()
            return
        }
        guard let id = item.representedObject as? String,
              let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == id }),
              let preview = ScreenshotHistory.shared.loadPreview(for: entry)
        else {
            MenuPreviewController.shared.hide()
            return
        }
        MenuPreviewController.shared.show(image: preview, near: NSEvent.mouseLocation)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === historyMenu else { return }
        MenuPreviewController.shared.hide()
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == id }) else { return }
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }

        ImageEncoder.copyToClipboard(image)
        showFloatingThumbnail(image: image, historyEntryID: entry.id)

        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            Self.captureSound?.stop()
            Self.captureSound?.play()
        }
    }

    @objc private func clearHistory() {
        confirmClearHistory()
    }

    private func clearHistorySilently() {
        ScreenshotHistory.shared.clear()
    }

    /// Show a confirmation dialog before clearing all history. Reused by history panel trash button.
    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = L("Clear History?")
        alert.informativeText = L("This will permanently delete all screenshots from history.")
        alert.addButton(withTitle: L("Clear All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenshotHistory.shared.clear()
        }
    }
}
