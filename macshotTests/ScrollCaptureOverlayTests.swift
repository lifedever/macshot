import Cocoa
import XCTest

/// While scroll capture runs, the overlay shows the live screen with the
/// region picked out as recording does: everything outside it dimmed, an
/// outline outside its edge, and nothing at all drawn inside it.
@MainActor
final class ScrollCaptureOverlayTests: XCTestCase {

    private func render(scrim: Bool) throws -> NSImage {
        var image: NSImage?
        withDefaults(["disableSelectionOutsideShadow": !scrim]) {
            let overlay = OverlayView()
            overlay.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
            overlay.applySelection(NSRect(x: 20, y: 20, width: 100, height: 80))
            overlay.isScrollCapturing = true
            image = ImageProbe.makeImage(width: 200, height: 160) { cg in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
                overlay.draw(overlay.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return try XCTUnwrap(image)
    }

    func testOutsideTheRegionIsDimmed() throws {
        let corner = try XCTUnwrap(ImageProbe.pixelColor(try render(scrim: true), x: 5, y: 5))
        XCTAssertEqual(corner.alphaComponent, OverlayView.selectionScrimAlpha, accuracy: 0.02)
    }

    func testNothingIsDrawnInsideTheRegion() throws {
        let image = try render(scrim: true)
        // y counts from the top: the region spans x 20..<120, y 60..<140.
        for (x, y) in [(70, 100), (20, 100), (119, 100), (70, 60), (70, 139)] {
            let pixel = try XCTUnwrap(ImageProbe.pixelColor(image, x: x, y: y))
            XCTAssertEqual(pixel.alphaComponent, 0, accuracy: 0.01, "pixel \(x),\(y)")
        }
    }

    func testTheScrimSettingTurnsTheDimmingOff() throws {
        let corner = try XCTUnwrap(ImageProbe.pixelColor(try render(scrim: false), x: 5, y: 5))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01)
    }
}
