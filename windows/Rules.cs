// The decisions behind automatic brightness and light/dark mode, plus the sun and the Home Assistant
// template. No WPF, WinForms or Win32 here, so windows/tests runs them on any OS.
using System.Globalization;

namespace Daylit;

/// Solar elevation from latitude/longitude and the clock (low-precision almanac; within 0.05° of NOAA's reference values in the tests).
static class Sun {
    static double Rad(double d) => d * Math.PI / 180;
    static double Deg(double r) => r * 180 / Math.PI;
    static double Mod(double a, double m) => ((a % m) + m) % m;

    public static double Elevation(DateTimeOffset t, double lat, double lon) {
        double jd = t.ToUnixTimeMilliseconds() / 86400000.0 + 2440587.5, d = jd - 2451545.0;
        double g = Rad(Mod(357.529 + 0.98560028 * d, 360));
        double q = Mod(280.459 + 0.98564736 * d, 360);
        double L = Rad(q + 1.915 * Math.Sin(g) + 0.020 * Math.Sin(2 * g));
        double e = Rad(23.439 - 0.00000036 * d);
        double ra = Deg(Math.Atan2(Math.Cos(e) * Math.Sin(L), Math.Cos(L)));
        double dec = Math.Asin(Math.Sin(e) * Math.Sin(L));
        double gmst = Mod(18.697374558 + 24.06570982441908 * d, 24);
        double ha = Rad(gmst * 15 + lon - ra);
        return Deg(Math.Asin(Math.Sin(Rad(lat)) * Math.Sin(dec) + Math.Cos(Rad(lat)) * Math.Cos(dec) * Math.Cos(ha)));
    }

    /// How much daylight counts, 0..1: 0 below -3° elevation, 1 from 12°.
    public static double Fraction(double elev) => Math.Clamp((elev + 3) / 15, 0, 1);
}

/// What automatic mode remembers per monitor between ticks.
record struct Hold(double? RemoteSeen, int? LastSet, int? LastTarget);

/// The outcome of one tick for one monitor.
/// Current: the level after this tick; Write: what to send to the monitor; Remote: a "set" from HA that was applied.
record struct Step(Hold State, int Current, int? Write, int? Remote, int Applied, bool Manual);

static class Rules {
    /// v = [day, blindDown, night]. The daytime value slides between "blind down" and "blind up" with the
    /// blind position; the sun then blends it with the night value; room lights at night add a little.
    /// `boost`: room lights may lift the night level now (the sun is below tuning's lightsBoostSunBelow);
    /// without it, the default rule (daylight under 30%).
    public static int Target(double[] v, double pos, bool lights, double sun, Tuning? t = null, bool? boost = null) {
        double daytime = v[1] + (v[0] - v[1]) * pos / 100;
        double x = v[2] + (daytime - v[2]) * sun;
        if (lights && (boost ?? sun < 0.3)) x = Math.Max(x, v[2] + (t?.LightsBoost ?? 5));
        return (int)Math.Round(Math.Clamp(x, 0, 100), MidpointRounding.AwayFromZero);
    }

    /// One automatic decision for one monitor (Windows rules).
    /// - A change of the HA "set" helper applies once, even when this PC is idle, then is held like a
    ///   hand-set level. The value seen on the first look is not a command.
    /// - A level set by hand is kept until the target moves by `hold` points.
    /// - An idle PC (someone may be using the other machine on these monitors) writes nothing automatic.
    public static Step Decide(int c, int target, (double Value, double Changed)? remote, Hold s, bool auto, bool here, int hold) {
        int? write = null, remoteValue = null;
        bool fromRemote = false;
        if (remote is { } r) {
            if (s.RemoteSeen == null) s = s with { RemoteSeen = r.Changed };
            else if (r.Changed > s.RemoteSeen) {
                int v = (int)Math.Round(Math.Clamp(r.Value, 0, 100), MidpointRounding.AwayFromZero);
                if (c != v) write = v;
                c = v; fromRemote = true; remoteValue = v;
                s = s with { RemoteSeen = r.Changed, LastTarget = target, LastSet = v == target ? null : target };   // held as hand-set until the target moves
            }
        }
        int applied = c; bool manual = false;
        if (auto) {
            bool handSet = s.LastSet != null && c != s.LastSet;
            if (fromRemote || (handSet && Math.Abs(target - (s.LastTarget ?? target)) < hold)) manual = true;
            else if (here) {
                if (c != target) write = target;
                applied = target; c = target;
                s = s with { LastSet = target, LastTarget = target };
            }
        }
        return new Step(s, c, write, remoteValue, applied, manual);
    }

    /// "lights 80% white" / "lights 40% warm": the colour matters for light/dark mode, so show it.
    public static string LightsNote(bool lights, double bri, double sat, Tuning? t = null) {
        t ??= new Tuning();
        if (!lights) return "";
        if (bri <= 0) return " · lights on";
        string tone = sat <= t.WhiteSaturationMax ? " white" : sat > t.WarmSaturationMin ? " warm" : "";
        return $" · lights {(int)Math.Round(bri / 2.55)}%{tone}";
    }
}

/// Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
/// dark otherwise. Each condition has a gap between its on and off thresholds so it doesn't flip
/// back and forth; in the gap the previous answer stays.
sealed class LookRule {
    bool? daylight, whiteLights;
    public void Reset() { daylight = whiteLights = null; }

    /// lightsOn: the room lights are on and come from Home Assistant (bri 0-255, hs saturation 0 white … ~60+ warm).
    public bool WantDark(double elev, double pos, bool hasBlind, bool lightsOn, double bri, double sat, Tuning? t = null) {
        t ??= new Tuning();
        hasBlind &= t.Room; lightsOn &= t.Room;
        // Before any answer, the middle of each gap decides (3° and 50% with the defaults).
        // Before any answer, a point inside each gap decides (3° and 50% with the defaults).
        double midSun = (t.LightSunAbove + t.DarkSunBelow) / 2 + Math.Min(0.5, (t.LightSunAbove - t.DarkSunBelow) / 4);
        double midBlind = (t.LightBlindAbove + t.DarkBlindBelow) / 2 + Math.Min(5, (t.LightBlindAbove - t.DarkBlindBelow) / 4);
        daylight = hasBlind
            ? elev > t.LightSunAbove && pos >= t.LightBlindAbove ? true : elev < t.DarkSunBelow || pos <= t.DarkBlindBelow ? false : daylight ?? (elev > midSun && pos >= midBlind)
            : elev > t.LightSunAbove ? true : elev < t.DarkSunBelow ? false : daylight ?? elev > midSun;
        bool lit = lightsOn && bri > 0; double pct = bri / 2.55;
        whiteLights = lit && pct >= t.WhiteLightsAbove && sat <= t.WhiteSaturationMax ? true
                    : !lit || pct < t.WhiteLightsBelow || sat > t.WarmSaturationMin ? false : whiteLights ?? false;
        return !(daylight.Value || whiteLights.Value);
    }
}

/// The one Home Assistant template each tick sends to POST /api/template.
static class HaTemplate {
    static string Num(string? entity, double fallback) =>
        string.IsNullOrWhiteSpace(entity) ? fallback.ToString(CultureInfo.InvariantCulture)
                                          : $"{{{{ states('{entity}') | float({fallback.ToString(CultureInfo.InvariantCulture)}) }}}}";

    /// One row per monitor, in order; -1 marks "use the local number" (no entity, or the entity is unknown).
    public static string Build(HaConfig h0, IEnumerable<MonitorHa?> monitors0) {
        // Config.Validate already rejects bad ids; this second filter keeps any that slip through out of the Jinja.
        static string? Ok(string? e) => e != null && Config.IsEntityId(e) ? e : null;
        var h = new HaConfig { Url = h0.Url, TokenName = h0.TokenName, AutoSwitch = Ok(h0.AutoSwitch), Sun = Ok(h0.Sun), Cover = Ok(h0.Cover), Lights = Ok(h0.Lights) };
        var monitors = monitors0.Select(m => m == null ? null : new MonitorHa {
            Sensor = Ok(m.Sensor), Day = Ok(m.Day), BlindDown = Ok(m.BlindDown), Night = Ok(m.Night), Set = Ok(m.Set) });
        string pos = h.Cover is { Length: > 0 } cv ? $"state_attr('{cv}','current_position') | float(100)" : "100";
        string lights = h.Lights is { Length: > 0 } l ? $"is_state('{l}','on') | tojson" : "false | tojson";   // bare false renders as Python False
        string bri = h.Lights is { Length: > 0 } l2 ? $"state_attr('{l2}','brightness') | float(0)" : "0";
        string sat = h.Lights is { Length: > 0 } l3 ? $"(state_attr('{l3}','hs_color') or [0, 100])[1] | float(100)" : "100";
        string auto = h.AutoSwitch is { Length: > 0 } a ? $"{{{{ is_state('{a}','on') | tojson }}}}" : "null";
        string mons_ = string.Join(", ", monitors.Select(e => {
            string set = e?.Set is { Length: > 0 } st
                ? $"{Num(st, -1)}, {{{{ as_timestamp(states.{st}.last_changed) if states.{st} else 0 }}}}" : "-1, 0";   // states.domain.name: None when missing
            return $"[{Num(e?.Day, -1)}, {Num(e?.BlindDown, -1)}, {Num(e?.Night, -1)}, {set}]";
        }));
        string sun = string.IsNullOrWhiteSpace(h.Sun) ? "sun.sun" : h.Sun!;
        return $$$"""
            {"elev": {{ state_attr('{{{sun}}}','elevation') | float(-10) }},
             "pos": {{ {{{pos}}} }},
             "lights": {{ {{{lights}}} }},
             "auto": {{{auto}}},
             "m": [{{{mons_}}}],
             "bri": {{ {{{bri}}} }},
             "sat": {{ {{{sat}}} }} }
            """;
    }
}

/// Whether a DDC monitor reports its brightness. Some monitors accept DDC writes but never answer
/// reads; they stay usable as "write-only", with the slider as the only record of their level.
enum ReadState {
    Unknown,    // no successful read yet since it was detected
    Readable,   // has answered a read (a later failure means it is showing another computer)
    WriteOnly,  // never answered a read, but accepted a write the user made here
    Silent,     // never answered a read and refused a write: not controllable from here
}

static class ReadRules {
    public static ReadState AfterRead(this ReadState s, bool ok) => ok ? ReadState.Readable : s;
    /// Only a user action (slider or hotkey) can turn an unreadable monitor into a write-only one: it
    /// proves the monitor is showing this PC, so the automatic writes that follow can't fight the Mac.
    public static ReadState AfterUserWrite(this ReadState s, bool ok) =>
        s is ReadState.Unknown or ReadState.Silent ? (ok ? ReadState.WriteOnly : ReadState.Silent) : s;
    /// The level automatic mode treats as current: the reading, or for a write-only monitor the slider.
    public static int? Current(this ReadState s, int? reading, int slider) =>
        reading ?? (s == ReadState.WriteOnly ? slider : null);
    public static bool Usable(this ReadState s) => s != ReadState.Silent;
}

/// "Sync monitors": every external monitor keeps the offset it had when sync was switched on, so
/// moving one moves the others by the same amount. Offsets are relative to a shared base level; any
/// monitor in the group can set the base, so the group survives one monitor being unplugged.
sealed class SyncOffsets {
    public Dictionary<string, int> Offsets { get; set; } = new();
    /// Monitors taken out of the group by hand; they are not adopted again until they rejoin.
    public HashSet<string> Excluded { get; set; } = new();
    public SyncOffsets() { }

    public bool IsMember(string key) => Offsets.ContainsKey(key);
    /// Takes a monitor out of the group. Offsets are measured from a virtual base, not from one monitor,
    /// so the others keep theirs and nothing moves.
    public void Leave(string key) { Offsets.Remove(key); Excluded.Add(key); }
    /// Puts a monitor back at its current offset from the group (`levels` are the connected monitors').
    public void Join(string key, IReadOnlyList<(string Key, int Level)> levels) { Excluded.Remove(key); Adopt(levels); }
    public int Members(IEnumerable<string> keys) => keys.Count(IsMember);

    /// Captures the current levels; the first monitor's level is the base (its offset is 0).
    public static SyncOffsets Capture(IEnumerable<(string Key, int Level)> levels) {
        var s = new SyncOffsets(); int? first = null;
        foreach (var (k, l) in levels) { first ??= l; s.Offsets[k] = l - first.Value; }
        return s;
    }

    public int? Base(string key, int level) => Offsets.TryGetValue(key, out var o) ? level - o : null;
    /// Clamped to 0..100; the stored offset is kept, so the monitors line up again when the base moves back.
    public int? Level(string key, int b) => Offsets.TryGetValue(key, out var o) ? Math.Clamp(b + o, 0, 100) : null;

    /// Adds monitors that joined after sync was switched on, at their current offset from the group.
    /// If none of the connected monitors is in the group, the group starts again from these levels.
    /// Returns whether anything changed.
    public bool Adopt(IReadOnlyList<(string Key, int Level)> levels) {
        levels = levels.Where(l => !Excluded.Contains(l.Key)).ToList();
        var known = levels.FirstOrDefault(l => Offsets.ContainsKey(l.Key));
        if (known.Key == null) {
            var fresh = Capture(levels);
            bool changed = !fresh.Offsets.OrderBy(p => p.Key).SequenceEqual(Offsets.OrderBy(p => p.Key));
            Offsets = fresh.Offsets;
            return changed;
        }
        int b = Base(known.Key, known.Level)!.Value; bool any = false;
        foreach (var (k, l) in levels) if (!Offsets.ContainsKey(k)) { Offsets[k] = l - b; any = true; }
        return any;
    }

    /// One monitor was moved by hand to `level`: the levels for the other monitors in `keys`.
    public Dictionary<string, int> Follow(string key, int level, IEnumerable<string> keys) {
        var r = new Dictionary<string, int>();
        if (Base(key, level) is not int b) return r;
        foreach (var k in keys) if (k != key && Level(k, b) is int v) r[k] = v;
        return r;
    }

    /// Automatic mode: the first connected monitor's target drives the group (the leader keeps its own).
    public Dictionary<string, int> Targets(string leader, int leaderTarget, IEnumerable<string> keys) {
        var r = new Dictionary<string, int>();
        if (Base(leader, leaderTarget) is not int b) return r;
        r[leader] = leaderTarget;
        foreach (var k in keys) if (k != leader && Level(k, b) is int v) r[k] = v;
        return r;
    }
}

/// Hand-set state kept across restarts, so quitting or rebooting does not jump every monitor back to
/// the automatic target. Saved per monitor (its stable key) with the time it was saved; an entry older
/// than MaxAge is forgotten, since the target has moved on by then anyway.
sealed class SavedHolds {
    public sealed record Entry(int? LastSet, int? LastTarget, double Saved);
    public static readonly double MaxAge = 12 * 3600;
    public Dictionary<string, Entry> Entries { get; set; } = new();

    /// Records a monitor's state; one with nothing to remember is removed. Returns whether it changed.
    public bool Record(string key, int? lastSet, int? lastTarget, double now) {
        if (lastSet == null && lastTarget == null) return Entries.Remove(key);
        if (Entries.TryGetValue(key, out var e) && e.LastSet == lastSet && e.LastTarget == lastTarget) return false;   // keep "last decided" time
        Entries[key] = new Entry(lastSet, lastTarget, now);
        return true;
    }
    /// The state to start a monitor with after a restart, or null when there is none or it is too old.
    public (int? LastSet, int? LastTarget)? Restore(string key, double now, double? maxAge = null) =>
        Entries.TryGetValue(key, out var e) && now >= e.Saved && now - e.Saved <= (maxAge ?? MaxAge) ? (e.LastSet, e.LastTarget) : null;

    public string ToJson() => System.Text.Json.JsonSerializer.Serialize(Entries);
    public static SavedHolds FromJson(string? json) {
        try { return new SavedHolds { Entries = json == null ? new() : System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, Entry>>(json) ?? new() }; }
        catch { return new SavedHolds(); }
    }
}

/// Home Assistant errors. A connection that fails right after start, wake or a network switch usually
/// works a few seconds later, so it is retried quickly and only shown once Home Assistant has been
/// unreachable for a while. A rejected or missing token will not fix itself and shows at once.
public static class HaErrorRule {
    public static readonly double[] RetryDelays = { 2, 5 };
    public const double ShowAfter = 60;
    public static bool ShouldShow(bool transient, double? downSince, double now) =>
        !transient || (downSince is double since && now - since >= ShowAfter);
}
