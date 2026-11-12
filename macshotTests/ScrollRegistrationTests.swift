import Cocoa
import XCTest

/// Light-grey page of sparse white cards, each with a few short dark text
/// bars, drawn top-down. With `numberedRows`, every row carries its own index
/// in the left margin, to be read back with `pageRow(in:at:)`.
private func sparsePage(width: Int, height pageHeight: Int, numberedRows: Bool = false) -> CGImage {
    let image = ImageProbe.makeImage(width: width, height: pageHeight) { cg in
        cg.translateBy(x: 0, y: CGFloat(pageHeight)); cg.scaleBy(x: 1, y: -1)
        cg.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
        for row in 0..<(numberedRows ? pageHeight : 0) {
            cg.setFillColor(CGColor(srgbRed: CGFloat(row % 250) / 255, green: CGFloat(row / 250 * 10) / 255,
                                    blue: 0.5, alpha: 1))
            cg.fill(CGRect(x: 4, y: row, width: 6, height: 1))
        }
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
}

/// The index a `numberedRows` page wrote into row `y` of `image`.
private func pageRow(in image: ScrollFrameAnalyzer.Frame, at y: Int) -> Int? {
    guard let offset = image.offset(x: 6, y: y) else { return nil }
    return Int(image.bytes[offset + image.redOffset]) + Int(image.bytes[offset + image.greenOffset]) / 10 * 250
}

/// Stitches frames as a capture does: measure the scroll, look for a header
/// until one is found, add the rows that scrolled into view.
private func stitchAsACaptureDoes(_ frames: [CGImage]) throws -> (image: CGImage, headerRows: Int) {
    var previous = try XCTUnwrap(frames.first)
    var merged = previous
    var headerRows = 0
    for (index, current) in frames.enumerated().dropFirst() {
        let shift = Int(try XCTUnwrap(ScrollCaptureController.verticalShift(
            current: current, previous: previous,
            confirmedHeaderRows: headerRows > 0 ? headerRows : nil, rightMarginPx: 0),
            "frame \(index)").rounded())
        if headerRows == 0 {
            headerRows = ScrollCaptureController.pinnedHeaderRows(
                current: current, previous: previous, shiftPx: shift, rightMarginPx: 0) ?? 0
        }
        merged = try XCTUnwrap(ScrollCaptureController.stitched(
            onto: merged, frame: current, newRows: shift,
            underPinnedHeader: headerRows > 0, rightMarginPx: 0))
        previous = current
    }
    return (merged, headerRows)
}

/// Scroll capture measures each scroll by registering a frame against the one
/// before. A pinned, high-contrast toolbar over sparse content (Shadowrocket's
/// settings pages) dragged that measurement to a small near-constant value, so
/// no strip was ever added and the capture ended at the first screen.
final class ScrollRegistrationTests: XCTestCase {

    private let width = 480, height = 720, header = 72, pageHeight = 3000

    private lazy var page = sparsePage(width: width, height: pageHeight)

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

    /// At the end of a page the last scroll is usually short — 56px of a
    /// 1122px region in a recorded WeChat session. Mid-scroll a shift that
    /// short waits to accumulate; once the page has settled there is nothing
    /// left to accumulate, and it was dropped, ending the capture early.
    func testASettledFrameStitchesTheShortLastScroll() {
        XCTAssertTrue(ScrollCaptureController.isStitchable(offsetPx: 56, frameHeight: 1122, settled: true))
        XCTAssertFalse(ScrollCaptureController.isStitchable(offsetPx: 56, frameHeight: 1122, settled: false))
        XCTAssertTrue(ScrollCaptureController.isStitchable(offsetPx: 140, frameHeight: 1122, settled: false))
        for settled in [true, false] {
            XCTAssertFalse(ScrollCaptureController.isStitchable(offsetPx: 0, frameHeight: 1122, settled: settled))
            XCTAssertFalse(ScrollCaptureController.isStitchable(offsetPx: -40, frameHeight: 1122, settled: settled))
        }
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

/// A strip pinned over the top of the region need not look the same in two
/// frames. Mail's toolbar ends in one: plain while the page is at its top,
/// and once scrolled, white material the page shows through above a hairline.
/// Its rows change with every scroll, so they were never taken for a header,
/// and every frame was stitched in whole — a band across the long image at
/// each seam, over the text that belonged there.
final class ScrollPinnedStripTests: XCTestCase {

    private let width = 480, height = 720, strip = 20, pageHeight = 3000
    private lazy var page = sparsePage(width: width, height: pageHeight, numberedRows: true)

    /// The window scrolled down by `offset`, the strip over its top rows.
    private func frame(scrolledBy offset: Int, pinnedStrip: Bool = true) throws -> CGImage {
        let image = ImageProbe.makeImage(width: width, height: height) { [self] cg in
            cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
            cg.saveGState()
            cg.translateBy(x: 0, y: CGFloat(pageHeight - offset)); cg.scaleBy(x: 1, y: -1)
            cg.draw(page, in: CGRect(x: 0, y: 0, width: width, height: pageHeight))
            cg.restoreGState()
            guard pinnedStrip, offset > 0 else { return }
            cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
            cg.fill(CGRect(x: 0, y: 0, width: width, height: strip - 2))
            cg.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
            cg.fill(CGRect(x: 0, y: strip - 2, width: width, height: 2))
        }
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private let offsets = [0, 150, 310, 437, 600]

    func testAStripThatChangesWithTheScrollIsStitchedOnlyOnce() throws {
        let (image, headerRows) = try stitchAsACaptureDoes(try offsets.map { try frame(scrolledBy: $0) })
        XCTAssertEqual(headerRows, strip)

        // The page's grey margin runs unbroken down the right edge. A strip
        // stitched in again crosses it: near-white material, then the hairline.
        let pixels = try XCTUnwrap(ScrollFrameAnalyzer.frame(for: image))
        let crossed = (strip..<image.height).filter { row in
            guard let offset = pixels.offset(x: width - 4, y: row) else { return true }
            return abs(Int(pixels.bytes[offset + pixels.redOffset]) - 245) > 2
        }
        XCTAssertEqual(crossed, [], "strip rows stitched into the page")
    }

    /// Each strip used to be stitched one row short of the measured scroll,
    /// and that row of the page was gone: text crossing a seam lost a line of
    /// pixels, and the image came out a row short for every strip in it.
    func testEveryRowOfThePageIsStitchedOnce() throws {
        for pinnedStrip in [false, true] {
            let (image, headerRows) = try stitchAsACaptureDoes(
                try offsets.map { try frame(scrolledBy: $0, pinnedStrip: pinnedStrip) })
            XCTAssertEqual(headerRows > 0, pinnedStrip)
            XCTAssertEqual(image.height, height + 600, "pinned strip: \(pinnedStrip)")
            let pixels = try XCTUnwrap(ScrollFrameAnalyzer.frame(for: image))
            let rows = (0..<image.height).map { pageRow(in: pixels, at: $0) }
            XCTAssertEqual(rows, (0..<image.height).map { $0 }, "pinned strip: \(pinnedStrip)")
        }
    }

    func testAPageWithNothingPinnedHasNoHeader() throws {
        // Without the strip every row follows the scroll.
        let top = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 300, width: width, height: height)))
        let scrolled = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 450, width: width, height: height)))
        XCTAssertNil(ScrollCaptureController.pinnedHeaderRows(
            current: scrolled, previous: top, shiftPx: 150, rightMarginPx: 0))
    }
}
