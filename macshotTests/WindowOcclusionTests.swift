import CoreGraphics
import XCTest

/// A window snap takes its pixels from the full-screen shot unless something
/// covered the window when that shot was taken. Only layer-0 windows used to
/// count, so a menu-bar app's menu or Control Center over the window was baked
/// into the result.
final class WindowOcclusionTests: XCTestCase {

    private typealias Stacked = ScreenCaptureManager.StackedWindow

    private let ownPID: pid_t = 999
    private let target = Stacked(
        windowID: 10, ownerPID: 1, alpha: 1, bounds: CGRect(x: 100, y: 100, width: 800, height: 600))

    private func window(_ id: CGWindowID, pid: pid_t = 2, alpha: Double = 1, _ rect: CGRect) -> Stacked {
        Stacked(windowID: id, ownerPID: pid, alpha: alpha, bounds: rect)
    }

    private func covered(_ stack: [Stacked]) -> Bool? {
        ScreenCaptureManager.windowIsCovered(target.windowID, in: stack, ownPID: ownPID)
    }

    func testAMenuOverTheWindowCoversIt() {
        let menu = window(20, CGRect(x: 600, y: 80, width: 240, height: 400))
        XCTAssertEqual(covered([menu, target]), true)
    }

    func testAWindowBesideItDoesNotCoverIt() {
        let beside = window(20, CGRect(x: 1000, y: 100, width: 300, height: 300))
        XCTAssertEqual(covered([beside, target]), false)
    }

    func testAWindowBelowItDoesNotCoverIt() {
        let below = window(20, CGRect(x: 0, y: 0, width: 1500, height: 900))
        XCTAssertEqual(covered([target, below]), false)
    }

    func testTheMenuBarTouchingItsTopEdgeDoesNotCoverIt() {
        let menuBar = window(20, CGRect(x: 0, y: 0, width: 1500, height: 100))
        XCTAssertEqual(covered([menuBar, target]), false)
    }

    func testACornerBarelyOverlappingDoesNotCoverIt() {
        let corner = window(20, CGRect(x: 0, y: 0, width: 105, height: 105))
        XCTAssertEqual(covered([corner, target]), false)
    }

    func testMacshotsOwnOverlayDoesNotCoverIt() {
        let overlay = window(20, pid: ownPID, CGRect(x: 0, y: 0, width: 1500, height: 900))
        XCTAssertEqual(covered([overlay, target]), false)
    }

    func testAnInvisibleWindowDoesNotCoverIt() {
        let hidden = window(20, alpha: 0, CGRect(x: 200, y: 200, width: 200, height: 60))
        XCTAssertEqual(covered([hidden, target]), false)
    }

    func testAWindowMissingFromTheStackHasNoAnswer() {
        let other = window(20, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertNil(covered([other]))
        XCTAssertNil(covered([]))
    }

    func testTheStackRecordedWithTheShotDecides() {
        // The window isn't on screen now; only the recorded stack knows it.
        let id: CGWindowID = 0xFFFF_FFF0
        let recordedTarget = window(id, CGRect(x: 100, y: 100, width: 800, height: 600))
        let menu = window(id - 1, CGRect(x: 600, y: 80, width: 240, height: 400))
        XCTAssertTrue(ScreenCaptureManager.windowIsOccluded(
            windowID: id, stackAtCapture: [menu, recordedTarget]))
        XCTAssertFalse(ScreenCaptureManager.windowIsOccluded(
            windowID: id, stackAtCapture: [recordedTarget, menu]))
    }
}
