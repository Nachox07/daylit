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
        }
    }

    static func key(elev: Double, morning: Bool) -> String {
        "\(morning ? "am" : "pm")\(Int((elev / step).rounded(.down)))"
    }
    public func clearSky(elev: Double, morning: Bool) -> Double? { bins[Self.key(elev: elev, morning: morning)] }
    public var largest: Double { bins.values.max() ?? 0 }
    public var isEmpty: Bool { bins.isEmpty }
}

/// How clear the sky is now, 0…1, or nil when the reading tells nothing: no reference for this part of
/// the sky, a reference too small to compare with (the sun barely up on the panels), or a reading of 0
/// with the sun well up, which is a fault (inverter off), not a cloud.
public func lightRatio(value: Double?, elev: Double, morning: Bool, reference r: LightReference) -> Double? {
    guard let v = value, v.isFinite, v >= 0, elev > 0, let clear = r.clearSky(elev: elev, morning: morning),
          clear > 0, clear >= r.largest * 0.05 else { return nil }
    if v == 0 && clear >= r.largest * 0.2 { return nil }
    return min(1, v / clear)
}

/// What the daylight part of the brightness is multiplied by: 1 under a clear sky (or with no reading),
/// down to `floor` (0…1) under a fully overcast one. Faded in between 3° and 6° of sun elevation, so
/// dawn and dusk keep their usual ramp.
public func lightScale(ratio: Double?, elev: Double, floor: Double) -> Double {
    guard let r = ratio else { return 1 }
    let s = floor + (1 - floor) * min(max(r, 0), 1)
    let w = min(max((elev - 3) / 3, 0), 1)
    return 1 + (s - 1) * w
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
/// with the sun's elevation and direction at that moment. Readings that are not numbers are skipped.
public func lightSamples(history: Data, latitude: Double, longitude: Double) -> [(elev: Double, morning: Bool, value: Double)] {
    guard let series = (try? JSONSerialization.jsonObject(with: history)) as? [[[String: Any]]] else { return [] }
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var out: [(elev: Double, morning: Bool, value: Double)] = []
    for row in series.first ?? [] {
        guard let st = row["state"] as? String, let v = Double(st), let ts = row["last_changed"] as? String,
              let d = iso.date(from: ts) ?? plain.date(from: ts) else { continue }
        let e = solarElevation(latitude: latitude, longitude: longitude, at: d)
        if e <= 0 { continue }
        out.append((e, sunRising(latitude: latitude, longitude: longitude, at: d), v))
    }
    return out
}
