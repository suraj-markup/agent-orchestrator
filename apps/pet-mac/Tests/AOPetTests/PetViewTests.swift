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

    // MARK: - Bubble sound mapping

    func testUrgentPlaysSosumi() {
        XCTAssertEqual(PetController.soundName(for: .urgent), "Sosumi")
    }

    func testActionPlaysGlass() {
        XCTAssertEqual(PetController.soundName(for: .action), "Glass")
    }

    func testWarningHasNoSound() {
        XCTAssertNil(PetController.soundName(for: .warning))
    }

    func testInfoHasNoSound() {
        XCTAssertNil(PetController.soundName(for: .info))
    }

    func testUnknownHasNoSound() {
        XCTAssertNil(PetController.soundName(for: .unknown))
    }

    // MARK: - PetView geometry

    func testPetViewSizeFitsBigBubble() {
        // The bumped totalSize must accommodate the 64pt sprite, an 8pt
        // edge margin, and a 52pt bubble row without negative slack.
        XCTAssertGreaterThanOrEqual(PetView.totalSize.width, 240)
        XCTAssertGreaterThanOrEqual(PetView.totalSize.height, 132)
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

    func testBubbleTextPreservesNormalLengthMessageInFull() {
        // Realistic-length messages that fit under the budget must
        // round-trip unchanged — no ellipsis, no clipping. The bubble
        // wraps visually; we don't pre-truncate any more.
        let normal = "Session ao-170 needs your approval to merge the pull request"
        let result = PetController.bubbleText(
            message: normal,
            projectName: "agent-orchestrator",
            sessionId: "ao-170"
        )
        XCTAssertEqual(result, "agent-orchestrator ao-170 \(normal)")
        XCTAssertFalse(result.hasSuffix("…"))
    }

    func testBubbleTextTruncatesPathologicallyLongMessages() {
        // Cap is the runaway-input guard. A 1000-char message still
        // needs to truncate to keep the bounding-rect calc bounded.
        let runaway = String(repeating: "x", count: 1000)
        let result = PetController.bubbleText(
            message: runaway,
            projectName: "agent-orchestrator",
            sessionId: "ao-170"
        )
        XCTAssertTrue(result.hasPrefix("agent-orchestrator ao-170 "))
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertLessThanOrEqual(result.count, 250)
        // Project name and session id survive untouched.
        XCTAssertTrue(result.contains("agent-orchestrator"))
        XCTAssertTrue(result.contains("ao-170"))
    }

    // MARK: - Bubble auto-grow

    func testThoughtBubblePreferredHeightShortText() {
        let bubble = ThoughtBubbleView(frame: NSRect(x: 0, y: 0, width: 224, height: 52))
        bubble.text = "PR #5 opened"
        let h = bubble.preferredHeight(forWidth: 224)
        // One line of 13pt body fits under the default min height.
        XCTAssertGreaterThan(h, 0)
        XCTAssertLessThanOrEqual(h, PetView.minBubbleHeight)
    }

    func testThoughtBubblePreferredHeightLongTextGrowsBeyondMin() {
        let bubble = ThoughtBubbleView(frame: NSRect(x: 0, y: 0, width: 224, height: 52))
        bubble.text = String(repeating: "wrap me ", count: 30)  // ~240 chars
        let h = bubble.preferredHeight(forWidth: 224)
        // A 240-char message must wrap past the single-bubble min so
        // the auto-grow path is exercised in production.
        XCTAssertGreaterThan(h, PetView.minBubbleHeight)
    }

    func testPetViewPreferredSizeClampedToMaxForRunawayMessage() {
        // Even a pathologically long string must not push the view
        // taller than `maxBubbleHeight + sprite + margins`.
        let bubble = ThoughtBubbleView(frame: NSRect(x: 0, y: 0, width: 224, height: 52))
        let huge = String(repeating: "x ", count: 5000)
        let (bubbleHeight, total) = PetView.preferredSize(forText: huge, bubble: bubble)
        XCTAssertEqual(bubbleHeight, PetView.maxBubbleHeight)
        let expectedMaxTotal = PetView.maxBubbleHeight + 64 + 16  // sprite + 2*margin
        XCTAssertEqual(total.height, expectedMaxTotal)
    }

    func testPetViewPreferredSizeStaysAtMinForShortMessage() {
        let bubble = ThoughtBubbleView(frame: NSRect(x: 0, y: 0, width: 224, height: 52))
        let (bubbleHeight, total) = PetView.preferredSize(forText: "hi", bubble: bubble)
        XCTAssertEqual(bubbleHeight, PetView.minBubbleHeight)
        XCTAssertEqual(total, PetView.totalSize)
    }
}
