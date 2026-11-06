// The brightness chart in Settings → Automatic: today's level hour by hour, two handles that each
// store one sun elevation, and the "How Daylit decides, right now" row. Pure, so it is unit-tested;
// the views on both apps only draw what these return.
import Foundation

/// Where a handle sits on today's chart (fractions of the day, 0 = midnight).
public struct HandlePlace: Equatable {
    /// The crossing the handle is drawn on, and the other crossing of the same elevation (nil when
    /// the sun crosses it only once today, near the poles).
    public let at: Double, partner: Double?
    /// The sun never crosses this elevation today: the handle rests on the day's peak (a line above
    /// it) or trough (a line below it), and dragging it saves nothing until it leaves that point.
    public let parked: Bool
    /// For a parked handle: the sun stays above the line all day (false: below it all day).
    public let sunAbove: Bool
    public init(at: Double, partner: Double?, parked: Bool, sunAbove: Bool = false) {
        self.at = at; self.partner = partner; self.parked = parked; self.sunAbove = sunAbove
    }
}

/// The handle for elevation `e`: on the morning crossing (where the sun comes up through the line)
/// with the evening one as its partner, or parked on the peak or trough when today never crosses it.
/// `morning` false puts it on the evening crossing instead (the end the user is dragging).
public func handlePlace(_ s: [(t: Double, e: Double)], line e: Double, morning: Bool = true) -> HandlePlace {
    var ups: [Double] = [], downs: [Double] = []
    for i in s.indices.dropFirst() {
        let a = s[i - 1], b = s[i]
        guard (a.e < e) != (b.e < e) else { continue }
        let t = a.t + (b.t - a.t) * (e - a.e) / (b.e - a.e)
        if b.e > a.e { ups.append(t) } else { downs.append(t) }
    }
    if let up = ups.first, let down = downs.last {
        return morning ? HandlePlace(at: up, partner: down, parked: false) : HandlePlace(at: down, partner: up, parked: false)
    }
    if let one = ups.first ?? downs.first { return HandlePlace(at: one, partner: nil, parked: false) }
    // No crossing: the peak when the whole day is below the line, the trough when it is all above.
    let allBelow = s.allSatisfy { $0.e < e }
    let pick = allBelow ? s.max { $0.e < $1.e } : s.min { $0.e < $1.e }
    return HandlePlace(at: pick?.t ?? 0.5, partner: nil, parked: true, sunAbove: !allBelow)
}

/// The sun's elevation at a point of today (linear between samples).
public func elevation(_ s: [(t: Double, e: Double)], at t: Double) -> Double {
    guard let first = s.first, let last = s.last else { return 0 }
    if t <= first.t { return first.e }
    if t >= last.t { return last.e }
    let i = s.firstIndex { $0.t >= t }!
    let a = s[i - 1], b = s[i]
    return a.e + (b.e - a.e) * (t - a.t) / (b.t - a.t)
}

/// What dragging a handle to point `t` of today saves: the sun's elevation there in half-degree steps,
/// kept in the range tuning accepts and half a degree clear of the other handle, so the two never
/// cross (`day` true: the full-day line, which stays above the night one). Nil for a parked handle
/// that has not left its resting point: a click on it changes nothing.
public func draggedElevation(_ s: [(t: Double, e: Double)], to t: Double, day: Bool, other: Double,
                             parkedAt: Double? = nil, slop: Double = 0.01) -> Double? {
    if let p = parkedAt, abs(t - p) < slop { return nil }
    var v = (elevation(s, at: t) * 2).rounded() / 2
    v = day ? min(max(v, -18), 60) : min(max(v, -18), 30)
    return day ? max(v, other + 0.5) : min(v, other - 0.5)
}

/// One step of "How Daylit decides, right now", left to right.
public struct DecisionStep: Equatable {
    public let title: String, value: String
    public var final = false
    public init(_ title: String, _ value: String, final: Bool = false) { self.title = title; self.value = value; self.final = final }
}

/// The level right now and how it got there, in the order the rules apply: the blind picks the daytime
/// level, the sun blends it with night, clouds cap the sun's share, room lights at dusk lift it off the
/// night level, and a level set by hand keeps its distance. `level` equals what the tick sets.
public struct Decision: Equatable {
    public let level: Int
    public let steps: [DecisionStep]
}

public func explain(day: Double, blindDown: Double, night: Double, elev: Double, pos: Double?, lights: Bool,
                    tuning t: Tuning = Tuning(), light: Double = 1, offset: Int? = nil, offsetWeight w: Double = 1,
                    linked: Int? = nil, leader: String = "", applying: Bool = true) -> Decision {
    let p = pos ?? 100
    let base = target(day: day, blindDown: blindDown, night: night, elev: elev, pos: p, lights: lights, tuning: t, light: light)
    let daytime = blindDown + (day - blindDown) * p / 100
    let sunShare = daylightFraction(elevation: elev, tuning: t)
    let share = min(sunShare, light)
    let blended = night + (daytime - night) * share
    func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
    func lvl(_ x: Double) -> String { "\(Int(min(max(x, 0), 100).rounded()))" }
    var steps: [DecisionStep] = []
    if pos != nil {
        steps.append(DecisionStep(p >= 100 ? "Blind open" : p <= 0 ? "Blind closed" : "Blind \(Int(p.rounded()))% open", "daytime \(lvl(daytime))"))
    } else {
        steps.append(DecisionStep("Day level", lvl(daytime)))
    }
    let sunTitle = sunShare >= 1 ? "Sun high" : sunShare <= 0 ? "Sun down" : "Sun low"
    steps.append(DecisionStep(sunTitle, sunShare <= 0 ? "night \(lvl(night))" : "\(pct(sunShare)) → \(lvl(night + (daytime - night) * sunShare))"))
    if light < 1 && light < sunShare { steps.append(DecisionStep("Cloudy", "daylight \(pct(light)) → \(lvl(blended))")) }
    let lifted = lights && elev < t.lightsBoostSunBelow && Double(base) > blended.rounded()
    steps.append(DecisionStep("Lights", lifted ? "on → \(base)" : lights ? "on, no effect now" : elev < t.lightsBoostSunBelow ? "off" : "no effect by day"))
    var level = base
    if let v = linked {
        // A linked monitor that follows another lands at the group's level, keeping its link distance.
        steps.append(DecisionStep(leader.isEmpty ? "Linked" : "Linked to \(leader)", "→ \(v)", final: true))
        return Decision(level: v, steps: steps)
    }
    if let o = offset {
        let applied = Int((Double(o) * w).rounded())
        level = min(max(base + applied, 0), 100)
        if applied != 0 { steps.append(DecisionStep("You", "\(applied > 0 ? "+" : "")\(applied) → \(level)", final: true)) }
    }
    if !steps.contains(where: \.final) { steps.append(DecisionStep(applying ? "Now" : "Target", "\(level)", final: true)) }
    return Decision(level: level, steps: steps)
}

/// Today in `timeZone`, from local midnight to the next one: 23 or 25 hours on the days the clocks change.
public func dayBounds(_ now: Date, timeZone: TimeZone) -> (start: Date, length: TimeInterval) {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
    let start = cal.startOfDay(for: now)
    let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
    return (start, end.timeIntervalSince(start))
}

/// The sun's elevation through that day at `steps + 1` even points (every 4 minutes with 360).
public func daySamples(latitude: Double, longitude: Double, start: Date, length: TimeInterval, steps: Int = 360) -> [(t: Double, e: Double)] {
    (0...steps).map { i in
        let f = Double(i) / Double(steps)
        return (f, solarElevation(latitude: latitude, longitude: longitude, at: start.addingTimeInterval(f * length)))
    }
}
