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
    public init(url: String? = nil, tokenName: String? = nil, autoSwitch: String? = nil, sun: String? = nil,
                cover: String? = nil, lights: String? = nil) {
        self.url = url; self.tokenName = tokenName; self.autoSwitch = autoSwitch; self.sun = sun; self.cover = cover; self.lights = lights
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
    public var manualHold: Int?
    public var pauseOnBattery: Bool?    // default for the panel switch (true when missing)
    public var ddcTool: String?
    public var homeAssistant: HAConfig?
    public var monitors: [MonitorConfig]?

    public init(source: String? = nil, location: Location? = nil, manualHold: Int? = nil, pauseOnBattery: Bool? = nil,
                ddcTool: String? = nil, homeAssistant: HAConfig? = nil, monitors: [MonitorConfig]? = nil) {
        self.source = source; self.location = location; self.manualHold = manualHold; self.pauseOnBattery = pauseOnBattery
        self.ddcTool = ddcTool; self.homeAssistant = homeAssistant; self.monitors = monitors
    }

    public static let path: URL = {
        if let p = ProcessInfo.processInfo.environment["DAYLIT_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/daylit/config.json")
    }()

    /// A missing file is fine (all defaults). A broken one is reported, and the app still runs with defaults.
    public static func load(from url: URL = path) -> (Config, String?) {
        guard let d = try? Data(contentsOf: url) else { return (Config(), nil) }
        do { return (try JSONDecoder().decode(Config.self, from: d), nil) }
        catch { return (Config(), "config.json is not valid: \(Self.describe(error))") }
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
