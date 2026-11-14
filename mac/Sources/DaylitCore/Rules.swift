// The decisions behind automatic brightness and light/dark mode. No AppKit, so they are unit-tested.
import Foundation

/// Target level: the daytime value slides between "blind closed" and "blind open" with the blind
/// position; the sun then blends it with the night value (0 below -3°, full daytime from 12°).
/// Room lights on at night add a little.
/// With nightLights (optional), the room lights move the night end of the blend instead of adding the boost.
/// `light` (0…1, see lightCap) is the most daylight can count under a cloudy sky; 1 without a sensor.
/// The blind position to use: a blind that drops off Home Assistant for a moment keeps its last
/// known position instead of counting as fully open; with none seen yet it counts as open.
public func blindPosition(reported: Double, last: Double?) -> Double {
    reported >= 0 ? min(reported, 100) : last ?? 100
}

/// A brightness level as a finite 0–100: out of range is clamped, infinity counts as the nearest end,
/// and NaN as 0 (a level that is not a number must never reach the formula).
public func clampLevel(_ v: Double) -> Double {
    v.isNaN ? 0 : min(max(v, 0), 100)
}

public func target(day day0: Double, blindDown blindDown0: Double, night night0: Double, elev: Double, pos pos0: Double, lights: Bool,
                   tuning t: Tuning = Tuning(), light: Double = 1, nightLights nightLights0: Double? = nil) -> Int {
    let day = clampLevel(day0), blindDown = clampLevel(blindDown0), night = clampLevel(night0)
    let nightLights = nightLights0.map(clampLevel)
    let pos = clampLevel(pos0)
    let sunUp = daylightFraction(elevation: elev, tuning: t)
    let sun = min(sunUp, light)
    let daytime = blindDown + (day - blindDown) * pos / 100
    var v: Double
    if let nl = nightLights {
        // A monitor with its own lit-evening level: weak daylight blends toward night with the lights off.
        // With them on it blends toward a point that slides from night (sun high) to nightLights (sun down),
        // so the lamps change nothing in daylight and there is no step at dusk. No boost.
        let anchor = lights ? night * sunUp + nl * (1 - sunUp) : night
        v = anchor + (daytime - anchor) * sun
    } else {
        v = night + (daytime - night) * sun
        if lights && elev < t.lightsBoostSunBelow { v = max(v, night + t.lightsBoost) }
    }
    // Last guard: a NaN from elev or light would stop the app at Int(); fall back to the night level.
    guard v.isFinite else { return Int(night.rounded()) }
    return Int(min(max(v, 0), 100).rounded())
}

/// The levels in effect: [day, blindDown, night], plus a fourth, nightLights, when the monitor has one.
/// `local`: [day, blindDown, night], with nightLights as a fourth when the config sets it (below 0: none).
/// `fromHA`: a template row [day, blindDown, night, nightLights, set, setChanged] or what fallbackLevels kept.
/// Home Assistant's value wins where it has one (>= 0), else the local number.
public func effectiveLevels(local: [Double], fromHA: [Double]?) -> [Double] {
    var lv = local.prefix(3).map(clampLevel)
    if let ov = fromHA { for k in 0..<min(3, ov.count, lv.count) where ov[k] >= 0 { lv[k] = clampLevel(ov[k]) } }
    let fromRow = fromHA.flatMap { $0.count > 3 && $0[3] >= 0 ? $0[3] : nil }
    let own = local.count > 3 && local[3] >= 0 ? local[3] : nil
    if let nl = fromRow ?? own { lv.append(clampLevel(nl)) }
    return lv
}

/// The nightLights level in a monitor's levels in effect; nil when it has none.
public func nightLightsLevel(_ levels: [Double]) -> Double? { levels.count > 3 && levels[3] >= 0 ? levels[3] : nil }

/// The room lights for one monitor this tick. Home Assistant's answer while it gives one. In the sun fallback
/// a monitor with a nightLights level keeps the last state seen (`last`; off when none was seen), as the blind
/// keeps its last position, so a lit evening does not drop to night during an outage. Every other monitor
/// counts the lights as off there, as before.
public func roomLights(reported: Bool, fromHA: Bool, last: Bool?, hasNightLights: Bool) -> Bool {
    if fromHA { return reported }
    return hasNightLights ? last ?? false : false
}

/// Automatic mode while Home Assistant does not answer (the sun fallback). With an autoSwitch it keeps the
/// last state Home Assistant gave, so an outage never turns Automatic on or off; without a switch, or before
/// one was ever seen, the local setting decides.
public func automaticFallback(hasSwitch: Bool, lastFromHA: Bool?, local: Bool) -> Bool {
    hasSwitch ? lastFromHA ?? local : local
}

/// Automatic mode on a tick Home Assistant answered. Its switch decides when it gave a value; a switch it did not
/// give one for (a missing entity, `unavailable`) leaves Automatic as it was, the same as during an outage.
public func automaticNow(hasSwitch: Bool, fromHA: Bool?, lastFromHA: Bool?, local: Bool) -> Bool {
    fromHA ?? automaticFallback(hasSwitch: hasSwitch, lastFromHA: lastFromHA, local: local)
}

/// The Automatic state saved from Home Assistant counts only for the autoSwitch it was seen on: a different
/// entity in the config (or an older save with none recorded) starts again from the local setting.
public func storedAutomatic(value: Bool?, entity: String?, configured: String?) -> Bool? {
    guard let configured, !configured.isEmpty, entity == configured else { return nil }
    return value
}

/// The part of a Home Assistant row the sun fallback keeps: [day, blindDown, night, nightLights]. The "set"
/// helper is dropped, so an old remote value is never replayed while Home Assistant is down.
public func fallbackLevels(_ row: [Double]) -> [Double] { Array(row.prefix(4)) }

/// A value of a monitor's Home Assistant "set" helper and when it last changed (Unix seconds).
public struct RemoteSet: Equatable {
    public var value: Double
    public var changed: Double
    public init(value: Double, changed: Double) { self.value = value; self.changed = changed }
    /// From the template's per-monitor row [day, blindDown, night, nightLights, set, setChanged]; nil without a helper.
    public init?(row: [Double]?) {
        guard let r = row, r.count == 6, r[4] >= 0, r[5] > 0 else { return nil }
        value = r[4]; changed = r[5]
    }
}

/// What automatic mode remembers per monitor between ticks.
public struct HoldState: Equatable {
    public var lastSet: Int?         // level automatic mode last applied (nil: none yet / forget)
    public var lastTarget: Int?      // target at that time
    public var remoteSeen: Double?   // last_changed of the "set" helper already acted on
    public var remoteValue: Double?  // its value then: a restart of Home Assistant bumps last_changed alone
    public var offset: Int?          // a hand-set level, as its distance from the target (nil: none)
    public var offsetSun: Double?    // daylight fraction (0…1) when it was set
    public var offsetAt: Double?     // when it was set (Unix seconds)
    public init(lastSet: Int? = nil, lastTarget: Int? = nil, remoteSeen: Double? = nil, offset: Int? = nil, offsetSun: Double? = nil,
                offsetAt: Double? = nil, remoteValue: Double? = nil) {
        self.lastSet = lastSet; self.lastTarget = lastTarget; self.remoteSeen = remoteSeen; self.remoteValue = remoteValue
        self.offset = offset; self.offsetSun = offsetSun; self.offsetAt = offsetAt
    }
}

extension HoldState {
    /// After a tick sent a level to the monitor (`before`: the state that tick started from). A refused
    /// write applied nothing, so forget it: otherwise the next tick reads the old level, takes the gap
    /// for a hand-set change and stops retrying. A Home Assistant "set" it carried stays pending, so
    /// the next tick applies it again too.
    public func afterWrite(ok: Bool, before: HoldState) -> HoldState {
        var s = self
        if !ok { s.lastSet = nil; s.remoteSeen = before.remoteSeen; s.remoteValue = before.remoteValue }
        return s
    }
}

/// The outcome of one tick for one monitor.
public struct Step: Equatable {
    public var state: HoldState
    public var write: Int?           // level to send to the monitor, if any
    public var remote: Int?          // a "set" from Home Assistant was applied (this value)
    public var skip = false          // idle and nothing from HA: leave this monitor alone (no badge or publish change)
    public var applied: Int          // level the monitor is at after this tick (what gets published)
    public var manual = false        // a hand-set (or HA-set) level is being followed
    public var level: Int?           // new value for the slider
}

/// The daylight fraction where a night offset has faded out completely.
public let nightOffsetEdge = 0.3

/// How much of a hand-set offset applies (0…1) for the sun now, or nil once it is over.
/// One set by day fades out as the sun goes down and has no effect at night; it ends with the day
/// (offsetExpired), so tomorrow starts clean. One set at night ends as the sun comes up. Either way the
/// change is gradual, over 0.3 of the daylight fraction (about half an hour around sunrise or sunset).
/// A daytime one never fades faster than that half hour from when it was set (`age`, seconds): one set
/// in the last light would otherwise be gone in minutes.
public func offsetWeight(sun: Double, setAt: Double, age: Double? = nil) -> Double? {
    let edge = nightOffsetEdge, fade = 1800.0
    if setAt > 0 {
        let w = min(1, max(0, sun) / min(edge, setAt))
        guard let a = age, a >= 0, a < fade else { return w }
        return max(w, 1 - a / fade)
    }
    if sun >= edge { return nil }
    return 1 - sun / edge
}

/// Whether the next tick is due: `elapsed` seconds since the last one. A negative `elapsed` means the
/// clock was set back past the last tick, which must not hold ticks off until wall time catches up.
public func tickDue(elapsed: Double, interval: Double) -> Bool { elapsed < 0 || elapsed >= interval }

/// Whether the light sensor's history is due again: `elapsed` seconds since it was last tried. Hourly while
/// there is no reference (or only hours of it), daily otherwise; a clock set back counts as due.
public func lightHistoryDue(elapsed: Double, hasReference: Bool, young: Bool) -> Bool {
    elapsed < 0 || elapsed >= (hasReference && !young ? 86400 : 3600)
}

/// The time to store as "last tried" so the history is due again in an hour. With a reference in use the
/// wait is a day, so the stamp is moved back by the difference; otherwise the wait already is an hour
/// and the stamp is now (moving it back there made the retry fire on every tick).
public func lightRetryStamp(now: Double, hasReference: Bool, young: Bool) -> Double {
    hasReference && !young ? now + 3600 - 86400 : now
}

/// The longest a hand-set offset can live, whatever the sky does (a polar night or day never ends it).
public let offsetMaxAge = 36.0 * 3600
/// A daytime offset that is still older than this when the calendar day changes ends even with the sun up
/// (a computer that slept through the night wakes into a new day).
let dayOffsetCarryOver = 12.0 * 3600

/// A night offset without a location ends after this long (longer than any night but a polar one).
let nightOffsetFallback = 18.0 * 3600
/// How often the sun is sampled between setting an offset and now.
let offsetSampleStep = 600.0

/// An offset that no longer applies, even when no tick ran in between (the computer slept).
/// With a location it is decided from what the sun did between `offsetAt` and `now`, sampled every
/// 10 minutes, not from the current tick: one set at night ends once daylight reached the fade edge
/// (offsetWeight) at any point since, so sleeping through a sunrise cannot keep it, while a polar night
/// does; one set by day ends with the calendar day if the sun set in between, and only a polar day
/// (the sun never went down) carries it over midnight, for at most 12 hours. Without a location
/// (possible with Home Assistant as the source) a night offset ends after 18 hours and a day one with
/// the calendar day. Every offset ends after 36 hours. `dayOf` gives the local calendar day of a Unix
/// time; `sun` is the daylight fraction now.
public func offsetExpired(_ s: HoldState, now: Double, sun: Double, dayOf: (Double) -> Int,
                          place: (latitude: Double, longitude: Double)? = nil, tuning: Tuning = Tuning()) -> Bool {
    guard s.offset != nil, let at = s.offsetAt, now > 0 else { return false }
    let age = now - at
    if age > offsetMaxAge { return true }
    let byDay = (s.offsetSun ?? 0) > 0
    let newDay = dayOf(now) != dayOf(at)
    guard let p = place else { return byDay ? newDay : age > nightOffsetFallback }
    var lowest = sun, highest = sun
    var t = at
    while t < now {
        let f = daylightFraction(elevation: solarElevation(latitude: p.latitude, longitude: p.longitude,
                                                           at: Date(timeIntervalSince1970: t)), tuning: tuning)
        lowest = min(lowest, f); highest = max(highest, f)
        t += offsetSampleStep
    }
    if byDay { return newDay && (lowest <= 0 || age > dayOffsetCarryOver) }
    return highest >= nightOffsetEdge
}

/// Seconds since the hand-set offset was set; nil when unknown.
func offsetAge(_ s: HoldState, _ now: Double) -> Double? {
    guard now > 0, let at = s.offsetAt else { return nil }
    return now - at
}

/// The local calendar day of a Unix time.
public func localDay(_ t: Double, calendar: Calendar = .current) -> Int {
    calendar.ordinality(of: .day, in: .era, for: Date(timeIntervalSince1970: t)) ?? 0
}

/// One automatic decision for one monitor (macOS rules).
///
/// - A change of the HA "set" helper applies once, even when this Mac is idle, then is followed like a
///   hand-set level. The value seen on the first look is not a command, nor is the same value again
///   (a restart of Home Assistant gives the helper a new last_changed).
/// - Idle (someone may be using the other machine on these monitors): nothing else happens.
/// - A level set by hand keeps its distance from the target: set 52 when the target is 76 and the
///   screen follows the target 24 points lower as the blind opens and the sun rises. The distance
///   fades at dusk and ends at night (see offsetWeight); a new hand-set level replaces it.
public func decide(current c0: Int, want: Int, remote: RemoteSet?, state s0: HoldState,
                   here: Bool, auto: Bool, dragging: Bool, sun: Double, touched: Bool = true,
                   now: Double = 0, dayOf: (Double) -> Int = { localDay($0) },
                   place: (latitude: Double, longitude: Double)? = nil, tuning: Tuning = Tuning()) -> Step {
    var s = s0, c = c0, step = Step(state: s0, applied: c0)
    var fromRemote = false
    if let r = remote {
        // A restart of Home Assistant gives the helper a new last_changed with the same value: not a command.
        let same = s.remoteValue.map { $0 == r.value } ?? false
        if s.remoteSeen == nil { s.remoteSeen = r.changed; s.remoteValue = r.value }
        else if r.changed > s.remoteSeen! && same { s.remoteSeen = r.changed }
        else if r.changed > s.remoteSeen! {
            s.remoteSeen = r.changed; s.remoteValue = r.value
            let v = Int(min(max(r.value, 0), 100).rounded())
            if c != v { step.write = v }
            c = v; fromRemote = true
            step.remote = v; step.level = v
            s.lastSet = v; s.lastTarget = want
            s.offset = v == want ? nil : v - want; s.offsetSun = sun; s.offsetAt = now
        }
    }
    if !here && !fromRemote { step.state = s; step.skip = true; return step }
    if offsetExpired(s, now: now, sun: sun, dayOf: dayOf, place: place, tuning: tuning) { s.offset = nil; s.offsetSun = nil; s.offsetAt = nil }

    var applied = c
    if auto && !fromRemote && !dragging {
        if let last = s.lastSet, c != last {
            if touched || abs(c - last) > 1 {   // moved by hand since the last tick
                s.offset = c == want ? nil : c - want; s.offsetSun = sun; s.offsetAt = now
            } else {
                c = last   // a reading 1 off what Daylit wrote, with no hand on it: the monitor rounding
            }
        }
        var level = want
        if let o = s.offset {
            if let w = offsetWeight(sun: sun, setAt: s.offsetSun ?? sun, age: offsetAge(s, now)) {
                level = min(max(want + Int((Double(o) * w).rounded()), 0), 100)
            } else {
                s.offset = nil; s.offsetSun = nil; s.offsetAt = nil
            }
        }
        // A target 1 point away from what the monitor shows waits until it is 2 away, so a target hovering on
        // a rounding edge (99, 100, 99…) does not rewrite the monitor every few minutes. A hand-set level or a
        // "set" from Home Assistant is never held back: they are already on the monitor.
        if abs(level - c) == 1 && s.lastSet == c { level = c }
        if c != level { step.write = level; step.level = level }
        applied = level; s.lastSet = level; s.lastTarget = want
    }
    // The badge shows only while the offset changes something (a daytime one rests at night).
    let w = s.offset == nil ? 0 : offsetWeight(sun: sun, setAt: s.offsetSun ?? sun, age: offsetAge(s, now)) ?? 0
    step.state = s; step.applied = applied; step.manual = s.offset != nil && (fromRemote || (auto && w > 0))
    return step
}

/// Which brightness a tick should trust after it waited (the Home Assistant read, a write to another
/// monitor). `atRead` is the level the model held when the monitor was read, `now` what it holds after
/// the wait. A level that moved in between came from the user's hand (slider, keys); it is newer than
/// the reading, so it wins and the tick decides on it. `held`: the slider is in the user's hand.
public func userLevelWins(atRead: Int?, now: Int?, held: Bool) -> Bool {
    guard now != nil else { return false }
    return held || atRead != now
}

/// The level a tick decides on for one monitor: the model's level when the user set one after the
/// reading (see userLevelWins), else the reading.
public func levelToDecideOn(read: Int, atRead: Int?, model: Int?, held: Bool) -> Int {
    userLevelWins(atRead: atRead, now: model, held: held) ? model ?? read : read
}

/// The slider value after a write of `new`: nil keeps the current one. A refused write changes nothing,
/// and a level the user set while Daylit was writing (or a held slider) is newer than the write.
public func levelAfterWrite(new: Int?, ok: Bool, atStart: Int?, now: Int?, held: Bool) -> Int? {
    guard ok, let new, !userLevelWins(atRead: atStart, now: now, held: held) else { return nil }
    return new
}

/// What a finished write leaves on its monitor.
public struct WriteCommit: Equatable {
    public var state: HoldState
    public var level: Int?
}

/// The result of one write, for the monitor as it is now. Used when the monitor list was rebuilt under
/// the write: the new list's monitor takes the written state, or the next tick reads the new level
/// against the old lastSet and invents an offset. nil when the monitor's control changed in that
/// rebuild (the old level is on another scale). `clearedMeanwhile`: Apply cleared its offset meanwhile.
public func writeCommit(step: Step, before: HoldState, ok: Bool, clearedMeanwhile: Bool, controlChanged: Bool,
                        levelAtStart: Int?, levelNow: Int?, held: Bool) -> WriteCommit? {
    guard !controlChanged else { return nil }
    var st = step.state.afterWrite(ok: ok, before: before)
    if clearedMeanwhile { st = Suggest.afterApply(st) }
    return WriteCommit(state: st, level: levelAfterWrite(new: step.level, ok: ok, atStart: levelAtStart, now: levelNow, held: held))
}

/// Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
/// dark otherwise. Each condition has a gap between its on and off thresholds so it does not flip
/// back and forth; in the gap the previous answer stays.
public struct LookRule: Equatable {
    public var daylight: Bool?
    public var whiteLights: Bool?
    public init() {}

    /// - lightsOn: the room lights are on and come from Home Assistant (bri 0-255, hs saturation 0 white ... ~60+ warm).
    /// - previous: what the OS shows now (dark = true), passed while there is no earlier answer (start,
    ///   config reload, feature switched on). Inside a gap it fills the missing answer so the result
    ///   keeps the OS as it is; outside a gap it is ignored. nil: a point inside each gap decides.
    public mutating func wantDark(elev: Double, pos: Double, hasBlind: Bool, lightsOn: Bool, bri: Double, sat: Double,
                                  tuning t: Tuning = Tuning(), previous: Bool? = nil) -> Bool {
        let hasBlind = hasBlind && t.room, lightsOn = lightsOn && t.room
        // Each condition's answer when the sample is outside its gap; nil inside it.
        let dayNow: Bool? = hasBlind
            ? (elev > t.lightSunAbove && pos >= t.lightBlindAbove ? true : elev < t.darkSunBelow || pos <= t.darkBlindBelow ? false : nil)
            : (elev > t.lightSunAbove ? true : elev < t.darkSunBelow ? false : nil)
        let lit = lightsOn && bri > 0, pct = bri / 2.55
        let whiteNow: Bool? = lit && pct >= t.whiteLightsAbove && sat <= t.whiteSaturationMax ? true
                            : !lit || pct < t.whiteLightsBelow || sat > t.warmSaturationMin ? false : nil
        // In a gap with no earlier answer, take the one that keeps the OS as it is (light: true, dark: false).
        // A condition is left to the default below when the other one already decides the result.
        if let dark = previous {
            let fillDay = dayNow == nil && daylight == nil, fillWhite = whiteNow == nil && whiteLights == nil
            if fillDay && (!dark || fillWhite || (whiteNow ?? whiteLights) == false) { daylight = !dark }
            if fillWhite && (!dark || fillDay || (dayNow ?? daylight) == false) { whiteLights = !dark }
        }
        // Before any answer, a point inside each gap decides (3° and 50% with the defaults).
        let midSun = (t.lightSunAbove + t.darkSunBelow) / 2 + min(0.5, (t.lightSunAbove - t.darkSunBelow) / 4)
        let midBlind = (t.lightBlindAbove + t.darkBlindBelow) / 2 + min(5, (t.lightBlindAbove - t.darkBlindBelow) / 4)
        let day = dayNow ?? daylight ?? (elev > midSun && (!hasBlind || pos >= midBlind))
        let white = whiteNow ?? whiteLights ?? false
        daylight = day; whiteLights = white
        return !(day || white)
    }
}

/// "lights 80% white" / "lights 40% warm": the colour matters to how bright the room feels, so show it.
public func lightsNote(lights: Bool, bri: Double, sat: Double, tuning t: Tuning = Tuning()) -> String {
    guard lights else { return "" }
    guard bri > 0 else { return " · lights on" }
    let tone = sat <= t.whiteSaturationMax ? " white" : sat > t.warmSaturationMin ? " warm" : ""
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
    /// Monitors taken out of the group by hand; they are not adopted again until they rejoin.
    public var excluded: Set<String> = []
    public init(offsets: [String: Int] = [:]) { self.offsets = offsets }
    enum CodingKeys: String, CodingKey { case offsets, excluded }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        offsets = try c.decode([String: Int].self, forKey: .offsets)
        excluded = try c.decodeIfPresent(Set<String>.self, forKey: .excluded) ?? []   // saved before groups existed
    }

    public func isMember(_ key: String) -> Bool { offsets[key] != nil }

    /// Takes a monitor out of the group. The offsets are measured from a virtual base, not from one
    /// monitor, so the others keep theirs and nothing moves.
    public mutating func leave(_ key: String) { offsets[key] = nil; excluded.insert(key) }

    /// Puts a monitor back at its current offset from the group (`levels` are the connected monitors').
    public mutating func join(_ key: String, levels: [(key: String, level: Int)]) {
        excluded.remove(key)
        adopt(levels)
    }

    /// A member moved on its own (its monitor's buttons, or Home Assistant): it keeps the new level as its
    /// distance from the group, instead of being pulled back.
    public mutating func move(_ key: String, level: Int, base: Int) { if offsets[key] != nil { offsets[key] = level - base } }

    /// How many of `keys` are in the group.
    public func members(of keys: [String]) -> Int { keys.filter(isMember).count }

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
        let levels = levels.filter { !excluded.contains($0.key) }
        guard let ref = levels.first(where: { offsets[$0.key] != nil }), let b = base(key: ref.key, level: ref.level) else {
            let keep = excluded
            self = SyncOffsets(levels: levels)
            excluded = keep
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
        public var offset: Int?
        public var offsetSun: Double?
        public var offsetAt: Double?
        public var saved: Double     // Unix seconds
        public init(lastSet: Int?, lastTarget: Int?, offset: Int? = nil, offsetSun: Double? = nil, offsetAt: Double? = nil, saved: Double) {
            self.lastSet = lastSet; self.lastTarget = lastTarget; self.offset = offset; self.offsetSun = offsetSun
            self.offsetAt = offsetAt; self.saved = saved
        }
    }
    public static let maxAge: Double = 12 * 3600
    public var entries: [String: Entry]
    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    /// Records a monitor's state; one with nothing to remember is removed. A state equal to the stored one
    /// (offset, when it was set and in which sun included) is not stored again, so the time means "last
    /// decided", not "last tick". Returns whether anything changed.
    @discardableResult
    public mutating func record(key: String, state: HoldState, now: Double) -> Bool {
        if state.lastSet == nil && state.lastTarget == nil { return entries.removeValue(forKey: key) != nil }
        if let e = entries[key], e.lastSet == state.lastSet, e.lastTarget == state.lastTarget, e.offset == state.offset,
           e.offsetSun == state.offsetSun, e.offsetAt == state.offsetAt { return false }
        entries[key] = Entry(lastSet: state.lastSet, lastTarget: state.lastTarget, offset: state.offset, offsetSun: state.offsetSun, offsetAt: state.offsetAt, saved: now)
        return true
    }
    /// The state to start a monitor with after a restart, or nil when there is none or it is too old.
    public func restore(key: String, now: Double, maxAge: Double = Self.maxAge) -> HoldState? {
        guard let e = entries[key], now - e.saved <= maxAge, now >= e.saved else { return nil }
        return HoldState(lastSet: e.lastSet, lastTarget: e.lastTarget, offset: e.offset, offsetSun: e.offsetSun,
                         offsetAt: e.offsetAt ?? (e.offset != nil ? e.saved : nil))   // saved before offsets had a time
    }
}

/// Home Assistant errors. A connection that fails right after launch, wake or docking (macOS checks the
/// local-network permission, or the network is still switching) usually works a few seconds later, so
/// it is retried quickly and only shown once Home Assistant has been unreachable for a while. A
/// rejected or missing token will not fix itself and shows at once. A gateway answer (502, 503, 504:
/// Home Assistant restarting behind a proxy) counts as a failed connection; any other status
/// (403, 404, 500...) is an answer that will not fix itself and shows at once.
public enum HAErrorRule {
    /// Whether an HTTP status is a brief outage rather than an answer to act on.
    public static func transient(status: Int) -> Bool { status == 502 || status == 503 || status == 504 }
    public static let retryDelays: [Double] = [2, 5]
    public static let showAfter: Double = 60
    /// Whether the panel should show the error: `downSince` is when the current outage started.
    public static func shouldShow(transient: Bool, downSince: Double?, now: Double) -> Bool {
        if !transient { return true }
        guard let since = downSince else { return false }
        return now - since >= showAfter
    }

    /// While Home Assistant stays down, a reminder in the log this often (seconds).
    public static let logEvery: Double = 600
    /// Whether a failing tick writes to the log: the first failure of an outage, a different error,
    /// then one reminder every `logEvery`. Not three lines every tick for as long as it lasts.
    public static func shouldLog(message: String, lastMessage: String?, lastLogged: Double?, now: Double) -> Bool {
        guard let at = lastLogged, message == lastMessage else { return true }
        return now - at >= logEvery
    }
}

/// The name shown for a monitor: macOS and Windows sometimes report an empty one (a display that is
/// still waking up, or one behind an adapter). Never an empty label in the panel or the log.
public enum DisplayName {
    public static func label(_ name: String, index: Int) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Display \(index + 1)" : n
    }
}

/// A fixed contrast per monitor (config `contrast`, DDC/CI VCP 0x12). It is written once at start and
/// again after a display change, wake or config reload; never on the regular tick and never automated.
/// Only over DDC: with HDR on (macOS's own brightness control) monitors usually ignore it.
public enum ContrastRule {
    /// The value to write now, or nil: not configured, not a DDC monitor, or already written since the
    /// last display change. Out-of-range values are clamped to 0…100, like the brightness levels.
    public static func toWrite(configured: Double?, ddc: Bool, written: Int?) -> Int? {
        guard let c = configured, c.isFinite, ddc else { return nil }
        let v = Int(min(100, max(0, c)).rounded())
        return v == written ? nil : v
    }
    /// The Settings window's contrast box: empty = not set (nil), else a whole number 0–100 (a decimal comma
    /// is fine, halves round up). `ok` is false for anything else, so the window can say what is wrong.
    public static func parseField(_ text: String) -> (ok: Bool, value: Int?) {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.isEmpty { return (true, nil) }
        guard let v = Double(t), v.isFinite, (0...100).contains(v) else { return (false, nil) }
        return (true, Int(v.rounded()))
    }
    /// The same box when the file may hold a decimal: text equal to what the window loaded (`original`) means
    /// "not edited", so the file keeps its value (`keep`); only an edited box is parsed and rounded.
    public static func parseField(_ text: String, unchangedFrom original: String) -> (ok: Bool, value: Int?, keep: Bool) {
        if text == original { return (true, nil, true) }
        let r = parseField(text)
        return (r.ok, r.value, false)
    }
}

/// Keyboard shortcuts that would fight over the same keys.
public enum ShortcutRule {
    /// Indices of the first two combinations with the same key and modifiers, or nil.
    public static func clash(_ combos: [(key: UInt32, mods: UInt32)]) -> (first: Int, second: Int)? {
        for i in combos.indices {
            for j in combos.indices where j > i && combos[i].key == combos[j].key && combos[i].mods == combos[j].mods { return (i, j) }
        }
        return nil
    }
}
