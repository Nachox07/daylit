// Home Assistant REST calls (the template itself is in DaylitCore) and the keychain token.
import Foundation
import DaylitCore

/// Where this Mac may send its token (DaylitCore.TokenDestinationRule): the address and token name it last used,
/// in UserDefaults, so a change in an iCloud-synced config.json is asked about before the token goes there.
enum TokenGate {
    private static let key = "tokenDestination"
    private static let lock = NSLock()

    static func destination(_ ha: HAConfig?) -> TokenDestination? { TokenDestination(url: ha?.url, tokenName: ha?.tokenName) }

    static var remembered: TokenDestination? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TokenDestination.self, from: d)
    }

    static func remember(_ d: TokenDestination) {
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// The decision for this config; nothing remembered yet remembers it (first start, or an upgrade).
    static func decide(_ ha: HAConfig?) -> TokenDestinationRule.Decision {
        lock.lock(); defer { lock.unlock() }
        let cur = destination(ha)
        let d = TokenDestinationRule.decide(current: cur, remembered: remembered)
        if d == .remember, let cur { remember(cur) }
        return d
    }

    /// Whether the token may go to this config's address now.
    static func allows(_ ha: HAConfig?) -> Bool { [.send, .remember].contains(decide(ha)) }

    /// Approved on this Mac: Use in the panel, or a token pasted in the token window (the destination it showed
    /// when it opened, not whatever the config holds when Save lands).
    static func trust(_ d: TokenDestination?) {
        lock.lock(); defer { lock.unlock() }
        if let d { remember(d) }
    }

    /// The URL typed in this Mac's Settings window: approved, keeping the remembered token name.
    static func trustURLEdit(_ d: TokenDestination?) {
        lock.lock(); defer { lock.unlock() }
        if let d { remember(TokenDestinationRule.afterURLEdit(current: d, remembered: remembered)) }
    }
}

enum HAClient {
    /// Read from the main thread (REST) and from the push client's detached keychain read: always under the lock.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var tokenCache: [String: String] = [:]
    private static func cached(_ name: String) -> String? { cacheLock.lock(); defer { cacheLock.unlock() }; return tokenCache[name] }
    private static func cache(_ name: String, _ value: String?) { cacheLock.lock(); defer { cacheLock.unlock() }; tokenCache[name] = value }
    static func clearTokenCache() { cacheLock.lock(); defer { cacheLock.unlock() }; tokenCache = [:] }
    /// The token from the keychain (TokenStore), cached until the config or the token changes.
    static func token(_ name: String) -> String? {
        if let t = cached(name) { return t }
        guard let s = TokenStore.read(name) else { return nil }
        cache(name, s)
        return s
    }

    /// Whether a token is stored, without reading it.
    static func tokenStored(_ name: String) -> Bool { TokenStore.stored(name) }

    /// Transient (see `isTransient`): a connection that fails, or a gateway answer (502, 503, 504). Any other
    /// `.http` is an answer Home Assistant gave (403, 404, 500...), which will not fix itself in a minute.
    enum Failure: Error, Equatable {
        case noToken, rejected, unreachable, http(Int), badAnswer
        /// The address or token name changed since this Mac last used the token: nothing was sent (TokenGate).
        case notApproved
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

    /// A POST with `body`, or a GET without one. Only to an approved address (TokenGate) unless `approved`:
    /// the Settings window's Test with a URL typed there.
    static func call(_ ha: HAConfig, _ path: String, _ body: [String: Any]?, timeout: Double = 6, approved: Bool = false) async -> Result<Data, Failure> {
        let name = ha.tokenName ?? "daylit-home-assistant"
        guard approved || TokenGate.allows(ha) else { return .failure(.notApproved) }
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
        if code == 401 { cache(name, nil); lastCause = "HTTP 401"; return .failure(.rejected) }
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
        case .notApproved: return "The Home Assistant address changed: choose Use in the panel to send the token there"
        }
    }
}
