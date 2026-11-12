import Cocoa
import XCTest

/// During a scroll capture the pointer waits on the HUD and scrolling is sent
/// into the region: an app lights up whatever scrolls under the pointer, and
/// Mail's reply and delete buttons ended up in the long image.
@MainActor
final class ScrollCaptureEventTapTests: XCTestCase {

    /// Global display coordinates, y down. The HUD sits just below the region.
    private let region = CGRect(x: 400, y: 200, width: 600, height: 500)
    private let hud = CGRect(x: 570, y: 706, width: 260, height: 36)

    private func destination(_ x: CGFloat, _ y: CGFloat, region: CGRect? = nil, hud: CGRect? = nil) -> CGPoint? {
        ScrollCaptureEventTap.destination(ofScrollAt: CGPoint(x: x, y: y), region: region ?? self.region,
                                          covered: [hud ?? self.hud])
    }

    func testAScrollOverThePageIsLeftWhereThePointerIs() {
        // The user has pointed at what to scroll: one of two panes, say.
        XCTAssertNil(destination(450, 650))
        XCTAssertNil(destination(700, 450))
    }

    func testAScrollAnywhereElseGoesToTheMiddleOfTheRegion() {
        let middle = CGPoint(x: 700, y: 450)
        XCTAssertEqual(destination(700, 724), middle, "on the HUD, where the pointer waits")
        XCTAssertEqual(destination(120, 90), middle, "beside the window")
        XCTAssertEqual(destination(700, 199), middle, "just above the region")
        XCTAssertEqual(destination(1000, 450), middle, "on its right edge")
    }

    func testAHUDInsideTheRegionIsNotThePage() {
        // A region the height of the screen leaves the HUD no room outside it.
        let tall = CGRect(x: 400, y: 0, width: 600, height: 1117)
        let inside = CGRect(x: 570, y: 1040, width: 260, height: 36)
        XCTAssertEqual(destination(700, 1058, region: tall, hud: inside), CGPoint(x: 700, y: 558.5))
        XCTAssertNil(destination(700, 900, region: tall, hud: inside), "beside the HUD the page is under the pointer")
    }

    func testAScrollIsNotSentToTheHUD() {
        // The HUD over the middle of the region: the scroll goes to the page beside it.
        let centred = CGRect(x: 570, y: 432, width: 260, height: 36)
        let sent = try? XCTUnwrap(destination(120, 90, hud: centred))
        XCTAssertEqual(sent, CGPoint(x: 700, y: 325))
        XCTAssertFalse(centred.contains(sent ?? .zero))
    }

    func testARegionWithNoAreaSendsNothingAnywhere() {
        XCTAssertNil(destination(700, 724, region: CGRect(x: 400, y: 200, width: 0, height: 500)))
    }

    /// An app that only scrolls under the pointer itself gets the pointer
    /// after all, rather than a capture that does nothing.
    func testThePointerIsBroughtInWhenScrollingIntoTheRegionMovesNothing() {
        let ignored = { ScrollCaptureController.redirectedScrollsAreIgnored(
            scrolled: $0, failures: $1, regionHeight: 600) }
        XCTAssertFalse(ignored(0, 0))
        // A working capture has its first strip within a third of the region.
        XCTAssertFalse(ignored(240, 0))
        XCTAssertTrue(ignored(600, 0), "a whole region scrolled by hand and nothing stitched")
        XCTAssertFalse(ignored(0, 2))
        XCTAssertTrue(ignored(0, 3), "auto-scroll failing from the start")
        XCTAssertFalse(ScrollCaptureController.redirectedScrollsAreIgnored(scrolled: 0, failures: 0, regionHeight: 0))
    }

    func testThePointerWaitsOnTheHUDClearOfItsButtons() {
        let hud = ScrollCaptureHUDView()
        // The label grows as the capture does; the buttons move with it.
        for pixelSize in [CGSize.zero, CGSize(width: 1036, height: 24000)] {
            hud.update(stripCount: 3, pixelSize: pixelSize, backingScale: 2)
            let point = hud.pointerRestingPoint
            XCTAssertTrue(hud.bounds.contains(point), "\(pixelSize)")
            XCTAssertFalse(hud.hitTest(point) is NSButton, "a click there would stop the capture: \(pixelSize)")
        }
    }
}
