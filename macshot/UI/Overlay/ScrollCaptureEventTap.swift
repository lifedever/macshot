import Cocoa

/// The event tap a scroll capture runs behind. It keeps the pointer from
/// mattering to the app being captured.
///
/// Mouse-moved events are swallowed, as they always were, so moving the mouse
/// changes nothing on the page. That was not enough: each time its content
/// moves, AppKit asks where the pointer is and sends `mouseEntered` to
/// whatever has scrolled under it, mouse-moved or not. The pointer was put in
/// the middle of the region, because the wheel scrolls what is under it — so
/// Mail showed the reply and delete buttons of the message there, and they
/// were stitched into the long image.
///
/// So scrolling is sent into the region wherever the pointer is, and the
/// pointer waits on the HUD. With another app's window under the pointer
/// AppKit sends the page no `mouseEntered` at all, however it scrolls.
///
/// A scroll is sent elsewhere by giving the event another location here, in
/// a session tap: the window server delivers it to the window at that
/// location and leaves the pointer alone. Posting an event that has a
/// location of its own moves the pointer there, from either tap. All of this
/// was measured on macOS 27 with a list of tracking areas in one process and
/// a panel over it in another.
///
/// The tap runs on a thread of its own. Every scroll the user makes passes
/// through it, and the main thread is busy for tens of milliseconds at each
/// strip of a capture (grab, registration, stitching); a tap on the main run
/// loop held each scroll for that long, and the page moved in jerks.
final class ScrollCaptureEventTap {

    private let router: Router

    /// Where a macshot window that takes the mouse lies over the screen, in
    /// the same coordinates: the HUD. A scroll there never reaches the page.
    var covered: [CGRect] {
        get { router.covered }
        set { router.covered = newValue }
    }

    /// Nil when the tap can't be created, which takes Accessibility access.
    init?(region: CGRect, covered: [CGRect]) {
        let router = Router(region: region, covered: covered)
        let events = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<Router>.fromOpaque(userInfo).takeUnretainedValue()
                    .handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(router).toOpaque())
        else { return nil }
        guard router.start(port) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.router = router
    }

    deinit { router.stop() }

    /// Ends the tap. No event reaches this tap afterwards.
    func stop() {
        router.stop()
    }

    /// Where a scroll at `location` is sent instead, or nil to leave it
    /// alone: it is over the page in the region already, and the user has
    /// pointed at what to scroll.
    ///
    /// Anything else goes to the middle of the region — or, when the HUD is
    /// there, as it can be in a region the height of the screen, to the
    /// middle of one of its halves.
    nonisolated static func destination(ofScrollAt location: CGPoint, region: CGRect, covered: [CGRect]) -> CGPoint? {
        guard region.width > 0, region.height > 0 else { return nil }
        let isCovered = { (point: CGPoint) in covered.contains { $0.contains(point) } }
        if region.contains(location), !isCovered(location) { return nil }
        let candidates = [0.5, 0.25, 0.75].map {
            CGPoint(x: region.midX, y: region.minY + region.height * $0)
        }
        return candidates.first { !isCovered($0) } ?? candidates[0]
    }
}

/// The tap's state and the thread its events arrive on. The callback holds an
/// unretained pointer to this; the thread keeps it alive until its run loop
/// ends, and nothing calls back once the port is invalidated.
nonisolated private final class Router: @unchecked Sendable {

    let region: CGRect
    private let lock = NSLock()
    private var coveredRects: [CGRect]
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    init(region: CGRect, covered: [CGRect]) {
        self.region = region
        self.coveredRects = covered
    }

    var covered: [CGRect] {
        get { locked { coveredRects } }
        set { locked { coveredRects = newValue } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Starts the tap's thread and returns once events can arrive on it.
    func start(_ port: CFMachPort) -> Bool {
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return false }
        locked {
            self.port = port
            self.source = source
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            let (port, source) = self.locked { () -> (CFMachPort?, CFRunLoopSource?) in
                self.runLoop = loop
                return (self.port, self.source)
            }
            if let port, let source {
                CFRunLoopAddSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
            }
            ready.signal()
            // Returns once stop() has invalidated the port (which removes its
            // source, leaving the loop nothing to run) or stopped the loop.
            CFRunLoopRun()
        }
        thread.name = "macshot.scrollcapture.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        let (port, loop) = locked { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.port = nil
                self.source = nil
                self.runLoop = nil
            }
            return (self.port, self.runLoop)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .mouseMoved:
            return nil
        case .scrollWheel:
            if let destination = ScrollCaptureEventTap.destination(
                ofScrollAt: event.location, region: region, covered: covered) {
                event.location = destination
            }
        case .tapDisabledByTimeout:
            // The system switches off a tap that was slow to answer. Left
            // off, scrolling would go back to whatever is under the pointer:
            // the HUD.
            if let port = locked({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
