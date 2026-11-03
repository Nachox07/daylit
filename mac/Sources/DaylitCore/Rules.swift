// The decisions behind automatic brightness and light/dark mode. No AppKit, so they are unit-tested.
import Foundation

/// Target level: the daytime value slides between "blind closed" and "blind open" with the blind
/// position; the sun then blends it with the night value (0 below -3°, full daytime from 12°).
/// Room lights on at night add a little.
public func target(day: Double, blindDown: Double, night: Double, elev: Double, pos: Double, lights: Bool) -> Int {
    let sun = daylightFraction(elevation: elev)
    let daytime = blindDown + (day - blindDown) * pos / 100
    var v = night + (daytime - night) * sun
    if lights && sun < 0.3 { v = max(v, night + 5) }
    return Int(min(max(v, 0), 100).rounded())
}

/// The three levels in effect: Home Assistant's value where it has one (>= 0), else the local number.
public func effectiveLevels(local: [Double], fromHA: [Double]?) -> [Double] {
    var lv = local
    if let ov = fromHA { for k in 0..<min(3, ov.count, lv.count) where ov[k] >= 0 { lv[k] = ov[k] } }
    return lv
}

/// The part of a Home Assistant row the sun fallback keeps: [day, blindDown, night]. The "set" helper
/// is dropped, so an old remote value is never replayed while Home Assistant is down.
public func fallbackLevels(_ row: [Double]) -> [Double] { Array(row.prefix(3)) }

/// A value of a monitor's Home Assistant "set" helper and when it last changed (Unix seconds).
public struct RemoteSet: Equatable {
    public var value: Double
    public var changed: Double
    public init(value: Double, changed: Double) { self.value = value; self.changed = changed }
    /// From the template's per-monitor row [day, blindDown, night, set, setChanged]; nil without a helper.
    public init?(row: [Double]?) {
        guard let r = row, r.count == 5, r[3] >= 0, r[4] > 0 else { return nil }
        value = r[3]; changed = r[4]
    }
}

/// What automatic mode remembers per monitor between ticks.
public struct HoldState: Equatable {
    public var lastSet: Int?         // level automatic mode last applied (nil: none yet / forget)
    public var lastTarget: Int?      // target at that time
    public var remoteSeen: Double?   // last_changed of the "set" helper already acted on
    public init(lastSet: Int? = nil, lastTarget: Int? = nil, remoteSeen: Double? = nil) {
        self.lastSet = lastSet; self.lastTarget = lastTarget; self.remoteSeen = remoteSeen
    }
}

/// The outcome of one tick for one monitor.
public struct Step: Equatable {
    public var state: HoldState
    public var write: Int?           // level to send to the monitor, if any
    public var remote: Int?          // a "set" from Home Assistant was applied (this value)
    public var skip = false          // idle and nothing from HA: leave this monitor alone (no badge or publish change)
    public var applied: Int          // level the monitor is at after this tick (what gets published)
    public var manual = false        // a hand-set (or HA-set) level is being kept
    public var level: Int?           // new value for the slider
}

/// One automatic decision for one monitor (macOS rules).
///
/// - A change of the HA "set" helper applies once, even when this Mac is idle, then is held like a
///   hand-set level. The value seen on the first look is not a command.
/// - Idle (someone may be using the other machine on these monitors): nothing else happens.
/// - A level set by hand is kept until the target moves by `hold` points.
public func decide(current c0: Int, want: Int, remote: RemoteSet?, state s0: HoldState,
                   here: Bool, auto: Bool, dragging: Bool, hold: Int) -> Step {
    var s = s0, c = c0, step = Step(state: s0, applied: c0)
    var fromRemote = false
    if let r = remote {
        if s.remoteSeen == nil { s.remoteSeen = r.changed }
        else if r.changed > s.remoteSeen! {
            s.remoteSeen = r.changed
            let v = Int(min(max(r.value, 0), 100).rounded())
            if c != v { step.write = v }
            c = v; fromRemote = true
            step.remote = v; step.level = v
            s.lastTarget = want; s.lastSet = v == want ? nil : want   // held as hand-set until the target moves
        }
    }
    if !here && !fromRemote { step.state = s; step.skip = true; return step }

    var applied = c, manual = fromRemote
    if auto && !fromRemote && !dragging {
        let handSet = s.lastSet != nil && c != s.lastSet!
        if handSet && abs(want - (s.lastTarget ?? want)) < hold {
            manual = true
        } else {
            if c != want { step.write = want }
            applied = want; s.lastSet = want; s.lastTarget = want; step.level = want
        }
    }
    step.state = s; step.applied = applied; step.manual = manual
    return step
}

/// Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
/// dark otherwise. Each condition has a gap between its on and off thresholds so it does not flip
/// back and forth; in the gap the previous answer stays.
public struct LookRule: Equatable {
    public var daylight: Bool?
    public var whiteLights: Bool?
    public init() {}

    /// - lightsOn: the room lights are on and come from Home Assistant (bri 0-255, hs saturation 0 white ... ~60+ warm).
    public mutating func wantDark(elev: Double, pos: Double, hasBlind: Bool, lightsOn: Bool, bri: Double, sat: Double) -> Bool {
        if hasBlind {
            daylight = elev > 4 && pos >= 55 ? true : elev < 1 || pos <= 35 ? false : daylight ?? (elev > 3 && pos >= 50)
        } else {
            daylight = elev > 4 ? true : elev < 1 ? false : daylight ?? (elev > 3)
        }
        let lit = lightsOn && bri > 0
        whiteLights = lit && bri >= 200 && sat <= 35 ? true : !lit || bri < 170 || sat > 45 ? false : whiteLights ?? false
        return !(daylight! || whiteLights!)
    }
}

/// "lights 80% white" / "lights 40% warm": the colour matters to how bright the room feels, so show it.
public func lightsNote(lights: Bool, bri: Double, sat: Double) -> String {
    guard lights else { return "" }
    guard bri > 0 else { return " · lights on" }
    let tone = sat <= 35 ? " white" : sat > 45 ? " warm" : ""
    return " · lights \(Int((bri / 2.55).rounded()))%\(tone)"
}

/// Whether a DDC monitor reports its brightness. Some monitors accept DDC writes but never answer
/// reads; they stay usable as "write-only", with the slider as the only record of their level.
public enum ReadState: Equatable {
    case unknown     // no successful read yet since it was detected
    case readable    // has answered a read (a later failure means it is showing another computer)
    case writeOnly   // never answered a read, but accepted a write the user made here
    case silent      // never answered a read and refused a write: not controllable from here

    /// After a read attempt.
    public func afterRead(ok: Bool) -> ReadState {
        ok ? .readable : self
    }
    /// After a write the user made (slider or keys). Only a user action can turn an unreadable monitor
    /// into a write-only one: it proves the monitor is showing this computer, so automatic writes
    /// that follow can't fight another machine on the same monitor.
    public func afterUserWrite(ok: Bool) -> ReadState {
        switch self {
        case .unknown, .silent: return ok ? .writeOnly : .silent
        case .readable, .writeOnly: return self
        }
    }
    /// The level automatic mode should treat as current: the reading, or for a write-only monitor
    /// the slider (what was last sent). nil = leave this monitor alone this tick.
    public func current(reading: Int?, slider: Int) -> Int? {
        if let r = reading { return r }
        return self == .writeOnly ? slider : nil
    }
    /// Whether the slider and keys may act on it.
    public var usable: Bool { self != .silent }
}

/// "Sync monitors": every external monitor keeps the offset it had when sync was switched on, so
/// moving one moves the others by the same amount. Offsets are relative to a shared base level;
/// any monitor in the group can set the base, so the group survives one monitor being unplugged.
public struct SyncOffsets: Equatable, Codable {
    public var offsets: [String: Int]
    public init(offsets: [String: Int] = [:]) { self.offsets = offsets }

    /// Captures the current levels; the first monitor's level is the base (its offset is 0).
    public init(levels: [(key: String, level: Int)]) {
        offsets = [:]
        guard let first = levels.first else { return }
        for l in levels { offsets[l.key] = l.level - first.level }
    }

    /// The base level implied by one monitor being at `level`.
    public func base(key: String, level: Int) -> Int? { offsets[key].map { level - $0 } }

    /// Where a monitor goes for a base level, clamped to 0...100. The stored offset is not changed
    /// by clamping, so the monitors line up again once the base moves back.
    public func level(key: String, base: Int) -> Int? { offsets[key].map { min(max(base + $0, 0), 100) } }

    /// Adds monitors that joined after sync was switched on, at their current offset from the group.
    /// `levels` are the connected monitors' current levels. If none of them is in the group (all the
    /// old ones are unplugged), the group starts again from these levels.
    public mutating func adopt(_ levels: [(key: String, level: Int)]) {
        guard let ref = levels.first(where: { offsets[$0.key] != nil }), let b = base(key: ref.key, level: ref.level) else {
            self = SyncOffsets(levels: levels)
            return
        }
        for l in levels where offsets[l.key] == nil { offsets[l.key] = l.level - b }
    }

    /// One monitor was moved by hand to `level`: the levels for the other monitors in `keys`.
    public func follow(key: String, level: Int, keys: [String]) -> [String: Int] {
        guard let b = base(key: key, level: level) else { return [:] }
        var r: [String: Int] = [:]
        for k in keys where k != key { if let v = self.level(key: k, base: b) { r[k] = v } }
        return r
    }

    /// Automatic mode: the first connected monitor's target drives the group. Returns the target for
    /// each monitor in `keys` (the leader keeps its own target).
    public func targets(leader: String, leaderTarget: Int, keys: [String]) -> [String: Int] {
        guard let b = base(key: leader, level: leaderTarget) else { return [:] }
        var r: [String: Int] = [leader: leaderTarget]
        for k in keys where k != leader { if let v = level(key: k, base: b) { r[k] = v } }
        return r
    }
}

/// Hand-set state kept across restarts, so quitting or rebooting does not jump every monitor back to
/// the automatic target. Saved per monitor (keyed by its display identity) with the time it was saved;
/// an entry older than `maxAge` is forgotten, since the target has moved on by then anyway.
public struct SavedHolds: Equatable, Codable {
    public struct Entry: Equatable, Codable {
        public var lastSet: Int?
        public var lastTarget: Int?
        public var saved: Double     // Unix seconds
        public init(lastSet: Int?, lastTarget: Int?, saved: Double) { self.lastSet = lastSet; self.lastTarget = lastTarget; self.saved = saved }
    }
    public static let maxAge: Double = 12 * 3600
    public var entries: [String: Entry]
    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// Records a monitor's state; one with nothing to remember is removed.
    public mutating func record(key: String, state: HoldState, now: Double) {
        if state.lastSet == nil && state.lastTarget == nil { entries[key] = nil; return }
        entries[key] = Entry(lastSet: state.lastSet, lastTarget: state.lastTarget, saved: now)
    }
    /// The state to start a monitor with after a restart, or nil when there is none or it is too old.
    public func restore(key: String, now: Double) -> HoldState? {
        guard let e = entries[key], now - e.saved <= Self.maxAge, now >= e.saved else { return nil }
        return HoldState(lastSet: e.lastSet, lastTarget: e.lastTarget)
    }
}

/// Home Assistant errors. A connection that fails right after launch, wake or docking (macOS checks the
/// local-network permission, or the network is still switching) usually works a few seconds later, so
/// it is retried quickly and only shown once Home Assistant has been unreachable for a while. A
/// rejected or missing token will not fix itself and shows at once.
public enum HAErrorRule {
    public static let retryDelays: [Double] = [2, 5]
    public static let showAfter: Double = 60
    /// Whether the panel should show the error: `downSince` is when the current outage started.
    public static func shouldShow(transient: Bool, downSince: Double?, now: Double) -> Bool {
        if !transient { return true }
        guard let since = downSince else { return false }
        return now - since >= showAfter
    }
}
