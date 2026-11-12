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
