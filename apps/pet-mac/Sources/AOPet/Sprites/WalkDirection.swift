import Foundation

/// Compass directions the pet can wander in. Eight cases — four
/// cardinals and four diagonals. Used by `WanderController` to pick a
/// movement and by `SpriteSet` to look up the matching walk frames.
enum WalkDirection: String, CaseIterable, Equatable {
    case n, ne, e, se, s, sw, w, nw

    /// Unit-ish vector with a positive `dy` meaning "south" (screen
    /// coordinates: y grows downward in NSScreen.frame.origin terms,
    /// but window origins are bottom-left in AppKit so the controller
    /// flips the sign at the move site). Diagonals are normalized to
    /// avoid sqrt(2)-faster diagonal travel.
    var unitVector: (dx: Double, dy: Double) {
        // 1 / sqrt(2)
        let diag = 0.7071067811865475
        switch self {
        case .n:  return ( 0,    -1)
        case .ne: return ( diag, -diag)
        case .e:  return ( 1,     0)
        case .se: return ( diag,  diag)
        case .s:  return ( 0,     1)
        case .sw: return (-diag,  diag)
        case .w:  return (-1,     0)
        case .nw: return (-diag, -diag)
        }
    }
}
