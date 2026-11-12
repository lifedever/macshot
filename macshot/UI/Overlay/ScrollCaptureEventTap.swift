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
final class ScrollCaptureEventTap {

    /// The capture region, in global display coordinates (y down).
    private let region: CGRect
    /// Where a macshot window that takes the mouse lies over the screen, in
    /// the same coordinates: the HUD. A scroll there never reaches the page.
    var covered: [CGRect]

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    /// Nil when the tap can't be created, which takes Accessibility access.
    init?(region: CGRect, covered: [CGRect]) {
        self.region = region
        self.covered = covered
        let events = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ScrollCaptureEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                    .handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
    }

    deinit { stop() }

    /// Ends the tap. Nothing calls back into this object afterwards.
    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        self.source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .mouseMoved:
            return nil
        case .scrollWheel:
            if let destination = Self.destination(ofScrollAt: event.location, region: region, covered: covered) {
                event.location = destination
            }
        case .tapDisabledByTimeout:
            // The system switches off a tap that was slow to answer. Left
            // off, scrolling would go back to whatever is under the pointer:
            // the HUD.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Where a scroll at `location` is sent instead, or nil to leave it
    /// alone: it is over the page in the region already, and the user has
    /// pointed at what to scroll.
    ///
    /// Anything else goes to the middle of the region — or, when the HUD is
    /// there, as it can be in a region the height of the screen, to the
    /// middle of one of its halves.
    static func destination(ofScrollAt location: CGPoint, region: CGRect, covered: [CGRect]) -> CGPoint? {
        guard region.width > 0, region.height > 0 else { return nil }
        let isCovered = { (point: CGPoint) in covered.contains { $0.contains(point) } }
        if region.contains(location), !isCovered(location) { return nil }
        let candidates = [0.5, 0.25, 0.75].map {
            CGPoint(x: region.midX, y: region.minY + region.height * $0)
        }
        return candidates.first { !isCovered($0) } ?? candidates[0]
    }
}
