import Foundation

/// Solar elevation in degrees (same formula as the Windows app; within 0.05° of NOAA's reference values in the tests).
public func solarElevation(latitude: Double, longitude: Double, at date: Date = Date()) -> Double {
    func rad(_ x: Double) -> Double { x * .pi / 180 }
    func deg(_ x: Double) -> Double { x * 180 / .pi }
    func mod(_ a: Double, _ n: Double) -> Double { let r = a.truncatingRemainder(dividingBy: n); return r < 0 ? r + n : r }
    let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
    let g = rad(mod(357.529 + 0.98560028 * d, 360))
    let q = mod(280.459 + 0.98564736 * d, 360)
    let L = rad(q + 1.915 * sin(g) + 0.020 * sin(2 * g))
    let e = rad(23.439 - 0.00000036 * d)
    let ra = deg(atan2(cos(e) * sin(L), cos(L)))
    let dec = asin(sin(e) * sin(L))
    let gmst = mod(18.697374558 + 24.06570982441908 * d, 24)
    let ha = rad(gmst * 15 + longitude - ra)
    return deg(asin(sin(rad(latitude)) * sin(dec) + cos(rad(latitude)) * cos(dec) * cos(ha)))
}

/// How much daylight counts, 0...1: 0 below -3° elevation, 1 from 12°.
public func daylightFraction(elevation: Double, tuning t: Tuning = Tuning()) -> Double {
    min(max((elevation - t.sunNight) / (t.sunDay - t.sunNight), 0), 1)
}

/// A stretch of the day, as fractions of it (0 = the midnight it starts at, 1 = the next one).
public struct DaySpan: Equatable {
    public let from, to: Double
    public init(from: Double, to: Double) { self.from = from; self.to = to }
}

/// When the sun is at or above `line` today (or below it, with `below`), in the order it happens, from
/// a day of evenly spaced samples. Usually one span from rise to set, but near the poles the sun can
/// dip under a line after midnight and come back, so "above" is then the day's two ends.
public func sunSpans(_ s: [(t: Double, e: Double)], line e: Double, below: Bool = false) -> [DaySpan] {
    guard let first = s.first, let last = s.last else { return [] }
    func inside(_ x: Double) -> Bool { below ? x < e : x >= e }
    var spans: [DaySpan] = [], start: Double? = inside(first.e) ? first.t : nil
    for i in s.indices.dropFirst() where inside(s[i - 1].e) != inside(s[i].e) {
        let a = s[i - 1], b = s[i]
        let t = a.t + (b.t - a.t) * (e - a.e) / (b.e - a.e)   // a crossing: a.e and b.e differ
        if let st = start { spans.append(DaySpan(from: st, to: t)); start = nil } else { start = t }
    }
    if let st = start { spans.append(DaySpan(from: st, to: last.t)) }
    return spans
}

/// "06:52 – 21:14", "until 06:52 · from 21:14", "all day" or "not today" for those spans.
public func sunSpanLabel(_ spans: [DaySpan], clock: (Double) -> String) -> String {
    if spans.isEmpty { return "not today" }
    return spans.map { sp in
        let fromStart = sp.from <= 0, toEnd = sp.to >= 1
        return fromStart && toEnd ? "all day" : fromStart ? "until \(clock(sp.to))" : toEnd ? "from \(clock(sp.from))" : "\(clock(sp.from)) – \(clock(sp.to))"
    }.joined(separator: " · ")
}
