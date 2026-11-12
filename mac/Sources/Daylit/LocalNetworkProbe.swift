// Tells a macOS Local Network denial apart from a real outage (decision: DaylitCore.LocalNetworkBlock).
import Foundation
import Network
import DaylitCore

enum LocalNetworkProbe {
    /// Whether the Mac's network as a whole is usable, kept current by a path monitor.
    private final class General: @unchecked Sendable {
        private let lock = NSLock()
        private var ok = true
        let monitor = NWPathMonitor()
        init() {
            monitor.pathUpdateHandler = { [self] p in lock.lock(); ok = p.status == .satisfied; lock.unlock() }
            monitor.start(queue: DispatchQueue(label: "daylit.path"))
        }
        var satisfied: Bool { lock.lock(); defer { lock.unlock() }; return ok }
    }
    private static let general = General()
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Whether Home Assistant failing with `code` is most likely macOS's Local Network permission.
    /// Two signals: a connection to the host whose path says `localNetworkDenied` (what the system
    /// reports), else the heuristic of an "offline" error on a working network to a local host.
    static func blocked(url: String?, errorCode: Int?) async -> Bool {
        let local = LocalHost.isLocal(url: url)
        guard local else { return false }   // a cloud URL never needs the permission
        let denied = await pathDenied(url: url)
        return LocalNetworkBlock.isBlocked(errorCode: errorCode, generalPathSatisfied: general.satisfied,
                                           hostIsLocal: local, deniedReported: denied)
    }

    /// Opens a TCP connection to the host and reports whether its path is unsatisfied because of the
    /// Local Network permission. Gives up after 2 s.
    private static func pathDenied(url: String?) async -> Bool {
        guard let url, let c = URLComponents(string: url), let host = c.host else { return false }
        let port = c.port ?? (c.scheme == "https" ? 443 : 80)
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { v in
                guard once.first() else { return }
                conn.cancel(); k.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(false)
                case .waiting, .failed:
                    finish(conn.currentPath?.unsatisfiedReason == .localNetworkDenied)
                default: break
                }
            }
            conn.start(queue: DispatchQueue(label: "daylit.probe"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(conn.currentPath?.unsatisfiedReason == .localNetworkDenied) }
        }
    }
}
