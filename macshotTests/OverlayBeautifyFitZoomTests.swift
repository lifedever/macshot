import Cocoa
import XCTest

/// A beautified window snap is often larger than the screen once padding is added, so the
/// overlay scales its canvas down to fit (`updateBeautifyFitZoom`). Everything on screen must
/// then follow the scaled selection, and nothing around the preview may show the screen:
///
/// - the corner brackets were drawn, and clicked, where the window had been before the canvas
///   shrank, beside a preview that sat in the middle of the screen;
/// - the size box was placed by the same unscaled rect;
/// - the preview repainted its shadow's bleed with the screenshot under the zoom, so a
///   miniature of the other apps framed the result against an otherwise black backdrop.
///
/// The screen here is solid red: any of it showing through is unmistakable.
@MainActor
final class OverlayBeautifyFitZoomTests: XCTestCase {

    private let width = 400
    private let height = 300
    private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private func makeOverlay(selection: NSRect) -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.screenshotImage = ImageProbe.solidImage(width: width, height: height, color: red)
        view.applySelection(selection)
        view.beautifyEnabled = true
        view.beautifyMode = .rounded
        view.beautifyBackgroundEnabled = true
        view.beautifyPadding = 48
        view.beautifyShadowRadius = 20
        view.beautifyStyleIndex = 0
        view.updateBeautifyFitZoom()
        return view
    }

    /// Off-centre and too big to fit with its padding, like a tall window snap.
    private func makeZoomedOverlay() throws -> OverlayView {
        let view = makeOverlay(selection: NSRect(x: 10, y: 20, width: 300, height: 250))
        try XCTSkipUnless(OverlayView.beautifyFitZoomEnabled)
        XCTAssertLessThan(view.zoomLevel, 1, "precondition: the composition must not fit")
        XCTAssertNotEqual(view.selectionViewRect, view.selectionRect, "precondition: the zoom moves the selection")
        return view
    }

    private func render(_ view: OverlayView) -> NSImage {
        ImageProbe.makeImage(width: width, height: height) { cg in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Pixel at a view-space point (bottom-left origin).
    private func pixel(_ image: NSImage, at point: NSPoint,
                       file: StaticString = #filePath, line: UInt = #line) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let x = Int(point.x.rounded(.down))
        let y = height - 1 - Int(point.y.rounded(.down))
        let color = try XCTUnwrap(ImageProbe.pixelColor(image, x: x, y: y), file: file, line: line)
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    // MARK: - Brackets

    func testTheBracketsAreDrawnOnTheScaledSelection() throws {
        let view = try makeZoomedOverlay()
        let selection = view.selectionViewRect
        let (_, arm, _) = view.handleGeometry(for: selection)
        let image = render(view)

        // Along the top arm of the top-left bracket: the bracket's white body.
        let onBracket = try pixel(image, at: NSPoint(x: selection.minX + arm / 2, y: selection.maxY))
        XCTAssertGreaterThan(min(onBracket.r, onBracket.g, onBracket.b), 0.85,
                             "no bracket at the selection's top-left corner as drawn: \(onBracket)")
    }

    func testTheBracketsAreClickedWhereTheyAreDrawn() throws {
        let view = try makeZoomedOverlay()
        let drawn = view.selectionViewRect
        XCTAssertEqual(view.hitTestHandle(at: NSPoint(x: drawn.minX + 1, y: drawn.maxY - 1)), .topLeft)
        XCTAssertEqual(view.hitTestHandle(at: NSPoint(x: drawn.maxX - 1, y: drawn.minY + 1)), .bottomRight)
        XCTAssertEqual(view.hitTestHandle(at: NSPoint(x: drawn.midX, y: drawn.maxY)), .top)

        // Where the window was before the canvas shrank, nothing is drawn and nothing is hit.
        let unscaled = view.selectionRect
        XCTAssertEqual(view.hitTestHandle(at: NSPoint(x: unscaled.maxX - 1, y: unscaled.maxY - 1)),
                       OverlayView.ResizeHandle.none)
    }

    // MARK: - Backdrop

    func testNoScreenShowsAroundTheScaledPreview() throws {
        let view = try makeZoomedOverlay()
        let image = render(view)
        let background = view.canvasToView(view.beautifyPreviewFrames.background)
        let bleed = view.canvasToView(view.beautifyPreviewFrames.bleed)
        XCTAssertGreaterThan(background.minX - bleed.minX, 4, "precondition: the shadow needs room to bleed")

        // In the shadow's bleed, just outside the background, and far from the preview.
        for point in [NSPoint(x: background.minX - 3, y: background.midY),
                      NSPoint(x: background.midX, y: background.maxY + 3),
                      NSPoint(x: 2, y: 2),
                      NSPoint(x: CGFloat(width) - 3, y: CGFloat(height) - 3)] {
            let p = try pixel(image, at: point)
            XCTAssertLessThan(max(p.r, p.g, p.b), 0.05,
                              "the screen shows at \(point) around the scaled preview: \(p)")
        }
    }

    func testWithoutABackgroundThePaddingShowsNoScreenWhileScaled() throws {
        let view = try makeZoomedOverlay()
        view.beautifyBackgroundEnabled = false
        let image = render(view)
        let background = view.canvasToView(view.beautifyPreviewFrames.background)
        let inPadding = NSPoint(x: background.minX + 3, y: background.midY)
        let p = try pixel(image, at: inPadding)
        XCTAssertLessThan(p.r, 0.05, "a scaled copy of the screen shows in the padding: \(p)")
    }

    /// At 1× the preview's frame has to be indistinguishable from the rest of the backdrop,
    /// with the scrim on or off. It used to dim the bleed by a fixed 0.45 whatever the setting.
    func testAtFullSizeTheBleedMatchesTheBackdrop() throws {
        for scrimDisabled in [false, true] {
            try withDefaults(["disableSelectionOutsideShadow": scrimDisabled]) {
                let view = makeOverlay(selection: NSRect(x: 150, y: 110, width: 100, height: 80))
                XCTAssertEqual(view.zoomLevel, 1, "precondition: a small selection fits")
                let image = render(view)
                let background = view.beautifyPreviewFrames.background
                XCTAssertGreaterThan(background.minX - view.beautifyPreviewFrames.bleed.minX, 4,
                                     "precondition: the shadow needs room to bleed")
                let inBleed = try pixel(image, at: NSPoint(x: background.minX - 3, y: background.midY))
                let farAway = try pixel(image, at: NSPoint(x: 3, y: 3))
                XCTAssertEqual(inBleed.r, farAway.r, accuracy: 0.02,
                               "scrim disabled: \(scrimDisabled) — bleed \(inBleed), backdrop \(farAway)")
            }
        }
    }

    // MARK: - Gestures

    private let gestureSettings: [String: Any?] = [
        "startCapturesInMoveMode": true,
        "rememberLastTool": false,
        "boundarySnapEnabled": false,
        "doubleClickToCopy": false,
        "openEditorAfterSelection": false,
    ]

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The grabbed corner follows the pointer on screen. The drag used to hand the view-space
    /// pointer to the canvas-space selection, so the corner jumped away; and the zoom re-fitted
    /// on every step, moving the canvas under the pointer.
    func testDraggingABracketKeepsTheCornerUnderThePointer() throws {
        try withDefaults(gestureSettings) {
            let view = try makeZoomedOverlay()
            let zoom = view.zoomLevel
            let drawn = view.selectionViewRect
            let grab = NSPoint(x: drawn.maxX - 1, y: drawn.maxY - 1)
            XCTAssertEqual(view.hitTestHandle(at: grab), .topRight, "precondition")
            let end = NSPoint(x: grab.x + 12, y: grab.y + 8)

            view.mouseDown(with: mouse(.leftMouseDown, at: grab))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
            view.updateBeautifyFitZoom()  // what the next frame does
            XCTAssertEqual(view.zoomLevel, zoom, accuracy: 0.0001, "the zoom moved mid-gesture")
            let corner = view.canvasToView(NSPoint(x: view.selectionRect.maxX, y: view.selectionRect.maxY))
            XCTAssertEqual(corner.x, end.x, accuracy: 0.5, "the corner left the pointer")
            XCTAssertEqual(corner.y, end.y, accuracy: 0.5, "the corner left the pointer")
            view.mouseUp(with: mouse(.leftMouseUp, at: end))
        }
    }

    func testMovingTheSelectionFollowsThePointerOnScreen() throws {
        try withDefaults(gestureSettings) {
            let view = try makeZoomedOverlay()
            let before = view.selectionRect
            let drawn = view.selectionViewRect
            let start = NSPoint(x: drawn.midX, y: drawn.midY)
            let end = NSPoint(x: start.x + 20, y: start.y - 10)

            view.mouseDown(with: mouse(.leftMouseDown, at: start))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
            let moved = view.canvasToView(view.selectionRect.origin)
            let was = view.canvasToView(before.origin)
            XCTAssertEqual(moved.x - was.x, 20, accuracy: 0.5, "the selection lagged or ran ahead of the pointer")
            XCTAssertEqual(moved.y - was.y, -10, accuracy: 0.5, "the selection lagged or ran ahead of the pointer")
            view.mouseUp(with: mouse(.leftMouseUp, at: end))
        }
    }

    // MARK: - The next capture

    /// A capture that ends mid-gesture — double-click to copy returns from mouseUp early, and
    /// the keyboard can confirm while a bracket is held — must not leave the next capture
    /// scaled. The stuck resize flag froze the zoom, the next capture kept the old scale, and
    /// its whole screen was painted black.
    func testTheNextCaptureStartsUnscaledAfterOneEndsMidGesture() throws {
        try withDefaults(gestureSettings) {
            let view = try makeZoomedOverlay()
            var previewShown: Bool?
            view.externalScreenshotPreviewVisibilitySetter = { previewShown = $0 }
            let drawn = view.selectionViewRect
            view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: drawn.maxX - 1, y: drawn.maxY - 1)))

            view.reset()  // the capture ends; no mouseUp arrives
            XCTAssertEqual(view.zoomLevel, 1, "the next capture inherits the scale")
            XCTAssertEqual(previewShown, true, "the screen's preview layer stays hidden")

            view.screenshotImage = ImageProbe.solidImage(width: width, height: height, color: red)
            let image = render(view)
            let middle = try pixel(image, at: NSPoint(x: width / 2, y: height / 2))
            XCTAssertGreaterThan(middle.r, 0.3, "the idle overlay is black instead of the dimmed screen: \(middle)")
        }
    }

    func testLeavingTheSelectionAlwaysReturnsToFullSize() throws {
        let view = try makeZoomedOverlay()
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: view.selectionViewRect.maxX - 1,
                                                               y: view.selectionViewRect.maxY - 1)))
        view.beautifyEnabled = false  // the composition no longer needs to fit
        view.updateBeautifyFitZoom()
        XCTAssertEqual(view.zoomLevel, 1, "a held gesture kept a zoom nothing needs any more")
    }

    // MARK: - Size box

    func testTheSizeBoxIsPlacedByTheScaledSelection() throws {
        let view = try makeZoomedOverlay()
        view.updateResolutionBox()
        let box = view.resolutionBoxRect
        XCTAssertGreaterThan(box.width, 1)

        let fresh = ResolutionBoxView()
        let selection = view.selectionViewRect
        let expectedX = max(view.bounds.minX + 2,
                            min(selection.midX - fresh.dimensionsCenterX,
                                view.bounds.maxX - fresh.preferredSize.width - 2))
        XCTAssertEqual(box.minX, expectedX, accuracy: 0.5,
                       "the size box is centred on the unscaled selection, not the one on screen")
    }
}
