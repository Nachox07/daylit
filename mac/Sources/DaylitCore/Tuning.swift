// The numbers behind the rules, from config.json's optional "tuning" block. Every key is optional;
// a missing one keeps the value Daylit has always used. Same keys and defaults on Windows.
import Foundation

public struct Tuning: Equatable, Decodable {
    public struct Brightness: Equatable, Decodable {
        public var sunNight: Double?            // sun elevation (°) at or below which the night level applies
        public var sunDay: Double?              // elevation from which the full daytime level applies
        public var lightsBoost: Double?         // room lights on at dusk: at least night + this many points
        public var lightsBoostSunBelow: Double? // ...while the sun is below this elevation
        public init() {}
    }
    public struct Theme: Equatable, Decodable {
        public var lightSunAbove: Double?       // light mode once the sun is above this (°)...
        public var darkSunBelow: Double?        // ...dark again below this; in between the last answer stays
        public var lightBlindAbove: Double?     // with a blind: light mode needs it at least this open (%)
        public var darkBlindBelow: Double?      // ...and it turns dark at or below this
        public var whiteLightsAbove: Double?    // lights at least this bright (%) and white count as daylight
        public var whiteLightsBelow: Double?    // ...and stop counting below this
        public var whiteSaturationMax: Double?  // "white": colour saturation at most this (0 white … 100 deep colour)
        public var warmSaturationMin: Double?   // "warm": above this
        public var room: Bool?                  // use the blind and lights (Home Assistant); false = the sun only
        public init() {}
    }
    public struct Timing: Equatable, Decodable {
        public var pollSeconds: Double?
        public var batteryPollSeconds: Double?
        public var idleSeconds: Double?         // no input for this long = someone else may be using the monitors
        public var haFallbackSeconds: Double?   // Home Assistant down this long: the sun takes over
        public var manualKeepHours: Double?     // a hand-set level survives a restart this long
        public init() {}
    }
    public var brightness: Brightness?
    public var theme: Theme?
    public var timing: Timing?
    public init(brightness: Brightness? = nil, theme: Theme? = nil, timing: Timing? = nil) {
        self.brightness = brightness; self.theme = theme; self.timing = timing
    }

    public var sunNight: Double { brightness?.sunNight ?? -3 }
    public var sunDay: Double { brightness?.sunDay ?? 12 }
    public var lightsBoost: Double { brightness?.lightsBoost ?? 5 }
    public var lightsBoostSunBelow: Double { brightness?.lightsBoostSunBelow ?? 1.5 }
    public var lightSunAbove: Double { theme?.lightSunAbove ?? 4 }
    public var darkSunBelow: Double { theme?.darkSunBelow ?? 1 }
    public var lightBlindAbove: Double { theme?.lightBlindAbove ?? 55 }
    public var darkBlindBelow: Double { theme?.darkBlindBelow ?? 35 }
    public var whiteLightsAbove: Double { theme?.whiteLightsAbove ?? 78.4 }
    public var whiteLightsBelow: Double { theme?.whiteLightsBelow ?? 66.6 }
    public var whiteSaturationMax: Double { theme?.whiteSaturationMax ?? 35 }
    public var warmSaturationMin: Double { theme?.warmSaturationMin ?? 45 }
    public var room: Bool { theme?.room ?? true }
    public var pollSeconds: Double { timing?.pollSeconds ?? 30 }
    public var batteryPollSeconds: Double { timing?.batteryPollSeconds ?? 120 }
    public var idleSeconds: Double { timing?.idleSeconds ?? 300 }
    public var haFallbackSeconds: Double { timing?.haFallbackSeconds ?? 60 }
    public var manualKeepHours: Double { timing?.manualKeepHours ?? 12 }

    /// First impossible value, or nil. Messages name the key, like the rest of the config checks.
    public func validate() -> String? {
        func range(_ v: Double, _ lo: Double, _ hi: Double, _ key: String) -> String? {
            (lo...hi).contains(v) ? nil : "config.json: tuning.\(key) must be \(fmt(lo))–\(fmt(hi))"
        }
        let checks: [String?] = [
            range(sunNight, -18, 30, "brightness.sunNight"), range(sunDay, -18, 60, "brightness.sunDay"),
            sunDay > sunNight ? nil : "config.json: tuning.brightness.sunDay must be above sunNight",
            range(lightsBoost, 0, 100, "brightness.lightsBoost"), range(lightsBoostSunBelow, -18, 60, "brightness.lightsBoostSunBelow"),
            range(lightSunAbove, -18, 60, "theme.lightSunAbove"), range(darkSunBelow, -18, 60, "theme.darkSunBelow"),
            lightSunAbove >= darkSunBelow ? nil : "config.json: tuning.theme.lightSunAbove must not be below darkSunBelow",
            range(lightBlindAbove, 0, 100, "theme.lightBlindAbove"), range(darkBlindBelow, 0, 100, "theme.darkBlindBelow"),
            lightBlindAbove >= darkBlindBelow ? nil : "config.json: tuning.theme.lightBlindAbove must not be below darkBlindBelow",
            range(whiteLightsAbove, 0, 100, "theme.whiteLightsAbove"), range(whiteLightsBelow, 0, 100, "theme.whiteLightsBelow"),
            whiteLightsAbove >= whiteLightsBelow ? nil : "config.json: tuning.theme.whiteLightsAbove must not be below whiteLightsBelow",
            range(whiteSaturationMax, 0, 100, "theme.whiteSaturationMax"), range(warmSaturationMin, 0, 100, "theme.warmSaturationMin"),
            warmSaturationMin >= whiteSaturationMax ? nil : "config.json: tuning.theme.warmSaturationMin must not be below whiteSaturationMax",
            range(pollSeconds, 5, 3600, "timing.pollSeconds"), range(batteryPollSeconds, 5, 3600, "timing.batteryPollSeconds"),
            range(idleSeconds, 30, 86400, "timing.idleSeconds"), range(haFallbackSeconds, 0, 3600, "timing.haFallbackSeconds"),
            range(manualKeepHours, 0, 168, "timing.manualKeepHours"),
        ]
        return checks.compactMap { $0 }.first
    }

    func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}

/// One number the settings window shows: where it lives in "tuning", its label, unit and default.
public struct TuningField: Identifiable, Equatable {
    public let group: String, key: String, label: String, unit: String, defaultValue: Double
    public var id: String { group + "." + key }
}

extension Tuning {
    public static let appearanceFields: [TuningField] = [
        .init(group: "theme", key: "lightSunAbove", label: "Light once the sun is above", unit: "°", defaultValue: 4),
        .init(group: "theme", key: "darkSunBelow", label: "Dark again below", unit: "°", defaultValue: 1),
        .init(group: "theme", key: "lightBlindAbove", label: "Light needs the blind open at least", unit: "%", defaultValue: 55),
        .init(group: "theme", key: "darkBlindBelow", label: "Dark at or below", unit: "%", defaultValue: 35),
        .init(group: "theme", key: "whiteLightsAbove", label: "White lights count as daylight from", unit: "%", defaultValue: 78.4),
        .init(group: "theme", key: "whiteLightsBelow", label: "…and stop counting below", unit: "%", defaultValue: 66.6),
        .init(group: "theme", key: "whiteSaturationMax", label: "White: colour saturation up to", unit: "", defaultValue: 35),
        .init(group: "theme", key: "warmSaturationMin", label: "Warm: colour saturation above", unit: "", defaultValue: 45),
    ]
    public static let tuningFields: [TuningField] = [
        .init(group: "brightness", key: "sunNight", label: "Night level at or below", unit: "°", defaultValue: -3),
        .init(group: "brightness", key: "sunDay", label: "Full day level from", unit: "°", defaultValue: 12),
        .init(group: "brightness", key: "lightsBoost", label: "Room lights at dusk add", unit: "points", defaultValue: 5),
        .init(group: "brightness", key: "lightsBoostSunBelow", label: "…while the sun is below", unit: "°", defaultValue: 1.5),
        .init(group: "timing", key: "pollSeconds", label: "Check every", unit: "s", defaultValue: 30),
        .init(group: "timing", key: "batteryPollSeconds", label: "Check on battery every", unit: "s", defaultValue: 120),
        .init(group: "timing", key: "idleSeconds", label: "Idle (another computer may be in use) after", unit: "s", defaultValue: 300),
        .init(group: "timing", key: "haFallbackSeconds", label: "Sun takes over when Home Assistant is down for", unit: "s", defaultValue: 60),
        .init(group: "timing", key: "manualKeepHours", label: "Keep hand-set levels after a restart for", unit: "h", defaultValue: 12),
    ]
    public static var allFields: [TuningField] { appearanceFields + tuningFields }

    /// The values set in the file, keyed "group.key" (missing keys use the defaults).
    public var setValues: [String: Double] {
        let b = brightness, t = theme, m = timing
        let pairs: [(String, Double?)] = [
            ("brightness.sunNight", b?.sunNight), ("brightness.sunDay", b?.sunDay), ("brightness.lightsBoost", b?.lightsBoost),
            ("brightness.lightsBoostSunBelow", b?.lightsBoostSunBelow),
            ("theme.lightSunAbove", t?.lightSunAbove), ("theme.darkSunBelow", t?.darkSunBelow), ("theme.lightBlindAbove", t?.lightBlindAbove),
            ("theme.darkBlindBelow", t?.darkBlindBelow), ("theme.whiteLightsAbove", t?.whiteLightsAbove), ("theme.whiteLightsBelow", t?.whiteLightsBelow),
            ("theme.whiteSaturationMax", t?.whiteSaturationMax), ("theme.warmSaturationMin", t?.warmSaturationMin),
            ("timing.pollSeconds", m?.pollSeconds), ("timing.batteryPollSeconds", m?.batteryPollSeconds), ("timing.idleSeconds", m?.idleSeconds),
            ("timing.haFallbackSeconds", m?.haFallbackSeconds), ("timing.manualKeepHours", m?.manualKeepHours),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { k, v in v.map { (k, $0) } })
    }
}
