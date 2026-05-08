import Foundation

/// Visual mood the pet shows. Drives the idle animation.
/// Order in `priority(_:)` is the worst-state ranking — higher number wins.
enum PetMood: String, CaseIterable, Equatable {
    case sleeping       // all sessions idle/done — no work happening
    case happy          // PR open / under review / approved / mergeable / merged
    case working        // someone is actively working / typing
    case sad            // ci_failed / stuck / blocked
    case alert          // waiting_input — needs human now
    case hidden         // no sessions running anywhere — pet is hidden

    /// Higher = more attention-needing. Used by the worst-state picker.
    var priority: Int {
        switch self {
        case .hidden:   return -1
        case .sleeping: return 0
        case .happy:    return 1
        case .working:  return 2
        case .sad:      return 3
        case .alert:    return 4
        }
    }

    /// Per-mood frame duration. Walks at 8 fps; sleep at 1 fps; the
    /// scratch animation reads correctly at ~6 fps; static-pose blinks
    /// at ~2 fps. Driven by the oneko sprite cadence.
    var frameDurationSeconds: TimeInterval {
        switch self {
        case .working:        return 0.125
        case .alert:          return 0.166
        case .happy:          return 0.50
        case .sad:            return 0.40
        case .sleeping:       return 1.00
        case .hidden:         return 1.00
        }
    }
}

/// Collapses every session AO is tracking into a single instance-wide
/// mood. The pet is one global window now (not per-project), so we pick
/// the worst mood across all sessions across all projects.
enum StateAggregator {
    /// Map a single session to the mood it would induce on its own.
    /// Status takes priority over activity for the "alert/sad/happy" buckets;
    /// activity is the tiebreaker for "working" vs "sleeping".
    static func mood(for session: WireSession) -> PetMood {
        // 1. Waiting on a human — most urgent.
        if session.activity == .waitingInput || session.status == .needsInput {
            return .alert
        }

        // 2. Something is broken.
        switch session.status {
        case .ciFailed, .stuck, .errored, .changesRequested:
            return .sad
        default:
            break
        }
        if session.activity == .blocked {
            return .sad
        }

        // 3. PR is in a good place. review_pending is just "PR open,
        // waiting on a human reviewer" — same vibe as pr_open. merged is
        // the celebration moment before cleanup ticks the session to done.
        switch session.status {
        case .prOpen, .reviewPending, .approved, .mergeable, .merged:
            return .happy
        default:
            break
        }

        // 4. Something is actively running.
        if session.status == .working || session.status == .spawning ||
            session.status == .detecting || session.activity == .active {
            return .working
        }

        // 5. Done / merged / idle / unknown — sleep it off.
        return .sleeping
    }

    /// Single global state: worst mood across every session AO knows
    /// about, plus the total session count so the WindowManager can
    /// decide whether to show the pet at all.
    struct InstanceState: Equatable {
        let mood: PetMood
        let totalSessions: Int

        /// True when AO has any sessions running. The pet hides itself
        /// when this is false.
        var hasSessions: Bool { totalSessions > 0 }
    }

    /// Collapse every session into one InstanceState. Empty input maps
    /// to `.hidden` with `totalSessions = 0`.
    static func aggregateGlobal(sessions: [WireSession]) -> InstanceState {
        if sessions.isEmpty {
            return InstanceState(mood: .hidden, totalSessions: 0)
        }
        let worst = sessions
            .map { mood(for: $0) }
            .max(by: { $0.priority < $1.priority }) ?? .sleeping
        return InstanceState(mood: worst, totalSessions: sessions.count)
    }
}
