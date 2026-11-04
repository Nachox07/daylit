// An optional light sensor from Home Assistant (solar panel power, or an outdoor lux sensor) tells a
// cloudy day from a clear one. The sun's height alone says "bright day" on an overcast morning too.
import Foundation

/// What the sensor reads under a clear sky, learned from its own history: the 90th percentile of the
/// readings in each 2° step of sun elevation, mornings and afternoons apart (panels face one way, so
/// 20° in the morning and 20° in the afternoon read differently). Ten days of history is enough.
public struct LightReference: Equatable {
    public static let step = 2.0
    public static let minSamples = 4
    public var bins: [String: Double]

    public init(bins: [String: Double] = [:]) { self.bins = bins }

    /// From history samples: the sun's elevation and direction at each reading, and the reading.
    public init(samples: [(elev: Double, morning: Bool, value: Double)]) {
        var groups: [String: [Double]] = [:]
        for s in samples where s.elev > 0 && s.value.isFinite && s.value >= 0 {
            groups[Self.key(elev: s.elev, morning: s.morning), default: []].append(s.value)
        }
        bins = groups.filter { $0.value.count >= Self.minSamples }.mapValues { v in
            let sorted = v.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.9).rounded()))]
        }.filter { $0.value > 0 }   // a step that only ever read 0 (the sensor was off) tells nothing
    }

    static func key(elev: Double, morning: Bool) -> String {
        "\(morning ? "am" : "pm")\(Int((elev / step).rounded(.down)))"
    }
    public func clearSky(elev: Double, morning: Bool) -> Double? { bins[Self.key(elev: elev, morning: morning)] }
    /// The largest clear-sky reading in the same half of the day.
    public func largest(morning: Bool) -> Double {
        bins.filter { $0.key.hasPrefix(morning ? "am" : "pm") }.values.max() ?? 0
    }
    public var isEmpty: Bool { bins.isEmpty }
}

/// The unit the sensor reports in, and since when its history is all in that unit. Changing it in Home
/// Assistant (W to kW, lx to klx) leaves older readings 1000 times off, so the reference learns again
/// from that moment instead of mixing the two for the next ten days.
public struct LightUnit: Codable, Equatable {
    public var sensor: String
    public var unit: String     // "" until the sensor has reported one
    public var since: Double    // Unix seconds; 0 = all of its history

    public init(sensor: String, unit: String, since: Double) { self.sensor = sensor; self.unit = unit; self.since = since }

    /// After a tick read `unit` for `sensor`. A missing unit (the sensor briefly unavailable) changes nothing.
    public static func update(_ saved: LightUnit?, sensor: String, unit: String?, now: Double) -> LightUnit {
        let u = unit ?? ""
        guard let s = saved, s.sensor == sensor else { return LightUnit(sensor: sensor, unit: u, since: 0) }
        if u.isEmpty || u == s.unit { return s }
        if s.unit.isEmpty { return LightUnit(sensor: sensor, unit: u, since: s.since) }   // the first unit seen
        return LightUnit(sensor: sensor, unit: u, since: now)
    }
    /// How many days of history to learn from: `days`, or fewer since the unit changed.
    public func historyDays(_ days: Double, now: Double) -> Double { min(days, max(0, (now - since) / 86400)) }
}

/// How clear the sky is now, 0…1, or nil when the reading tells nothing: no reference for this part of
/// the sky, a reference too small to compare with (the sun barely up on the panels), or a reading of
/// exactly 0 while there is a reference, which is a fault (inverter off), not a cloud.
public func lightRatio(value: Double?, elev: Double, morning: Bool, reference r: LightReference) -> Double? {
    guard let v = value, v.isFinite, v > 0, elev > 0, let clear = r.clearSky(elev: elev, morning: morning),
          clear >= r.largest(morning: morning) * 0.05 else { return nil }
    return min(1, v / clear)
}

/// The most daylight can count (0…1) under this sky: 1 when clear (or with no reading), down to `floor`
/// when fully overcast. Brightness uses the smaller of this and the sun's own daylight fraction, so at
/// dawn and dusk, when the sun gives less anyway, nothing changes, and the level only ever rises with the sun.
public func lightCap(ratio: Double?, floor: Double) -> Double {
    guard let r = ratio else { return 1 }
    return floor + (1 - floor) * min(max(r, 0), 1)
}

/// Moves the scale in use toward the newest one, so a passing cloud does not jump the monitors:
/// dimming over about 2 minutes, brightening over about 5. `dt`: seconds since the last step.
public func smoothLight(_ previous: Double?, toward next: Double, dt: Double) -> Double {
    guard let p = previous else { return next }
    let tau = next < p ? 120.0 : 300.0
    return p + (next - p) * (1 - exp(-max(dt, 0) / tau))
}

/// Whether the sun is still climbing at `date` (morning) or going down (afternoon).
public func sunRising(latitude: Double, longitude: Double, at date: Date) -> Bool {
    solarElevation(latitude: latitude, longitude: longitude, at: date.addingTimeInterval(300))
        > solarElevation(latitude: latitude, longitude: longitude, at: date)
}

/// The readings in a Home Assistant history answer (GET /api/history/period, minimal_response), each
/// with the sun's elevation and direction at that moment. Readings that are not numbers are skipped, and
/// with `since` (LightUnit.since) so is everything up to that moment: Home Assistant starts the answer
/// with the state at the start time, which can still be in the old unit.
public func lightSamples(history: Data, latitude: Double, longitude: Double, since: Double = 0) -> [(elev: Double, morning: Bool, value: Double)] {
    guard let series = (try? JSONSerialization.jsonObject(with: history)) as? [[[String: Any]]] else { return [] }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var out: [(elev: Double, morning: Bool, value: Double)] = []
    for row in series.first ?? [] {
        guard let st = row["state"] as? String, let v = Double(st), let ts = row["last_changed"] as? String,
              let d = iso.date(from: ts) ?? plain.date(from: ts), since <= 0 || d.timeIntervalSince1970 > since else { continue }
        let e = solarElevation(latitude: latitude, longitude: longitude, at: d)
        if e <= 0 { continue }
        out.append((e, sunRising(latitude: latitude, longitude: longitude, at: d), v))
    }
    return out
}
