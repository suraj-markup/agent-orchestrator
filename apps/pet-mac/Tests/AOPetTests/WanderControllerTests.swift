import XCTest
import AppKit
@testable import AOPet

final class WanderControllerTests: XCTestCase {

    // MARK: - WalkDirection

    func testAllDirectionsHaveUnitVectors() {
        // Cardinals are length 1; diagonals normalized to 1/sqrt(2) per
        // axis so diagonal travel speed matches cardinal speed.
        for dir in WalkDirection.allCases {
            let v = dir.unitVector
            let length = (v.dx * v.dx + v.dy * v.dy).squareRoot()
            XCTAssertEqual(length, 1.0, accuracy: 0.0001,
                           "\(dir) vector length should be 1")
        }
    }

    func testCardinalsPointTheRightWay() {
        XCTAssertEqual(WalkDirection.n.unitVector.dy,  -1, accuracy: 0.0001)
        XCTAssertEqual(WalkDirection.s.unitVector.dy,   1, accuracy: 0.0001)
        XCTAssertEqual(WalkDirection.e.unitVector.dx,   1, accuracy: 0.0001)
        XCTAssertEqual(WalkDirection.w.unitVector.dx,  -1, accuracy: 0.0001)
    }

    // MARK: - State machine (pure transition)

    /// Start in walking(.e, 1). Single tick → emits .move with east
    /// vector × pxPerTick, then transitions per pickRoll.
    func testStepWalkingDecrementsThenPicksNext() {
        // pxPerTick = 30 px/s × 0.05 s = 1.5
        let (action, next) = WanderController.step(
            state: .walking(direction: .e, ticksRemaining: 2),
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll:        { 0 },
            pickDirection:   { .n },
            pickWalkDuration:  { 5 },
            pickPauseDuration: { 2 }
        )
        XCTAssertEqual(action, .move(dx: 1.5, dy: 0, frameDir: .e))
        XCTAssertEqual(next, .walking(direction: .e, ticksRemaining: 1))
    }

    func testStepWalkingExpiresAndPicksPause() {
        // Roll 0.0 < 0.30 → pause
        let (action, next) = WanderController.step(
            state: .walking(direction: .e, ticksRemaining: 1),
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll:        { 0.0 },                  // pause branch
            pickDirection:   { .nw },
            pickWalkDuration:  { 4 },
            pickPauseDuration: { 2 }                   // 2s = 40 ticks
        )
        XCTAssertEqual(action, .move(dx: 1.5, dy: 0, frameDir: .e))
        XCTAssertEqual(next, .paused(ticksRemaining: 40))
    }

    func testStepWalkingExpiresAndPicksNewDirection() {
        // Roll 0.99 > 0.30 → new direction
        let (action, next) = WanderController.step(
            state: .walking(direction: .e, ticksRemaining: 1),
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll:        { 0.99 },                 // walk branch
            pickDirection:   { .nw },
            pickWalkDuration:  { 4 },                  // 4s = 80 ticks
            pickPauseDuration: { 2 }
        )
        XCTAssertEqual(action, .move(dx: 1.5, dy: 0, frameDir: .e))
        XCTAssertEqual(next, .walking(direction: .nw, ticksRemaining: 80))
    }

    func testStepPausedDecrementsThenWalks() {
        let (action, next) = WanderController.step(
            state: .paused(ticksRemaining: 2),
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll:        { 0.5 },
            pickDirection:   { .s },
            pickWalkDuration:  { 6 },
            pickPauseDuration: { 1 }
        )
        XCTAssertEqual(action, .still)
        XCTAssertEqual(next, .paused(ticksRemaining: 1))

        // Last tick of pause → next state walks.
        let (action2, next2) = WanderController.step(
            state: .paused(ticksRemaining: 1),
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll:        { 0.0 },                  // ignored after pause
            pickDirection:   { .s },
            pickWalkDuration:  { 6 },                  // 120 ticks
            pickPauseDuration: { 1 }
        )
        XCTAssertEqual(action2, .still)
        XCTAssertEqual(next2, .walking(direction: .s, ticksRemaining: 120))
    }

    // MARK: - Bounds clamping

    func testClampOriginInsideScreenIsUnchanged() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let inside = NSPoint(x: visible.midX, y: visible.midY)
        let clamped = WanderController.clampOrigin(
            inside,
            size: NSSize(width: 240, height: 132),
            screens: [screen]
        )
        XCTAssertEqual(clamped, inside)
    }

    func testClampOriginPastTopIsClampedToVisibleFrame() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let size = NSSize(width: 240, height: 132)
        // Try to place the window so its top is way above the screen.
        let above = NSPoint(x: visible.minX, y: visible.maxY + 500)
        let clamped = WanderController.clampOrigin(above, size: size, screens: [screen])
        // Y must be at most maxY - height (so the top sits on the
        // visible-frame top edge).
        XCTAssertLessThanOrEqual(clamped.y, visible.maxY - size.height + 0.01)
        // X stays at minX (already inside bounds).
        XCTAssertEqual(clamped.x, visible.minX, accuracy: 0.01)
    }

    func testClampOriginPastLeftIsClampedToMinX() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let size = NSSize(width: 240, height: 132)
        let left = NSPoint(x: visible.minX - 500, y: visible.midY)
        let clamped = WanderController.clampOrigin(left, size: size, screens: [screen])
        XCTAssertEqual(clamped.x, visible.minX, accuracy: 0.01)
    }

    // MARK: - External suppression

    func testSuppressForSecondsEmitsStillForSubsequentTicks() {
        var actions: [WanderController.TickAction] = []
        let wander = WanderController(
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll: { 0.99 },
            pickDirection: { .e },
            pickWalkDuration: { 5 },
            pickPauseDuration: { 1 },
            onTick: { actions.append($0) }
        )
        wander.suppressForSeconds(60)
        wander.fireTick()
        wander.fireTick()
        XCTAssertEqual(actions, [.still, .still])
        XCTAssertTrue(wander.isSuppressed)
    }

    func testSuppressExtendsButDoesNotShorten() {
        let wander = WanderController(
            intervalSeconds: 0.05,
            speedPxPerSec: 30,
            pickRoll: { 0.99 },
            pickDirection: { .e },
            pickWalkDuration: { 5 },
            pickPauseDuration: { 1 },
            onTick: { _ in }
        )
        wander.suppressForSeconds(10)
        wander.suppressForSeconds(0.001) // shorter — must not override
        XCTAssertTrue(wander.isSuppressed)
    }
}

/// PetWindow's programmatic-move flag gates PositionStore.save in
/// `windowDidMove`. This guards the user's parked position from being
/// silently overwritten by every wander step.
final class PetWindowProgrammaticFlagTests: XCTestCase {
    func testFlagDefaultsFalse() {
        let win = PetWindow(size: NSSize(width: 240, height: 132))
        XCTAssertFalse(win.isProgrammaticMove)
    }

    func testPerformProgrammaticallySetsFlagAndRestores() {
        let win = PetWindow(size: NSSize(width: 240, height: 132))
        var observedDuring: Bool?
        win.performProgrammatically {
            observedDuring = win.isProgrammaticMove
        }
        XCTAssertEqual(observedDuring, true)
        XCTAssertFalse(win.isProgrammaticMove,
                       "must restore false after closure runs")
    }

    func testPerformProgrammaticallyRestoresPreviousValueWhenNested() {
        let win = PetWindow(size: NSSize(width: 240, height: 132))
        win.isProgrammaticMove = true
        var inner: Bool?
        win.performProgrammatically {
            inner = win.isProgrammaticMove
        }
        XCTAssertEqual(inner, true)
        XCTAssertTrue(win.isProgrammaticMove,
                      "outer programmatic context must persist")
    }
}
