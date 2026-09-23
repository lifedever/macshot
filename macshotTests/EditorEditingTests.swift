import Cocoa
import XCTest

/// Editing in the editor window must not lose work: typing still in the text
/// box belongs in every output, undo returns the previous state rather than a
/// mangled one, and transforms carry the marks along with the pixels.
@MainActor
final class EditorEditingTests: XCTestCase {

    private func makeEditor(width: CGFloat = 300, height: CGFloat = 200) -> EditorView {
        let view = EditorView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.screenshotImage = ImageProbe.quadrantImage(width: Int(width), height: Int(height))
        view.applySelection(NSRect(x: 0, y: 0, width: width, height: height))
        return view
    }

    /// Type `text` into a fresh text box, or into `existing` when re-editing.
    private func type(_ text: String, in editor: EditorView, editing existing: Annotation? = nil) {
        let controller = editor.textEditor
        if let existing {
            controller.restoreState(from: existing)
            controller.beginEditing(existing, canvas: editor)
            controller.show(in: editor, at: existing.textDrawRect.origin, color: .red,
                            existingText: existing.attributedText, existingFrame: existing.textDrawRect,
                            canvas: editor)
        } else {
            controller.show(in: editor, at: NSPoint(x: 40, y: 40), color: .red, canvas: editor)
        }
        controller.textView?.string = text
    }

    // MARK: - Uncommitted text

    func testToolbarOutputIncludesTextStillBeingTyped() {
        let editor = makeEditor()
        type("Draft", in: editor)
        XCTAssertTrue(editor.annotations.isEmpty, "precondition: the text is still in the box")

        editor.handleToolbarAction(.copy)

        XCTAssertFalse(editor.textEditor.isEditing)
        XCTAssertEqual(editor.annotations.map(\.text), ["Draft"])
    }

    func testReEditingThenCopyingKeepsTheLabel() {
        let editor = makeEditor()
        type("Label", in: editor)
        editor.commitTextFieldIfNeeded()
        let label = editor.annotations[0]

        type("Label fixed", in: editor, editing: label)
        XCTAssertTrue(editor.annotations.isEmpty, "re-editing lifts the label off the canvas")
        editor.handleToolbarAction(.save)

        XCTAssertEqual(editor.annotations.count, 1)
        XCTAssertTrue(editor.annotations[0] === label)
        XCTAssertEqual(label.text, "Label fixed")
    }

    // MARK: - Re-editing and undo

    func testUndoAfterReEditingRestoresThePreviousText() {
        let editor = makeEditor()
        type("Helo", in: editor)
        editor.commitTextFieldIfNeeded()
        let label = editor.annotations[0]

        type("Hello", in: editor, editing: label)
        editor.commitTextFieldIfNeeded()
        XCTAssertEqual(label.text, "Hello")

        editor.undo()
        XCTAssertEqual(editor.annotations.count, 1, "undo must not remove the label")
        XCTAssertEqual(editor.annotations.first?.text, "Helo")

        editor.redo()
        XCTAssertEqual(editor.annotations.count, 1, "redo must not stack a second copy")
        XCTAssertEqual(editor.annotations.first?.text, "Hello")
    }

    func testReEditedLabelKeepsItsPlaceInTheStack() {
        let editor = makeEditor()
        type("Bottom", in: editor)
        editor.commitTextFieldIfNeeded()
        let label = editor.annotations[0]
        let arrow = Annotation(tool: .arrow, startPoint: .zero, endPoint: NSPoint(x: 50, y: 50),
                               color: .red, strokeWidth: 3)
        editor.annotations.append(arrow)

        type("Bottom!", in: editor, editing: label)
        editor.commitTextFieldIfNeeded()
        XCTAssertTrue(editor.annotations.first === label, "the label must stay under the arrow")

        type("Bottom!", in: editor, editing: label)
        editor.cancelTextEditing()
        XCTAssertTrue(editor.annotations.first === label, "cancelling puts it back where it was")
    }

    func testClearingALabelIsAnUndoableDeletion() {
        let editor = makeEditor()
        type("Gone", in: editor)
        editor.commitTextFieldIfNeeded()
        let label = editor.annotations[0]

        type("", in: editor, editing: label)
        editor.commitTextFieldIfNeeded()
        XCTAssertTrue(editor.annotations.isEmpty)

        editor.undo()
        XCTAssertTrue(editor.annotations.first === label)
        XCTAssertEqual(label.text, "Gone")
    }

    // MARK: - Transforms

    func testFlipCarriesEveryKindOfMarkAcross() {
        let editor = makeEditor(width: 300, height: 200)
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 10, y: 20), endPoint: NSPoint(x: 60, y: 20),
                               color: .red, strokeWidth: 3)
        arrow.anchorPoints = [NSPoint(x: 30, y: 50)]
        arrow.rotation = 0.3
        type("Tag", in: editor)
        editor.commitTextFieldIfNeeded()
        let label = editor.annotations[0]
        let labelRect = label.textDrawRect
        editor.annotations.append(arrow)

        editor.flipImageHorizontally()

        XCTAssertEqual(arrow.startPoint.x, 290, accuracy: 0.001)
        XCTAssertEqual(arrow.anchorPoints?.first?.x ?? -1, 270, accuracy: 0.001)
        XCTAssertEqual(arrow.rotation, -0.3, accuracy: 0.0001)
        XCTAssertEqual(label.textDrawRect.maxX, 300 - labelRect.minX, accuracy: 0.001,
                       "the label moves to the mirrored spot")
        XCTAssertEqual(label.textDrawRect.width, labelRect.width, accuracy: 0.001)
    }

    func testUndoingAFlipPutsTheMarksBack() {
        let editor = makeEditor()
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 10, y: 20), endPoint: NSPoint(x: 60, y: 80),
                               color: .red, strokeWidth: 3)
        editor.annotations = [arrow]

        editor.flipImageVertically()
        XCTAssertNotEqual(arrow.startPoint, NSPoint(x: 10, y: 20))

        editor.undo()
        XCTAssertEqual(arrow.startPoint, NSPoint(x: 10, y: 20))
        XCTAssertEqual(arrow.endPoint, NSPoint(x: 60, y: 80))

        editor.redo()
        XCTAssertEqual(arrow.startPoint.y, 180, accuracy: 0.001)
    }

    // MARK: - Crop mode

    func testCropIsNotRememberedAsTheLastTool() {
        withDefaults(["rememberLastTool": true, "lastUsedTool": nil]) {
            let editor = makeEditor()
            editor.currentTool = .ellipse
            editor.toggleCropMode()
            XCTAssertEqual(editor.currentTool, .crop)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "lastUsedTool") as? Int,
                           AnnotationTool.ellipse.rawValue, "the next capture must not open on crop")

            editor.toggleCropMode()
            XCTAssertEqual(editor.currentTool, .ellipse, "leaving crop returns to the tool before it")
        }
    }
}
