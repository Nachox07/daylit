// Reading config.json the way people write it (comments, trailing commas) and saving the settings
// window's changes into it without losing anything the window does not own.
import Foundation

public enum ConfigText {
    /// True when the file has comments, which saving from the settings window does not keep.
    public static func hasComments(_ d: Data) -> Bool { scan(d).comments }

    /// The JSON with `//` and `/* */` comments and trailing commas removed, so a hand-edited file loads
    /// the same on macOS as on Windows. Text inside strings is left alone.
    public static func relaxed(_ d: Data) -> Data { scan(d).json }

    static func scan(_ d: Data) -> (json: Data, comments: Bool) {
        let s = Array(d)
        var comments = false
        var out: [UInt8] = []; out.reserveCapacity(s.count)
        var i = 0, inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                out.append(c)
                if c == UInt8(ascii: "\\"), i + 1 < s.count { out.append(s[i + 1]); i += 2; continue }
                if c == UInt8(ascii: "\"") { inString = false }
                i += 1; continue
            }
            if c == UInt8(ascii: "\"") { inString = true; out.append(c); i += 1; continue }
            if c == UInt8(ascii: "/"), i + 1 < s.count, s[i + 1] == UInt8(ascii: "/") {
                comments = true
                while i < s.count, s[i] != UInt8(ascii: "\n") { i += 1 }
                continue
            }
            if c == UInt8(ascii: "/"), i + 1 < s.count, s[i + 1] == UInt8(ascii: "*") {
                comments = true
                i += 2
                while i + 1 < s.count, !(s[i] == UInt8(ascii: "*") && s[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i += 2; continue
            }
            if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                // Drop a comma that only has whitespace between it and this closing bracket.
                var j = out.count - 1
                while j >= 0, [0x20, 0x09, 0x0A, 0x0D].contains(out[j]) { j -= 1 }
                if j >= 0, out[j] == UInt8(ascii: ",") { out.remove(at: j) }
            }
            out.append(c); i += 1
        }
        return (Data(out), comments)
    }
}

/// What the settings window owns. Everything else in the file is kept as it is.
public struct SettingsEdit: Equatable {
    public struct Monitor: Equatable {
        public var name: String              // the connected display's name
        public var suggestedMatch: String    // used only when no config entry matches it yet
        public var label: String
        public var day, blindDown, night: Int
        public init(name: String, suggestedMatch: String, label: String, day: Int, blindDown: Int, night: Int) {
            self.name = name; self.suggestedMatch = suggestedMatch; self.label = label
            self.day = day; self.blindDown = blindDown; self.night = night
        }
    }
    public var source: String                // "off", "sun" or "homeAssistant"
    public var latitude: Double?, longitude: Double?
    public var monitors: [Monitor]
    public var haURL, autoSwitch, sun, cover, lights: String
    public init(source: String, latitude: Double? = nil, longitude: Double? = nil, monitors: [Monitor] = [],
                haURL: String = "", autoSwitch: String = "", sun: String = "", cover: String = "", lights: String = "") {
        self.source = source; self.latitude = latitude; self.longitude = longitude; self.monitors = monitors
        self.haURL = haURL; self.autoSwitch = autoSwitch; self.sun = sun; self.cover = cover; self.lights = lights
    }
}

public enum ConfigEditError: Error, Equatable { case notAnObject, invalid(String) }

public enum ConfigPatch {
    /// The file with the edit applied. Unknown keys, unplugged monitors and per-monitor settings the
    /// window does not show (control, Home Assistant helpers) are kept. Comments are not: the file is
    /// written back as plain JSON. Throws when the result would not load.
    public static func apply(_ e: SettingsEdit, to original: Data?) throws -> Data {
        var root: [String: Any] = [:]
        if let d = original, !d.isEmpty {
            guard let o = try JSONSerialization.jsonObject(with: ConfigText.relaxed(d)) as? [String: Any] else {
                throw ConfigEditError.notAnObject
            }
            root = o
        }
        root["source"] = e.source
        if let lat = e.latitude, let lon = e.longitude {
            var loc = root["location"] as? [String: Any] ?? [:]   // keeps any other key in it
            loc["latitude"] = round2(lat); loc["longitude"] = round2(lon)
            root["location"] = loc
        } else {
            root["location"] = nil
        }

        var ha = root["homeAssistant"] as? [String: Any] ?? [:]
        for (k, v) in [("url", e.haURL), ("autoSwitch", e.autoSwitch), ("sun", e.sun), ("cover", e.cover), ("lights", e.lights)] {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            ha[k] = t.isEmpty ? nil : t
        }
        root["homeAssistant"] = ha.isEmpty ? nil : ha

        if let raw = root["monitors"], !(raw is [[String: Any]]) {
            throw ConfigEditError.invalid("monitors must be a list of objects; fix it with Open Config File")
        }
        var list = root["monitors"] as? [[String: Any]] ?? []
        var claimed = Set<Int>()   // an entry matching two connected monitors takes the first one's levels only
        for m in e.monitors {
            let i = list.indices.first { j in
                let entry = list[j]
                guard let match = entry["match"] as? String, !match.isEmpty else { return false }
                return m.name.localizedCaseInsensitiveContains(match.trimmingCharacters(in: .whitespaces))
            }
            if let i { if claimed.contains(i) { continue }; claimed.insert(i) }
            var entry = i.map { list[$0] } ?? ["match": m.suggestedMatch]
            let label = m.label.trimmingCharacters(in: .whitespacesAndNewlines)
            entry["label"] = label.isEmpty || label == m.name ? nil : label
            entry["day"] = clamp(m.day); entry["blindDown"] = clamp(m.blindDown); entry["night"] = clamp(m.night)
            if let i { list[i] = entry } else { list.append(entry) }
        }
        root["monitors"] = list.isEmpty ? nil : list

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let c = try JSONDecoder().decode(Config.self, from: out)
        if let err = c.validate() { throw ConfigEditError.invalid(err) }
        return out
    }

    /// Two decimals, written as typed: a Double would serialize 51.48 as 51.479999999999997.
    static func round2(_ v: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v == 0 ? 0 : v))
    }
    static func clamp(_ v: Int) -> Int { min(100, max(0, v)) }
}
