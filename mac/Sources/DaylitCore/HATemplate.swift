// The one Home Assistant template each tick sends to POST /api/template, and its answer.
import Foundation

public struct HAState: Decodable {
    public let elev: Double
    public let pos: Double                  // the blind's position; -1 when Home Assistant has none (blind unavailable)
    public let lights: Bool
    public let auto: Bool?                  // nil when there is no autoSwitch
    public let bri: Double                  // room light brightness 0-255 (0 = unknown)
    public let sat: Double                  // its hs colour saturation (0 = white, ~60+ = warm)
    public let light: Double?               // the light sensor's reading; -1 / missing = none or not a number
    public let lightAge: Double?            // seconds since it last reported
    public let lightUnit: String?           // its unit_of_measurement (W, kW, lx…); nil when unknown
    /// Per display UUID: [day, blindDown, night, set, setChanged]; -1 = use the local value / no set helper;
    /// setChanged is the set helper's last_changed (Unix seconds).
    public let m: [String: [Double]]

    /// nil when the answer is not what the template produces (e.g. a wrong entity id broke the JSON).
    public static func parse(_ d: Data) -> HAState? {
        guard let s = try? JSONDecoder().decode(HAState.self, from: d), s.m.values.allSatisfy({ $0.count == 5 }) else { return nil }
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
                                                                              night: ok($0.night), set: ok($0.set)) }) }
        let pos = ha.cover.map { "state_attr('\($0)','current_position') | float(-1)" } ?? "100"
        let lights = ha.lights.map { "is_state('\($0)','on') | tojson" } ?? "false | tojson"   // bare false renders as Python False
        let auto = ha.autoSwitch.map { "{{ is_state('\($0)','on') | tojson }}" } ?? "null"   // null outside {{ }}: Jinja has no null
        let bri = ha.lights.map { "state_attr('\($0)','brightness') | float(0)" } ?? "0"
        let sat = ha.lights.map { "(state_attr('\($0)','hs_color') or [0, 100])[1] | float(100)" } ?? "100"
        func num(_ e: String?) -> String { e.map { "{{ states('\($0)') | float(-1) }}" } ?? "-1" }
        // states['…'], not states.domain.name: an object id may start with a digit, which the dotted form can't parse.
        let lightUnit = ha.light.map { "{{ state_attr('\($0)','unit_of_measurement') | tojson }}" } ?? "null"
        let lightAge = ha.light.map { "{{ (now() - states['\($0)'].last_updated).total_seconds() | round(0) if states['\($0)'] else -1 }}" } ?? "-1"
        let m = mons.compactMap { mon -> String? in
            guard let h = mon.ha, h.day != nil || h.blindDown != nil || h.night != nil || h.set != nil else { return nil }
            // states['…'] is None when the entity is missing, so a typo gives "no set helper", not an error.
            let set = h.set.map { "\(num($0)), {{ as_timestamp(states['\($0)'].last_changed) if states['\($0)'] else 0 }}" } ?? "-1, 0"
            return "\"\(mon.uuid)\": [\(num(h.day)), \(num(h.blindDown)), \(num(h.night)), \(set)]"
        }.joined(separator: ", ")
        return """
        {"elev": {{ state_attr('\(ha.sun ?? "sun.sun")','elevation') | float(-10) }},
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
