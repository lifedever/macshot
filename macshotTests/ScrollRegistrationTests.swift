import Cocoa
import XCTest

/// Scroll capture measures each scroll by registering a frame against the one
/// before. A pinned, high-contrast toolbar over sparse content (Shadowrocket's
/// settings pages) dragged that measurement to a small near-constant value, so
/// no strip was ever added and the capture ended at the first screen.
final class ScrollRegistrationTests: XCTestCase {

    private let width = 480, height = 720, header = 72, pageHeight = 3000

    /// Light-grey page of sparse white cards, each with a few short dark text
    /// bars, drawn top-down.
    private lazy var page: CGImage = {
        let image = ImageProbe.makeImage(width: width, height: pageHeight) { [self] cg in
            cg.translateBy(x: 0, y: CGFloat(pageHeight)); cg.scaleBy(x: 1, y: -1)
            cg.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
            var y = 20, card = 0
            while y < pageHeight - 200 {
                let rows = 1 + card % 3
                let cardHeight = rows * 40
                cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                cg.addPath(CGPath(roundedRect: CGRect(x: 16, y: y, width: width - 32, height: cardHeight),
                                  cornerWidth: 14, cornerHeight: 14, transform: nil))
                cg.fillPath()
                for row in 0..<rows {
                    cg.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
                    cg.fill(CGRect(x: 32, y: y + row * 40 + 14,
                                   width: 60 + (card * 37 + row * 53) % 140, height: 12))
                    cg.setFillColor(CGColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1))
                    cg.fill(CGRect(x: width - 90, y: y + row * 40 + 10, width: 50, height: 20))
                }
                cg.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                cg.fill(CGRect(x: 32, y: y + cardHeight + 10, width: 150 + card * 29 % 160, height: 9))
                y += cardHeight + 70
                card += 1
            }
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }()

    /// The window scrolled down by `offset`: the page under a pinned blue bar.
    /// Once scrolled, `fadingTitle` swaps the bar's title for a narrower mark,
    /// as Shadowrocket's does, so part of the bar changes while the rest of it
    /// — including the buttons below the title — stays put.
    private func frame(scrolledBy offset: Int, fadingTitle: Bool = false) throws -> CGImage {
        let image = ImageProbe.makeImage(width: width, height: height) { [self] cg in
            cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: header, width: width, height: height - header))
            cg.translateBy(x: 0, y: CGFloat(header - offset + pageHeight)); cg.scaleBy(x: 1, y: -1)
            cg.draw(page, in: CGRect(x: 0, y: 0, width: width, height: pageHeight))
            cg.restoreGState()
            cg.setFillColor(CGColor(srgbRed: 0.24, green: 0.43, blue: 0.72, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: width, height: header))
            cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            cg.fill(CGRect(x: 14, y: 26, width: 6, height: 40))
            if fadingTitle && offset > 0 {
                cg.fill(CGRect(x: width / 2 - 6, y: 22, width: 12, height: 26))
            } else {
                cg.fill(CGRect(x: width / 2 - 24, y: 30, width: 48, height: 14))
            }
            cg.fill(CGRect(x: width - 40, y: 28, width: 22, height: 6))
            cg.fill(CGRect(x: width - 34, y: 40, width: 10, height: 24))
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    func testAPinnedToolbarDoesNotHideTheScrollBeforeItIsConfirmed() throws {
        let top = try frame(scrolledBy: 0)
        for offset in [90, 150, 240] {
            let shift = try XCTUnwrap(ScrollCaptureController.verticalShift(
                current: try frame(scrolledBy: offset), previous: top,
                confirmedHeaderRows: nil, rightMarginPx: 0), "offset \(offset)")
            XCTAssertEqual(shift, CGFloat(offset), accuracy: 1, "offset \(offset)")
        }
    }

    func testAConfirmedHeaderIsCroppedAway() throws {
        let shift = try XCTUnwrap(ScrollCaptureController.verticalShift(
            current: try frame(scrolledBy: 150), previous: try frame(scrolledBy: 0),
            confirmedHeaderRows: header, rightMarginPx: 0))
        XCTAssertEqual(shift, 150, accuracy: 1)
    }

    func testATitleChangingInsideThePinnedBarDoesNotHideTheScroll() throws {
        let top = try frame(scrolledBy: 0, fadingTitle: true)
        for offset in [60, 150, 240] {
            let shift = try XCTUnwrap(ScrollCaptureController.verticalShift(
                current: try frame(scrolledBy: offset, fadingTitle: true), previous: top,
                confirmedHeaderRows: nil, rightMarginPx: 0), "offset \(offset)")
            XCTAssertEqual(shift, CGFloat(offset), accuracy: 1, "offset \(offset)")
        }
    }

    func testFramesSharingNoContentHaveNoShift() throws {
        // A flick carried the page past a whole frame between two grabs.
        // Registration still produces some offset; it must not be returned.
        XCTAssertNil(ScrollCaptureController.verticalShift(
            current: try frame(scrolledBy: 1500), previous: try frame(scrolledBy: 0),
            confirmedHeaderRows: header, rightMarginPx: 0))
    }

    func testAnUnscrolledFrameShowsNoShift() throws {
        let top = try frame(scrolledBy: 0)
        let shift = ScrollCaptureController.verticalShift(
            current: top, previous: top, confirmedHeaderRows: nil, rightMarginPx: 0)
        XCTAssertEqual(shift ?? 0, 0, accuracy: 0.5)
    }
}

/// Stitched as captured, a scrollbar left a dash down the right edge of the
/// long image for every strip.
final class ScrollbarCoverTests: XCTestCase {

    private let background = CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)

    /// 100×40: a white card up to column 80 on a light page, and a dark
    /// scrollbar thumb in columns 92–97, rows 10–20 from the top.
    private func strip() throws -> CGImage {
        let image = ImageProbe.makeImage(width: 100, height: 40) { [self] cg in
            cg.setFillColor(background)
            cg.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
            cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            cg.fill(CGRect(x: 0, y: 5, width: 80, height: 30))
            cg.setFillColor(CGColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            cg.fill(CGRect(x: 92, y: 20, width: 6, height: 10))
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func covered(margin: Int) throws -> NSImage {
        let source = try strip()
        return ImageProbe.makeImage(width: 100, height: 40) { cg in
            let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
            cg.draw(source, in: rect)
            ScrollCaptureController.coverRightMargin(of: source, at: rect, marginPx: margin, in: cg)
        }
    }

    func testTheThumbIsReplacedByThePageBesideIt() throws {
        let image = try covered(margin: 10)
        let thumb = try XCTUnwrap(ImageProbe.pixelColor(image, x: 95, y: 15))
        XCTAssertEqual(thumb.redComponent, 0.95, accuracy: 0.02)
        // Everything left of the margin is untouched.
        XCTAssertEqual(try XCTUnwrap(ImageProbe.pixelColor(image, x: 40, y: 20)).redComponent, 1, accuracy: 0.01)
    }

    func testWithoutAScrollbarNothingIsCovered() throws {
        let thumb = try XCTUnwrap(ImageProbe.pixelColor(try covered(margin: 0), x: 95, y: 15))
        XCTAssertEqual(thumb.redComponent, 0.3, accuracy: 0.02)
    }
}
