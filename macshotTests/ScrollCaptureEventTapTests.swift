import Cocoa
import XCTest

/// During a scroll capture scrolling is sent into the region wherever the
/// pointer is, so the pointer, which is never moved, can stay off the page:
/// an app lights up whatever scrolls under the pointer, and Mail's reply and
/// delete buttons ended up in the long image.
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
        XCTAssertEqual(destination(700, 724), middle, "on the HUD")
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
}
