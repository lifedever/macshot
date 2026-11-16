import Cocoa
import XCTest

/// The live beautify preview has to show what the export will contain.
///
/// A window snap delivered without beautify keeps transparent room around the
/// window for its own drop shadow. Opened in the editor and beautified, the
/// preview filled that room white — the opaque shape it cast the shadow from
/// showed through — while the export, which casts the shadow from the image's
/// own alpha, showed the background there.
@MainActor
final class BeautifyPreviewTests: XCTestCase {

    private let imageWidth = 160
    private let imageHeight = 120
    private let windowInset: CGFloat = 20
    /// Room around the canvas for the padding the preview draws outside the image.
    private let border = 40

    /// A dark window with transparent room on every side, like a window snap
    /// delivered with its own shadow.
    private func paddedWindowImage() -> NSImage {
        ImageProbe.makeImage(width: imageWidth, height: imageHeight) { cg in
            cg.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1))
            cg.fill(CGRect(x: windowInset, y: windowInset,
                           width: CGFloat(imageWidth) - windowInset * 2,
                           height: CGFloat(imageHeight) - windowInset * 2))
        }
    }

    private func makeBeautifiedEditor(shadow: CGFloat) -> EditorView {
        let editor = EditorView()
        editor.frame = NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        editor.screenshotImage = paddedWindowImage()
        editor.applySelection(NSRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        editor.beautifyEnabled = true
        editor.beautifyMode = .rounded
        // The last style is a plain near-black gradient: no mesh render, and
        // a white fill shows up against it unmistakably.
        editor.beautifyStyleIndex = BeautifyRenderer.styles.count - 1
        editor.beautifyPadding = 48
        editor.beautifyCornerRadius = 10
        editor.beautifyShadowRadius = shadow
        editor.beautifyBackgroundEnabled = true
        return editor
    }

    /// The editor's drawing at 1x, with canvas point (0, 0) at (border, border).
    private func renderPreview(_ editor: EditorView) -> NSImage {
        ImageProbe.makeImage(width: imageWidth + border * 2, height: imageHeight + border * 2) { cg in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            cg.translateBy(x: CGFloat(border), y: CGFloat(border))
            editor.draw(editor.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The exported composition at 1x, and where the source image sits in it.
    private func renderExport(_ editor: EditorView) throws -> (image: NSImage, imageOrigin: NSPoint) {
        let source = try XCTUnwrap(editor.screenshotImage)
        let config = editor.beautifyConfig
        let output = BeautifyRenderer.render(image: source, config: config)
        let width = Int(output.size.width.rounded())
        let height = Int(output.size.height.rounded())
        let raster = ImageProbe.makeImage(width: width, height: height) { cg in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            output.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
        return (raster, BeautifyRenderer.contentRect(forImageSize: source.size, config: config).origin)
    }

    /// Pixel at a point given in the source image's own (bottom-left) coordinates.
    private func pixel(_ image: NSImage, imageOrigin: NSPoint, at point: NSPoint) throws -> NSColor {
        let x = Int(imageOrigin.x + point.x)
        let y = Int(image.size.height) - 1 - Int(imageOrigin.y + point.y)
        return try XCTUnwrap(ImageProbe.pixelColor(image, x: x, y: y))
    }

    func testTransparentRoomAroundAWindowShowsTheBackgroundNotWhite() throws {
        for shadow: CGFloat in [0, 20] {
            let editor = makeBeautifiedEditor(shadow: shadow)
            let preview = renderPreview(editor)
            let export = try renderExport(editor)
            let previewOrigin = NSPoint(x: border, y: border)

            // Inside the image but outside the window: above, beside, below it.
            for point in [NSPoint(x: 80, y: 112), NSPoint(x: 8, y: 60), NSPoint(x: 80, y: 6)] {
                let shown = try pixel(preview, imageOrigin: previewOrigin, at: point)
                let exported = try pixel(export.image, imageOrigin: export.imageOrigin, at: point)
                let label = "shadow \(shadow) at \(point)"
                XCTAssertEqual(shown.alphaComponent, 1, accuracy: 0.01, "\(label): the preview punched a hole")
                XCTAssertLessThan(shown.redComponent, 0.3, "\(label): the preview painted the room light")
                XCTAssertEqual(shown.redComponent, exported.redComponent, accuracy: 0.06, label)
                XCTAssertEqual(shown.greenComponent, exported.greenComponent, accuracy: 0.06, label)
                XCTAssertEqual(shown.blueComponent, exported.blueComponent, accuracy: 0.06, label)
            }
        }
    }
}
