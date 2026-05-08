import XCTest
import AppKit
@testable import AOPet

/// The pet window is borderless and relies on
/// `isMovableByWindowBackground` for drag. AppKit only forwards
/// mouseDown to the window background if the subview tree opts in via
/// `mouseDownCanMoveWindow`. Without these overrides, dragging anywhere
/// on the cat does nothing.
final class PetViewTests: XCTestCase {
    func testPetViewOptsInToWindowDrag() {
        let view = PetView(frame: NSRect(origin: .zero, size: PetView.totalSize))
        XCTAssertTrue(view.mouseDownCanMoveWindow)
    }

    func testDraggableImageViewOptsInToWindowDrag() {
        let view = DraggableImageView(frame: .zero)
        XCTAssertTrue(view.mouseDownCanMoveWindow)
    }

    // MARK: - Event bubble label

    func testBubbleTextOmitsBracketsWhenNoProjectName() {
        XCTAssertEqual(
            PetController.bubbleText(message: "PR #5 opened", projectName: nil),
            "PR #5 opened"
        )
    }

    func testBubbleTextOmitsBracketsWhenProjectNameIsEmpty() {
        XCTAssertEqual(
            PetController.bubbleText(message: "PR #5 opened", projectName: ""),
            "PR #5 opened"
        )
    }

    func testBubbleTextPrependsProjectName() {
        XCTAssertEqual(
            PetController.bubbleText(message: "PR #5 opened", projectName: "ao"),
            "[ao] PR #5 opened"
        )
    }

    func testBubbleTextTruncatesLongProjectNames() {
        // Single-pet UI must show *which* project the event came from
        // without blowing the bubble's width budget. Anything past 16
        // chars is truncated with an ellipsis.
        let longName = "agent-orchestrator-monorepo-internal"
        let result = PetController.bubbleText(
            message: "PR #5 opened",
            projectName: longName
        )
        XCTAssertEqual(result, "[agent-orchestrat…] PR #5 opened")
    }
}
