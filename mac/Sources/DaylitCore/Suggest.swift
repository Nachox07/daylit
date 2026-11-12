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
