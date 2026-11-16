import AppKit
import XCTest

final class UIFontsTests: XCTestCase {
    func testEachFontIsMadeOnceAndKept() {
        let first = UIFonts.monospaced(ofSize: 12, weight: .semibold)
        XCTAssertTrue(first === UIFonts.monospaced(ofSize: 12, weight: .semibold))
        XCTAssertFalse(first === UIFonts.monospacedDigit(ofSize: 12, weight: .semibold),
                       "digits-only is a different font")
        XCTAssertFalse(UIFonts.isNil(first))
        XCTAssertEqual(first.pointSize, 12)
    }

    func testTheFontsMeasureText() {
        // The crash this guards against happened while measuring a hint in Chinese.
        let size = ("按 C 复制" as NSString).size(withAttributes: [.font: UIFonts.monospaced(ofSize: 10)])
        XCTAssertGreaterThan(size.width, 0)
    }
}
