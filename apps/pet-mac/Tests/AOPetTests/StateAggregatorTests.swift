import XCTest
@testable import AOPet

final class StateAggregatorTests: XCTestCase {
    private func session(_ id: String, _ project: String, _ status: SessionStatus, _ activity: ActivityState? = nil) -> WireSession {
        return WireSession(id: id, projectId: project, status: status, activity: activity)
    }

    // MARK: - Single-session moods

    func testWaitingInputProducesAlert() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .working, .waitingInput)), .alert)
    }

    func testNeedsInputStatusProducesAlert() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .needsInput, .ready)), .alert)
    }

    func testCIFailedProducesSad() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .ciFailed, .ready)), .sad)
    }

    func testStuckProducesSad() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .stuck)), .sad)
    }

    func testBlockedActivityProducesSad() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .working, .blocked)), .sad)
    }

    func testPROpenProducesHappy() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .prOpen, .idle)), .happy)
    }

    func testApprovedProducesHappy() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .approved, .idle)), .happy)
    }

    func testReviewPendingProducesHappy() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .reviewPending, .idle)), .happy)
    }

    func testMergedProducesHappy() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .merged, .idle)), .happy)
    }

    func testWorkingActivityProducesWorking() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .working, .active)), .working)
    }

    func testIdleSessionProducesSleeping() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .idle, .idle)), .sleeping)
    }

    func testDoneProducesSleeping() {
        XCTAssertEqual(StateAggregator.mood(for: session("s", "p", .done)), .sleeping)
    }

    // MARK: - Global aggregator

    func testEmptySessionsProducesHiddenInstance() {
        let state = StateAggregator.aggregateGlobal(sessions: [])
        XCTAssertEqual(state.mood, .hidden)
        XCTAssertEqual(state.totalSessions, 0)
        XCTAssertFalse(state.hasSessions)
    }

    func testSingleSessionPicksItsMood() {
        let state = StateAggregator.aggregateGlobal(sessions: [
            session("a", "p1", .working, .active)
        ])
        XCTAssertEqual(state.mood, .working)
        XCTAssertEqual(state.totalSessions, 1)
        XCTAssertTrue(state.hasSessions)
    }

    func testGlobalCollapsesAcrossProjectsWithWorstMoodWinning() {
        // Three projects, four sessions: one worker, one happy PR, one
        // sad CI failure, one human-block. The instance-wide pick is
        // `alert` (highest priority).
        let sessions = [
            session("a", "p1", .working, .active),
            session("b", "p2", .prOpen, .idle),
            session("c", "p3", .ciFailed, .ready),
            session("d", "p1", .needsInput, .waitingInput),
        ]
        let state = StateAggregator.aggregateGlobal(sessions: sessions)
        XCTAssertEqual(state.mood, .alert)
        XCTAssertEqual(state.totalSessions, 4)
    }

    func testGlobalCollapsesPicksSadWhenNoAlert() {
        let sessions = [
            session("a", "p1", .working, .active),
            session("b", "p2", .ciFailed, .ready),
            session("c", "p3", .prOpen, .idle),
        ]
        let state = StateAggregator.aggregateGlobal(sessions: sessions)
        XCTAssertEqual(state.mood, .sad)
        XCTAssertEqual(state.totalSessions, 3)
    }

    func testGlobalCollapsesAllIdleProducesSleeping() {
        let sessions = [
            session("a", "p1", .idle, .idle),
            session("b", "p2", .done),
            session("c", "p3", .done),
        ]
        let state = StateAggregator.aggregateGlobal(sessions: sessions)
        XCTAssertEqual(state.mood, .sleeping)
        XCTAssertEqual(state.totalSessions, 3)
    }

    // MARK: - Mood priority ordering

    func testMoodPriorityOrdering() {
        // The global aggregator's worst-state pick depends on this.
        XCTAssertLessThan(PetMood.sleeping.priority, PetMood.happy.priority)
        XCTAssertLessThan(PetMood.happy.priority, PetMood.working.priority)
        XCTAssertLessThan(PetMood.working.priority, PetMood.sad.priority)
        XCTAssertLessThan(PetMood.sad.priority, PetMood.alert.priority)
    }
}
