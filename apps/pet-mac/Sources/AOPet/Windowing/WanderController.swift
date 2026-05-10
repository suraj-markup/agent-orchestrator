import AppKit
import Foundation

/// Drives the pet's autonomous wander: every 50ms it picks the next
/// move (or pause) according to a small state machine and emits a
/// `TickAction` for the PetController to apply to the window.
///
/// Stateless wherever possible: the random rolls and timing pickers are
/// injectable, the `step(...)` transition is a pure function, and
/// bounds clamping lives in a separate pure helper. The only mutable
/// state is the current `State` and a soft external-pause timestamp
/// (used when the user is mid-drag or an event has pinned an attention
/// pose).
final class WanderController {

    // MARK: - Tunables

    /// Tick interval. 50ms = 20fps — smooth enough that 30 px/sec
    /// motion doesn't visibly jitter.
    static let tickIntervalSeconds: TimeInterval = 0.05

    /// Slow, pet-like pace.
    static let speedPxPerSec: Double = 30

    /// Random walk-burst duration before the controller picks again.
    static let walkSecondsRange: ClosedRange<Double> = 3.0...8.0

    /// Random pause duration when the pet stops between walks.
    static let pauseSecondsRange: ClosedRange<Double> = 1.0...3.0

    /// Probability of a pause vs a new walk after a walking burst ends.
    /// 0.30 means ~30% pauses, ~70% direction changes.
    static let pauseProbability: Double = 0.30

    // MARK: - Output

    enum TickAction: Equatable {
        /// Move the window by (dx, dy) in screen-points and render the
        /// matching walk frame for `frameDir`.
        case move(dx: Double, dy: Double, frameDir: WalkDirection)
        /// Pet is paused (or externally suppressed). Show the still
        /// idle frame; do not move the window.
        case still
    }

    enum State: Equatable {
        case walking(direction: WalkDirection, ticksRemaining: Int)
        case paused(ticksRemaining: Int)
    }

    // MARK: - Wiring

    private(set) var state: State
    private let intervalSeconds: TimeInterval
    private let speedPxPerSec: Double
    private let pickRoll: () -> Double
    private let pickDirection: () -> WalkDirection
    private let pickWalkDuration: () -> Double
    private let pickPauseDuration: () -> Double
    private let onTick: (TickAction) -> Void
    private var timer: DispatchSourceTimer?
    private var externalSuppressUntil: Date?

    init(
        intervalSeconds: TimeInterval = WanderController.tickIntervalSeconds,
        speedPxPerSec: Double = WanderController.speedPxPerSec,
        pickRoll: @escaping () -> Double = { Double.random(in: 0..<1) },
        pickDirection: @escaping () -> WalkDirection = {
            WalkDirection.allCases.randomElement() ?? .e
        },
        pickWalkDuration: @escaping () -> Double = {
            Double.random(in: WanderController.walkSecondsRange)
        },
        pickPauseDuration: @escaping () -> Double = {
            Double.random(in: WanderController.pauseSecondsRange)
        },
        onTick: @escaping (TickAction) -> Void
    ) {
        self.intervalSeconds = intervalSeconds
        self.speedPxPerSec = speedPxPerSec
        self.pickRoll = pickRoll
        self.pickDirection = pickDirection
        self.pickWalkDuration = pickWalkDuration
        self.pickPauseDuration = pickPauseDuration
        self.onTick = onTick
        // Seed with a walking burst so the pet starts moving.
        let dir = pickDirection()
        let secs = pickWalkDuration()
        let ticks = max(1, Int((secs / intervalSeconds).rounded()))
        self.state = .walking(direction: dir, ticksRemaining: ticks)
    }

    // MARK: - Lifecycle

    func start() { schedule() }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Suppress moves for `seconds`. Used when the mood becomes
    /// `.sleeping` / `.alert` (event pinned) or the user just dragged
    /// the window. Ticks still fire (so the still frame renders) but
    /// the state machine is frozen — no movement, no transitions.
    func suppressForSeconds(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        // Extend, never shorten: a 10s suppression should override a
        // queued 0.5s suppression from drag, etc.
        if let current = externalSuppressUntil, current >= until { return }
        externalSuppressUntil = until
    }

    /// Whether the controller is currently in soft-suppress mode.
    /// Exposed for tests + the controller's "what frame to show" logic.
    var isSuppressed: Bool {
        guard let until = externalSuppressUntil else { return false }
        return Date() < until
    }

    // MARK: - Tick

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(
            deadline: .now() + intervalSeconds,
            repeating: intervalSeconds
        )
        t.setEventHandler { [weak self] in
            self?.fireTick()
        }
        t.resume()
        timer = t
    }

    /// Single tick of the state machine. Public so tests can advance
    /// the controller without spinning a real timer.
    func fireTick() {
        if isSuppressed {
            onTick(.still)
            return
        }
        let (action, next) = WanderController.step(
            state: state,
            intervalSeconds: intervalSeconds,
            speedPxPerSec: speedPxPerSec,
            pickRoll: pickRoll,
            pickDirection: pickDirection,
            pickWalkDuration: pickWalkDuration,
            pickPauseDuration: pickPauseDuration
        )
        state = next
        onTick(action)
    }

    /// Pure transition. Given a state and the timing/pickers, return
    /// `(action this tick, next state)`. Bounds clamping happens at
    /// the call site so this stays free of AppKit dependencies.
    static func step(
        state: State,
        intervalSeconds: TimeInterval,
        speedPxPerSec: Double,
        pickRoll: () -> Double,
        pickDirection: () -> WalkDirection,
        pickWalkDuration: () -> Double,
        pickPauseDuration: () -> Double
    ) -> (action: TickAction, next: State) {
        let pxPerTick = speedPxPerSec * intervalSeconds
        switch state {
        case .walking(let dir, let n):
            let v = dir.unitVector
            let action = TickAction.move(
                dx: v.dx * pxPerTick,
                dy: v.dy * pxPerTick,
                frameDir: dir
            )
            if n > 1 {
                return (action, .walking(direction: dir, ticksRemaining: n - 1))
            }
            // Walking burst ended — pick what's next.
            if pickRoll() < pauseProbability {
                let ticks = secondsToTicks(pickPauseDuration(), interval: intervalSeconds)
                return (action, .paused(ticksRemaining: ticks))
            }
            let nextDir = pickDirection()
            let ticks = secondsToTicks(pickWalkDuration(), interval: intervalSeconds)
            return (action, .walking(direction: nextDir, ticksRemaining: ticks))

        case .paused(let n):
            if n > 1 {
                return (.still, .paused(ticksRemaining: n - 1))
            }
            // Pause ended — always go back to walking (we just decided
            // to pause; no point picking pause again immediately).
            let dir = pickDirection()
            let ticks = secondsToTicks(pickWalkDuration(), interval: intervalSeconds)
            return (.still, .walking(direction: dir, ticksRemaining: ticks))
        }
    }

    private static func secondsToTicks(
        _ seconds: Double,
        interval: TimeInterval
    ) -> Int {
        return max(1, Int((seconds / interval).rounded()))
    }

    // MARK: - Bounds

    /// Clamp a window origin to the visible frame of whichever screen
    /// contains the window's current centre. Multi-monitor safe: if
    /// the centre is off-screen (e.g. the pet was dragged out) it
    /// falls back to `NSScreen.main`, then to any screen at all.
    static func clampOrigin(
        _ origin: NSPoint,
        size: NSSize,
        screens: [NSScreen]
    ) -> NSPoint {
        let centre = NSPoint(
            x: origin.x + size.width / 2,
            y: origin.y + size.height / 2
        )
        let home = screens.first(where: { NSPointInRect(centre, $0.frame) })
            ?? NSScreen.main
            ?? screens.first
        guard let screen = home else { return origin }
        let visible = screen.visibleFrame
        let clampedX = max(visible.minX,
                           min(origin.x, visible.maxX - size.width))
        let clampedY = max(visible.minY,
                           min(origin.y, visible.maxY - size.height))
        return NSPoint(x: clampedX, y: clampedY)
    }
}
