import Cocoa
import XCTest

/// Behaviour that only goes wrong with more than one display — or with an
/// overlay reused after a session ended early.
@MainActor
final class MultiDisplayCaptureTests: XCTestCase {

    private func makeOverlay() -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.screenshotImage = ImageProbe.quadrantImage(width: 400, height: 300)
        return view
    }

    func testFSelectsTheWholeDisplay() {
        withDefaults(["captureSnapMode": nil, "windowSnapEnabled": true]) {
            let view = makeOverlay()
            view.keyDown(with: TestKeyEvent.keyDown(characters: "f", keyCode: 3))
            XCTAssertEqual(view.state, .selected)
            XCTAssertEqual(view.selectionRect, view.bounds)
        }
    }

    func testSelectingTheWholeDisplayLeavesAnExistingSelectionAlone() {
        let view = makeOverlay()
        view.applySelection(NSRect(x: 10, y: 10, width: 50, height: 40))
        view.selectWholeScreen()
        XCTAssertEqual(view.selectionRect, NSRect(x: 10, y: 10, width: 50, height: 40))
    }

    func testResettingAnOverlayMidScrollCaptureEndsTheSession() {
        // A pooled overlay dismissed while a scroll capture ran kept its HUD,
        // key monitors and event tap into the next capture.
        let view = makeOverlay()
        view.applySelection(NSRect(x: 20, y: 20, width: 200, height: 150))
        view.startScrollCaptureMode()
        XCTAssertTrue(view.isScrollCapturing)

        view.reset()
        XCTAssertFalse(view.isScrollCapturing)
    }

    func testStartingScrollCaptureTwiceDoesNotStackSessions() {
        let view = makeOverlay()
        view.applySelection(NSRect(x: 20, y: 20, width: 200, height: 150))
        view.startScrollCaptureMode()
        view.startScrollCaptureMode()
        view.stopScrollCaptureMode()
        XCTAssertFalse(view.isScrollCapturing)
    }
}
