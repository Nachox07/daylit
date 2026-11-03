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

    enum Failure: Error { case noToken, rejected, unreachable, badAnswer }

    static func call(_ ha: HAConfig, _ path: String, _ body: [String: Any]) async -> Result<Data, Failure> {
        let name = ha.tokenName ?? "daylit-home-assistant"
        guard let token = token(name) else { return .failure(.noToken) }
        var base = ha.url ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { return .failure(.unreachable) }
        var r = URLRequest(url: url, timeoutInterval: 6)
        r.httpMethod = "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return .failure(.unreachable) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { tokenCache[name] = nil; return .failure(.rejected) }
        return code < 300 ? .success(d) : .failure(.unreachable)
    }
    static func state(_ ha: HAConfig, _ mons: [Mon]) async -> Result<HAState, Failure> {
        switch await call(ha, "/api/template", ["template": HATemplate.build(ha, mons.map { ($0.uuid, $0.ha) })]) {
        case .failure(let f): return .failure(f)
        case .success(let d):
            guard let s = HAState.parse(d) else { return .failure(.badAnswer) }
            return .success(s)
        }
    }
    static func describe(_ f: Failure, _ ha: HAConfig) -> String {
        switch f {
        case .noToken: return "No Home Assistant token in the keychain (\"\(ha.tokenName ?? "daylit-home-assistant")\", see README)"
        case .rejected: return "Home Assistant rejected the token"
        case .unreachable: return "Cannot reach Home Assistant"
        case .badAnswer: return "Unexpected answer from Home Assistant (check the entity ids)"
        }
    }
}
