import AppKit
import CoreGraphics
import Foundation

/// Drives the pet's idle mood with a random rotation so it behaves like
/// a real pet doing its own thing instead of mirroring session status.
///
/// Every 20–45s the scheduler picks a non-attention mood (`.sleeping`
/// / `.happy` / `.working`, biased ~50/30/20) and forwards it to the
/// PetController via `onTick`. When the OS reports the user has been
/// idle for ≥`forceSleepIdleSeconds`, the pick is overridden to
/// `.sleeping` regardless of the random roll.
///
/// `.alert` / `.sad` / `.hidden` are deliberately **not** in the
/// random pool — those moods belong to event reactions, not the idle
/// rotation, and surfacing them randomly would lie to the user.
final class MoodScheduler {
    static let forceSleepIdleSeconds: TimeInterval = 300
    static let minTickSeconds: TimeInterval = 20
    static let maxTickSeconds: TimeInterval = 45

    /// Idle-mood distribution. Weights sum to 1.0. The `.sleeping`
    /// bias matches what a cat actually does most of the day.
    static let randomMoodWeights: [(PetMood, Double)] = [
        (.sleeping, 0.50),
        (.happy,    0.30),
        (.working,  0.20),
    ]

    private let pickRoll: () -> Double           // uniform [0, 1)
    private let pickInterval: () -> TimeInterval
    private let idleProvider: () -> TimeInterval
    private let onTick: (PetMood) -> Void
    private var timer: Timer?

    init(
        pickRoll: @escaping () -> Double = { Double.random(in: 0..<1) },
        pickInterval: @escaping () -> TimeInterval = {
            TimeInterval.random(in: MoodScheduler.minTickSeconds...MoodScheduler.maxTickSeconds)
        },
        idleProvider: @escaping () -> TimeInterval = MoodScheduler.systemIdleSeconds,
        onTick: @escaping (PetMood) -> Void
    ) {
        self.pickRoll = pickRoll
        self.pickInterval = pickInterval
        self.idleProvider = idleProvider
        self.onTick = onTick
    }

    func start() { schedule() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Compute the next mood without scheduling a timer. Used by the
    /// controller's event-override resume path.
    func pickMood() -> PetMood {
        if idleProvider() >= MoodScheduler.forceSleepIdleSeconds {
            return .sleeping
        }
        return MoodScheduler.weightedMood(roll: pickRoll())
    }

    private func schedule() {
        timer?.invalidate()
        let interval = pickInterval()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.onTick(self.pickMood())
            self.schedule()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Resolve a [0, 1) roll to one of the random idle moods using the
    /// `randomMoodWeights` distribution. Pure function, used directly
    /// by tests with synthetic rolls.
    static func weightedMood(roll: Double) -> PetMood {
        let clamped = max(0, min(roll, 0.9999999))
        var acc = 0.0
        for (mood, weight) in randomMoodWeights {
            acc += weight
            if clamped < acc { return mood }
        }
        return randomMoodWeights.last?.0 ?? .sleeping
    }

    /// macOS user-input idle time. Wraps
    /// `CGEventSource.secondsSinceLastEventType` with the "any event"
    /// constant. Returns 0 if the system reports a negative value
    /// (paused machine, sandbox, etc.).
    static func systemIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: UInt32.max) else { return 0 }
        let secs = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyEvent
        )
        return max(0, secs)
    }
}
