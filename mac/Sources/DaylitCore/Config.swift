// Settings file: ~/.config/daylit/config.json (DAYLIT_CONFIG overrides the path). Every key is
// optional; no file = zero config (detected monitors, sliders and keys, no automatic mode).
import Foundation

public struct HAConfig: Decodable {
    public var url: String?
    public var tokenName: String?       // keychain service holding the long-lived token
    public var autoSwitch: String?      // input_boolean for automatic mode; without it the switch is local
    public var sun: String?             // default sun.sun
    public var cover: String?           // optional blind; its position scales the daytime level
    public var lights: String?          // optional light; on at night = a little brighter
    public var light: String?           // optional outdoor light sensor (solar power W, or lux): a cloudy day dims the monitors
    public init(url: String? = nil, tokenName: String? = nil, autoSwitch: String? = nil, sun: String? = nil,
                cover: String? = nil, lights: String? = nil, light: String? = nil) {
        self.url = url; self.tokenName = tokenName; self.autoSwitch = autoSwitch; self.sun = sun; self.cover = cover; self.lights = lights
        self.light = light
    }
}

public struct MonitorHA: Decodable {
    public var sensor: String?          // sensor this app publishes, e.g. sensor.daylit_left_monitor
    public var day: String?             // input_numbers that override the local levels
    public var blindDown: String?
    public var night: String?
    public var set: String?             // input_number: changing it in HA sets this monitor now, even when the Mac is idle
    public init(sensor: String? = nil, day: String? = nil, blindDown: String? = nil, night: String? = nil, set: String? = nil) {
        self.sensor = sensor; self.day = day; self.blindDown = blindDown; self.night = night; self.set = set
    }
}

public struct MonitorConfig: Decodable {
    public var match: String            // part of the display name (case-insensitive)
    public var label: String?
    public var control: String?         // "native", "ddc" or "auto" (default)
    public var day: Double?             // daytime level, blind open (default 70)
    public var blindDown: Double?       // daytime level, blind closed (default 40)
    public var night: Double?           // night level (default 20)
    public var homeAssistant: MonitorHA?
}

public struct Location: Decodable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public struct Config: Decodable {
    public var source: String?
    public var location: Location?
    public var pauseOnBattery: Bool?    // default for the panel switch (true when missing)
    public var ddcTool: String?
    public var builtIn: Bool?           // macOS: show the built-in screen's slider while the lid is open (default true)
    public var homeAssistant: HAConfig?
    public var monitors: [MonitorConfig]?
    public var tuning: Tuning?          // the numbers behind the rules (Tuning.swift); missing = the defaults
    public var tuned: Tuning { tuning ?? Tuning() }

    public init(source: String? = nil, location: Location? = nil, pauseOnBattery: Bool? = nil,
                ddcTool: String? = nil, homeAssistant: HAConfig? = nil, monitors: [MonitorConfig]? = nil) {
        self.source = source; self.location = location; self.pauseOnBattery = pauseOnBattery
        self.ddcTool = ddcTool; self.homeAssistant = homeAssistant; self.monitors = monitors
    }

    public static let path: URL = {
        if let p = ProcessInfo.processInfo.environment["DAYLIT_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/daylit/config.json")
    }()

    /// The path with the home folder shown as ~, for output a user may paste somewhere.
    public static var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = path.path
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// A missing file is fine (all defaults). A broken one is reported, and the app still runs with defaults.
    /// A file that parses but fails validation keeps only the safe parts (monitors and local settings) and
    /// drops the source settings, so a bad entity id or URL is never sent to Home Assistant.
    public static func load(from url: URL = path) -> (Config, String?) {
        guard let d = try? Data(contentsOf: url) else { return (Config(), nil) }
        let c: Config
        do { c = try JSONDecoder().decode(Config.self, from: ConfigText.relaxed(d)) }
        catch { return (Config(), "config.json is not valid: \(Self.describe(error))") }
        if let err = c.validate() {
            var safe = Config(pauseOnBattery: c.pauseOnBattery, ddcTool: c.ddcTool, monitors: c.monitors)
            safe.builtIn = c.builtIn
            return (safe, err)
        }
        return (c, nil)
    }

    /// Home Assistant entity ids are pasted into a Jinja template and URL paths, so only the plain
    /// `domain.object_id` form is accepted.
    public static func isEntityId(_ s: String) -> Bool {
        // Checked by hand rather than with a regex: ICU's `$` also matches before a trailing newline.
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }
    }

    /// First problem found, or nil.
    public func validate() -> String? {
        if let u = homeAssistant?.url, !u.isEmpty {
            guard let url = URL(string: u), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
                return "config.json: homeAssistant.url is not an http(s) URL"
            }
        }
        if let l = location, !(-90...90).contains(l.latitude) || !(-180...180).contains(l.longitude) {
            return "config.json: location latitude/longitude out of range"
        }
        if let e = tuning?.validate() { return e }
        var ids: [(String, String?)] = []
        if let h = homeAssistant {
            ids += [("homeAssistant.autoSwitch", h.autoSwitch), ("homeAssistant.sun", h.sun),
                    ("homeAssistant.cover", h.cover), ("homeAssistant.lights", h.lights), ("homeAssistant.light", h.light)]
            // Its clear-sky reference comes from history, which needs the sun's position at each reading.
            if let l = h.light, !l.isEmpty, location == nil { return "config.json: homeAssistant.light needs a location" }
        }
        for m in monitors ?? [] {
            guard let h = m.homeAssistant else { continue }
            let at = "monitor \"\(m.match)\" homeAssistant."
            ids += [(at + "sensor", h.sensor), (at + "day", h.day), (at + "blindDown", h.blindDown),
                    (at + "night", h.night), (at + "set", h.set)]
        }
        for (key, v) in ids { if let v, !Self.isEntityId(v) { return "config.json: \(key) is not an entity id like light.office" } }
        return nil
    }

    /// True when the token would travel unencrypted beyond the local network: http:// to a host that
    /// is not a private IP, a *.local name or a single-label name.
    public static func isCleartextToNonLocal(_ s: String) -> Bool {
        guard let u = URL(string: s), u.scheme?.lowercased() == "http", let host = u.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") { return false }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Only real IP literals count as addresses: "10.1.2.3.example.com" is a name, not 10.1.2.3.
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }   // network byte order
            let local = b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168)
                || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 169 && b[1] == 254)
            return !local
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, h, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
            let uniqueLocal = b[0] & 0xFE == 0xFC                  // fc00::/7
            let linkLocal = b[0] == 0xFE && b[1] & 0xC0 == 0x80   // fe80::/10
            return !(loopback || uniqueLocal || linkLocal)
        }
        return true
    }
    static func describe(_ e: Error) -> String {
        switch e as? DecodingError {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            let at = c.codingPath.map(\.stringValue).joined(separator: ".")
            return (at.isEmpty ? "" : at + ": ") + c.debugDescription
        default: return e.localizedDescription
        }
    }
}

public enum Source { case off, sun, homeAssistant }

extension Config {
    /// The source to use, plus a problem to show when the config asks for something it cannot do.
    public func resolvedSource() -> (Source, String?) {
        let hasHA = !(homeAssistant?.url ?? "").isEmpty
        let fallback: Source = location != nil ? .sun : .off
        switch source {
        case nil: return (hasHA ? .homeAssistant : fallback, nil)
        case "off": return (.off, nil)
        case "sun": return location != nil ? (.sun, nil) : (.off, "Sun mode needs a location (latitude, longitude)")
        case "homeAssistant": return hasHA ? (.homeAssistant, nil) : (fallback, "Home Assistant mode needs homeAssistant.url")
        case let s?: return (hasHA ? .homeAssistant : fallback, "Unknown source \"\(s)\" (use off, sun or homeAssistant)")
        }
    }
}
