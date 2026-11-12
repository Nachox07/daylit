// Suggest new levels from repeated hand changes. Pure: no IO, so every rule here is unit-tested.
// The app records a Sample for each deliberate correction, keeps them in corrections.json and asks
// Suggest.suggestion for a change to offer in the panel. Same rules on Windows (windows/Suggest.cs).
import Foundation

/// The three levels of a monitor, in the order `target` and the config use them.
public enum Level: Int, CaseIterable, Codable {
    case day = 0, blindDown = 1, night = 2
    /// As the panel says it.
    public var name: String { ["day", "blind down", "night"][rawValue] }
    /// The config key: monitors[].day / blindDown / night.
    public var key: String { ["day", "blindDown", "night"][rawValue] }
    /// When this level is the one that counts most.
    public var situation: String { ["with the blind open", "with the blind partly or fully down", "in the evening"][rawValue] }
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
    public var levels: [Double]    // [day, blindDown, night] in effect then
    public var at: Double          // Unix seconds
    public init(monitor: String, chosen: Int, auto: Int, s: Double, p: Double, elev: Double, lights: Bool, levels: [Double], at: Double) {
        self.monitor = monitor; self.chosen = chosen; self.auto = auto; self.s = s; self.p = p
        self.elev = elev; self.lights = lights; self.levels = levels; self.at = at
    }
}

public enum Suggest {
    /// A level "carries most of the weight" in a sample from this weight (0.55, so a blind exactly 40% open still counts).
    public static let dominant = 0.55
    /// A level is a candidate only with dominant samples on this many local days.
    public static let minDays = 3

    /// How much each level counts in `target` for a sample: [day, blindDown, night], summing to 1.
    public static func weights(s: Double, p: Double) -> [Double] { [s * p, s * (1 - p), 1 - s] }

    /// Whether `level` carries most of the weight in this sample.
    public static func dominates(_ x: Sample, _ level: Level) -> Bool {
        weights(s: x.s, p: x.p)[level.rawValue] >= dominant - 1e-9
    }

    /// The levels the samples can tell apart: dominant samples on at least `minDays` different local days.
    public static func candidates(_ samples: [Sample], dayOf: (Double) -> Int = { localDay($0) }) -> [Level] {
        Level.allCases.filter { l in Set(samples.filter { dominates($0, l) }.map { dayOf($0.at) }).count >= minDays }
    }
}

extension Suggest {
    /// Least squares for the candidate levels, the others held at their current values, with a pull of
    /// weight 1 toward the current value (as one extra sample at the current level):
    ///     minimise Σ (chosen − x·L)² + Σ_candidates (L_k − current_k)²
    /// Returns all three levels, each fitted one clamped to 0–100 (not rounded: see roundToStep).
    public static func fit(_ samples: [Sample], levels: [Double], candidates: [Level]) -> [Double] {
        let c = candidates.map(\.rawValue), n = c.count
        guard n > 0, levels.count == 3 else { return levels }
        var a = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var b = [Double](repeating: 0, count: n)
        for x in samples {
            let w = weights(s: x.s, p: x.p)
            var y = Double(x.chosen)
            for k in 0..<3 where !c.contains(k) { y -= w[k] * levels[k] }
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
    public static func roundToStep(_ v: Double, _ st: NumberStep) -> Double {
        let lo = max(st.min, 0), hi = min(st.max, 100)
        let first = ((lo - st.min) / st.step - 1e-9).rounded(.up), last = ((hi - st.min) / st.step + 1e-9).rounded(.down)
        guard last >= first else { return min(max(v, lo), hi) }   // a step coarser than the range: just clamp
        let n = min(max(((v - st.min) / st.step).rounded(), first), last)
        return ((st.min + n * st.step) * 1e6).rounded() / 1e6   // no 61.500000001 from the multiplication
    }
}

/// One level to change: from its current value to the proposed one.
public struct LevelChange: Equatable {
    public var level: Level
    public var from: Double
    public var to: Double
    public init(level: Level, from: Double, to: Double) { self.level = level; self.from = from; self.to = to }
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
    /// "blind down 78 → 62, day 100 → 95"
    public var changeText: String {
        changes.map { "\($0.level.name) \(Self.fmt($0.from)) → \(Self.fmt($0.to))" }.joined(separator: ", ")
    }
    /// The panel line: "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62?"
    public func sentence(label: String) -> String {
        "You \(lower ? "lower" : "raise") \(label) by about \(amount) \(main.situation). Set \(changeText)?"
    }
    /// "suggest: Monitor blind down 78 → 62 (12 changes on 4 days)"
    public func logLine(label: String) -> String { "suggest: \(label) \(changeText) (\(samples) changes on \(days) days)" }

    /// A whole number without decimals, otherwise one decimal (an input_number with step 0.5).
    public static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
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
        target(day: l[0], blindDown: l[1], night: l[2], elev: x.elev, pos: x.p * 100, lights: x.lights, tuning: tuning, light: x.s)
    }

    /// Mean of |target − chosen| over the samples, with `levels`.
    public static func meanAbsError(_ samples: [Sample], levels: [Double], tuning: Tuning = Tuning()) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + abs(rerun($1, levels: levels, tuning: tuning) - $1.chosen) }
        return Double(total) / Double(samples.count)
    }

    /// The change to offer for one monitor, or nil.
    /// - samples: all recorded samples (other monitors' and stale ones are ignored here)
    /// - levels: the monitor's [day, blindDown, night] now
    /// - steps: per level, what it can be stored as; nil = it comes from Home Assistant and is unavailable now
    /// - dismissedUntil: "Not now" was clicked; nothing until this time
    public static func suggestion(monitor: String, samples all: [Sample], levels: [Double], steps: [NumberStep?], now: Double,
                                  dismissedUntil: Double?, tuning: Tuning = Tuning(),
                                  dayOf: (Double) -> Int = { localDay($0) }) -> Suggestion? {
        if let d = dismissedUntil, now < d { return nil }
        guard levels.count == 3, steps.count == 3 else { return nil }
        let mine = all.filter { $0.monitor == monitor && sameLevels($0.levels, levels) }
        let cand = candidates(mine, dayOf: dayOf).filter { steps[$0.rawValue] != nil }
        guard !cand.isEmpty else { return nil }
        let fitted = fit(mine, levels: levels, candidates: cand)
        var proposed = levels
        var changes: [LevelChange] = []
        for l in cand {
            let v = roundToStep(fitted[l.rawValue], steps[l.rawValue]!)
            if abs(v - levels[l.rawValue]) >= minMove - 1e-9 {
                proposed[l.rawValue] = v
                changes.append(LevelChange(level: l, from: levels[l.rawValue], to: v))
            }
        }
        guard !changes.isEmpty else { return nil }
        let gain = meanAbsError(mine, levels: levels, tuning: tuning) - meanAbsError(mine, levels: proposed, tuning: tuning)
        guard gain >= minGain - 1e-9 else { return nil }
        var main = changes[0]   // the one that moves most; the first of them on a tie
        for c in changes where abs(c.to - c.from) > abs(main.to - main.from) { main = c }
        let ordered = [main] + changes.filter { $0.level != main.level }
        let dom = mine.filter { dominates($0, main.level) }
        let mean = Double(dom.reduce(0) { $0 + $1.chosen - $1.auto }) / Double(max(dom.count, 1))
        return Suggestion(monitor: monitor, changes: ordered, amount: Int(abs(mean).rounded()), lower: mean < 0,
                          samples: mine.count, days: Set(mine.map { dayOf($0.at) }).count)
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
    /// see SampleContext, the lights boost deciding the target, or `chosen` / `auto` at 0 or 100 (the clamp
    /// hides the true wish). `pos` is the blind position 0–100 (100 without a blind), `light` the cloud cap (1 without a sensor).
    public static func makeSample(monitor: String, chosen: Int, auto: Int, elev: Double, pos: Double, lights: Bool, light: Double,
                                  levels: [Double], tuning: Tuning, now: Double, context: SampleContext) -> Sample? {
        if context.follower || context.writeFailed || context.idle || context.paused || context.sunFallback { return nil }
        guard levels.count == 3, (1...99).contains(chosen), (1...99).contains(auto) else { return nil }
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

    /// Without the samples older than `maxAge`.
    public static func dropOld(_ samples: [Sample], now: Double) -> [Sample] { samples.filter { now - $0.at <= maxAge } }

    /// Without the samples whose levels differ from their monitor's levels now (`current`, by monitor key):
    /// after Apply, a change in Settings or of a Home Assistant helper, a level starts from fresh evidence.
    /// Monitors not in `current` (unplugged) keep theirs.
    public static func dropStale(_ samples: [Sample], current: [String: [Double]]) -> [Sample] {
        samples.filter { x in current[x.monitor].map { sameLevels($0, x.levels) } ?? true }
    }

    /// The samples in corrections.json; none when it is missing or broken. Entries without three levels are skipped.
    public static func decode(_ d: Data?) -> [Sample] {
        guard let d, let f = try? JSONDecoder().decode(CorrectionsFile.self, from: d) else { return [] }
        return f.samples.filter { $0.levels.count == 3 }
    }

    /// corrections.json's content.
    public static func encode(_ samples: [Sample]) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(CorrectionsFile(samples: samples))) ?? Data("{\"samples\":[]}".utf8)
    }
}
