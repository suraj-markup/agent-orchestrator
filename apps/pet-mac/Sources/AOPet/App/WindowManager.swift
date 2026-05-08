import AppKit

/// Top-level coordinator for the single global pet. Owns one PetController
/// (created on demand once any session exists), routes socket events to
/// it, and labels event bubbles with the originating project name from
/// the latest poller snapshot.
final class WindowManager {
    private var controller: PetController?
    private var currentSpriteName: String
    private var spriteSet: SpriteSet
    private var projectNames: [String: String] = [:]
    private static let defaultsKey = "pet.spriteSet"

    init() {
        let defaultsName = UserDefaults.standard.string(forKey: WindowManager.defaultsKey)
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

    /// Show / hide / update the single pet to match the current
    /// instance-wide state. The pet hides when no sessions exist
    /// anywhere or when the user has explicitly hidden it.
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

        guard let controller = controller else { return }
        controller.updateMood(state.mood)

        if let screen = NSScreen.main {
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
        let projectName: String? = envelope.event.projectId.flatMap { projectNames[$0] }
        controller?.handleEvent(envelope.event, projectName: projectName)
    }

    // MARK: - Sprite switching

    private func cycleSprite() {
        let sets = SpriteLoader.availableSets
        guard sets.count > 1, let currentIdx = sets.firstIndex(of: currentSpriteName) else {
            return
        }
        let nextName = sets[(currentIdx + 1) % sets.count]
        guard let next = SpriteLoader.load(nextName) else { return }
        currentSpriteName = nextName
        spriteSet = next
        UserDefaults.standard.set(nextName, forKey: WindowManager.defaultsKey)
        controller?.updateSpriteSet(next)
    }
}
