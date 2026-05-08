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

    // MARK: - Bubble priority filter

    func testShouldShowBubbleForUrgent() {
        XCTAssertTrue(PetController.shouldShowBubble(for: .urgent))
    }

    func testShouldShowBubbleForAction() {
        XCTAssertTrue(PetController.shouldShowBubble(for: .action))
    }

    func testShouldNotShowBubbleForWarning() {
        XCTAssertFalse(PetController.shouldShowBubble(for: .warning))
    }

    func testShouldNotShowBubbleForInfo() {
        XCTAssertFalse(PetController.shouldShowBubble(for: .info))
    }

    func testShouldNotShowBubbleForUnknown() {
        XCTAssertFalse(PetController.shouldShowBubble(for: .unknown))
    }

    // MARK: - Bubble text format

    func testBubbleTextDropsPrefixWhenNoProjectOrSession() {
        XCTAssertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: nil,
                sessionId: nil
            ),
            "PR #5 opened"
        )
    }

    func testBubbleTextDropsPrefixWhenBothEmpty() {
        XCTAssertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: "",
                sessionId: ""
            ),
            "PR #5 opened"
        )
    }

    func testBubbleTextWithProjectAndSessionIsSpaceSeparated() {
        XCTAssertEqual(
            PetController.bubbleText(
                message: "needs your approval",
                projectName: "agent-orchestrator",
                sessionId: "ao-170"
            ),
            "agent-orchestrator ao-170 needs your approval"
        )
    }

    func testBubbleTextWithOnlyProjectName() {
        XCTAssertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: "ao",
                sessionId: nil
            ),
            "ao PR #5 opened"
        )
    }

    func testBubbleTextWithOnlySessionId() {
        XCTAssertEqual(
            PetController.bubbleText(
                message: "PR #5 opened",
                projectName: nil,
                sessionId: "ao-170"
            ),
            "ao-170 PR #5 opened"
        )
    }

    func testBubbleTextTruncatesMessageNotIdentifiers() {
        // Long message + short project/session: cut MUST fall on the
        // message so the user can still tell which session this is.
        let longMessage = String(repeating: "x", count: 200)
        let result = PetController.bubbleText(
            message: longMessage,
            projectName: "agent-orchestrator",
            sessionId: "ao-170"
        )
        XCTAssertTrue(result.hasPrefix("agent-orchestrator ao-170 "))
        XCTAssertTrue(result.hasSuffix("…"))
        // Total bubble text is bounded by the char budget (60).
        XCTAssertLessThanOrEqual(result.count, 60)
        // Project name and session id survive untouched.
        XCTAssertTrue(result.contains("agent-orchestrator"))
        XCTAssertTrue(result.contains("ao-170"))
    }
}
