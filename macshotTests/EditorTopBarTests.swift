import Cocoa
import XCTest

/// The editor's top bar buttons were plain borderless `NSButton`s: nothing on
/// hover, almost nothing on press, and the crop button gave no sign that it
/// had switched the editor into cropping.
@MainActor
final class EditorTopBarTests: XCTestCase {

    // MARK: - Hover and press

    private func makeButton() -> EditorTopBarButton {
        let button = EditorTopBarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        button.image = NSImage(systemSymbolName: "crop", accessibilityDescription: nil)
        return button
    }

    private func enterExit(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    /// A corner pixel: inside the rounded fill, clear of the glyph.
    private func cornerPixel(of button: EditorTopBarButton) throws -> NSColor {
        let image = ImageProbe.makeImage(width: 24, height: 22) { cg in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            button.draw(button.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        return try XCTUnwrap(ImageProbe.pixelColor(image, x: 3, y: 11))
    }

    func testHoverFillsTheButtonAndLeavingClearsIt() throws {
        let button = makeButton()
        XCTAssertEqual(try cornerPixel(of: button).alphaComponent, 0, accuracy: 0.01, "idle: no fill")

        button.mouseEntered(with: try enterExit(.mouseEntered))
        XCTAssertTrue(button.isHovered)
        XCTAssertGreaterThan(try cornerPixel(of: button).alphaComponent, 0.05, "hover must show a fill")

        button.mouseExited(with: try enterExit(.mouseExited))
        XCTAssertFalse(button.isHovered)
        XCTAssertEqual(try cornerPixel(of: button).alphaComponent, 0, accuracy: 0.01)
    }

    func testPressingFillsMoreStronglyThanHovering() {
        let hover = EditorTopBarButton.highlightFill(pressed: false).alphaComponent
        let press = EditorTopBarButton.highlightFill(pressed: true).alphaComponent
        XCTAssertGreaterThan(press, hover)
    }

    func testAnActiveButtonTakesTheAccentFill() throws {
        let button = makeButton()
        button.isActive = true
        let pixel = try cornerPixel(of: button)
        XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.01, "active: an opaque accent pill")
        XCTAssertEqual(button.contentTintColor, ToolbarButtonView.onAccentColor,
                       "the glyph switches to the on-accent colour, like a selected tool")

        button.isActive = false
        XCTAssertNotEqual(button.contentTintColor, ToolbarButtonView.onAccentColor)
    }

    // MARK: - Crop state

    /// An editor wired the way `DetachedEditorWindowController` wires it: the
    /// top bar is a sibling of the canvas in the chrome container.
    private func makeEditorWithTopBar() -> (EditorView, EditorTopBarView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let editor = EditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        editor.screenshotImage = ImageProbe.quadrantImage(width: 300, height: 200)
        editor.currentTool = .arrow
        let topBar = EditorTopBarView(frame: NSRect(x: 0, y: 368, width: 600, height: 32))
        topBar.overlayView = editor
        container.addSubview(topBar)
        editor.chromeParentView = container
        editor.applySelection(NSRect(x: 0, y: 0, width: 300, height: 200))
        return (editor, topBar)
    }

    func testTheCropButtonStaysLitWhileCropping() {
        let (editor, topBar) = makeEditorWithTopBar()
        XCTAssertFalse(topBar.isCropActive)

        editor.toggleCropMode()
        XCTAssertEqual(editor.currentTool, .crop)
        XCTAssertTrue(topBar.isCropActive, "entering crop must light the button")

        editor.toggleCropMode()
        XCTAssertNotEqual(editor.currentTool, .crop)
        XCTAssertFalse(topBar.isCropActive, "leaving crop must clear it")
    }

    func testLeavingCropByPickingAnotherToolClearsTheButton() {
        let (editor, topBar) = makeEditorWithTopBar()
        editor.toggleCropMode()
        XCTAssertTrue(topBar.isCropActive)

        editor.currentTool = .rectangle
        XCTAssertFalse(topBar.isCropActive)
    }
}
