import Cocoa
import ScreenCaptureKit
import Vision

// MARK: - ScrollCaptureController

/// Scroll capture engine:
///
/// - **`CGWindowListCreateImage`** for on-demand frame capture — each grab is a
///   complete, compositor-finished snapshot. No stream management, no stale frames.
/// - **TIFF byte-by-byte comparison** — two consecutive identical TIFF representations
///   = content has truly stopped rendering. Zero tolerance, no false positives.
/// - **Timer-driven `captureAndCompare`** on a dedicated serial queue — consistent
///   timing, no main-thread contention.
/// - **Incremental stitching** — new content is merged into `mergedImage` immediately
///   after each match, keeping memory bounded (no storing all raw strips).
/// - **Vision-only offset detection** — `VNTranslationalImageRegistrationRequest`
///   for pixel-precise scroll offset measurement.
/// - **`matchNotFoundCount`** tracking — surfaces errors to the user via callbacks
///   instead of silently failing.
/// - **Programmatic scrolling** via `CGEventCreateScrollWheelEvent2`.
/// - **Frozen header detection** — identifies sticky headers and excludes from stitching.
/// - **Scrollbar exclusion** — auto-detects scrollbar width, excludes from comparisons.
/// - **Max height: 30,000 pixels** (configurable via UserDefaults).
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private(set) var frozenTopHeight: CGFloat = 0
    private var isCancelled: Bool = false

    /// Current estimated total height of the final image (points).
    var estimatedTotalHeight: CGFloat {
        guard let merged = mergedImage else { return 0 }
        return CGFloat(merged.height) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings

    /// Fallbacks for settings that were never written. The settings pane reads
    /// these too: it used to carry its own (on, medium, unlimited) and showed
    /// the opposite of what a capture actually did.
    static let defaultAutoScrollEnabled = false
    static let defaultAutoScrollSpeed = 3
    /// 0 means unlimited.
    static let defaultMaxScrollHeight = 30000

    private var autoScrollEnabled: Bool = defaultAutoScrollEnabled
    private var autoScrollSpeed: Int = defaultAutoScrollSpeed
    private var maxScrollHeight: Int = defaultMaxScrollHeight
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    // Dedicated serial queue for capture-and-compare (off main thread)
    private let captureQueue = DispatchQueue(label: "macshot.scrollcapture", qos: .userInitiated)

    // Frame state
    /// The last frame stitched into `mergedImage`. Every new frame is matched
    /// against it, not against the last frame grabbed: a frame that could not
    /// be matched — scrolled back up, or carried past the overlap by a fast
    /// flick — must not become the reference, or the next strip is measured
    /// from content that was never stitched and lands in the wrong place.
    /// Scrolling back to where stitching stopped picks it up again.
    private var shotA: CGImage?
    private var shotB: CGImage?          // current frame
    private var lastComparedTIFF: Data?  // TIFF of last settled frame for byte comparison
    private var mergedImage: CGImage?    // accumulated stitched result
    private var headerHeight: Int = 0    // frozen header height in pixels
    private var headerDetectionDone: Bool = false
    private var headerDetectionSamples: Int = 0

    // Scrollbar exclusion
    private var rightMarginPx: Int = 0
    private var rightMarginDetected: Bool = false

    // Match tracking
    private var matchNotFoundCount: Int = 0
    private let maxMatchNotFound: Int = 8  // stop after 8 consecutive failures
    private var didReportFirstMatch: Bool = false
    private var hasScrolledOnce: Bool = false
    private var consecutiveZeroShifts: Int = 0
    private let maxZeroShiftsBeforeStop: Int = 6

    // Scroll monitors (for manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.15
    private var lastCaptureTime: TimeInterval = 0
    /// Scroll distance (points) reported since the last grab. A fast flick
    /// moves the page further in one interval than a frame overlaps, so a
    /// grab is also due once this reaches a share of the region's height.
    private var scrolledSinceGrab: CGFloat = 0
    private let grabDistanceFraction: CGFloat = 0.35
    /// Bumped by every scroll event, so a settled capture can tell that the
    /// user has resumed scrolling and give way.
    private var scrollEventSerial = 0
    private var pendingCaptureTask: Task<Void, Never>?
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25

    // Guard: only one capture at a time
    private var isCapturing: Bool = false

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // CGWindowList capture config
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero  // CG coordinates (top-left origin)

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive, !isCancelled else { return }

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? Self.defaultAutoScrollEnabled
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? Self.defaultAutoScrollSpeed
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? Self.defaultMaxScrollHeight
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Convert AppKit coords to CG coords (top-left origin) for CGWindowListCreateImage
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        // Find the target window under the capture region
        resolveTargetWindow()
        resolveTargetApp()

        // Capture first settled frame
        guard let firstFrame = await captureSettledFrame() else {
            if !isCancelled { onSessionDone?(nil) }
            return
        }
        guard !isCancelled else { return }

        isActive = true
        shotA = firstFrame
        shotB = nil
        lastComparedTIFF = nil
        mergedImage = firstFrame
        headerHeight = 0
        headerDetectionDone = false
        headerDetectionSamples = 0
        rightMarginPx = 0
        rightMarginDetected = false
        matchNotFoundCount = 0
        didReportFirstMatch = false
        hasScrolledOnce = false
        consecutiveZeroShifts = 0
        frozenTopHeight = 0
        stripCount = 1

        stitchedImage = firstFrame
        stitchedPixelSize = CGSize(width: CGFloat(firstFrame.width), height: CGFloat(firstFrame.height))
        emitPreview()
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    func stopSession() {
        // The HUD (and its Stop button) is on screen before `isActive` becomes
        // true — startSession first awaits a settled frame, which can take a
        // couple of seconds on a page with a blinking caret or a clock. A stop
        // in that window used to do nothing at all, and the session then
        // installed its scroll monitors anyway.
        guard isActive || !isCancelled else { return }
        guard isActive else {
            isCancelled = true
            onSessionDone?(nil)
            return
        }
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false

        // Deliver final image
        let finalImage: NSImage?
        if let cg = mergedImage {
            let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                                height: CGFloat(cg.height) / backingScale)
            finalImage = NSImage(cgImage: cg, size: ptSize)
        } else {
            finalImage = nil
        }
        onSessionDone?(finalImage)
    }

    func cancelSession() {
        // Cancellation is also valid while the initial settled frame is being
        // captured, before `isActive` becomes true. The cancelled flag keeps
        // that asynchronous startup from installing monitors after the UI has
        // already been dismissed.
        isCancelled = true
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false
    }

    // MARK: - Target window/app management

    /// Finds the window ID under the capture region center for targeted capture.
    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Frame capture via CGWindowListCreateImage

    /// Captures the screen region using CGWindowListCreateImage.
    /// Returns a complete, compositor-finished snapshot — no stream management needed.
    private func captureFrame() -> CGImage? {
        let excludeSet = Set(excludedWindowIDs)
        let listOption: CGWindowListOption = [.optionOnScreenBelowWindow]
        let windowID = excludeSet.isEmpty ? kCGNullWindowID : (excludeSet.first ?? kCGNullWindowID)

        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming]

        guard let image = CGWindowListCreateImage(
            captureRectCG, listOption, windowID, imageOption
        ) else { return nil }

        return image
    }

    /// Captures a settled frame: grabs frames until two consecutive TIFF representations
    /// match byte-for-byte. Used for initial capture and manual scroll mode.
    private func captureSettledFrame() async -> CGImage? {
        var previousTIFF: Data? = nil
        var previousCG: CGImage? = nil
        var waitNs: UInt64 = 10_000_000  // 10ms

        for _ in 0..<30 {
            guard !isCancelled else { return nil }
            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard !isCancelled else { return nil }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                lastComparedTIFF = currentTIFF
                return cg
            }

            previousTIFF = currentTIFF
            previousCG = cg
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        return previousCG
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 1: linesPerTick = 1
        case 2: linesPerTick = 1
        case 4: linesPerTick = 2
        default: linesPerTick = 1
        }

        let burstCount: Int
        switch autoScrollSpeed {
        case 1: burstCount = 1
        case 2: burstCount = 2
        case 4: burstCount = 4
        default: burstCount = 3
        }

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, self.isActive, self.autoScrollActive else { return }
            await self.autoScrollLoop(linesPerTick: linesPerTick, burstCount: burstCount)
        }
    }

    /// Core auto-scroll loop: scroll → captureAndCompare → repeat.
    private func autoScrollLoop(linesPerTick: Int32, burstCount: Int) async {
        while isActive && autoScrollActive {
            // Post scroll event(s)
            for _ in 0..<burstCount {
                if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                       wheel1: -linesPerTick, wheel2: 0, wheel3: 0) {
                    event.post(tap: .cghidEventTap)
                }
            }

            // captureAndCompare: settle, capture, compare, stitch.
            // `isCapturing` serializes this against a manual settledCapture
            // that may still be running — both mutate shotA/mergedImage/
            // stripCount around their suspension points.
            if isCapturing {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            isCapturing = true
            let success = await captureAndCompare()
            isCapturing = false

            if !success {
                matchNotFoundCount += 1
                if matchNotFoundCount >= maxMatchNotFound {
                    stopSession()
                    return
                }
            } else {
                matchNotFoundCount = 0
            }

            // Check max height
            if let merged = mergedImage, maxScrollHeight > 0 {
                if merged.height >= maxScrollHeight {
                    stopSession()
                    return
                }
            }

            // Small breathing room
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The core capture-and-compare cycle.
    /// Waits for pixel-perfect settlement via TIFF comparison, then computes the scroll
    /// offset via Vision and merges new content into the accumulated image.
    /// Returns true if a match was found, false if no shift detected.
    ///
    /// With `abortOnScroll`, gives up as soon as a new scroll event arrives:
    /// a settled capture holds `isCapturing`, and while it waited for a still
    /// frame that never came every grab of the resumed scroll was skipped.
    private func captureAndCompare(abortOnScroll: Bool = false) async -> Bool {
        let serial = scrollEventSerial
        let superseded = { [unowned self] in abortOnScroll && self.scrollEventSerial != serial }
        // Initial delay for scroll animation to begin
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Wait for settlement: poll frames until two consecutive TIFFs match
        var previousTIFF: Data? = nil
        var settledCG: CGImage? = nil
        var waitNs: UInt64 = 12_000_000

        for _ in 0..<30 {
            guard isActive, !superseded() else { return false }

            guard let cg = captureFrame() else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            let tiffData: Data? = await withCheckedContinuation { cont in
                captureQueue.async {
                    let bitmapRep = NSBitmapImageRep(cgImage: cg)
                    cont.resume(returning: bitmapRep.tiffRepresentation)
                }
            }
            guard !superseded() else { return false }
            guard let currentTIFF = tiffData else {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
                continue
            }

            if let prevTIFF = previousTIFF, currentTIFF == prevTIFF {
                settledCG = cg
                lastComparedTIFF = currentTIFF
                break
            }

            previousTIFF = currentTIFF
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)
        }

        guard let currentFrame = settledCG else { return false }
        guard let previousFrame = shotA ?? mergedImage?.cropping(to: CGRect(
            x: 0, y: 0, width: currentFrame.width, height: currentFrame.height
        )) else {
            shotA = currentFrame
            return false
        }

        // Compute offset via Vision
        guard let offset = visionShift(current: currentFrame, previous: previousFrame) else {
            consecutiveZeroShifts += 1
            // Only auto-scroll ends itself. A manual session sees unmatched
            // frames whenever the user scrolls back up, and must keep going.
            if autoScrollActive && hasScrolledOnce && consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
                stopSession()
            }
            return false
        }

        let offsetPx = Int(round(offset))
        guard offsetPx > 0 else { return false }

        // Need minimum shift to avoid noise
        let minShift = currentFrame.height / 10
        if offsetPx < minShift {
            // Don't update shotA — let shifts accumulate
            return false
        }

        consecutiveZeroShifts = 0
        hasScrolledOnce = true

        // Scrollbar first: header detection leaves it out.
        if !rightMarginDetected {
            detectRightMargin(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }
        // Header detection (first few frames)
        if frozenDetectionEnabled && !headerDetectionDone {
            detectHeader(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }

        // Use Vision's offset directly — pixel refinement can worsen it on
        // low-contrast / dark-themed content. Bias by -1px so strips overlap by
        // 1 extra row: the newer frame overwrites that row, hiding any sub-pixel
        // rendering differences at the seam boundary.
        let safeOffset = max(1, offsetPx - 1)

        // Incremental stitch: merge new content into mergedImage
        mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset)

        shotA = currentFrame
        stripCount += 1
        didReportFirstMatch = true

        emitPreview()
        onStripAdded?(stripCount)

        return true
    }

    /// Merges the newly-scrolled content from `currentFrame` into `mergedImage`.
    /// Only the new rows (below the overlap region) are appended.
    private func mergeNewContent(currentFrame: CGImage, offsetPx: Int) {
        guard let existing = mergedImage else {
            mergedImage = currentFrame
            return
        }

        let w = currentFrame.width
        let existingH = existing.height
        let newRows = offsetPx  // pixels of new content
        guard newRows > 0, newRows <= currentFrame.height else { return }

        let totalH = existingH + newRows

        let cs = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: totalH,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: bitmapInfo) else { return }

        // Draw existing image at the top (CGContext: bottom-left origin, so top = highest y)
        let existingRect = CGRect(x: 0, y: newRows, width: w, height: existingH)
        ctx.draw(existing, in: existingRect)
        // The scrollbar sits somewhere else in every strip; stitched as
        // captured it leaves a dash per strip down the right edge. Covering the
        // whole image again each time also clears the first frame, which was
        // stitched before the scrollbar was found.
        Self.coverRightMargin(of: existing, at: existingRect, marginPx: rightMarginPx, in: ctx)

        if headerDetectionDone && headerHeight > 0 {
            // Sticky header detected: only append the bottom newRows pixels.
            let stripY = currentFrame.height - newRows
            if let strip = currentFrame.cropping(to: CGRect(
                x: 0, y: stripY, width: w, height: newRows)) {
                let stripRect = CGRect(x: 0, y: 0, width: w, height: newRows)
                ctx.draw(strip, in: stripRect)
                Self.coverRightMargin(of: strip, at: stripRect, marginPx: rightMarginPx, in: ctx)
            }
        } else {
            // No header: draw full current frame with natural overlap.
            let frameRect = CGRect(x: 0, y: 0, width: w, height: currentFrame.height)
            ctx.draw(currentFrame, in: frameRect)
            Self.coverRightMargin(of: currentFrame, at: frameRect, marginPx: rightMarginPx, in: ctx)
        }

        guard let merged = ctx.makeImage() else { return }
        mergedImage = merged
        stitchedImage = merged
        stitchedPixelSize = CGSize(width: CGFloat(w), height: CGFloat(totalH))
    }

    /// Paints the `marginPx` columns at the right of `image`, drawn in
    /// `context` at `rect`, with the column just inside them, row by row —
    /// background and card edges carry on to the edge, the scrollbar is gone.
    nonisolated static func coverRightMargin(of image: CGImage, at rect: CGRect, marginPx: Int,
                                             in context: CGContext) {
        guard marginPx > 0, marginPx < image.width / 4,
              let column = image.cropping(to: CGRect(
                x: image.width - marginPx - 1, y: 0, width: 1, height: image.height))
        else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(column, in: CGRect(x: rect.maxX - CGFloat(marginPx), y: rect.minY,
                                        width: CGFloat(marginPx), height: rect.height))
        context.restoreGState()
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            startAutoScroll()
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent(event)
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent(event)
            return event
        }
    }

    private func onManualScrollEvent(_ event: NSEvent) {
        guard isActive else { return }
        scrollEventSerial &+= 1

        // After scrolling stops, do a final settled capture (TIFF comparison)
        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.settledCapture() }
        }

        // During scrolling, grab and process frames immediately at a fixed interval —
        // no TIFF settlement. This ensures we capture content continuously even with
        // small selection areas where a single scroll gesture can move past the entire
        // viewport.
        // Wheel mice report lines rather than points; ten points a line is
        // close enough to judge when a grab is due.
        scrolledSinceGrab += abs(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10)
        let now = ProcessInfo.processInfo.systemUptime
        let dueByTime = now - lastCaptureTime >= manualCaptureInterval
        let dueByDistance = scrolledSinceGrab >= captureRect.height * grabDistanceFraction
        guard dueByTime || dueByDistance else { return }
        // A grab skipped because a capture is still running doesn't count:
        // the next event tries again instead of waiting out the interval.
        if grabAndProcess() {
            lastCaptureTime = now
            scrolledSinceGrab = 0
        }
    }

    /// Immediate frame grab + process during active scrolling. No TIFF settlement —
    /// just captures whatever is on screen right now and tries to stitch it.
    /// Returns false when no frame was grabbed.
    @discardableResult
    private func grabAndProcess() -> Bool {
        guard isActive, !isCapturing else { return false }
        isCapturing = true
        defer { isCapturing = false }

        guard let currentFrame = captureFrame() else { return false }
        guard let previousFrame = shotA else {
            shotA = currentFrame
            return true
        }

        guard let offset = visionShift(current: currentFrame, previous: previousFrame) else { return true }

        let offsetPx = Int(round(offset))
        guard offsetPx > 0 else { return true }

        let minShift = currentFrame.height / 10
        if offsetPx < minShift { return true }

        hasScrolledOnce = true
        consecutiveZeroShifts = 0

        // Scrollbar first: header detection leaves it out.
        if !rightMarginDetected {
            detectRightMargin(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }
        if frozenDetectionEnabled && !headerDetectionDone {
            detectHeader(current: currentFrame, previous: previousFrame, shiftPx: offsetPx)
        }

        let safeOffset = max(1, offsetPx - 1)
        mergeNewContent(currentFrame: currentFrame, offsetPx: safeOffset)

        shotA = currentFrame
        stripCount += 1
        didReportFirstMatch = true

        emitPreview()
        onStripAdded?(stripCount)
        return true
    }

    /// Final settled capture after scrolling stops — uses full TIFF settlement,
    /// and gives way the moment scrolling resumes.
    private func settledCapture() async {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        let _ = await captureAndCompare(abortOnScroll: true)
    }

    // MARK: - Vision shift detection

    /// Vision framework translational image registration.
    /// Crops out frozen header and/or scrollbar for more accurate results.
    private func visionShift(current: CGImage, previous: CGImage) -> CGFloat? {
        Self.verticalShift(
            current: current, previous: previous,
            confirmedHeaderRows: headerDetectionDone ? headerHeight : nil,
            rightMarginPx: rightMarginPx)
    }

    /// Vertical scroll offset of `current` against `previous`, in pixels, or
    /// nil when no offset is borne out by the pixels.
    ///
    /// A pinned header is cropped away before registration even before one has
    /// been confirmed: until then this pair's own unchanged top rows stand in
    /// for it. A high-contrast toolbar over sparse content otherwise outweighs
    /// the content that moved — Vision then reports a small near-constant shift
    /// whatever the scroll, it never reaches the minimum a strip needs, and the
    /// header, which is only confirmed after a strip, never gets confirmed.
    /// Shadowrocket's settings pages captured nothing past the first screen.
    ///
    /// Unchanged rows stop at the first change, which can be inside the header:
    /// Shadowrocket cross-fades its title into an icon as the page scrolls, and
    /// the static half of the bar below it pinned the offset to 0 again. So the
    /// top fifth is tried as well, and an offset is only returned once the two
    /// frames actually agree at it — registration produces an offset even for
    /// frames that share no content.
    nonisolated static func verticalShift(
        current: CGImage, previous: CGImage, confirmedHeaderRows: Int?, rightMarginPx: Int
    ) -> CGFloat? {
        let maxCropY = current.height / 5
        let headerRows = confirmedHeaderRows
            ?? ScrollFrameAnalyzer.frozenTopRows(
                current: current, previous: previous, rightMarginPx: rightMarginPx
            ).flatMap { $0 < current.height ? $0 : nil }
            ?? 0
        var tops = [min(headerRows, maxCropY)]
        if tops[0] != maxCropY { tops.append(maxCropY) }
        for top in tops {
            guard let shift = registeredShift(
                    current: current, previous: previous, cropY: top, rightMarginPx: rightMarginPx),
                  ScrollFrameAnalyzer.overlapAgrees(
                    current: current, previous: previous, shift: Int(shift.rounded()),
                    top: top, rightMarginPx: rightMarginPx)
            else { continue }
            return shift
        }
        return nil
    }

    /// Vision's translational registration of the two frames below `cropY`
    /// and left of the scrollbar margin.
    nonisolated private static func registeredShift(
        current: CGImage, previous: CGImage, cropY: Int, rightMarginPx: Int
    ) -> CGFloat? {
        var curImg = current
        var prevImg = previous
        let cropW = current.width - rightMarginPx
        let cropH = current.height - cropY
        if cropY > 0 || rightMarginPx > 0 {
            guard cropH > 20 && cropW > 20 else { return nil }
            let cropRect = CGRect(x: 0, y: cropY, width: cropW, height: cropH)
            guard let cc = current.cropping(to: cropRect),
                  let pc = previous.cropping(to: cropRect) else { return nil }
            curImg = cc
            prevImg = pc
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prevImg)
        let handler = VNImageRequestHandler(cgImage: curImg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        // Vision returns a degenerate transform when registration fails on
        // blank, dark or repetitive content. The caller rounds this into an
        // Int, which traps on a non-finite value.
        let shift = obs.alignmentTransform.ty
        return ScrollFrameAnalyzer.validatedVerticalShift(shift, frameHeight: curImg.height)
    }

    // MARK: - Scrollbar detection

    /// Looks for the scrollbar in a pair about to be stitched, aligned by its
    /// content shift. Until one is found it is retried on every stitch: it
    /// was settled on the first pair compared, which is often the first frame
    /// against one barely scrolled — before an overlay scrollbar even shows —
    /// and so concluded there was none for the rest of the capture.
    private func detectRightMargin(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard let scrollbarWidth = ScrollFrameAnalyzer.scrollbarWidth(
                current: current, previous: previous, shift: shiftPx),
              scrollbarWidth >= 3, scrollbarWidth <= 40 else { return }
        rightMarginDetected = true
        rightMarginPx = scrollbarWidth + 4
    }

    // MARK: - Header (frozen region) detection

    private func detectHeader(current: CGImage, previous: CGImage, shiftPx: Int) {
        guard shiftPx > 5 else { return }
        guard let frozenRows = ScrollFrameAnalyzer.frozenTopRows(
            current: current, previous: previous, rightMarginPx: rightMarginPx) else { return }

        let h = current.height
        // Nothing changed anywhere: this pair says nothing about a header, so
        // leave detection open for the next frame instead of freezing the
        // whole capture area.
        guard frozenRows < h else { return }

        if frozenRows >= 10 && frozenRows < (h * 6 / 10) {
            headerDetectionSamples += 1

            if headerDetectionSamples == 1 {
                headerHeight = frozenRows
                frozenTopHeight = CGFloat(headerHeight) / backingScale
                headerDetectionDone = true
            } else {
                if abs(frozenRows - headerHeight) <= 5 {
                    headerHeight = min(headerHeight, frozenRows)
                    frozenTopHeight = CGFloat(headerHeight) / backingScale
                } else {
                    headerHeight = 0
                    frozenTopHeight = 0
                }
                headerDetectionDone = true
            }
        } else if frozenRows < 10 {
            headerDetectionDone = true
        }
    }

    // MARK: - Preview

    private func emitPreview() {
        guard let cg = mergedImage, let callback = onPreviewUpdated else { return }
        let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                            height: CGFloat(cg.height) / backingScale)
        callback(NSImage(cgImage: cg, size: ptSize))
    }
}
