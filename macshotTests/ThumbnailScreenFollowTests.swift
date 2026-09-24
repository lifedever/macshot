import Cocoa
import XCTest

/// The floating cards follow keyboard focus to whichever display the user is
/// working on. These pin the decisions behind that: which display a card is
/// on, when the stack may be moved, how far a card may slide in or out
/// without crossing onto a neighbouring display, and the size and resting
/// place of a new card.
@MainActor
final class ThumbnailScreenFollowTests: XCTestCase {

    /// A laptop with an external display to its left, lower edge offset —
    /// the arrangement the feature was built against.
    private let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = NSRect(x: -1920, y: -98, width: 1920, height: 1080)
    private var screens: [NSRect] { [builtIn, external] }

    private let margin = FloatingThumbnailController.shadowMargin

    /// A card window in the bottom-right corner of a screen, shadow margin
    /// included, the way the stack lays one out.
    private func cardWindow(bottomRightOf screen: NSRect, raisedBy lift: CGFloat = 0) -> NSRect {
        let card = NSSize(width: 240, height: 150)
        return NSRect(x: screen.maxX - 16 - card.width - margin,
                      y: screen.minY + 16 + lift - margin,
                      width: card.width + margin * 2,
                      height: card.height + margin * 2)
    }

    // MARK: - Which display a card is on

    func testACardBelongsToTheScreenHoldingItsCentre() {
        XCTAssertEqual(FloatingThumbnailController.screenIndex(of: cardWindow(bottomRightOf: builtIn), in: screens), 0)
        XCTAssertEqual(FloatingThumbnailController.screenIndex(of: cardWindow(bottomRightOf: external), in: screens), 1)
    }

    func testTheShadowMarginDoesNotClaimTheNeighbouringDisplay() {
        // The external display's right edge meets the laptop's left edge. A card
        // in its bottom-right corner has a window that pokes a few points across;
        // that must not count as being on the laptop.
        let window = cardWindow(bottomRightOf: external)
        XCTAssertTrue(window.intersects(builtIn), "fixture: the window should reach across the seam")
        XCTAssertFalse(FloatingThumbnailController.isCard(window, on: builtIn))
    }

    func testACardOnADisconnectedDisplayBelongsToNoScreen() {
        let gone = NSRect(x: 5000, y: 0, width: 1920, height: 1080)
        XCTAssertNil(FloatingThumbnailController.screenIndex(of: cardWindow(bottomRightOf: gone), in: screens))
    }

    // MARK: - When the stack moves

    func testAStackAlreadyOnTheActiveScreenStays() {
        let stack = [cardWindow(bottomRightOf: external), cardWindow(bottomRightOf: external, raisedBy: 158)]
        XCTAssertFalse(FloatingThumbnailController.stackShouldFollow(
            cardFrames: stack, activeScreen: external, pointer: NSPoint(x: 500, y: 500)))
    }

    func testTheStackFollowsFocusToAnotherDisplay() {
        let stack = [cardWindow(bottomRightOf: external), cardWindow(bottomRightOf: external, raisedBy: 158)]
        XCTAssertTrue(FloatingThumbnailController.stackShouldFollow(
            cardFrames: stack, activeScreen: builtIn, pointer: NSPoint(x: 500, y: 500)))
    }

    func testOneStrayCardIsEnoughToMoveTheStack() {
        let stack = [cardWindow(bottomRightOf: builtIn), cardWindow(bottomRightOf: external, raisedBy: 158)]
        XCTAssertTrue(FloatingThumbnailController.stackShouldFollow(
            cardFrames: stack, activeScreen: builtIn, pointer: nil))
    }

    func testACardUnderThePointerIsNotPulledAway() {
        // Focus can change by keyboard (⌘-Tab) while the pointer rests on a card.
        let card = cardWindow(bottomRightOf: external)
        let onCard = NSPoint(x: card.midX, y: card.midY)
        XCTAssertFalse(FloatingThumbnailController.stackShouldFollow(
            cardFrames: [card], activeScreen: builtIn, pointer: onCard))
    }

    func testThePointerInTheShadowMarginDoesNotHoldTheCard() {
        let card = cardWindow(bottomRightOf: external)
        let inShadow = NSPoint(x: card.minX + margin / 2, y: card.midY)
        XCTAssertTrue(FloatingThumbnailController.stackShouldFollow(
            cardFrames: [card], activeScreen: builtIn, pointer: inShadow))
    }

    func testANewCardMovesTheStackEvenUnderThePointer() {
        let card = cardWindow(bottomRightOf: external)
        XCTAssertTrue(FloatingThumbnailController.stackShouldFollow(
            cardFrames: [card], activeScreen: builtIn, pointer: nil))
    }

    func testNoCardsNeverMove() {
        XCTAssertFalse(FloatingThumbnailController.stackShouldFollow(
            cardFrames: [], activeScreen: builtIn, pointer: nil))
    }

    // MARK: - Sliding in and out beside another display

    private func cardWindow(bottomLeftOf screen: NSRect) -> NSRect {
        var window = cardWindow(bottomRightOf: screen)
        window.origin.x = screen.minX + 16 - margin
        return window
    }

    private func exitPath(
        _ window: NSRect, towardLeft: Bool, on screen: NSRect,
        visibleFrame: NSRect? = nil, others: [NSRect]
    ) -> FloatingThumbnailController.ExitPath {
        FloatingThumbnailController.exitPath(
            for: window, towardLeft: towardLeft, screenFrame: screen,
            visibleFrame: visibleFrame ?? screen, otherScreens: others)
    }

    func testWithNothingPastTheEdgeTheCardLeavesTheScreen() {
        let right = exitPath(cardWindow(bottomRightOf: builtIn), towardLeft: false, on: builtIn, others: [external])
        XCTAssertEqual(right, .init(x: builtIn.maxX + 10, leavesScreen: true), "unchanged from before")

        let window = cardWindow(bottomLeftOf: external)
        let left = exitPath(window, towardLeft: true, on: external, others: [builtIn])
        XCTAssertEqual(left, .init(x: external.minX - window.width - 10, leavesScreen: true))
    }

    func testTheCardStopsAtTheSeamWhenADisplayContinuesPastIt() {
        // The reported case: a card in the external display's bottom-right
        // corner started out on the laptop's left edge and slid across onto it.
        let window = cardWindow(bottomRightOf: external)
        let path = exitPath(window, towardLeft: false, on: external, others: [builtIn])
        XCTAssertFalse(path.leavesScreen)
        let cardAtExit = window.offsetBy(dx: path.x - window.minX, dy: 0).insetBy(dx: margin, dy: margin)
        XCTAssertEqual(cardAtExit.maxX, external.maxX, accuracy: 0.001, "the card's edge rests on the seam")
        XCTAssertGreaterThan(path.x, window.minX, "and it still moves toward the edge")
    }

    func testTheLeftEdgeStopsAtTheSeamToo() {
        let window = cardWindow(bottomLeftOf: builtIn)
        let path = exitPath(window, towardLeft: true, on: builtIn, others: [external])
        XCTAssertFalse(path.leavesScreen)
        XCTAssertEqual(path.x + margin, builtIn.minX, accuracy: 0.001)
    }

    func testADisplayBesideButClearOfTheCardsRowDoesNotStopIt() {
        // A display to the right that only starts above the card's row.
        let high = NSRect(x: builtIn.maxX, y: 600, width: 1920, height: 1080)
        let path = exitPath(cardWindow(bottomRightOf: builtIn), towardLeft: false, on: builtIn, others: [high])
        XCTAssertTrue(path.leavesScreen)
    }

    func testTheSeamIsTheScreensEdgeNotTheDocks() {
        // Dock on the right: the visible frame ends 70pt short of the seam, and
        // the card may pass under the Dock up to the seam itself.
        let visible = NSRect(x: external.minX, y: external.minY, width: external.width - 70, height: external.height)
        let window = cardWindow(bottomRightOf: visible)
        let path = exitPath(window, towardLeft: false, on: external, visibleFrame: visible, others: [builtIn])
        XCTAssertFalse(path.leavesScreen)
        XCTAssertEqual(path.x + window.width - margin, external.maxX, accuracy: 0.001)
    }

    // MARK: - The card's size

    func testTheCardIsSquareAndFollowsThePreviewSize() {
        // Every card is the same square, whatever the shot's shape, so a stack
        // lines up; the "preview size" setting scales it.
        withDefaults(["thumbnailScale": nil]) {
            XCTAssertEqual(FloatingThumbnailController.thumbnailSize, NSSize(width: 240, height: 240))
        }
        withDefaults(["thumbnailScale": 0.5]) {
            XCTAssertEqual(FloatingThumbnailController.thumbnailSize, NSSize(width: 120, height: 120))
        }
        withDefaults(["thumbnailScale": 1.5]) {
            let window = FloatingThumbnailController.windowSize
            XCTAssertEqual(window.width, 360 + margin * 2)
            XCTAssertEqual(window.height, window.width)
        }
    }

    // MARK: - Where a card comes to rest

    private func restingOrigin(_ window: NSRect, in visible: NSRect) -> NSPoint {
        FloatingThumbnailController.restingOrigin(
            for: window.origin, windowSize: window.size, visibleFrame: visible, padding: 16)
    }

    func testASlotTheStackLaysOutIsKeptInEveryCorner() {
        // The stack places cards 16pt in from the edges in card terms. Clamping
        // the window instead of the card held a new card 22pt further in, so
        // it sat out of line with the cards reflowed beside it.
        let bottomRight = cardWindow(bottomRightOf: builtIn)
        let bottomLeft = cardWindow(bottomLeftOf: builtIn)
        let lift = builtIn.height - 32 - (bottomRight.height - margin * 2)
        let topRight = cardWindow(bottomRightOf: builtIn, raisedBy: lift)
        var topLeft = topRight
        topLeft.origin.x = bottomLeft.minX
        for window in [bottomRight, bottomLeft, topRight, topLeft] {
            XCTAssertEqual(restingOrigin(window, in: builtIn), window.origin, "moved \(window)")
        }
        XCTAssertEqual(topRight.maxY - margin, builtIn.maxY - 16, "fixture: the top card sits 16pt below the top")
    }

    func testAStackTallerThanTheScreenStopsWithTheCardInside() {
        let tooHigh = cardWindow(bottomRightOf: builtIn, raisedBy: builtIn.height)
        let origin = restingOrigin(tooHigh, in: builtIn)
        XCTAssertEqual(origin.y + tooHigh.height - margin, builtIn.maxY - 16, accuracy: 0.001)
    }

    func testAnOriginOffTheLeftIsPulledInToTheCardsPadding() {
        var window = cardWindow(bottomLeftOf: builtIn)
        window.origin.x = builtIn.minX - 300
        XCTAssertEqual(restingOrigin(window, in: builtIn).x + margin, builtIn.minX + 16, accuracy: 0.001)
    }

    func testACardDraggedPastTheSeamPointDoesNotSlideBack() {
        var window = cardWindow(bottomRightOf: external)
        window.origin.x = external.maxX - window.width + margin + 5
        let path = exitPath(window, towardLeft: false, on: external, others: [builtIn])
        XCTAssertEqual(path.x, window.minX)
    }
}
