import Cocoa
import XCTest

/// The floating cards follow keyboard focus to whichever display the user is
/// working on. These pin the two decisions behind that: which display a card
/// is on, and when the stack may be moved.
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
}
