// What a config reload keeps of what Home Assistant last gave: the "set" helper already acted on, the
// last blind position, room lights and level row (used while Home Assistant is down). Each belongs to one
// Home Assistant (its address) and one entity; after either changes it is another helper's past. A kept
// "set" value would make the new helper's current value look like a command and move the monitor.
// windows/Rules.cs (HaCacheRule) is the twin; tests/parity/ha-cache.json holds the shared cases.
import Foundation

public enum HACacheRule {
    /// The address as compared here: trimmed, lower case, without trailing slashes; nil when empty.
    public static func address(_ url: String?) -> String? {
        guard var s = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// An entity id as compared here: trimmed; nil when empty.
    static func entity(_ e: String?) -> String? {
        guard let s = e?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Whether a value cached for `oldEntity` at `oldURL` must go now that the config says `newEntity` at `newURL`.
    public static func stale(oldURL: String?, newURL: String?, oldEntity: String?, newEntity: String?) -> Bool {
        address(oldURL) != address(newURL) || entity(oldEntity) != entity(newEntity)
    }

    /// A monitor's level helpers as one key for `stale`: [day, blindDown, night, nightLights]; nil when it has none.
    public static func levelsKey(day: String?, blindDown: String?, night: String?, nightLights: String?) -> String? {
        let parts = [day, blindDown, night, nightLights].map { entity($0) ?? "" }
        return parts.allSatisfy(\.isEmpty) ? nil : parts.joined(separator: "|")
    }
}
