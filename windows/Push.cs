// Push updates from Home Assistant (experimental, config homeAssistant.push): the WebSocket only says *when*
// to tick; the tick still reads everything through the REST template. Twin of mac/Sources/DaylitCore/Push.swift.
// No WPF or Win32 here: the test project compiles this file. The socket itself is PushClient.cs.
using System.Text.Json;

namespace Daylit;

enum PushKind { AuthRequired, AuthOk, AuthInvalid, Result, Event, Pong, Other }

/// One message from Home Assistant's WebSocket API, reduced to what Daylit needs. `Ids`: for an event, the entity
/// ids it added (`a`), changed (`c`) or removed (`r`).
sealed record PushMessage(PushKind Kind, string? Reason = null, int Id = 0, bool Ok = false, IReadOnlySet<string>? Ids = null) {
    public static readonly PushMessage Other = new(PushKind.Other);
}

enum PushTickKind { Now, After, Ignore }

/// What a set of changed entities asks for: a tick after the 1 s debounce, one in `Seconds`, or nothing.
readonly record struct PushTick(PushTickKind Kind, double Seconds = 0) {
    public static readonly PushTick Now = new(PushTickKind.Now);
    public static readonly PushTick Ignore = new(PushTickKind.Ignore);
    public static PushTick After(double seconds) => new(PushTickKind.After, seconds);
}

static class PushRule {
    /// A burst of changes within this many seconds runs one tick.
    public const double Debounce = 1;
    /// The daylight sensor alone ticks at most this often (it can report every few seconds).
    public const double DaylightEvery = 60;
    /// While the socket is connected and subscribed, polling is only the safety net.
    public const double HealthyPollSeconds = 300;
    /// An application ping this often; no pong within PongTimeout means the connection is gone.
    public const double PingEvery = 60, PongTimeout = 10;
    /// Home Assistant's own protocol ping is answered by the system and cannot be seen by the app, so it does not tell
    /// Daylit the link is dead; our ping does. On battery it runs half as often, to wake the PC less.
    public static double PingInterval(bool onBattery) => onBattery ? 2 * PingEvery : PingEvery;
    /// auth_ok must arrive this many seconds after connecting (auth_required, the auth message and the answer), or the
    /// connection counts as lost.
    public const double AuthTimeout = 10;
    /// Waits before each reconnect attempt; the last one repeats.
    public static readonly double[] Backoff = [2, 5, 15, 60];

    /// `ws(s)://<host>/api/websocket` from homeAssistant.url, or null when it is not an http(s) URL.
    public static Uri? SocketUrl(string? http) {
        if (!Uri.TryCreate(http?.Trim(), UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host)) return null;
        string? scheme = u.Scheme switch { "http" => "ws", "https" => "wss", _ => null };   // Uri lower-cases the scheme
        if (scheme == null) return null;
        // Authority is host[:port] without credentials, brackets kept for IPv6, the port only when not the scheme's default.
        string path = u.AbsolutePath.TrimEnd('/') + "/api/websocket";
        return new Uri($"{scheme}://{u.Authority}{path}");
    }

    /// Every entity the tick reads, once each, sorted: the HA-wide ones (the sun is sun.sun when unset or not an
    /// entity id, as in the template) and each configured monitor's helpers. Never a monitor's `sensor`: Daylit
    /// publishes it, so following it would make every publish trigger another tick.
    public static string[] Entities(Config c) {
        if (c.HomeAssistant is not { } ha) return [];
        string sun = ha.Sun is { } s && Config.IsEntityId(s) ? s : "sun.sun";
        var ids = new List<string?> { ha.AutoSwitch, sun, ha.Cover, ha.Lights, ha.Light };
        foreach (var m in c.Monitors ?? [])
            if (m?.HomeAssistant is { } h) ids.AddRange([h.Day, h.BlindDown, h.Night, h.NightLights, h.Set]);
        return ids.OfType<string>().Where(i => i.Length > 0 && Config.IsEntityId(i)).Distinct().OrderBy(i => i, StringComparer.Ordinal).ToArray();
    }

    /// One incoming text frame. Anything unexpected (bad JSON, a list, an unknown type) is Other.
    public static PushMessage Parse(string text) {
        try {
            using var doc = JsonDocument.Parse(text);
            var o = doc.RootElement;
            if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String)
                return PushMessage.Other;
            switch (type.GetString()) {
                case "auth_required": return new(PushKind.AuthRequired);
                case "auth_ok": return new(PushKind.AuthOk);
                case "auth_invalid":
                    return new(PushKind.AuthInvalid, Reason: o.TryGetProperty("message", out var why) && why.ValueKind == JsonValueKind.String ? why.GetString() : "");
                case "pong": return new(PushKind.Pong);
                case "result":
                    if (o.TryGetProperty("id", out var idEl) && idEl.ValueKind == JsonValueKind.Number && idEl.TryGetInt32(out var idNum)
                        && o.TryGetProperty("success", out var okEl) && (okEl.ValueKind is JsonValueKind.True or JsonValueKind.False))
                        return new(PushKind.Result, Id: idNum, Ok: okEl.GetBoolean());
                    return PushMessage.Other;
                case "event":
                    if (!o.TryGetProperty("event", out var ev) || ev.ValueKind != JsonValueKind.Object) return PushMessage.Other;
                    var ids = new HashSet<string>();
                    if (ev.TryGetProperty("a", out var added) && added.ValueKind == JsonValueKind.Object)
                        foreach (var p in added.EnumerateObject()) ids.Add(p.Name);
                    if (ev.TryGetProperty("c", out var changed) && changed.ValueKind == JsonValueKind.Object)
                        foreach (var p in changed.EnumerateObject()) ids.Add(p.Name);
                    if (ev.TryGetProperty("r", out var removed) && removed.ValueKind == JsonValueKind.Array)
                        foreach (var x in removed.EnumerateArray()) if (x.ValueKind == JsonValueKind.String) ids.Add(x.GetString()!);
                    return new(PushKind.Event, Ids: ids);
                default: return PushMessage.Other;
            }
        } catch (JsonException) { return PushMessage.Other; }
    }

    /// The answer to auth_required. The token goes only here: never into a URL, a log line or an error.
    public static string AuthMessage(string token) => JsonSerializer.Serialize(new { type = "auth", access_token = token });
    public static string SubscribeMessage(int id, IReadOnlyList<string> entities) =>
        JsonSerializer.Serialize(new { id, type = "subscribe_entities", entity_ids = entities });
    public static string PingMessage(int id) => JsonSerializer.Serialize(new { id, type = "ping" });

    /// Whether these changes need a tick. `daylight` is homeAssistant.light; `lastTick` is when the last tick ran
    /// (Unix seconds; any tick reads the daylight sensor too).
    public static PushTick Decide(IEnumerable<string> changed, IReadOnlySet<string> subscribed, string? daylight, double? lastTick, double now,
                                  double every = DaylightEvery) {
        var relevant = changed.Where(subscribed.Contains).ToHashSet();
        if (relevant.Count == 0) return PushTick.Ignore;
        if (daylight != null && relevant.Count == 1 && relevant.Contains(daylight)) {
            if (lastTick is not double last) return PushTick.Now;
            double wait = every - (now - last);
            return wait <= 0 ? PushTick.Now : PushTick.After(wait);
        }
        return PushTick.Now;
    }

    /// How often the daylight sensor alone may tick: a minute, or the normal poll interval when that is longer
    /// (battery: BatteryPollSeconds), so push never ticks more than polling would on battery.
    public static double DaylightLimit(bool onBattery, Tuning t) => Math.Max(DaylightEvery, onBattery ? t.BatteryPollSeconds : t.PollSeconds);

    /// The wait before reconnect attempt `attempt` (0 = the first after a drop).
    public static double RetryDelay(int attempt) => Backoff[Math.Clamp(attempt, 0, Backoff.Length - 1)];

    /// The poll interval: today's while the socket is not healthy, else 300 s (or the configured one when longer).
    public static double PollInterval(bool healthy, bool onBattery, Tuning t) {
        double normal = onBattery ? t.BatteryPollSeconds : t.PollSeconds;
        return healthy ? Math.Max(HealthyPollSeconds, normal) : normal;
    }

    /// Whether the socket should be open: push on, Home Assistant the source, Automatic on, not paused on battery,
    /// and a monitor to drive.
    public static bool Wanted(bool? push, Source source, bool paused, bool auto, bool hasMonitors) =>
        push == true && source == Source.HomeAssistant && !paused && auto && hasMonitors;

    /// The log lines (Log.Write adds the time). None of them can carry the token.
    public static string ConnectedLine(int count) => $"push: connected ({count} entities)";
    public static string LostLine(string reason, double retryIn) => $"push: lost ({reason}), retrying in {(int)retryIn}s";
    public static string RejectedLine(string reason) => $"push: token rejected ({reason}), not retrying until the token or config changes";
    public const string OffLine = "push: off";
    /// The problem line shown in the panel after auth_invalid, like the REST token errors.
    public const string RejectedProblem = "Home Assistant rejected the token (push updates)";
}

/// The one pending push tick. A change asks for a tick in 1 s; each further change before it fires pushes it back
/// to 1 s after that change (a real debounce), but never later than 3 s after the first change, so a steady stream
/// still ticks every 3 s. A daylight-only change waits for its limit, unless a tick is already due.
sealed class PushTimer {
    public const double MaxWait = 3;
    public double? Due { get; private set; }
    double first;
    bool immediate;   // the pending tick is a debounce window, not a daylight wait
    /// Adds a request; true when Due moved, so the caller restarts its timer.
    public bool Add(PushTick t, double now) {
        switch (t.Kind) {
            case PushTickKind.Ignore: return false;
            case PushTickKind.Now:
                if (immediate && Due is double d) {
                    double at = Math.Min(now + PushRule.Debounce, first + MaxWait);
                    if (at <= d) return false;
                    Due = at; return true;
                }
                first = now; immediate = true; Due = now + PushRule.Debounce;
                return true;
            default:
                double later = now + Math.Max(t.Seconds, PushRule.Debounce);
                if (Due is double due && due <= later) return false;
                if (Due == null) { first = now; immediate = false; }
                Due = later; return true;
        }
    }
    /// The timer fired (or the socket closed): nothing pending.
    public void Clear() { Due = null; immediate = false; }
}
