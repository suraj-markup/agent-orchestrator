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

    /// Drives the pet's idle mood. The pet is now event-driven: the
    /// scheduler picks a random non-attention mood every 20–45s, and
    /// socket events temporarily override that pick for ~10s before
    /// the rotation resumes.
    private var moodScheduler: MoodScheduler?
    /// While set and in the future, the scheduler's pick is ignored.
    /// Cleared when the override expires or when a new event lands.
    private var eventOverrideExpiry: Date?

    /// How long an event-driven mood (`urgent → .alert`,
    /// `action → .happy`) sticks before the random rotation resumes.
    private static let eventOverrideSeconds: TimeInterval = 10

    /// Force `.sleeping` when the OS reports user idle ≥ this many
    /// seconds. Threaded into the scheduler from here so the constant
    /// is discoverable on the controller.
    private static let forceSleepIdleSeconds: TimeInterval = 300

    /// Drives autonomous wandering — the pet picks a random direction,
    /// walks for a few seconds, occasionally pauses. See WanderController.
    private var wanderController: WanderController?
    /// Set by the most recent wander `.move` tick; cleared on `.still`.
    /// `renderFrame` uses this to decide between a walk frame and the
    /// mood frame.
    private var currentWalkDirection: WalkDirection?
    /// Walk-frame counter — incremented every wander tick the pet is
    /// moving. Divided by `walkFrameSubdivision` to slow the visible
    /// cadence below the wander tick rate (20fps wander → ~7fps walk).
    private var walkTick = 0
    private static let walkFrameSubdivision = 3
    /// After a user-driven move (= drag), suspend wander for this long
    /// so the cat doesn't fight the user's cursor.
    private static let userDragSuppressSeconds: TimeInterval = 1.0

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
        view.onPreferredSizeChange = { [weak self] newSize in
            self?.resizeWindow(to: newSize)
        }
        renderFrame()
        startAnimation()
        startMoodScheduler()
    }

    /// Grow or shrink the window to match the view's requested size.
    /// Bottom-left origin is preserved so the sprite stays planted on
    /// screen — only the top edge moves. Bubble auto-grow goes up; the
    /// auto-hide path then shrinks back to the default size.
    private func resizeWindow(to size: NSSize) {
        var frame = window.frame
        guard frame.size != size else { return }
        frame.size = size
        window.performProgrammatically {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: - Lifecycle

    func show(at fallbackOrigin: NSPoint) {
        let origin = PositionStore.load(for: positionKey) ?? fallbackOrigin
        window.performProgrammatically {
            window.setFrameOrigin(origin)
        }
        window.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didMove),
            name: NSWindow.didMoveNotification,
            object: window
        )
        startWanderControllerIfNeeded()
    }

    func close() {
        animationTimer?.invalidate()
        animationTimer = nil
        moodScheduler?.stop()
        moodScheduler = nil
        wanderController?.stop()
        wanderController = nil
        NotificationCenter.default.removeObserver(self)
        window.orderOut(nil)
    }

    private func startWanderControllerIfNeeded() {
        guard wanderController == nil else { return }
        let wander = WanderController { [weak self] action in
            self?.applyWanderTick(action)
        }
        // Apply the current mood's gating so the pet doesn't immediately
        // start walking if it spawned in `.alert` / `.sleeping`.
        applyWanderGate(for: mood, on: wander)
        wander.start()
        wanderController = wander
    }

    private func startMoodScheduler() {
        let scheduler = MoodScheduler { [weak self] mood in
            self?.applyScheduledMood(mood)
        }
        scheduler.start()
        moodScheduler = scheduler
    }

    private func applyScheduledMood(_ mood: PetMood) {
        // While an event override is in effect, leave the mood pinned.
        // The override's resume timer will pick the next mood when it
        // expires, so we don't need to drop ticks forever.
        if let expiry = eventOverrideExpiry, Date() < expiry { return }
        eventOverrideExpiry = nil
        updateMood(mood)
    }

    @objc private func didMove() {
        // Programmatic moves (wander steps, bubble auto-grow) must NOT
        // overwrite the user's parked position. Only persist when the
        // move came from outside our code paths — i.e. the user dragged.
        guard !window.isProgrammaticMove else { return }
        PositionStore.save(window.frame.origin, for: positionKey)
        // The user just grabbed the pet. Suppress wander so the cat
        // doesn't immediately walk away from where they parked it.
        wanderController?.suppressForSeconds(PetController.userDragSuppressSeconds)
    }

    /// Apply one tick from the wander controller. `.move` translates
    /// the window (clamped to the current screen) and remembers the
    /// direction so `renderFrame` shows the matching walk pose.
    /// `.still` clears the direction so we fall back to the mood frame.
    private func applyWanderTick(_ action: WanderController.TickAction) {
        switch action {
        case .move(let dx, let dy, let dir):
            // Mood gates inside the wander controller already suppress
            // ticks for `.alert`/`.sleeping`, but if the gate was just
            // released and the mood hasn't transitioned yet, double-check.
            guard !shouldSuppressMovementForMood(mood) else {
                applyWanderTick(.still)
                return
            }
            let current = window.frame.origin
            // AppKit window origin is bottom-left; `dy` from the wander
            // vector is positive-south, so subtract to move down on screen.
            let proposed = NSPoint(x: current.x + dx, y: current.y - dy)
            let clamped = WanderController.clampOrigin(
                proposed,
                size: window.frame.size,
                screens: NSScreen.screens
            )
            window.performProgrammatically {
                window.setFrameOrigin(clamped)
            }
            currentWalkDirection = dir
            walkTick += 1
            renderFrame()
        case .still:
            currentWalkDirection = nil
            renderFrame()
        }
    }

    /// Whether the wander loop should freeze for this mood. Sleeping
    /// pets don't roam; alert pets stay put while the user reads the
    /// bubble.
    private func shouldSuppressMovementForMood(_ mood: PetMood) -> Bool {
        switch mood {
        case .sleeping, .alert: return true
        default: return false
        }
    }

    private func applyWanderGate(for mood: PetMood, on wander: WanderController) {
        if shouldSuppressMovementForMood(mood) {
            // Suppress for the full event-override window so an alert
            // event doesn't immediately surrender to wander after 1s.
            wander.suppressForSeconds(PetController.eventOverrideSeconds)
        }
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
        // Sleeping/alert moods freeze the wander loop. Other moods let
        // it run; the `.still` action will render the mood frame.
        if let wander = wanderController, shouldSuppressMovementForMood(newMood) {
            wander.suppressForSeconds(PetController.eventOverrideSeconds)
            currentWalkDirection = nil
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
        let pinnedMood: PetMood
        switch event.priority {
        case .urgent:
            tint = NSColor.systemRed
            pinnedMood = .alert
        case .action:
            tint = NSColor.systemBlue
            pinnedMood = .happy
        // Filtered above; fall back to a neutral tint defensively.
        case .warning, .info, .unknown:
            tint = NSColor(white: 0.2, alpha: 1)
            pinnedMood = mood
        }

        // Pin the mood so the random scheduler doesn't immediately
        // overwrite an attention pose. The override expires after
        // eventOverrideSeconds; the resume timer below transitions
        // back to a fresh scheduler pick rather than waiting up to
        // 45s for the next regular tick.
        eventOverrideExpiry = Date().addingTimeInterval(PetController.eventOverrideSeconds)
        updateMood(pinnedMood)

        let duration: TimeInterval = event.priority == .urgent ? 6 : 4
        let text = PetController.bubbleText(
            message: event.message,
            projectName: projectName,
            sessionId: event.sessionId
        )
        view.showBubble(text: text, tint: tint, durationSeconds: duration)
        view.playReaction(PetView.ReactionKind.forPriority(event.priority))

        if let soundName = PetController.soundName(for: event.priority) {
            NSSound(named: NSSound.Name(soundName))?.play()
        }

        // Resume the random rotation when the pin expires — without
        // this we'd stay alert/happy until the next 20–45s tick.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PetController.eventOverrideSeconds
        ) { [weak self] in
            self?.resumeFromOverrideIfExpired()
        }
    }

    private func resumeFromOverrideIfExpired() {
        guard let expiry = eventOverrideExpiry, Date() >= expiry else { return }
        eventOverrideExpiry = nil
        if let next = moodScheduler?.pickMood() {
            updateMood(next)
        }
    }

    /// Only urgent and action priorities surface a bubble. Routine
    /// warning/info chatter is dropped before any UI work happens.
    static func shouldShowBubble(for priority: EventPriority) -> Bool {
        switch priority {
        case .urgent, .action: return true
        case .warning, .info, .unknown: return false
        }
    }

    /// macOS system sound name to play alongside the bubble. Urgent gets
    /// the classic Sosumi attention chime; action gets the softer Glass.
    /// Anything else is silent (those events don't show a bubble).
    static func soundName(for priority: EventPriority) -> String? {
        switch priority {
        case .urgent:  return "Sosumi"
        case .action:  return "Glass"
        case .warning, .info, .unknown: return nil
        }
    }

    /// Soft ceiling on the message's character length. The bubble auto
    /// -grows to fit text up to `PetView.maxBubbleHeight` (~8 lines of
    /// 13pt body), which is roughly 200 chars at this width. The
    /// budget protects against pathological inputs (1MB messages) and
    /// guarantees that, when truncation does happen, the cut falls on
    /// the message — projectName and sessionId are needed for
    /// disambiguation and never get clipped.
    private static let bubbleCharBudget = 250

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
        // While wandering with a known direction, prefer the walk frame.
        // Falls through to the mood frame if the sprite set lacks walk
        // assets (older sets pre-wander) or we're paused / suppressed.
        if let dir = currentWalkDirection,
           !shouldSuppressMovementForMood(mood),
           let walkImage = spriteSet.image(
                for: dir,
                tick: walkTick / PetController.walkFrameSubdivision
           ) {
            view.setImage(walkImage)
            return
        }
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
