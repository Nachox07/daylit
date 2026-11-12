// Push updates from Home Assistant (experimental, config homeAssistant.push). A WebSocket subscribed to the
// entities the tick reads; a change only asks for a tick (DaylitCore.PushRule decides when). The token is
// read from the keychain, sent once in the auth message, and never logged or put in a URL.
import Foundation
import Network
import DaylitCore

@MainActor final class PushClient {
    /// What to connect to. The same target keeps the connection.
    struct Target: Equatable {
        let url: URL
        let tokenName: String
        let entities: [String]
        let daylight: String?
    }

    /// Connected and subscribed: polling can slow down to PushRule.healthyPollSeconds.
    private(set) var healthy = false
    /// After auth_invalid: the problem line for the panel, until the token or the config changes.
    private(set) var problem: String?

    private let tick: () -> Void
    private let lastTick: () -> Date
    private let daylightLimit: () -> Double
    private var target: Target?
    private var task: URLSessionWebSocketTask?
    /// Bumped on every open and close, so callbacks from an older connection do nothing.
    private var conn = 0
    private var attempt = 0
    /// auth_invalid or no token: no retry until the token or the config changes.
    private var stopped = false
    private var nextId = 1, subscribeId = 0
    private var awaitingPong = false
    private var retryTask: Task<Void, Never>?, pingTask: Task<Void, Never>?, tickTask: Task<Void, Never>?
    private var timer = PushTimer()
    /// The once-then-every-10-minutes rule (HAErrorRule.shouldLog) for "lost" lines.
    private var lastReason: String?, loggedAt: Date?
    private let session = URLSession(configuration: .ephemeral)
    private var path: NWPathMonitor?
    private var lastPath: String?

    init(tick: @escaping () -> Void, lastTick: @escaping () -> Date, daylightLimit: @escaping () -> Double) {
        self.tick = tick
        self.lastTick = lastTick
        self.daylightLimit = daylightLimit
    }

    /// Opens, keeps or closes the socket. `force` reconnects even when nothing changed (a config reload resubscribes).
    func update(_ t: Target?, force: Bool = false) {
        if t == target && !force { return }
        let was = target
        target = t
        stopped = false; problem = nil   // a new config gets a fresh try
        close()
        attempt = 0; lastReason = nil; loggedAt = nil
        guard t != nil else {
            if was != nil { Log.write(PushRule.offLine) }
            path?.cancel(); path = nil; lastPath = nil   // no target: stop watching the network
            return
        }
        watchNetwork()
        open()
    }

    /// A new token was saved: try again, also after auth_invalid.
    func tokenChanged() {
        guard target != nil else { return }
        stopped = false; problem = nil
        close(); attempt = 0
        open()
    }

    /// Wake from sleep or a network change: the old connection may be dead without knowing it.
    func reconnect(_ why: String) {
        guard target != nil, !stopped else { return }
        log("push: reconnecting (\(why))")
        close(); attempt = 0
        open()
    }

    private func open() {
        guard let t = target, !stopped else { return }
        conn += 1
        let c = conn, name = t.tokenName
        Task {
            // Runs /usr/bin/security: off the main thread. `stored` tells "no token" from a failed read.
            let (token, stored) = await Task.detached { () -> (String?, Bool) in
                if let t = HAClient.token(name) { return (t, true) }
                return (nil, HAClient.tokenStored(name))
            }.value
            guard c == self.conn else { return }
            guard let token else {
                if stored { self.lost("keychain read failed", c); return }   // a failed read retries on the normal backoff
                // The REST tick already shows "No Home Assistant token"; the token window calls tokenChanged().
                self.close(); self.stopped = true
                Log.write("push: no token stored, waiting for one")
                return
            }
            let ws = self.session.webSocketTask(with: t.url)
            self.task = ws
            ws.resume()
            self.receive(ws, c, token, t)
        }
    }

    private func receive(_ ws: URLSessionWebSocketTask, _ c: Int, _ token: String, _ t: Target) {
        Task {
            var token: String? = token   // sent once per connection; the next connection reads it again (HAClient caches it)
            while c == self.conn {
                let message: URLSessionWebSocketTask.Message
                do { message = try await ws.receive() } catch {
                    // A close frame from Home Assistant (a restart) reads better than the socket error it causes.
                    self.lost(ws.closeCode != .invalid ? "closed by Home Assistant" : Self.reason(error), c)
                    return
                }
                guard c == self.conn else { return }
                guard case .string(let text) = message else { continue }
                switch PushRule.parse(text) {
                case .authRequired:
                    guard let tk = token else { continue }
                    token = nil
                    self.send(ws, PushRule.authMessage(token: tk), c)
                case .authOk:
                    self.subscribeId = self.nextId; self.nextId += 1
                    self.send(ws, PushRule.subscribeMessage(id: self.subscribeId, entities: t.entities), c)
                case .authInvalid(let why):
                    self.rejected(why)
                    return
                case .result(let id, let ok) where id == self.subscribeId:
                    guard ok else { self.lost("subscribe refused", c); return }
                    self.healthy = true
                    Log.write(PushRule.connectedLine(t.entities.count))
                    self.startPing(ws, c)
                case .event(let ids):
                    self.request(ids, t)
                case .pong:
                    self.awaitingPong = false
                default:
                    break
                }
            }
        }
    }

    private func send(_ ws: URLSessionWebSocketTask, _ text: String, _ c: Int) {
        Task {
            do { try await ws.send(.string(text)) } catch { self.lost(Self.reason(error), c) }
        }
    }

    /// A ping every minute; no pong within 10 s closes and retries. A connection that lasted a minute ends
    /// the outage: the backoff and the log rule start again.
    private func startPing(_ ws: URLSessionWebSocketTask, _ c: Int) {
        pingTask?.cancel()
        pingTask = Task {
            while c == self.conn {
                try? await Task.sleep(nanoseconds: UInt64(PushRule.pingInterval(onBattery: Power.onBattery) * 1_000_000_000))
                guard c == self.conn, !Task.isCancelled else { return }
                self.awaitingPong = true
                let id = self.nextId; self.nextId += 1
                self.send(ws, PushRule.pingMessage(id: id), c)
                try? await Task.sleep(nanoseconds: UInt64(PushRule.pongTimeout * 1_000_000_000))
                guard c == self.conn, !Task.isCancelled else { return }
                if self.awaitingPong { self.lost("no pong", c); return }
                self.attempt = 0; self.lastReason = nil; self.loggedAt = nil
            }
        }
    }

    private func request(_ ids: Set<String>, _ t: Target) {
        let now = Date().timeIntervalSince1970
        let d = PushRule.decide(changed: ids, subscribed: Set(t.entities), daylight: t.daylight,
                                lastTick: lastTick().timeIntervalSince1970, now: now,
                                every: daylightLimit())
        guard timer.add(d, now: now), let due = timer.due else { return }
        log("push: \(ids.sorted().joined(separator: ", ")) changed, tick in \(Int((due - now).rounded())) s")
        tickTask?.cancel()
        let c = conn
        tickTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, due - now) * 1_000_000_000))
            guard c == self.conn, !Task.isCancelled else { return }
            self.timer.clear()
            self.tick()
        }
    }

    private func lost(_ reason: String, _ c: Int) {
        guard c == conn, target != nil else { return }
        close()
        let delay = PushRule.retryDelay(attempt: attempt)
        attempt += 1
        let now = Date()
        if HAErrorRule.shouldLog(message: reason, lastMessage: lastReason, lastLogged: loggedAt?.timeIntervalSince1970,
                                 now: now.timeIntervalSince1970) {
            Log.write(PushRule.lostLine(reason, retryIn: delay))
            loggedAt = now
        }
        lastReason = reason
        let cc = conn
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard cc == self.conn, !Task.isCancelled else { return }
            self.open()
        }
    }

    private func rejected(_ why: String) {
        close()
        stopped = true
        problem = PushRule.rejectedProblem
        Log.write(PushRule.rejectedLine(why))
        tick()   // shows the problem line
    }

    private func close() {
        conn += 1
        healthy = false; awaitingPong = false
        task?.cancel(with: .goingAway, reason: nil); task = nil
        retryTask?.cancel(); pingTask?.cancel(); tickTask?.cancel()
        retryTask = nil; pingTask = nil; tickTask = nil
        timer.clear()
    }

    /// Network changes (Wi-Fi to Ethernet, a VPN, another network): reconnect at once rather than wait for a missed pong.
    private func watchNetwork() {
        guard path == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            let key = "\(p.status) " + p.availableInterfaces.map(\.name).joined(separator: ",")
            Task { @MainActor in self?.pathChanged(key) }
        }
        m.start(queue: .main)
        path = m
    }

    private func pathChanged(_ key: String) {
        defer { lastPath = key }
        guard let was = lastPath, was != key else { return }   // the first report is the current network
        reconnect("network change")
    }

    /// The cause for the log: the error's domain and code, never the request.
    static func reason(_ e: Error) -> String {
        let n = e as NSError
        return "\(n.domain) \(n.code)"
    }
}
