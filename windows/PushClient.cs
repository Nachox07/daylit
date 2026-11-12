// Push updates from Home Assistant (experimental, config homeAssistant.push). A WebSocket subscribed to the
// entities the tick reads; a change only asks for a tick (PushRule in Push.cs decides when). The receive loop runs
// on the thread pool and hands each message to the UI thread; everything else here runs on the UI thread. The token
// is sent once in the auth message and never logged or put in a URL. Twin of mac/Sources/Daylit/PushClient.swift.
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Windows.Threading;

namespace Daylit;

sealed class PushClient {
    /// What to connect to. The same target keeps the connection.
    public sealed record Target(Uri Url, string[] Entities, string? Daylight) {
        /// Records compare arrays by reference, so the entity lists are compared here.
        public bool Same(Target? o) => o != null && Url == o.Url && Daylight == o.Daylight && Entities.SequenceEqual(o.Entities);
    }

    /// Connected and subscribed: polling can slow down to PushRule.HealthyPollSeconds.
    public bool Healthy { get; private set; }
    /// After auth_invalid: the problem line for the panel, until the token or the config changes.
    public string? Problem { get; private set; }
    /// Healthy changed: the controller resets its poll timer.
    public event Action? HealthChanged;

    readonly Dispatcher ui;
    readonly Action tick;
    readonly Func<DateTime> lastTick;   // UTC; DateTime.MinValue before the first tick
    readonly Func<string?> token;
    Target? target;
    ClientWebSocket? ws;
    CancellationTokenSource? cts;
    SemaphoreSlim? sendGate;            // one send at a time per connection (ClientWebSocket allows only one)
    int conn;                           // bumped on every open and close: messages from an older connection do nothing
    int attempt, nextId = 1, subscribeId;
    bool stopped;                       // auth_invalid or no token: no retry until the token or the config changes
    bool awaitingPong;
    string? lastReason; DateTime? loggedAt;   // the once-then-every-10-minutes rule (HaErrorRule.ShouldLog)
    readonly PushTimer pending = new();
    readonly DispatcherTimer retry = new(), ping = new(), pong = new(), tickTimer = new(), network = new();

    public PushClient(Dispatcher ui, Action tick, Func<DateTime> lastTick, Func<string?> token) {
        this.ui = ui; this.tick = tick; this.lastTick = lastTick; this.token = token;
        retry.Tick += (_, _) => { retry.Stop(); Open(); };
        ping.Interval = TimeSpan.FromSeconds(PushRule.PingEvery);
        ping.Tick += (_, _) => SendPing();
        pong.Interval = TimeSpan.FromSeconds(PushRule.PongTimeout);
        pong.Tick += (_, _) => {
            pong.Stop();
            if (awaitingPong) { Lost("no pong", conn); return; }
            attempt = 0; lastReason = null; loggedAt = null;   // up for a minute: the next drop starts the backoff again
        };
        tickTimer.Tick += (_, _) => { tickTimer.Stop(); pending.Clear(); tick(); };
        // NetworkAddressChanged fires several times for one change: reconnect once, 2 s after the last.
        network.Interval = TimeSpan.FromSeconds(2);
        network.Tick += (_, _) => { network.Stop(); Reconnect("network change"); };
    }

    /// Opens, keeps or closes the socket. `force` reconnects even when nothing changed (a config reload resubscribes).
    public void Update(Target? t, bool force = false) {
        if (!force && (t == null ? target == null : t.Same(target))) return;
        var was = target;
        target = t;
        stopped = false; Problem = null;   // a new config gets a fresh try
        Close();
        attempt = 0; lastReason = null; loggedAt = null;
        if (t == null) { if (was != null) Log.Write(PushRule.OffLine); return; }
        Open();
    }

    /// A new token was saved: try again, also after auth_invalid.
    public void TokenChanged() {
        if (target == null) return;
        stopped = false; Problem = null;
        Close(); attempt = 0;
        Open();
    }

    /// Wake from sleep or a network change: the old connection may be dead without knowing it.
    public void Reconnect(string why) {
        if (target == null || stopped) return;
        Close(); attempt = 0;
        Open();
    }

    /// From NetworkChange.NetworkAddressChanged (on the UI thread).
    public void NetworkChanged() { network.Stop(); network.Start(); }

    void Open() {
        if (target is not { } t || stopped) return;
        if (token() is not { } secret) {
            // The REST tick already shows "No Home Assistant token"; AskToken calls TokenChanged().
            Close(); stopped = true;
            Log.Write("push: no token stored, waiting for one");
            return;
        }
        int c = ++conn;
        var socket = new ClientWebSocket();
        var source = new CancellationTokenSource();
        var gate = new SemaphoreSlim(1, 1);
        ws = socket; cts = source; sendGate = gate;
        _ = Run(socket, source.Token, gate, c, secret, t);
    }

    /// The receive loop, on the thread pool. auth_required is answered here, so the token never leaves this method.
    async Task Run(ClientWebSocket socket, CancellationToken stop, SemaphoreSlim gate, int c, string? secret, Target t) {
        string reason;
        try {
            await socket.ConnectAsync(t.Url, stop).ConfigureAwait(false);
            var buffer = new byte[16 * 1024];
            using var message = new MemoryStream();
            while (true) {
                var r = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), stop).ConfigureAwait(false);
                if (r.MessageType == WebSocketMessageType.Close) { reason = "closed by Home Assistant"; break; }
                message.Write(buffer, 0, r.Count);
                if (!r.EndOfMessage) continue;
                var text = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                message.SetLength(0);
                if (r.MessageType != WebSocketMessageType.Text) continue;
                var m = PushRule.Parse(text);
                if (m.Kind == PushKind.AuthRequired) {
                    if (secret is { } s) { secret = null; await Send(socket, gate, PushRule.AuthMessage(s), stop).ConfigureAwait(false); }
                    continue;
                }
                ui.BeginInvoke(() => Handle(m, c, t));
            }
        } catch (OperationCanceledException) when (stop.IsCancellationRequested) {
            return;   // closed on purpose
        } catch (Exception e) {
            // The type and code only: never a message that could quote the request.
            reason = e is WebSocketException we ? $"WebSocket {we.WebSocketErrorCode}" : e.GetType().Name;
        }
        ui.BeginInvoke(() => Lost(reason, c));
    }

    static async Task Send(ClientWebSocket socket, SemaphoreSlim gate, string text, CancellationToken stop) {
        var bytes = Encoding.UTF8.GetBytes(text);
        await gate.WaitAsync(stop).ConfigureAwait(false);
        try { await socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, stop).ConfigureAwait(false); }
        finally { gate.Release(); }
    }

    /// A send from the UI thread; a failure closes and retries.
    async Task SendOrLose(string text, int c) {
        if (ws is not { } socket || cts is not { } source || sendGate is not { } gate || c != conn) return;
        try { await Send(socket, gate, text, source.Token); }
        catch (OperationCanceledException) { }
        catch (Exception e) { Lost(e is WebSocketException we ? $"WebSocket {we.WebSocketErrorCode}" : e.GetType().Name, c); }
    }

    void Handle(PushMessage m, int c, Target t) {
        if (c != conn) return;
        switch (m.Kind) {
            case PushKind.AuthOk:
                subscribeId = nextId++;
                _ = SendOrLose(PushRule.SubscribeMessage(subscribeId, t.Entities), c);
                break;
            case PushKind.AuthInvalid:
                Rejected(m.Reason ?? "");
                break;
            case PushKind.Result when m.Id == subscribeId:
                if (!m.Ok) { Lost("subscribe refused", c); break; }
                SetHealthy(true);
                Log.Write(PushRule.ConnectedLine(t.Entities.Length));
                ping.Start();
                break;
            case PushKind.Event:
                Request(m.Ids ?? new HashSet<string>(), t);
                break;
            case PushKind.Pong:
                awaitingPong = false;
                break;
        }
    }

    void SendPing() {
        if (ws == null) return;
        awaitingPong = true;
        _ = SendOrLose(PushRule.PingMessage(nextId++), conn);
        pong.Stop(); pong.Start();
    }

    void Request(IReadOnlySet<string> ids, Target t) {
        double now = Secs(DateTime.UtcNow);
        var last = lastTick();
        var d = PushRule.Decide(ids, t.Entities.ToHashSet(), t.Daylight, last == DateTime.MinValue ? null : (double?)Secs(last), now);
        if (!pending.Add(d, now) || pending.Due is not double due) return;
        tickTimer.Stop();
        tickTimer.Interval = TimeSpan.FromSeconds(Math.Max(0.01, due - now));
        tickTimer.Start();
    }

    void Lost(string reason, int c) {
        if (c != conn || target == null) return;
        Close();
        double delay = PushRule.RetryDelay(attempt++);
        var now = DateTime.UtcNow;
        if (HaErrorRule.ShouldLog(reason, lastReason, loggedAt is DateTime at ? (double?)Secs(at) : null, Secs(now))) {
            Log.Write(PushRule.LostLine(reason, delay));
            loggedAt = now;
        }
        lastReason = reason;
        retry.Interval = TimeSpan.FromSeconds(delay);
        retry.Start();
    }

    void Rejected(string why) {
        Close();
        stopped = true;
        Problem = PushRule.RejectedProblem;
        Log.Write(PushRule.RejectedLine(why));
        tick();   // shows the problem line
    }

    void Close() {
        conn++;
        awaitingPong = false;
        cts?.Cancel(); cts = null;   // not disposed: the receive loop may still hold its token
        try { ws?.Abort(); ws?.Dispose(); } catch { }
        ws = null; sendGate = null;
        retry.Stop(); ping.Stop(); pong.Stop(); tickTimer.Stop();
        pending.Clear();
        SetHealthy(false);
    }

    void SetHealthy(bool h) {
        if (Healthy == h) return;
        Healthy = h;
        HealthChanged?.Invoke();
    }

    static double Secs(DateTime t) => (t - DateTime.UnixEpoch).TotalSeconds;
}
