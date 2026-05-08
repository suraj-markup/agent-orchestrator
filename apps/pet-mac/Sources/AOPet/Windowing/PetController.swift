import AppKit

/// Owns the single global pet window. Updates sprite frame on a timer,
/// reacts to events with a one-shot animation + thought bubble (labelled
/// with the originating project), and provides a right-click context menu.
final class PetController {
    /// Identity for `PositionStore` and the hidden flag. Always
    /// `PositionStore.globalKey` today, but kept as an init parameter so
    /// tests (and a possible future per-project mode) can override it.
    let positionKey: String
    private var mood: PetMood = .sleeping
    private var spriteSet: SpriteSet
    private let window: PetWindow
    private let view: PetView
    private var animationTimer: Timer?
    private var tick = 0

    /// Called when the user picks "Switch sprite".
    var onSwitchSprite: (() -> Void)?
    /// Called when the user picks "Hide pet".
    var onHide: (() -> Void)?

    init(positionKey: String = PositionStore.globalKey, spriteSet: SpriteSet) {
        self.positionKey = positionKey
        self.spriteSet = spriteSet
        self.window = PetWindow(size: PetView.totalSize)
        self.view = PetView(frame: NSRect(origin: .zero, size: PetView.totalSize))
        window.contentView = view

        view.menuProvider = { [weak self] in self?.buildMenu() }
        renderFrame()
        startAnimation()
    }

    // MARK: - Lifecycle

    func show(at fallbackOrigin: NSPoint) {
        let origin = PositionStore.load(for: positionKey) ?? fallbackOrigin
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didMove),
            name: NSWindow.didMoveNotification,
            object: window
        )
    }

    func close() {
        animationTimer?.invalidate()
        animationTimer = nil
        NotificationCenter.default.removeObserver(self)
        window.orderOut(nil)
    }

    @objc private func didMove() {
        PositionStore.save(window.frame.origin, for: positionKey)
    }

    // MARK: - State updates

    func updateMood(_ newMood: PetMood) {
        guard newMood != mood else { return }
        mood = newMood
        tick = 0
        // Overlay badges disambiguate moods the oneko sheet doesn't have
        // a unique pose for. See MoodOverlayView.
        switch newMood {
        case .sad:   view.setOverlay(.exclaim)
        case .happy: view.setOverlay(.check)
        default:     view.setOverlay(nil)
        }
        renderFrame()
        // Different moods animate at different cadences — re-arm the
        // tick timer so e.g. walking runs at 8 fps but sleeping at 1 fps.
        startAnimation()
    }

    func updateSpriteSet(_ set: SpriteSet) {
        spriteSet = set
        renderFrame()
    }

    /// Show an event reaction: bubble + one-shot animation. The bubble
    /// is prefixed with `[projectName]` so the user can tell which
    /// project the event came from in a single-pet world.
    func handleEvent(_ event: SocketEvent, projectName: String?) {
        let tint: NSColor
        switch event.priority {
        case .urgent:  tint = NSColor.systemRed
        case .warning: tint = NSColor.systemOrange
        case .action:  tint = NSColor.systemBlue
        case .info, .unknown: tint = NSColor(white: 0.2, alpha: 1)
        }
        let duration: TimeInterval = event.priority == .urgent ? 6 : 4
        let text = PetController.bubbleText(message: event.message, projectName: projectName)
        view.showBubble(text: text, tint: tint, durationSeconds: duration)
        view.playReaction(PetView.ReactionKind.forPriority(event.priority))
    }

    /// Compose the bubble text. ProjectName is truncated to 16 chars so
    /// long names don't blow the bubble's width budget.
    static func bubbleText(message: String, projectName: String?) -> String {
        guard let name = projectName, !name.isEmpty else { return message }
        let truncated = name.count > 16
            ? String(name.prefix(16)) + "…"
            : name
        return "[\(truncated)] \(message)"
    }

    // MARK: - Animation

    private func startAnimation() {
        animationTimer?.invalidate()
        let timer = Timer(
            timeInterval: mood.frameDurationSeconds,
            repeats: true
        ) { [weak self] _ in
            guard let self = self else { return }
            self.tick += 1
            self.renderFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func renderFrame() {
        view.setImage(spriteSet.image(for: mood, tick: tick))
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "AOPet")

        let hideItem = NSMenuItem(
            title: "Hide pet",
            action: #selector(menuHide),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        let switchItem = NSMenuItem(
            title: "Switch sprite",
            action: #selector(menuSwitchSprite),
            keyEquivalent: ""
        )
        switchItem.target = self
        menu.addItem(switchItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit AOPet",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func menuHide() {
        PositionStore.setHidden(true, for: positionKey)
        onHide?()
    }

    @objc private func menuSwitchSprite() {
        onSwitchSprite?()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
}
