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

    /// The video editor is always dark and its export panel is built for that
    /// (light text). On a light toolbar theme it opened on a white surface.
    func testAVideoEditorPanelStaysDarkOnALightToolbarTheme() throws {
        let white = try NSKeyedArchiver.archivedData(withRootObject: NSColor.white, requiringSecureCoding: true)
        try withDefaults(["toolbarBgColor": white]) {
            XCTAssertFalse(ToolbarLayout.isDarkSurface)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))

            PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds, of: anchor,
                               preferredEdge: .maxY, surface: .videoEditor)
            let editorPanel = try XCTUnwrap(self.panel)
            XCTAssertEqual(editorPanel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
            XCTAssertEqual(editorPanel.contentView?.layer?.backgroundColor, VideoEditorStyle.panelRaised.cgColor)
            PopoverHelper.dismiss()

            PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            let toolbarPanel = try XCTUnwrap(self.panel)
            XCTAssertEqual(toolbarPanel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
            XCTAssertEqual(toolbarPanel.contentView?.layer?.backgroundColor, NSColor.white.cgColor)
        }
    }

    /// The colour picker opened from the video editor's inspector draws its
    /// glyphs and hex field for the editor's dark panel, not the toolbar theme.
    func testTheColourPickerFollowsTheSurfaceItOpensOn() throws {
        let white = try NSKeyedArchiver.archivedData(withRootObject: NSColor.white, requiringSecureCoding: true)
        try withDefaults(["toolbarBgColor": white]) {
            func hexField(of picker: ColorPickerView) throws -> NSTextField {
                try XCTUnwrap(picker.subviews.compactMap { $0 as? NSTextField }.first)
            }
            func brightness(_ color: NSColor?) -> CGFloat {
                (color?.usingColorSpace(.deviceRGB)?.brightnessComponent) ?? -1
            }
            let editorField = try hexField(of: ColorPickerView(surface: .videoEditor))
            XCTAssertEqual(editorField.appearance?.name, .darkAqua)
            XCTAssertGreaterThan(brightness(editorField.textColor), 0.8, "light text on the dark panel")

            let toolbarField = try hexField(of: ColorPickerView())
            XCTAssertEqual(toolbarField.appearance?.name, .aqua)
            XCTAssertLessThan(brightness(toolbarField.textColor), 0.5, "dark text on the light toolbar theme")
        }
    }

    func testListsGetTheNarrowInset() throws {
        let list = ListPickerView()
        list.items = [.init(title: "One", isSelected: true), .init(title: "Two", isSelected: false)]
        PopoverHelper.showList(list, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let panel = try XCTUnwrap(self.panel)
        XCTAssertEqual(panel.frame.width, list.preferredSize.width + PopoverHelper.listInset * 2, accuracy: 0.5)
    }
}
