import XCTest
@testable import AOPet

/// Sanity for the "Switch sprite" cycle. The previous build had only
/// one entry in `availableSets`, so cycleSprite bailed on the
/// `sets.count > 1` guard and the menu item silently no-op'd.
final class WindowManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AOPetTests.WindowManager.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAvailableSetsHasAllThreeSprites() {
        // Without these three the cycle below has nothing to cycle.
        XCTAssertEqual(SpriteLoader.availableSets, ["oneko", "cat", "dog"])
    }

    func testCycleSpriteRotatesOnekoCatDogOneko() {
        let manager = WindowManager(defaults: defaults)

        let first = manager.cycleSprite()
        XCTAssertEqual(first, "cat")
        XCTAssertEqual(manager.currentSpriteName, "cat")

        let second = manager.cycleSprite()
        XCTAssertEqual(second, "dog")
        XCTAssertEqual(manager.currentSpriteName, "dog")

        let third = manager.cycleSprite()
        XCTAssertEqual(third, "oneko")
        XCTAssertEqual(manager.currentSpriteName, "oneko")
    }

    func testCycleSpritePersistsToUserDefaults() {
        let manager = WindowManager(defaults: defaults)
        _ = manager.cycleSprite() // → cat
        XCTAssertEqual(defaults.string(forKey: "pet.spriteSet"), "cat")

        // A fresh WindowManager backed by the same defaults must
        // resume on the persisted set.
        let resumed = WindowManager(defaults: defaults)
        XCTAssertEqual(resumed.currentSpriteName, "cat")
    }

    func testEachAvailableSetLoadsAndCoversAllAnimatedMoods() {
        // Every bundled set must ship frames for the moods the random
        // scheduler can pick (`.sleeping`/`.happy`/`.working`) plus the
        // two event-pinned moods (`.alert`/`.sad`). `frameCount` is
        // floor-clamped to 1 by SpriteSet so a missing mood would
        // animate as a stuck single frame, but we still want real
        // multi-frame coverage so ship-time regressions are caught.
        let critical: [PetMood] = [.sleeping, .happy, .working, .alert, .sad]
        for setName in SpriteLoader.availableSets {
            guard let set = SpriteLoader.load(setName) else {
                XCTFail("\(setName) failed to load")
                continue
            }
            for mood in critical {
                XCTAssertGreaterThanOrEqual(
                    set.frameCount(for: mood),
                    2,
                    "\(setName) needs ≥ 2 frames for \(mood.rawValue)"
                )
            }
        }
    }
}
