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
