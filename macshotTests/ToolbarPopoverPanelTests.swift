import Cocoa
import XCTest

/// Toolbar pickers open in a themed panel beside their button (see
/// `PopoverHelper`). These pin where it opens and how it goes away.
@MainActor
final class ToolbarPopoverPanelTests: XCTestCase {

    private var window: NSWindow!
    private var anchor: NSView!

    override func setUp() {
        super.setUp()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: NSRect(x: visible.midX - 200, y: visible.midY - 150, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root
        anchor = NSView(frame: NSRect(x: 184, y: 40, width: 32, height: 32))
        root.addSubview(anchor)
        window.orderFrontRegardless()
    }

    override func tearDown() {
        PopoverHelper.dismiss()
        window.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private var anchorOnScreen: NSRect {
        window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private var panel: NSWindow? { window.childWindows?.first }

    func testThePanelOpensAboveTheButtonWithTheContentInset() throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        let panel = try XCTUnwrap(self.panel)
        XCTAssertTrue(PopoverHelper.isVisible)
        let inset = PopoverHelper.contentInset
        XCTAssertEqual(panel.frame.width, 100 + inset * 2, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, 80 + inset * 2, accuracy: 0.5)
        XCTAssertGreaterThan(panel.frame.minY, anchorOnScreen.maxY, "opens above the button")
        XCTAssertEqual(panel.frame.midX, anchorOnScreen.midX, accuracy: 0.5)
        XCTAssertGreaterThan(panel.level.rawValue, window.level.rawValue)
    }

    func testASideBarPanelOpensToTheLeft() throws {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 40))
        PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        let panel = try XCTUnwrap(self.panel)
        XCTAssertLessThan(panel.frame.maxX, anchorOnScreen.minX)
    }

    func testDismissingClosesThePanelAndClickingTheButtonAgainDoesNotReopen() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 60, height: 40))
        PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        PopoverHelper.dismiss()

        XCTAssertFalse(PopoverHelper.isVisible)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        // The outside-click monitor closes the panel on the button's own
        // mouseDown; the button's action must then read that as "closed".
        XCTAssertTrue(PopoverHelper.toggleClosedIfOpen())
    }

    func testListsGetTheNarrowInset() throws {
        let list = ListPickerView()
        list.items = [.init(title: "One", isSelected: true), .init(title: "Two", isSelected: false)]
        PopoverHelper.showList(list, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let panel = try XCTUnwrap(self.panel)
        XCTAssertEqual(panel.frame.width, list.preferredSize.width + PopoverHelper.listInset * 2, accuracy: 0.5)
    }
}
