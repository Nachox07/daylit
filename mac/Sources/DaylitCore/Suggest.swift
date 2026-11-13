// Suggest new levels from repeated hand changes. Pure: no IO, so every rule here is unit-tested.
// The app records a Sample for each deliberate correction, keeps them in corrections.json and asks
// Suggest.suggestion for a change to offer in the panel. Same rules on Windows (windows/Suggest.cs).
import Foundation

/// The levels of a monitor, in the order `target` and the config use them: day, blind down, night and the
/// optional lights-on night level (nightLights).
public enum Level: Int, CaseIterable, Codable {
    case day = 0, blindDown = 1, night = 2, nightLights = 3
    /// As the panel says it.
    public var name: String { ["day", "blind down", "night", "lights on"][rawValue] }
    /// The config key: monitors[].day / blindDown / night / nightLights.
    public var key: String { ["day", "blindDown", "night", "nightLights"][rawValue] }
    /// When this level is the one that counts most.
    public var situation: String {
        ["with the blind open", "with the blind partly or fully down", "when the room is dim", "with the lights on"][rawValue]
    }
}

/// One deliberate correction by hand.
public struct Sample: Codable, Equatable {
    public var monitor: String     // the monitor's key (the same key the hold state uses)
    public var chosen: Int         // the level the user set
    public var auto: Int           // the automatic target at that moment
    public var s: Double           // the daylight fraction target used: min(daylightFraction(elev), light)
    public var p: Double           // blind position / 100
    public var elev: Double        // sun elevation, so scoring can rerun target
    public var lights: Bool        // the room lights were on
    public var levels: [Double]    // [day, blindDown, night] in effect then, plus nightLights when the monitor has one
    public var at: Double          // Unix seconds
    public init(monitor: String, chosen: Int, auto: Int, s: Double, p: Double, elev: Double, lights: Bool, levels: [Double], at: Double) {
        self.monitor = monitor; self.chosen = chosen; self.auto = auto; self.s = s; self.p = p
        self.elev = elev; self.lights = lights; self.levels = levels; self.at = at
    }
}

public enum Suggest {
    /// Day or blind down "carries most of the weight" in a sample from this weight (0.55, so a blind exactly 40% open still counts).
    public static let dominant = 0.55
    /// Night or the lights-on level carries most of the weight when its weight is the largest of the four and at
    /// least this much (with the lights on at dusk the two share what daylight leaves, so neither reaches 0.55).
    public static let dimDominant = 0.45
    /// A level is a candidate only with dominant samples on this many local days.
    public static let minDays = 3

    /// How much each level counts in `target` for a sample: [day, blindDown, night], summing to 1.
    public static func weights(s: Double, p: Double) -> [Double] { [s * p, s * (1 - p), 1 - s] }

    /// How much each level counts in `target` for a sample: [day, blindDown, night, nightLights], summing to 1.
    /// With a nightLights level and the lights on, what daylight leaves is split between night (sun high) and
    /// nightLights (sun down): [s·p, s·(1−p), (1−s)·sun, (1−s)·(1−sun)], sun the elevation's own daylight
    /// fraction (no cloud cap). Otherwise [s·p, s·(1−p), 1−s, 0].
    public static func weights(_ x: Sample, nightLights: Bool, tuning: Tuning = Tuning()) -> [Double] {
        let w = weights(s: x.s, p: x.p)
        guard nightLights && x.lights else { return w + [0] }
        let sun = daylightFraction(elevation: x.elev, tuning: tuning)
        return [w[0], w[1], w[2] * sun, w[2] * (1 - sun)]
    }

    /// Whether `level` carries most of the weight in this sample (with the levels the sample was taken with).
    public static func dominates(_ x: Sample, _ level: Level, tuning: Tuning = Tuning()) -> Bool {
        let w = weights(x, nightLights: nightLightsLevel(x.levels) != nil, tuning: tuning), v = w[level.rawValue]
        switch level {
        case .day, .blindDown: return v >= dominant - 1e-9
        case .night, .nightLights:   // a tie for the largest weight counts for neither
            return v >= dimDominant - 1e-9 && w.indices.allSatisfy { $0 == level.rawValue || v > w[$0] + 1e-9 }
        }
    }

    /// The levels the samples can tell apart: dominant samples on at least `minDays` different local days.
    public static func candidates(_ samples: [Sample], tuning: Tuning = Tuning(), dayOf: (Double) -> Int = { localDay($0) }) -> [Level] {
        Level.allCases.filter { l in Set(samples.filter { dominates($0, l, tuning: tuning) }.map { dayOf($0.at) }).count >= minDays }
    }
}

extension Suggest {
    /// Least squares for the candidate levels, the others held at their current values, with a pull of
    /// weight 1 toward the current value (as one extra sample at the current level):
    ///     minimise Σ (chosen − x·L)² + Σ_candidates (L_k − current_k)²
    /// The weights come from `levels` (four with nightLights), not from the levels each sample was taken with.
    /// Returns all the levels, each fitted one clamped to 0–100 (not rounded: see roundToStep).
    public static func fit(_ samples: [Sample], levels: [Double], candidates: [Level], tuning: Tuning = Tuning()) -> [Double] {
        let hasNL = nightLightsLevel(levels) != nil
        // nightLights can only be fitted on a monitor that has one.
        let c = candidates.map(\.rawValue).filter { $0 < 3 || hasNL }, n = c.count
        guard n > 0, (3...4).contains(levels.count) else { return levels }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)
        for x in samples {
            let w = weights(x, nightLights: hasNL, tuning: tuning)
            var y = Double(x.chosen)
            for k in 0..<levels.count where !c.contains(k) { y -= w[k] * levels[k] }
            for i in 0..<n {
                b[i] += w[c[i]] * y
                for j in 0..<n { a[i][j] += w[c[i]] * w[c[j]] }
            }
        }
        for i in 0..<n { a[i][i] += 1; b[i] += levels[c[i]] }   // the pull toward the current value
        let solved = solve(a, b)
        var out = levels
        for i in 0..<n { out[c[i]] = min(max(solved[i], 0), 100) }
        return out
    }

    /// Gaussian elimination with partial pivoting. The pull adds 1 to the diagonal, so the matrix is
    /// positive definite and no pivot is 0.
    static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double] {
        var a = a0, b = b0
        let n = b.count
        for col in 0..<n {
            let piv = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            a.swapAt(col, piv); b.swapAt(col, piv)
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                for k in col..<n { a[r][k] -= f * a[col][k] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }
}

/// The values a level can be stored as. A Home Assistant input_number has its own min, max and step;
/// a local level is a whole number 0–100.
public struct NumberStep: Equatable {
    public var min: Double
    public var max: Double
    public var step: Double
    public init(min: Double, max: Double, step: Double) { self.min = min; self.max = max; self.step = step }
    public static let whole = NumberStep(min: 0, max: 100, step: 1)

    /// From the answer to GET /api/states/<input_number>: its min, max and step attributes. nil when one is missing.
    public static func parse(_ d: Data) -> NumberStep? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = o["attributes"] as? [String: Any],
              let lo = (a["min"] as? NSNumber)?.doubleValue, let hi = (a["max"] as? NSNumber)?.doubleValue,
              let st = (a["step"] as? NSNumber)?.doubleValue, st > 0, hi >= lo else { return nil }
        return NumberStep(min: lo, max: hi, step: st)
    }
}

extension Suggest {
    /// The nearest value `st` accepts, inside both its range and 0–100. Halves round up.
    /// nil when `st` cannot be used: a step that is not positive, min above max, a non-finite number, or a range outside 0–100.
    public static func roundToStep(_ v: Double, _ st: NumberStep) -> Double? {
        guard v.isFinite, st.min.isFinite, st.max.isFinite, st.step.isFinite, st.step > 0, st.min <= st.max,
              st.max >= 0, st.min <= 100 else { return nil }
        let lo = max(st.min, 0), hi = min(st.max, 100)
        let first = ((lo - st.min) / st.step - 1e-9).rounded(.up), last = ((hi - st.min) / st.step + 1e-9).rounded(.down)
        guard last >= first else { return min(max(v, lo), hi) }   // a step coarser than the range: just clamp
        let n = min(max(((v - st.min) / st.step).rounded(), first), last)
        return ((st.min + n * st.step) * 1e6).rounded() / 1e6   // no 61.500000001 from the multiplication
    }
}

/// One level to change: from its current value to the proposed one. `added`: the monitor has no such level
/// yet (only nightLights): Apply adds it at `to`, and `from` is the same value (what the lights give now).
public struct LevelChange: Equatable {
    public var level: Level
    public var from: Double
    public var to: Double
    public var added: Bool
    public init(level: Level, from: Double, to: Double, added: Bool = false) {
        self.level = level; self.from = from; self.to = to; self.added = added
    }
}

/// What the panel offers for one monitor.
public struct Suggestion: Equatable {
    public var monitor: String          // the monitor's key
    public var changes: [LevelChange]   // the main level (the one that moves most) first
    public var amount: Int              // how far the user moves it: mean of chosen − auto where the main level dominates, rounded, no sign
    public var lower: Bool              // the user lowers it (true) or raises it
    public var samples: Int             // the hand changes behind it
    public var days: Int                // on this many local days
    public init(monitor: String, changes: [LevelChange], amount: Int, lower: Bool, samples: Int, days: Int) {
        self.monitor = monitor; self.changes = changes; self.amount = amount; self.lower = lower; self.samples = samples; self.days = days
    }

    public var main: Level { changes[0].level }
    /// "blind down 78 → 62, day 100 → 95"; an added level reads "lights on 80 (new)".
    public var changeText: String {
        changes.map { $0.added ? "\($0.level.name) \(Self.fmt($0.to)) (new)" : "\($0.level.name) \(Self.fmt($0.from)) → \(Self.fmt($0.to))" }
            .joined(separator: ", ")
    }
    /// The panel line: "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62?"
    public func sentence(label: String) -> String {
        "You \(lower ? "lower" : "raise") \(label) by about \(amount) \(main.situation). Set \(changeText)?"
    }
    /// "suggest: Monitor blind down 78 → 62 (12 changes on 4 days)"
    public func logLine(label: String) -> String { "suggest: \(label) \(changeText) (\(samples) changes on \(days) days)" }

    /// Up to two decimals, trailing zeros trimmed: 62.25 → "62.25", 62.5 → "62.5", 62 → "62". Locale-independent.
    public static func fmt(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var t = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), r)
        while t.hasSuffix("0") { t.removeLast() }
        return t
    }
}

extension Suggest {
    /// A proposed level must move at least this much after rounding.
    public static let minMove = 5.0
    /// ...and the proposed levels must lower the mean absolute error by at least this much.
    public static let minGain = 3.0
    /// "Not now" hides a monitor's suggestions this long (seconds).
    public static let notNow: Double = 7 * 86400

    /// The two level lists are the same (an input_number may hold decimals).
    public static func sameLevels(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
    }

    /// The real target (boost, clamp, rounding) for a sample's moment with other levels.
    /// `light: x.s` gives target the same daylight fraction: s is never above daylightFraction(elev).
    public static func rerun(_ x: Sample, levels l: [Double], tuning: Tuning) -> Int {
        target(day: l[0], blindDown: l[1], night: l[2], elev: x.elev, pos: x.p * 100, lights: x.lights, tuning: tuning, light: x.s,
               nightLights: nightLightsLevel(l))
    }

    /// Mean of |target − chosen| over the samples, with `levels`.
    public static func meanAbsError(_ samples: [Sample], levels: [Double], tuning: Tuning = Tuning()) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + abs(rerun($1, levels: levels, tuning: tuning) - $1.chosen) }
        return Double(total) / Double(samples.count)
    }

    /// The change to offer for one monitor, or nil.
    /// - samples: all recorded samples (other monitors' and stale ones are ignored here)
    /// - levels: the monitor's [day, blindDown, night] now, plus nightLights when it has one
    /// - steps: per level [day, blindDown, night, nightLights], what it can be stored as; nil = it comes from Home
    ///   Assistant and is unavailable now. For a monitor without nightLights, steps[3] non-nil means one may be
    ///   added (the room lights come from Home Assistant); three steps = never.
    /// - dismissedUntil: "Not now" was clicked; nothing until this time
    public static func suggestion(monitor: String, samples all: [Sample], levels: [Double], steps: [NumberStep?], now: Double,
                                  dismissedUntil: Double?, tuning: Tuning = Tuning(),
                                  dayOf: (Double) -> Int = { localDay($0) }) -> Suggestion? {
        if let d = dismissedUntil, now < d { return nil }
        guard (3...4).contains(levels.count), (3...4).contains(steps.count) else { return nil }
        let mine = dropOld(all, now: now).filter { $0.monitor == monitor && sameLevels($0.levels, levels) }
        let cand = candidates(mine, tuning: tuning, dayOf: dayOf).filter { $0.rawValue < steps.count && steps[$0.rawValue] != nil }
        guard !cand.isEmpty else { return nil }
        let base = proposal(mine, levels: levels, candidates: cand, steps: steps, tuning: tuning)
        var picked: (levels: [Double], changes: [LevelChange])?
        // Lowering night on a monitor without nightLights would lower its lit evenings too (the boost sits on top of
        // night). Offer the pair instead: add nightLights where the lights put it today (night + the boost) and
        // lower night, refitted and scored with the four-level rule. A lit evening stays where it is.
        if nightLightsLevel(levels) == nil, levels.count == 3, steps.count == 4, let nlStep = steps[3],
           base.changes.contains(where: { $0.level == .night && $0.to < $0.from }),
           let start = roundToStep(levels[2] + tuning.lightsBoost, nlStep) {
            let four = levels + [start]
            var pair = proposal(mine, levels: four, candidates: cand.filter { $0 != .nightLights }, steps: steps, tuning: tuning)
            if pair.changes.contains(where: { $0.level == .night && $0.to < $0.from }) {
                pair.changes.append(LevelChange(level: .nightLights, from: start, to: start, added: true))
                if gain(mine, from: levels, to: pair.levels, tuning: tuning) >= minGain - 1e-9 { picked = pair }
            }
        }
        if picked == nil, !base.changes.isEmpty, gain(mine, from: levels, to: base.levels, tuning: tuning) >= minGain - 1e-9 { picked = base }
        guard let chosen = picked else { return nil }
        let changes = chosen.changes
        var main = changes[0]   // the one that moves most; the first of them on a tie
        for c in changes where abs(c.to - c.from) > abs(main.to - main.from) { main = c }
        let ordered = [main] + changes.filter { $0.level != main.level }
        // The sentence follows the change: only the samples that pull the same way as the proposal count for the amount.
        let lower = main.to < main.from
        let agree = mine.filter { dominates($0, main.level, tuning: tuning) && (lower ? $0.chosen < $0.auto : $0.chosen > $0.auto) }
        guard !agree.isEmpty else { return nil }
        let mean = Double(agree.reduce(0) { $0 + abs($1.chosen - $1.auto) }) / Double(agree.count)
        return Suggestion(monitor: monitor, changes: ordered, amount: Int(mean.rounded()), lower: lower,
                          samples: mine.count, days: Set(mine.map { dayOf($0.at) }).count)
    }

    /// The fitted candidates rounded to their steps, keeping those that move at least `minMove`: the levels
    /// they give (`levels` with those replaced) and the changes, in candidate order.
    static func proposal(_ samples: [Sample], levels: [Double], candidates: [Level], steps: [NumberStep?],
                         tuning: Tuning) -> (levels: [Double], changes: [LevelChange]) {
        let fitted = fit(samples, levels: levels, candidates: candidates, tuning: tuning)
        var proposed = levels
        var changes: [LevelChange] = []
        for l in candidates where l.rawValue < levels.count {
            guard let st = steps[l.rawValue], let v = roundToStep(fitted[l.rawValue], st) else { continue }
            if abs(v - levels[l.rawValue]) >= minMove - 1e-9 {
                proposed[l.rawValue] = v
                changes.append(LevelChange(level: l, from: levels[l.rawValue], to: v))
            }
        }
        return (proposed, changes)
    }

    /// How much the mean absolute error falls from `from` to `to` (each scored with its own rule: three or four levels).
    static func gain(_ samples: [Sample], from: [Double], to: [Double], tuning: Tuning) -> Double {
        meanAbsError(samples, levels: from, tuning: tuning) - meanAbsError(samples, levels: to, tuning: tuning)
    }
}

/// Why a tick's hand change is not a sample (each of these hides what the user really wanted).
public struct SampleContext: Equatable {
    public var follower: Bool      // a linked follower: its level comes from the leader
    public var writeFailed: Bool   // this tick's write to the monitor failed
    public var idle: Bool          // this machine is idle
    public var paused: Bool        // paused on battery
    public var sunFallback: Bool   // the source is Home Assistant but it is down: the sun is standing in
    public init(follower: Bool = false, writeFailed: Bool = false, idle: Bool = false, paused: Bool = false, sunFallback: Bool = false) {
        self.follower = follower; self.writeFailed = writeFailed; self.idle = idle; self.paused = paused; self.sunFallback = sunFallback
    }
}

/// Hand changes waiting to settle, one per monitor. A change becomes a sample after `settle` seconds with
/// no further hand change on that monitor, while its offset is still held.
public struct Recorder: Equatable {
    public static let settle: Double = 300
    public private(set) var pending: [String: Sample] = [:]
    public init() {}

    /// A hand change on `monitor` this tick. `sample` is nil when the tick may not be recorded (see
    /// Suggest.makeSample) or the user put it back to automatic: either way it ends the gesture before it.
    public mutating func handChanged(monitor: String, sample: Sample?) { pending[monitor] = sample }

    /// Every tick, per monitor. Returns the sample that became final now, if any.
    /// - held: the hand-set offset is still set and automatic mode is on (false drops the pending change)
    /// - levels: the monitor's levels now (a change drops it too)
    public mutating func settle(monitor: String, held: Bool, levels: [Double], now: Double) -> Sample? {
        guard let p = pending[monitor] else { return nil }
        if !held || !Suggest.sameLevels(p.levels, levels) { pending[monitor] = nil; return nil }
        guard now - p.at >= Self.settle else { return nil }
        pending[monitor] = nil
        return p
    }

    /// Forget a monitor's pending change (Apply, Automatic switched, back to automatic).
    public mutating func drop(_ monitor: String) { pending[monitor] = nil }
}

extension Suggest {
    /// The room lights' boost decided the target (it lifted the level above the blend).
    public static func boostDecides(levels l: [Double], elev: Double, pos: Double, lights: Bool, tuning t: Tuning, light: Double) -> Bool {
        guard lights, elev < t.lightsBoostSunBelow, l.count == 3 else { return false }
        let s = min(daylightFraction(elevation: elev, tuning: t), light)
        let daytime = l[1] + (l[0] - l[1]) * pos / 100
        return l[2] + t.lightsBoost > l[2] + (daytime - l[2]) * s
    }

    /// The sample for a tick where decide recorded a new hand-set level, or nil when it may not be recorded:
    /// see SampleContext, the lights boost deciding the target, or `chosen` / `auto` at 0 or 100 (the clamp hides the
    /// true wish). A monitor with nightLights records its lit evenings too: the four-level weights explain them. `pos` is the blind position 0–100 (100 without a blind), `light` the cloud cap (1 without a sensor).
    public static func makeSample(monitor: String, chosen: Int, auto: Int, elev: Double, pos: Double, lights: Bool, light: Double,
                                  levels: [Double], tuning: Tuning, now: Double, context: SampleContext) -> Sample? {
        if context.follower || context.writeFailed || context.idle || context.paused || context.sunFallback { return nil }
        guard (3...4).contains(levels.count), levels.allSatisfy(\.isFinite), elev.isFinite, pos.isFinite, light.isFinite,
              (1...99).contains(chosen), (1...99).contains(auto) else { return nil }
        if boostDecides(levels: levels, elev: elev, pos: pos, lights: lights, tuning: tuning, light: light) { return nil }
        return Sample(monitor: monitor, chosen: chosen, auto: auto, s: min(daylightFraction(elevation: elev, tuning: tuning), light),
                      p: min(max(pos, 0), 100) / 100, elev: elev, lights: lights, levels: levels, at: now)
    }

    /// Whether this tick's decide took a new hand-set level (moved by hand): it stamps offsetAt with now.
    /// A level from the Home Assistant "set" helper (`remote`) stamps it too, but is not a hand change.
    public static func isHandChange(before: HoldState, after: HoldState, remote: Int?, now: Double) -> Bool {
        remote == nil && now > 0 && after.offsetAt == now && before.offsetAt != now
    }

    /// The hold state after Apply: the hand-set offset is cleared, or it would be applied again on top of
    /// the new level (target 85, set 70, new level gives 70: the monitor would go to 55).
    public static func afterApply(_ s: HoldState) -> HoldState {
        var r = s
        r.lastSet = nil; r.offset = nil; r.offsetSun = nil; r.offsetAt = nil
        return r
    }
}

/// corrections.json: {"samples": [...]}.
private struct CorrectionsFile: Codable { var samples: [Sample] }

extension Suggest {
    /// Samples older than this are dropped on load and on save (seconds).
    public static let maxAge: Double = 14 * 86400

    /// Without the samples older than `maxAge` or dated more than a day ahead (a corrupt `at`).
    public static func dropOld(_ samples: [Sample], now: Double) -> [Sample] { samples.filter { now - $0.at <= maxAge && $0.at <= now + 86400 } }

    /// Without the samples whose levels differ from their monitor's levels now (`current`, by monitor key):
    /// after Apply, a change in Settings or of a Home Assistant helper, a level starts from fresh evidence.
    /// Monitors not in `current` (unplugged) keep theirs.
    public static func dropStale(_ samples: [Sample], current: [String: [Double]]) -> [Sample] {
        samples.filter { x in current[x.monitor].map { sameLevels($0, x.levels) } ?? true }
    }

    /// The samples in corrections.json; none when it is missing or broken. Entries without three or four levels are skipped.
    public static func decode(_ d: Data?) -> [Sample] {
        guard let d, let f = try? JSONDecoder().decode(CorrectionsFile.self, from: d) else { return [] }
        return f.samples.filter { (3...4).contains($0.levels.count) }
    }

    /// corrections.json's content.
    public static func encode(_ samples: [Sample]) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A sample with a NaN or infinite number cannot be written as JSON: leave that one out, keep the rest.
        let ok = samples.filter { [$0.s, $0.p, $0.elev, $0.at].allSatisfy(\.isFinite) && $0.levels.allSatisfy(\.isFinite) }
        return (try? e.encode(CorrectionsFile(samples: ok))) ?? Data("{\"samples\":[]}".utf8)
    }
}
