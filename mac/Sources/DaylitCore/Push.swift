// Push updates from Home Assistant (experimental, config homeAssistant.push): the WebSocket only says
// *when* to tick. The tick still reads everything through the REST template. The app side is
// mac/Sources/Daylit/PushClient.swift; windows/Push.cs is the twin of this file.
import Foundation

public enum PushRule {
    /// `ws(s)://<host>/api/websocket` from homeAssistant.url, or nil when it is not an http(s) URL.
    public static func socketURL(_ http: String) -> URL? {
        guard var c = URLComponents(string: http.trimmingCharacters(in: .whitespaces)), c.host?.isEmpty == false else { return nil }
        switch c.scheme?.lowercased() {
        case "http": c.scheme = "ws"
        case "https": c.scheme = "wss"
        default: return nil
        }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path + "/api/websocket"
        c.query = nil; c.fragment = nil; c.user = nil; c.password = nil
        return c.url
    }

    /// Every entity the tick reads, once each, sorted: the HA-wide ones (the sun is sun.sun when unset or not
    /// an entity id, as in the template) and each configured monitor's helpers. Never a monitor's `sensor`:
    /// Daylit publishes it, so following it would make every publish trigger another tick.
    public static func entities(_ c: Config) -> [String] {
        guard let ha = c.homeAssistant else { return [] }
        let sun = ha.sun.flatMap { Config.isEntityId($0) ? $0 : nil } ?? "sun.sun"
        var ids: [String?] = [ha.autoSwitch, sun, ha.cover, ha.lights, ha.light]
        for m in c.monitors ?? [] {
            guard let h = m.homeAssistant else { continue }
            ids += [h.day, h.blindDown, h.night, h.nightLights, h.set]
        }
        return Array(Set(ids.compactMap { $0 }.filter { !$0.isEmpty && Config.isEntityId($0) })).sorted()
    }
}

/// One message from Home Assistant's WebSocket API, reduced to what Daylit needs.
public enum PushMessage: Equatable {
    case authRequired
    case authOk
    case authInvalid(String)
    case result(id: Int, ok: Bool)
    /// A subscribe_entities event: the entity ids it added (`a`), changed (`c`) or removed (`r`).
    case event(Set<String>)
    case pong
    case other
}

extension PushRule {
    /// One incoming text frame. Anything unexpected (bad JSON, a list, an unknown type) is `.other`.
    public static func parse(_ text: String) -> PushMessage {
        guard let d = text.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let type = o["type"] as? String else { return .other }
        switch type {
        case "auth_required": return .authRequired
        case "auth_ok": return .authOk
        case "auth_invalid": return .authInvalid(o["message"] as? String ?? "")
        case "pong": return .pong
        case "result":
            guard let id = o["id"] as? Int, let ok = o["success"] as? Bool else { return .other }
            return .result(id: id, ok: ok)
        case "event":
            guard let e = o["event"] as? [String: Any] else { return .other }
            var ids = Set<String>()
            if let a = e["a"] as? [String: Any] { ids.formUnion(a.keys) }
            if let c = e["c"] as? [String: Any] { ids.formUnion(c.keys) }
            if let r = e["r"] as? [String] { ids.formUnion(r) }
            return .event(ids)
        default: return .other
        }
    }

    /// The answer to auth_required. The token goes only here: never into a URL, a log line or an error.
    public static func authMessage(token: String) -> String {
        json(["type": "auth", "access_token": token])
    }
    public static func subscribeMessage(id: Int, entities: [String]) -> String {
        json(["id": id, "type": "subscribe_entities", "entity_ids": entities])
    }
    public static func pingMessage(id: Int) -> String { json(["id": id, "type": "ping"]) }

    static func json(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The log lines (Log.write adds the time). None of them can carry the token.
    public static func connectedLine(_ count: Int) -> String { "push: connected (\(count) entities)" }
    public static func lostLine(_ reason: String, retryIn: Double) -> String { "push: lost (\(reason)), retrying in \(Int(retryIn))s" }
    public static func rejectedLine(_ reason: String) -> String { "push: token rejected (\(reason)), not retrying until the token or config changes" }
    public static let offLine = "push: off"
    /// The problem line shown in the panel after auth_invalid, like the REST token errors.
    public static let rejectedProblem = "Home Assistant rejected the token (push updates)"
}

/// What a set of changed entities asks for.
public enum PushTick: Equatable {
    case now                 // a tick after the 1 s debounce
    case after(Double)       // the daylight sensor alone: a tick in this many seconds
    case ignore
}

extension PushRule {
    /// A burst of changes within this many seconds runs one tick.
    public static let debounce: Double = 1
    /// The daylight sensor alone ticks at most this often (it can report every few seconds); see `daylightLimit`.
    public static let daylightEvery: Double = 60
    /// While the socket is connected and subscribed, polling is only the safety net.
    public static let healthyPollSeconds: Double = 300
    /// An application ping this often; no pong within `pongTimeout` means the connection is gone.
    public static let pingEvery: Double = 60
    /// Home Assistant's own protocol ping (every 55 s) is answered by the system and cannot be seen by the app, so it does
    /// not tell Daylit the link is dead; our ping does. On battery it runs half as often, to wake the Mac less.
    public static func pingInterval(onBattery: Bool) -> Double { onBattery ? 2 * pingEvery : pingEvery }
    public static let pongTimeout: Double = 10
    /// Waits before each reconnect attempt; the last one repeats.
    public static let backoff: [Double] = [2, 5, 15, 60]

    /// Whether these changes need a tick. `daylight` is homeAssistant.light; `lastTick` is when the last tick
    /// ran (Unix seconds; any tick reads the daylight sensor too).
    public static func decide(changed: Set<String>, subscribed: Set<String>, daylight: String?, lastTick: Double?, now: Double,
                              every: Double = daylightEvery) -> PushTick {
        let relevant = changed.intersection(subscribed)
        if relevant.isEmpty { return .ignore }
        if let d = daylight, relevant == [d] {
            guard let last = lastTick else { return .now }
            let wait = every - (now - last)
            return wait <= 0 ? .now : .after(wait)
        }
        return .now
    }

    /// How often the daylight sensor alone may tick: a minute, or the normal poll interval when that is longer
    /// (battery: batteryPollSeconds), so push never ticks more than polling would on battery.
    public static func daylightLimit(onBattery: Bool, tuning: Tuning) -> Double {
        max(daylightEvery, onBattery ? tuning.batteryPollSeconds : tuning.pollSeconds)
    }

    /// The wait before reconnect attempt `attempt` (0 = the first after a drop).
    public static func retryDelay(attempt: Int) -> Double { backoff[min(max(attempt, 0), backoff.count - 1)] }

    /// The poll interval: today's while the socket is not healthy, else 300 s (or the configured one when longer).
    public static func pollInterval(healthy: Bool, onBattery: Bool, tuning: Tuning) -> Double {
        let normal = onBattery ? tuning.batteryPollSeconds : tuning.pollSeconds
        return healthy ? max(healthyPollSeconds, normal) : normal
    }

    /// Whether the socket should be open: push on, Home Assistant the source, Automatic on, not paused on
    /// battery, and a monitor to drive.
    public static func wanted(push: Bool?, source: Source, paused: Bool, auto: Bool, hasMonitors: Bool) -> Bool {
        push == true && source == .homeAssistant && !paused && auto && hasMonitors
    }
}

/// The one pending push tick. A change asks for a tick in 1 s; each further change before it fires pushes it back
/// to 1 s after that change (a real debounce), but never later than 3 s after the first change, so a steady stream
/// still ticks every 3 s. A daylight-only change waits for its limit, unless a tick is already due.
public struct PushTimer: Equatable {
    public private(set) var due: Double?
    private var first = 0.0
    private var immediate = false   // the pending tick is a debounce window, not a daylight wait
    public static let maxWait: Double = 3
    public init() {}
    /// Adds a request; true when `due` moved, so the caller reschedules its timer.
    public mutating func add(_ t: PushTick, now: Double) -> Bool {
        switch t {
        case .ignore: return false
        case .now:
            if immediate, let d = due {
                let at = min(now + PushRule.debounce, first + PushTimer.maxWait)
                if at <= d { return false }
                due = at; return true
            }
            first = now; immediate = true; due = now + PushRule.debounce
            return true
        case .after(let s):
            let at = now + max(s, PushRule.debounce)
            if let d = due, d <= at { return false }
            if due == nil { first = now; immediate = false }
            due = at; return true
        }
    }
    /// The timer fired (or the socket closed): nothing pending.
    public mutating func clear() { due = nil; immediate = false }
}
