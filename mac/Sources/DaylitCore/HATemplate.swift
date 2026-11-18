// The one Home Assistant template each tick sends to POST /api/template, and its answer.
import Foundation

public struct HAState: Decodable {
    public let elev: Double?                // nil when the sun entity does not exist in Home Assistant
    public let pos: Double                  // the blind's position; -1 when Home Assistant has none (blind unavailable)
    public let lights: Bool
    public let auto: Bool?                  // nil when there is no autoSwitch
    public let bri: Double                  // room light brightness 0-255 (0 = unknown)
    public let sat: Double                  // its hs colour saturation (0 = white, ~60+ = warm)
    public let light: Double?               // the light sensor's reading; -1 / missing = none or not a number
    public let lightAge: Double?            // seconds since it last reported
    public let lightUnit: String?           // its unit_of_measurement (W, kW, lx…); nil when unknown
    /// Per display UUID: [day, blindDown, night, nightLights, set, setChanged]; -1 = use the local value / no set helper;
    /// setChanged is the set helper's last_changed (Unix seconds).
    public let m: [String: [Double]]

    enum CodingKeys: String, CodingKey { case elev, pos, lights, auto, bri, sat, light, lightAge, lightUnit, m }

    /// Every number is kept to the range it can really have (HABounds): an absurd answer must not crash a
    /// conversion to Int or push a formula past what it was written for.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        elev = try c.decodeIfPresent(Double.self, forKey: .elev).map(HABounds.elevation)
        pos = HABounds.position(try c.decode(Double.self, forKey: .pos))
        lights = try c.decode(Bool.self, forKey: .lights)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto)
        bri = HABounds.brightness(try c.decode(Double.self, forKey: .bri))
        sat = HABounds.saturation(try c.decode(Double.self, forKey: .sat))
        light = try c.decodeIfPresent(Double.self, forKey: .light).map(HABounds.reading)
        lightAge = try c.decodeIfPresent(Double.self, forKey: .lightAge).map(HABounds.age)
        lightUnit = try c.decodeIfPresent(String.self, forKey: .lightUnit)
        m = try c.decode([String: [Double]].self, forKey: .m).mapValues(HABounds.row)
    }

    /// The configured entities Home Assistant does not have, as far as this answer shows: the autoSwitch
    /// (its `auto` came back null) and the sun entity (its `elev` came back null).
    public func missingEntities(_ ha: HAConfig) -> [String] {
        var r: [String] = []
        if let a = ha.autoSwitch, !a.isEmpty, auto == nil { r.append(a) }
        if elev == nil { r.append(ha.sun.flatMap { $0.isEmpty ? nil : $0 } ?? "sun.sun") }
        return r
    }

    /// The problem line for those entities, or nil when none is missing.
    public static func noValueNote(_ ids: [String]) -> String? {
        ids.isEmpty ? nil : "Home Assistant gives no value for " + ids.joined(separator: ", ") + " (missing or unavailable)"
    }

    /// The problem line: a config problem first (the user fixes the file), else the missing entities.
    public static func problemLine(config: String?, missing: [String]) -> String? { config ?? noValueNote(missing) }

    /// nil when the answer is not what the template produces (e.g. a wrong entity id broke the JSON).
    public static func parse(_ d: Data) -> HAState? {
        guard let s = try? JSONDecoder().decode(HAState.self, from: d), s.m.values.allSatisfy({ $0.count == 6 }) else { return nil }
        return s
    }
}

public enum HATemplate {
    /// One template call returns everything a tick needs. Monitors: display UUID and its HA entities.
    public static func build(_ ha0: HAConfig, _ mons0: [(uuid: String, ha: MonitorHA?)]) -> String {
        // Config.validate() already rejects bad ids; this second filter keeps any that slip through out of the Jinja.
        func ok(_ e: String?) -> String? { e.flatMap { Config.isEntityId($0) ? $0 : nil } }
        let ha = HAConfig(url: ha0.url, tokenName: ha0.tokenName, autoSwitch: ok(ha0.autoSwitch), sun: ok(ha0.sun),
                          cover: ok(ha0.cover), lights: ok(ha0.lights), light: ok(ha0.light))
        let mons = mons0.map { m in (uuid: m.uuid, ha: m.ha.map { MonitorHA(sensor: ok($0.sensor), day: ok($0.day), blindDown: ok($0.blindDown),
                                                                              night: ok($0.night), set: ok($0.set), nightLights: ok($0.nightLights)) }) }
        let pos = ha.cover.map { "state_attr('\($0)','current_position') | float(-1)" } ?? "100"
        let lights = ha.lights.map { "is_state('\($0)','on') | tojson" } ?? "false | tojson"   // bare false renders as Python False
        // A missing or unavailable entity renders null, not false: a typo or an outage must not look like "Automatic is off". states['…'] is None when missing.
        let auto = ha.autoSwitch.map { "{{ is_state('\($0)','on') | tojson if states['\($0)'] and states['\($0)'].state not in ['unavailable', 'unknown'] else 'null' }}" } ?? "null"   // null outside {{ }}: Jinja has no null
        let sunId = ha.sun ?? "sun.sun"
        let elev = "{{ state_attr('\(sunId)','elevation') | float if state_attr('\(sunId)','elevation') is number else 'null' }}"   // no number: null, so the computed sun is used
        let bri = ha.lights.map { "state_attr('\($0)','brightness') | float(0)" } ?? "0"
        let sat = ha.lights.map { "(state_attr('\($0)','hs_color') or [0, 100])[1] | float(100)" } ?? "100"
        func num(_ e: String?) -> String { e.map { "{{ states('\($0)') | float(-1) }}" } ?? "-1" }
        // states['…'], not states.domain.name: an object id may start with a digit, which the dotted form can't parse.
        let lightUnit = ha.light.map { "{{ state_attr('\($0)','unit_of_measurement') | tojson }}" } ?? "null"
        let lightAge = ha.light.map { "{{ (now() - states['\($0)'].last_updated).total_seconds() | round(0) if states['\($0)'] else -1 }}" } ?? "-1"
        let m = mons.compactMap { mon -> String? in
            guard let h = mon.ha, h.day != nil || h.blindDown != nil || h.night != nil || h.set != nil || h.nightLights != nil else { return nil }
            // states['…'] is None when the entity is missing, so a typo gives "no set helper", not an error.
            let set = h.set.map { "\(num($0)), {{ as_timestamp(states['\($0)'].last_changed) if states['\($0)'] else 0 }}" } ?? "-1, 0"
            return "\"\(mon.uuid)\": [\(num(h.day)), \(num(h.blindDown)), \(num(h.night)), \(num(h.nightLights)), \(set)]"
        }.joined(separator: ", ")
        return """
        {"elev": \(elev),
         "pos": {{ \(pos) }},
         "lights": {{ \(lights) }},
         "auto": \(auto),
         "bri": {{ \(bri) }},
         "sat": {{ \(sat) }},
         "light": \(num(ha.light)),
         "lightAge": \(lightAge),
         "lightUnit": \(lightUnit),
         "m": {\(m)}}
        """
    }
}

/// The ranges Home Assistant's numbers can really have. Anything outside is clamped to the nearest end, or
/// treated as "no value" (-1) where a huge number cannot be a real reading. The same rules as HaBounds on Windows.
public enum HABounds {
    /// The latest Unix time a set helper's last_changed is taken as (about the year 5100).
    public static let maxTimestamp = 1e11
    /// A light sensor reading above this is no real sensor (lux in full sun is ~120 000).
    static let maxReading = 1e9

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isNaN ? lo : min(max(v, lo), hi) }

    /// The sun's elevation in degrees.
    public static func elevation(_ v: Double) -> Double { v.isNaN ? -10 : clamp(v, -90, 90) }
    /// The blind's position 0–100; below 0 means it has none (-1).
    public static func position(_ v: Double) -> Double { v.isNaN || v < 0 ? -1 : min(v, 100) }
    /// Light brightness 0–255.
    public static func brightness(_ v: Double) -> Double { clamp(v, 0, 255) }
    /// hs_color saturation 0–100.
    public static func saturation(_ v: Double) -> Double { clamp(v, 0, 100) }
    /// A light sensor reading; -1 = none.
    public static func reading(_ v: Double) -> Double { v.isNaN || v < 0 || v > maxReading ? -1 : v }
    /// Seconds since the sensor reported; -1 = unknown.
    public static func age(_ v: Double) -> Double { v.isNaN || v < 0 ? -1 : min(v, maxTimestamp) }
    /// A monitor row [day, blindDown, night, nightLights, set, setChanged]: levels 0–100 or -1 (none),
    /// setChanged a Unix time or -1. Other lengths pass through (parse rejects them).
    public static func row(_ r: [Double]) -> [Double] {
        r.enumerated().map { i, v in
            if v.isNaN || v < 0 { return -1 }
            return i == 5 ? min(v, maxTimestamp) : min(v, 100)
        }
    }
}
