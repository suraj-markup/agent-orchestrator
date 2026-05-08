import XCTest
@testable import AOPet

final class SpriteLoaderTests: XCTestCase {
    func testLoadsBundledOnekoSet() throws {
        let set = try XCTUnwrap(SpriteLoader.load("oneko"))
        XCTAssertEqual(set.name, "oneko")
        // Each animatable mood ships with at least 2 frames so animation
        // has something to advance through.
        for mood in [PetMood.sleeping, .happy, .working, .sad, .alert] {
            XCTAssertGreaterThanOrEqual(
                set.frameCount(for: mood),
                2,
                "expected ≥2 frames for \(mood.rawValue) in oneko set"
            )
        }
    }

    func testStateToFramesMapping() throws {
        // Per the AO state → oneko frame table, every dashboard mood
        // resolves to a non-empty animation strip with the expected
        // canonical frame counts.
        let set = try XCTUnwrap(SpriteLoader.load("oneko"))
        let expected: [(PetMood, Int)] = [
            (.sleeping, 2),  // sleeping[0..1] — Z's
            (.working,  2),  // E[0..1] — walk east
            (.happy,    2),  // idle / tired blink
            (.sad,      2),  // alert / idle blink
            (.alert,    3),  // scratchSelf[0..2]
        ]
        for (mood, count) in expected {
            XCTAssertEqual(
                set.frameCount(for: mood),
                count,
                "expected exactly \(count) frames for \(mood.rawValue)"
            )
            for tick in 0..<count {
                XCTAssertNotNil(
                    set.image(for: mood, tick: tick),
                    "tick \(tick) of \(mood.rawValue) returned nil"
                )
            }
        }
    }

    func testReturnsNilForMissingSet() {
        XCTAssertNil(SpriteLoader.load("does-not-exist"))
    }

    func testFrameIndexingWrapsAround() throws {
        let set = try XCTUnwrap(SpriteLoader.load("oneko"))
        let count = set.frameCount(for: .working)
        let first = set.image(for: .working, tick: 0)
        let wrapped = set.image(for: .working, tick: count)
        let negative = set.image(for: .working, tick: -1)
        XCTAssertNotNil(first)
        XCTAssertNotNil(wrapped)
        XCTAssertNotNil(negative)
        XCTAssertTrue(first === wrapped || first?.tiffRepresentation == wrapped?.tiffRepresentation)
    }

    func testFrameCountIsAtLeastOneForUnknownMood() {
        let empty = SpriteSet(name: "empty", frames: [:])
        XCTAssertGreaterThanOrEqual(empty.frameCount(for: .working), 1)
    }

    func testPerMoodFrameDurations() {
        // Walks must run noticeably faster than sleep — otherwise the
        // walking animation stutters. This mirrors the timing table in
        // the README.
        XCTAssertLessThan(PetMood.working.frameDurationSeconds,
                          PetMood.sleeping.frameDurationSeconds)
        XCTAssertLessThan(PetMood.alert.frameDurationSeconds,
                          PetMood.happy.frameDurationSeconds)
    }
}
