// Tells a macOS Local Network denial apart from a real outage (decision: DaylitCore.LocalNetworkBlock).
import Foundation
import Network
import DaylitCore

enum LocalNetworkProbe {
    /// Whether the Mac's network as a whole is usable, kept current by a path monitor.
    private final class General: @unchecked Sendable {
        private let lock = NSLock()
        private var ok = false   // unknown until the monitor reports: never blame macOS on a guess
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

    /// Starts the path monitor early, so its first report has arrived by the time a request fails.
    static func warm() { _ = general.satisfied }

    /// Whether Home Assistant failing with `code` is most likely macOS's Local Network permission.
    /// Two signals: a connection to the host whose path says `localNetworkDenied` (what the system
    /// reports), else the heuristic of an "offline" error on a working network to a local host.
    static func blocked(url: String?, errorCode: Int?) async -> Bool {
        let local = LocalHost.isLocal(url: url)
        guard local else { return false }   // a cloud URL never needs the permission
        let probe = await probeHost(url: url)
        return LocalNetworkBlock.isBlocked(errorCode: errorCode, generalPathSatisfied: general.satisfied,
                                           hostIsLocal: local, probe: probe)
    }

    /// Opens a TCP connection to the host. `.denied`: its path is unsatisfied because of the Local
    /// Network permission. `.notDenied`: it connected, or ended for another reason. `.unknown`: no
    /// answer within 2 s.
    private static func probeHost(url: String?) async -> LocalNetworkBlock.Probe {
        guard let url, let c = URLComponents(string: url), let host = c.host else { return .unknown }
        let port = c.port ?? (c.scheme == "https" ? 443 : 80)
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unknown }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        return await withCheckedContinuation { (k: CheckedContinuation<LocalNetworkBlock.Probe, Never>) in
            let once = Once()
            let finish: @Sendable (LocalNetworkBlock.Probe) -> Void = { v in
                guard once.first() else { return }
                conn.cancel(); k.resume(returning: v)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.notDenied)
                case .waiting, .failed:
                    finish(conn.currentPath?.unsatisfiedReason == .localNetworkDenied ? .denied : .notDenied)
                default: break
                }
            }
            conn.start(queue: DispatchQueue(label: "daylit.probe"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(.unknown) }
        }
    }
}
