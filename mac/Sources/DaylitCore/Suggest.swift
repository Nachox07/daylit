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
