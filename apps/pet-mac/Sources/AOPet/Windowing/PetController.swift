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

    /// Show an event reaction: bubble + one-shot animation. Filtered to
    /// `urgent` and `action` priorities only — `warning` and `info`
    /// events are silently dropped so the pet stays calm during routine
    /// chatter (CI ticks, log lines, etc.) and only speaks when the
    /// human actually needs to look at something.
    func handleEvent(_ event: SocketEvent, projectName: String?) {
        guard PetController.shouldShowBubble(for: event.priority) else { return }

        let tint: NSColor
        switch event.priority {
        case .urgent:  tint = NSColor.systemRed
        case .action:  tint = NSColor.systemBlue
        // Filtered above; fall back to a neutral tint defensively.
        case .warning, .info, .unknown:
            tint = NSColor(white: 0.2, alpha: 1)
        }
        let duration: TimeInterval = event.priority == .urgent ? 6 : 4
        let text = PetController.bubbleText(
            message: event.message,
            projectName: projectName,
            sessionId: event.sessionId
        )
        view.showBubble(text: text, tint: tint, durationSeconds: duration)
        view.playReaction(PetView.ReactionKind.forPriority(event.priority))
    }

    /// Only urgent and action priorities surface a bubble. Routine
    /// warning/info chatter is dropped before any UI work happens.
    static func shouldShowBubble(for priority: EventPriority) -> Bool {
        switch priority {
        case .urgent, .action: return true
        case .warning, .info, .unknown: return false
        }
    }

    /// Hard ceiling on rendered bubble characters. The bubble is ~152pt
    /// wide at 9pt medium, which fits roughly this many glyphs on one
    /// line before NSString truncation kicks in. We do an explicit
    /// budget so the cut always falls on the message — projectName and
    /// sessionId are needed for disambiguation and never get clipped.
    private static let bubbleCharBudget = 60

    /// Compose `<projectName> <sessionId> <message>`. ProjectName falls
    /// back to projectId via the caller; if neither is known the prefix
    /// is dropped. Message is truncated with an ellipsis so the
    /// identifying prefix always survives.
    static func bubbleText(
        message: String,
        projectName: String?,
        sessionId: String?
    ) -> String {
        var prefixParts: [String] = []
        if let name = projectName, !name.isEmpty { prefixParts.append(name) }
        if let sid = sessionId, !sid.isEmpty { prefixParts.append(sid) }

        guard !prefixParts.isEmpty else {
            return truncateMessage(message, budget: bubbleCharBudget)
        }

        let prefix = prefixParts.joined(separator: " ")
        // Reserve the prefix + a separating space; the message gets
        // whatever is left of the budget.
        let used = prefix.count + 1
        let remaining = max(0, bubbleCharBudget - used)
        let body = truncateMessage(message, budget: remaining)
        return "\(prefix) \(body)"
    }

    private static func truncateMessage(_ message: String, budget: Int) -> String {
        if budget <= 0 { return "" }
        if message.count <= budget { return message }
        // Reserve one char for the ellipsis itself.
        let cut = max(0, budget - 1)
        return String(message.prefix(cut)) + "…"
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
