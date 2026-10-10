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

/// "Open in Editor" used to crop the full-screen shot as a plain rectangle,
/// carrying in whatever covered a snapped window. It now opens the window as
/// it would be delivered, without the drop shadow.
@MainActor
final class WindowSnapEditorImageTests: XCTestCase {

    private let screenRed = CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)

    /// A window snap of a 100×80 window whose bottom-left 10×10 corner is
    /// transparent, over a red screen shot.
    private func makeSnappedOverlay(occluded: Bool) -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        view.screenshotImage = ImageProbe.solidImage(width: 200, height: 160, color: screenRed)
        view.applySelection(NSRect(x: 20, y: 20, width: 100, height: 80))
        view.selectionIsWindowSnap = true
        view.snappedWindowWasOccluded = occluded
        view.snappedWindowImage = ImageProbe.makeImage(width: 100, height: 80) { cg in
            cg.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
            cg.clear(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        return view
    }

    func testACoveredWindowOpensAsItsOwnCapture() throws {
        let image = try XCTUnwrap(makeSnappedOverlay(occluded: true).windowSnapImage())
        let centre = try XCTUnwrap(ImageProbe.pixelColor(image, x: 50, y: 40))
        XCTAssertGreaterThan(centre.blueComponent, 0.8, "the covering UI must not come along")
        XCTAssertLessThan(centre.redComponent, 0.2)
    }

    func testAnUncoveredWindowKeepsTheOnScreenPixels() throws {
        let image = try XCTUnwrap(makeSnappedOverlay(occluded: false).windowSnapImage())
        let centre = try XCTUnwrap(ImageProbe.pixelColor(image, x: 50, y: 40))
        XCTAssertGreaterThan(centre.redComponent, 0.8)
    }

    func testTheWindowKeepsItsShapeButNotItsShadow() throws {
        for occluded in [true, false] {
            let view = makeSnappedOverlay(occluded: occluded)
            let image = try XCTUnwrap(view.windowSnapImage())
            XCTAssertEqual(image.size, NSSize(width: 100, height: 80), "occluded \(occluded)")
            // y counts from the top, so the bottom-left corner is at y = 75.
            let corner = try XCTUnwrap(ImageProbe.pixelColor(image, x: 5, y: 75))
            XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01, "occluded \(occluded)")
            // The delivered image does carry the shadow, in padding around it.
            XCTAssertGreaterThan(try XCTUnwrap(view.captureSelectedRegion()).size.width, 100)
        }
    }

    func testOnlyAWindowSnapWithItsCaptureHasOne() {
        let notSnapped = makeSnappedOverlay(occluded: false)
        notSnapped.selectionIsWindowSnap = false
        XCTAssertNil(notSnapped.windowSnapImage())

        let notLanded = makeSnappedOverlay(occluded: true)
        notLanded.snappedWindowImage = nil
        XCTAssertNil(notLanded.windowSnapImage())
    }
}
