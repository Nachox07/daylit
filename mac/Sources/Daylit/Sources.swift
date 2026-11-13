// Home Assistant REST calls (the template itself is in DaylitCore) and the keychain token.
import Foundation
import DaylitCore

enum HAClient {
    nonisolated(unsafe) static var tokenCache: [String: String] = [:]
    static func token(_ name: String) -> String? {
        if let t = tokenCache[name] { return t }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", name, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s, !s.isEmpty else { return nil }
        tokenCache[name] = s
        return s
    }

    /// Whether a token is stored, without reading it (security exits 0 when the item exists).
    static func tokenStored(_ name: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", name]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Transient (see `isTransient`): a connection that fails, or a gateway answer (502, 503, 504). Any other
    /// `.http` is an answer Home Assistant gave (403, 404, 500...), which will not fix itself in a minute.
    enum Failure: Error, Equatable {
        case noToken, rejected, unreachable, http(Int), badAnswer
        var isTransient: Bool {
            switch self {
            case .unreachable: return true
            case .http(let code): return HAErrorRule.transient(status: code)
            default: return false
            }
        }
    }
    /// The underlying cause of the last failed call (URL error domain and code, or HTTP status), for the log.
    nonisolated(unsafe) static var lastCause: String?
    /// The NSURLError code of the last failed call (nil for an HTTP status).
    nonisolated(unsafe) static var lastCode: Int?

    /// A POST with `body`, or a GET without one.
    static func call(_ ha: HAConfig, _ path: String, _ body: [String: Any]?, timeout: Double = 6) async -> Result<Data, Failure> {
        let name = ha.tokenName ?? "daylit-home-assistant"
        guard let token = token(name) else { return .failure(.noToken) }
        var base = ha.url ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { return .failure(.unreachable) }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let d: Data, resp: URLResponse
        do { (d, resp) = try await URLSession.shared.data(for: r) }
        catch {
            let e = error as NSError
            lastCause = "\(e.domain) \(e.code): \(e.localizedDescription)"
            lastCode = e.domain == NSURLErrorDomain ? e.code : nil
            return .failure(.unreachable)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        lastCode = nil
        if code == 401 { tokenCache[name] = nil; lastCause = "HTTP 401"; return .failure(.rejected) }
        if code >= 300 { lastCause = "HTTP \(code)"; return .failure(.http(code)) }
        lastCause = nil
        return .success(d)
    }
    static func state(_ ha: HAConfig, _ mons: [Mon]) async -> Result<HAState, Failure> {
        switch await call(ha, "/api/template", ["template": HATemplate.build(ha, mons.map { ($0.uuid, $0.ha) })]) {
        case .failure(let f): return .failure(f)
        case .success(let d):
            guard let s = HAState.parse(d) else { return .failure(.badAnswer) }
            return .success(s)
        }
    }
    /// The last `days` of a sensor's history, as Home Assistant returns it.
    static func history(_ ha: HAConfig, _ entity: String, days: Double) async -> Result<Data, Failure> {
        let iso = ISO8601DateFormatter()
        let end = Date(), start = end.addingTimeInterval(-days * 86400)
        var q = URLComponents()
        q.queryItems = [.init(name: "end_time", value: iso.string(from: end)), .init(name: "filter_entity_id", value: entity),
                        .init(name: "minimal_response", value: nil), .init(name: "no_attributes", value: nil)]
        // "+" in a time would read as a space, so the query is percent-encoded with it escaped.
        let query = (q.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let path = "/api/history/period/" + iso.string(from: start).replacingOccurrences(of: "+", with: "%2B") + "?" + query
        return await call(ha, path, nil, timeout: 60)
    }
    /// input_number/set_value: a level from an accepted suggestion (DaylitCore.Suggest).
    static func setNumber(_ ha: HAConfig, _ entity: String, _ value: Double) async -> Result<Data, Failure> {
        guard Config.isEntityId(entity) else { return .failure(.badAnswer) }
        return await call(ha, "/api/services/input_number/set_value", ["entity_id": entity, "value": value])
    }
    enum StepRead: Equatable { case step(NumberStep), noAnswer, noAttributes }
    /// An input_number's min, max and step, so a suggestion rounds to a value it accepts. `noAnswer`: Home
    /// Assistant did not answer (try again); `noAttributes`: it answered but the entity has none (not an input_number).
    static func numberStep(_ ha: HAConfig, _ entity: String) async -> StepRead {
        guard Config.isEntityId(entity), case .success(let d) = await call(ha, "/api/states/" + entity, nil) else { return .noAnswer }
        return NumberStep.parse(d).map { .step($0) } ?? .noAttributes
    }
    static func describe(_ f: Failure, _ ha: HAConfig) -> String {
        switch f {
        case .noToken: return "No Home Assistant token in the keychain (\"\(ha.tokenName ?? "daylit-home-assistant")\", gear menu → Home Assistant Token…)"
        case .rejected: return "Home Assistant rejected the token"
        case .unreachable: return "Cannot reach Home Assistant"
        case .http(let code): return "Home Assistant answered \(code)"
        case .badAnswer: return "Unexpected answer from Home Assistant (check the entity ids)"
        }
    }
}
