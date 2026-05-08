import AppKit
import Foundation

/// Window position + hidden flag persistence. The pet is now a single
/// global window — call sites pass the global key (`PositionStore.globalKey`)
/// instead of a per-project ID. The keyed API is kept generic in case we
/// want to revert or reintroduce per-project pets.
enum PositionStore {
    private static let prefix = "pet.position."
    private static let hiddenPrefix = "pet.hidden."

    /// The single key the global pet uses for both position and hidden
    /// flag. Call sites should not hardcode the literal.
    static let globalKey = "aopet.global"

    static func save(_ point: NSPoint, for key: String) {
        let dict: [String: Double] = ["x": Double(point.x), "y": Double(point.y)]
        UserDefaults.standard.set(dict, forKey: prefix + key)
    }

    static func load(for key: String) -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: prefix + key),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    static func setHidden(_ hidden: Bool, for key: String) {
        UserDefaults.standard.set(hidden, forKey: hiddenPrefix + key)
    }

    static func isHidden(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: hiddenPrefix + key)
    }

    /// One-shot migration: if no `aopet.global` position exists but at
    /// least one legacy per-project position does, copy the first one
    /// over so users don't lose where they parked the pet. UserDefaults
    /// doesn't preserve write order, so we just take whichever comes
    /// first — close enough for a single-launch nudge.
    static func migrateLegacyToGlobal(defaults: UserDefaults = .standard) {
        if load(for: globalKey) != nil { return }
        let all = defaults.dictionaryRepresentation()
        for (k, v) in all where k.hasPrefix(prefix) && k != prefix + globalKey {
            guard let dict = v as? [String: Any],
                  let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double
            else { continue }
            save(NSPoint(x: x, y: y), for: globalKey)
            return
        }
    }
}
