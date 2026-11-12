// macOS can silently deny an app the Local Network permission (for example after an update of an
// ad-hoc signed app). Every request to a local Home Assistant then fails as "offline". These are the
// pure decisions; the network probing itself lives in the app.
import Foundation

public enum LocalHost {
    /// Whether `host` is an address on the local network: private IPv4, link-local, `.local` names,
    /// IPv6 link-local (fe80::/10) and unique-local (fc00::/7). A public name or a cloud URL is not.
    public static func isLocal(_ host: String) -> Bool {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let z = h.firstIndex(of: "%") { h = String(h[..<z]) }   // fe80::1%en0
        if h.contains(":") {
            if h.hasPrefix("::ffff:") {   // IPv4-mapped: dotted (::ffff:192.168.1.5) or hex (::ffff:c0a8:0105)
                let rest = String(h.dropFirst(7))
                if rest.contains(".") { return isLocal(rest) }
                let w = rest.split(separator: ":").compactMap { UInt16($0, radix: 16) }
                if w.count == 2 { return isLocal("\(w[0] >> 8).\(w[0] & 255).\(w[1] >> 8).\(w[1] & 255)") }
                return false
            }
            guard let first = h.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init),
                  let v = UInt16(first.isEmpty ? "0" : first, radix: 16) else { return false }
            return (v & 0xFFC0) == 0xFE80 || (v & 0xFE00) == 0xFC00
        }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            let o = parts.compactMap { Int($0) }
            guard o.count == 4, o.allSatisfy({ $0 <= 255 }) else { return false }
            return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
        }
        if h.isEmpty || h == "localhost" { return false }   // loopback is not covered by the permission
        for suffix in [".local", ".lan", ".home.arpa"] where h.count > suffix.count && h.hasSuffix(suffix) { return true }
        // A name with no dot ("homeassistant") only resolves through the local network's own DNS or mDNS.
        return !h.contains(".") && !h.allSatisfy(\.isNumber) && h != "lan" && h != "local"
    }

    /// The same for a URL string such as the configured `homeAssistant.url`.
    public static func isLocal(url: String?) -> Bool {
        guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return false }
        return isLocal(host)
    }
}

public enum LocalNetworkBlock {
    /// NSURLErrorNotConnectedToInternet: what a denied Local Network request reports.
    public static let offlineCode = -1009

    /// Whether Home Assistant failures are blocked by macOS's Local Network permission.
    /// `probe.denied`: the system itself said so (a path with `localNetworkDenied`).
    /// Only when the probe is inconclusive, a guess: the request failed as "offline" while the Mac's network as a whole is
    /// fine and the host is local. A real outage or a cloud URL is never blamed on the permission.
    public static func isBlocked(errorCode: Int?, generalPathSatisfied: Bool, hostIsLocal: Bool, probe: Probe) -> Bool {
        switch probe {
        case .denied: return true
        case .notDenied: return false   // the connection got through or failed for another reason
        case .unknown: return errorCode == offlineCode && generalPathSatisfied && hostIsLocal
        }
    }

    /// What a direct connection to the host said. `unknown`: it did not answer in time (the only case
    /// where the guess below is used).
    public enum Probe: Equatable { case denied, notDenied, unknown }

    public static let message = "macOS is blocking Daylit from your local network"
    /// The log line (after "home assistant: ").
    public static let logMessage = "blocked by macOS Local Network permission"
    /// Where the Open Settings button goes.
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
}
