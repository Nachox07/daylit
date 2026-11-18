// Where this Mac sends its Home Assistant token. With "Keep settings in iCloud Drive" another Mac can change
// homeAssistant.url or tokenName in the shared file; each Mac remembers the address and token name it last
// used with its token and asks before sending the token anywhere else. These are the pure decisions; the
// remembered value (UserDefaults) and the panel line live in the app. macOS only: Windows has no synced config.
import Foundation

/// A Home Assistant address (normalised: scheme, host, port and path) and the token name used with it.
public struct TokenDestination: Codable, Equatable, Sendable {
    public var url: String
    public var tokenName: String

    public static let defaultTokenName = "daylit-home-assistant"

    /// nil when `url` is not an http(s) URL with a host: there is nowhere to send a token.
    public init?(url: String?, tokenName: String?) {
        guard let n = TokenDestination.normalise(url ?? "") else { return nil }
        self.url = n
        let t = (tokenName ?? "").trimmingCharacters(in: .whitespaces)
        self.tokenName = t.isEmpty ? Self.defaultTokenName : t
    }

    /// `https://HA.example.local:8123/ha/` → `https://ha.example.local:8123/ha`. The port is always written,
    /// so `http://ha.example.local` and `http://ha.example.local:80` are the same address; query, fragment
    /// and user info are dropped.
    public static func normalise(_ url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host   // IPv6
        return "\(scheme)://\(h):\(port)\(path)"
    }

    /// The address as a person reads it: `https://ha.example.local:443/ha` → `https://ha.example.local/ha`
    /// (the default port left out). Shown in the token window, which approves exactly this address.
    public var shown: String {
        guard let r = url.range(of: "://") else { return url }
        let rest = url[r.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = String(rest[..<slash])
        let defaultPort = url.hasPrefix("https://") ? ":443" : ":80"
        if authority.hasSuffix(defaultPort) { authority.removeLast(defaultPort.count) }
        return String(url[..<r.upperBound]) + authority + rest[slash...]
    }

    /// The host for the panel line ("ha.example.local").
    public var host: String {
        var h = URLComponents(string: url)?.host ?? url
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }   // Foundation versions differ
        return h
    }
}

public enum TokenDestinationRule {
    public enum Decision: Equatable {
        /// The remembered destination: send the token.
        case send
        /// Nothing remembered and no token stored on this Mac: there is nothing to send, so nothing to ask (the
        /// caller says "no token").
        /// Nothing is remembered either: the address is approved when a token is pasted in the token window
        /// (which shows it) or when the user chooses Use.
        case noToken
        /// Changed since the token was last used, or a token is stored but no address was ever approved for it
        /// on this Mac (an upgrade from a version without this check, or a token added from Terminal): send
        /// nothing until the user chooses Use.
        case ask
        /// No valid address: send nothing (the config check already says why).
        case hold
    }

    /// `tokenStored` is only consulted when nothing is remembered (pass a closure so the keychain is not
    /// queried on every call).
    public static func decide(current: TokenDestination?, remembered: TokenDestination?, tokenStored: () -> Bool) -> Decision {
        guard let current else { return .hold }
        guard let remembered else { return tokenStored() ? .ask : .noToken }
        return current == remembered ? .send : .ask
    }

    /// Whether the token may be read and sent. Not with `.noToken`: a token stored a moment later (from
    /// Terminal) must still be asked about, so the caller reports "no token" without reading the keychain.
    public static func allows(_ d: Decision) -> Bool { d == .send }

    /// What to remember after the URL is edited in this Mac's Settings window. The window has no token-name
    /// field, so a token name changed in the file is not approved by saving it: the remembered one stays.
    public static func afterURLEdit(current: TokenDestination, remembered: TokenDestination?) -> TokenDestination {
        var d = current
        if let r = remembered { d.tokenName = r.tokenName }
        return d
    }

    /// The question in the panel: the whole address (scheme, port and path), since Use approves all of it.
    public static func question(current: TokenDestination, remembered: TokenDestination?) -> String {
        guard let r = remembered else { return "Send this Mac’s Home Assistant token to \(current.shown)?" }
        if r.url == current.url, r.tokenName != current.tokenName {
            return "The Home Assistant token name changed to “\(current.tokenName)”. Send that token to \(current.shown)?"
        }
        return "Home Assistant address changed to \(current.shown). Send the token there?"
    }

    /// The log line when a change is first held back (never the token).
    public static func heldLine(current: TokenDestination, remembered: TokenDestination?) -> String {
        if remembered == nil {
            return "home assistant: no address approved for the token on this Mac yet (now \(current.host), token \"\(current.tokenName)\"); not sending the token until Use is chosen in the panel"
        }
        return "home assistant: address or token name changed (now \(current.host), token \"\(current.tokenName)\"); not sending the token until Use is chosen in the panel"
    }

    /// "Not now" hides the question for this long; then it shows again. Nothing is sent meanwhile.
    public static let snoozeSeconds: Double = 3600

    /// Whether the panel shows the question: always, unless "Not now" was chosen for this same destination
    /// less than `snoozeSeconds` ago.
    public static func showQuestion(current: TokenDestination, dismissed: TokenDestination?, dismissedAt: Double?, now: Double) -> Bool {
        guard let d = dismissed, d == current, let at = dismissedAt else { return true }
        return now - at >= snoozeSeconds || now < at
    }
}
