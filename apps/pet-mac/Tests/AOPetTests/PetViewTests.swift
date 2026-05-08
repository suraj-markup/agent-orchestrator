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
}
