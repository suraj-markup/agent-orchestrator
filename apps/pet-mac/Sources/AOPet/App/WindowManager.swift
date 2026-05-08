import AppKit

/// Top-level coordinator for the single global pet. Owns one PetController
/// (created on demand once any session exists), routes socket events to
/// it, and labels event bubbles with the originating project name from
/// the latest poller snapshot.
///
/// Note: as of the event-driven pivot the manager **no longer drives the
/// pet's mood** from session status. The mood comes from
/// `PetController.MoodScheduler` (random rotation + idle-sleep). This
/// class is now responsible only for show/hide, sprite switching, and
/// event routing.
final class WindowManager {
    private var controller: PetController?
    private(set) var currentSpriteName: String
    private var spriteSet: SpriteSet
    private var projectNames: [String: String] = [:]
    private let defaults: UserDefaults
    private static let defaultsKey = "pet.spriteSet"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let defaultsName = defaults.string(forKey: WindowManager.defaultsKey)
        let initial = defaultsName
            ?? SpriteLoader.availableSets.first
            ?? "oneko"
        currentSpriteName = initial
        if let loaded = SpriteLoader.load(initial) {
            spriteSet = loaded
        } else if let fallback = SpriteLoader.availableSets.first.flatMap({ SpriteLoader.load($0) }) {
            spriteSet = fallback
            currentSpriteName = fallback.name
        } else {
            // Shouldn't happen — Resources/sprites always ships at least one
            // set — but provide an empty placeholder so the app still launches.
            spriteSet = SpriteSet(name: "empty", frames: [:])
        }

        // One-launch nudge: if the user previously parked a per-project
        // pet, carry that position over to the global slot so the
        // refactor doesn't relocate them to the default top-right.
        PositionStore.migrateLegacyToGlobal()
    }

    // MARK: - Reconcile

    /// Show or hide the pet based on whether AO has any sessions
    /// running and whether the user has explicitly hidden it. The
    /// pet's mood is **not** driven from here — see `MoodScheduler`.
    /// `state.mood` is intentionally ignored.
    func reconcile(state: StateAggregator.InstanceState, projectNames: [String: String]) {
        self.projectNames = projectNames

        let userHidden = PositionStore.isHidden(PositionStore.globalKey)
        let shouldShow = state.hasSessions && !userHidden

        if !shouldShow {
            controller?.close()
            controller = nil
            return
        }

        if controller == nil {
            let c = PetController(spriteSet: spriteSet)
            c.onHide = { [weak self] in
                self?.controller?.close()
                self?.controller = nil
            }
            c.onSwitchSprite = { [weak self] in self?.cycleSprite() }
            controller = c
        }

        if let screen = NSScreen.main, let controller = controller {
            let fallback = WindowLayout.origin(
                forIndex: 0,
                size: PetView.totalSize,
                in: screen
            )
            controller.show(at: fallback)
        }
    }

    // MARK: - Event routing

    func deliver(event envelope: SocketEnvelope) {
        // Prefer the human-readable project name from the latest poller
        // snapshot; fall back to the raw projectId when an event arrives
        // before the first /api/sessions response has populated names.
        let projectName: String? = envelope.event.projectId.map { id in
            projectNames[id] ?? id
        }
        controller?.handleEvent(envelope.event, projectName: projectName)
    }

    // MARK: - Sprite switching

    /// Advance to the next bundled sprite set and persist the choice to
    /// UserDefaults so it survives a relaunch. `internal` so tests can
    /// drive the cycle directly.
    @discardableResult
    func cycleSprite() -> String {
        let sets = SpriteLoader.availableSets
        guard sets.count > 1, let currentIdx = sets.firstIndex(of: currentSpriteName) else {
            return currentSpriteName
        }
        let nextName = sets[(currentIdx + 1) % sets.count]
        guard let next = SpriteLoader.load(nextName) else {
            return currentSpriteName
        }
        currentSpriteName = nextName
        spriteSet = next
        defaults.set(nextName, forKey: WindowManager.defaultsKey)
        controller?.updateSpriteSet(next)
        return nextName
    }
}
