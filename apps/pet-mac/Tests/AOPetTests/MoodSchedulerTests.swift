import XCTest
@testable import AOPet

/// MoodScheduler is the heart of the event-driven pivot — the pet's
/// idle mood comes from here, not from session-status polling. These
/// tests cover the deterministic pieces (`weightedMood`, `pickMood`)
/// with injected RNG / idle providers.
final class MoodSchedulerTests: XCTestCase {

    // MARK: - Distribution

    /// `weightedMood` resolves a synthetic [0, 1) roll to one of the
    /// three idle moods according to the 50/30/20 distribution. Test
    /// the boundaries explicitly so the distribution can't drift.
    func testWeightedMoodBoundaries() {
        XCTAssertEqual(MoodScheduler.weightedMood(roll: 0.00),  .sleeping)
        XCTAssertEqual(MoodScheduler.weightedMood(roll: 0.49),  .sleeping)
        XCTAssertEqual(MoodScheduler.weightedMood(roll: 0.50),  .happy)
        XCTAssertEqual(MoodScheduler.weightedMood(roll: 0.79),  .happy)
        XCTAssertEqual(MoodScheduler.weightedMood(roll: 0.80),  .working)
        XCTAssertEqual(MoodScheduler.weightedMood(roll: 0.999), .working)
    }

    /// Sample a thousand rolls from a deterministic LCG and assert the
    /// counts are within ±5 percentage points of the target weights.
    func testWeightedMoodDistributionMatches50_30_20() {
        var counts: [PetMood: Int] = [.sleeping: 0, .happy: 0, .working: 0]
        var rng = SeededRNG(seed: 0xC0FFEE)
        let samples = 5000
        for _ in 0..<samples {
            let roll = Double(rng.next()) / Double(UInt64.max)
            counts[MoodScheduler.weightedMood(roll: roll), default: 0] += 1
        }

        let total = Double(samples)
        let sleepingFrac = Double(counts[.sleeping] ?? 0) / total
        let happyFrac    = Double(counts[.happy]    ?? 0) / total
        let workingFrac  = Double(counts[.working]  ?? 0) / total

        XCTAssertEqual(sleepingFrac, 0.50, accuracy: 0.05)
        XCTAssertEqual(happyFrac,    0.30, accuracy: 0.05)
        XCTAssertEqual(workingFrac,  0.20, accuracy: 0.05)
    }

    /// `weightedMood` MUST never surface attention/event moods as a
    /// random idle pick. Those belong to event reactions only.
    func testRandomMoodNeverReturnsAttentionOrHidden() {
        for i in 0..<10_000 {
            let roll = Double(i) / 10_000.0
            let mood = MoodScheduler.weightedMood(roll: roll)
            XCTAssertNotEqual(mood, .alert, "alert at roll=\(roll)")
            XCTAssertNotEqual(mood, .sad,   "sad at roll=\(roll)")
            XCTAssertNotEqual(mood, .hidden, "hidden at roll=\(roll)")
        }
    }

    // MARK: - Idle override

    /// When the OS reports user idle ≥ forceSleepIdleSeconds (5 min),
    /// pickMood ignores the random roll and returns `.sleeping`.
    func testForceSleepWhenIdleExceedsThreshold() {
        let scheduler = MoodScheduler(
            pickRoll: { 0.95 },                // would normally roll .working
            pickInterval: { 30 },
            idleProvider: { 350 },             // > 300s threshold
            onTick: { _ in }
        )
        XCTAssertEqual(scheduler.pickMood(), .sleeping)
    }

    /// Boundary: exactly 300s idle counts as forced sleep (>= comparison).
    func testForceSleepBoundaryAtThreshold() {
        let scheduler = MoodScheduler(
            pickRoll: { 0.95 },
            pickInterval: { 30 },
            idleProvider: { 300 },             // == threshold
            onTick: { _ in }
        )
        XCTAssertEqual(scheduler.pickMood(), .sleeping)
    }

    /// Just below the threshold the random pick is honoured.
    func testRandomPickWhenBelowIdleThreshold() {
        let scheduler = MoodScheduler(
            pickRoll: { 0.95 },                // .working under the dist.
            pickInterval: { 30 },
            idleProvider: { 299 },             // < threshold
            onTick: { _ in }
        )
        XCTAssertEqual(scheduler.pickMood(), .working)
    }

    /// `forceSleepIdleSeconds` is documented as 5 minutes — guard
    /// against accidental regression (e.g. someone "tightening" it).
    func testForceSleepConstantIs300Seconds() {
        XCTAssertEqual(MoodScheduler.forceSleepIdleSeconds, 300)
    }
}

/// Minimal deterministic RNG for distribution tests. Linear-congruential;
/// good enough for "did the buckets land near 50/30/20" — not crypto.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
