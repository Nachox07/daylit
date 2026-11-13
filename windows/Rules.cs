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

    /// When the sun is at or above `line` today (or below it, with `below`), in the order it happens, from
    /// a day of evenly spaced samples (t: 0 = the midnight it starts at, 1 = the next one). Usually one span
    /// from rise to set, but near the poles the sun can dip under a line after midnight and come back,
    /// so "above" is then the day's two ends.
    public static List<(double From, double To)> Spans(IReadOnlyList<(double t, double e)> s, double line, bool below = false) {
        var spans = new List<(double From, double To)>();
        if (s.Count == 0) return spans;
        bool Inside(double x) => below ? x < line : x >= line;
        double? start = Inside(s[0].e) ? s[0].t : null;
        for (int i = 1; i < s.Count; i++) {
            var (a, b) = (s[i - 1], s[i]);
            if (Inside(a.e) == Inside(b.e)) continue;
            double t = a.t + (b.t - a.t) * (line - a.e) / (b.e - a.e);   // a crossing: a.e and b.e differ
            if (start is double st) { spans.Add((st, t)); start = null; } else start = t;
        }
        if (start is double st2) spans.Add((st2, s[^1].t));
        return spans;
    }

    /// "06:52 – 21:14", "until 06:52 · from 21:14", "all day" or "not today" for those spans.
    public static string SpanLabel(IReadOnlyList<(double From, double To)> spans, Func<double, string> clock) =>
        spans.Count == 0 ? "not today" : string.Join(" · ", spans.Select(sp => (sp.From <= 0, sp.To >= 1) switch {
            (true, true) => "all day",
            (true, false) => $"until {clock(sp.To)}",
            (false, true) => $"from {clock(sp.From)}",
            _ => $"{clock(sp.From)} – {clock(sp.To)}",
        }));
}

/// What automatic mode remembers per monitor between ticks.
/// Offset: a hand-set level as its distance from the target; OffsetSun: the daylight fraction when it was set;
/// OffsetAt: when (Unix seconds).
/// RemoteValue: the "set" helper's value when RemoteSeen was taken (a restart of Home Assistant bumps last_changed alone).
record struct Hold(double? RemoteSeen, int? LastSet, int? LastTarget, int? Offset = null, double? OffsetSun = null, double? OffsetAt = null,
                   double? RemoteValue = null);

/// The outcome of one tick for one monitor.
/// Current: the level after this tick; Write: what to send to the monitor; Remote: a "set" from HA that was applied.
record struct Step(Hold State, int Current, int? Write, int? Remote, int Applied, bool Manual);

static class Rules {
    /// v = [day, blindDown, night], or with a fourth, nightLights (the level with the room lights on after sunset). The daytime value slides between "blind down" and "blind up" with the
    /// blind position; the sun then blends it with the night value; room lights at night add a little.
    /// `boost`: room lights may lift the night level now (the sun is below tuning's lightsBoostSunBelow);
    /// without it, the default rule (daylight under 30%).
    /// `light` (0…1, see LightRules.Cap) is the most daylight can count under a cloudy sky; 1 without a sensor.
    /// The blind position to use: a blind that drops off Home Assistant for a moment keeps its last
    /// known position instead of counting as fully open; with none seen yet it counts as open.
    public static double BlindPosition(double reported, double? last) => reported >= 0 ? Math.Min(reported, 100) : last ?? 100;

    /// A brightness level as a finite 0–100: out of range is clamped, infinity counts as the nearest end,
    /// and NaN as 0 (a level that is not a number must never reach the formula).
    public static double ClampLevel(double v) => double.IsNaN(v) ? 0 : Math.Clamp(v, 0, 100);

    public static int Target(double[] v0, double pos, bool lights, double sun, Tuning? t = null, bool? boost = null, double light = 1) {
        var v = v0.Select(ClampLevel).ToArray();
        pos = ClampLevel(pos);
        if (double.IsNaN(light)) light = 1;   // a light scale that is not a number caps nothing
        if (double.IsNaN(sun)) sun = 0;
        double daytime = v[1] + (v[0] - v[1]) * pos / 100;
        double share = Math.Min(sun, light);
        double x;
        if (NightLightsLevel(v) is double nl) {
            // A monitor with its own lit-evening level: weak daylight blends toward night with the lights off.
            // With them on it blends toward a point that slides from night (sun high) to nightLights (sun down),
            // so the lamps change nothing in daylight and there is no step at dusk. No boost.
            double anchor = lights ? v[2] * sun + nl * (1 - sun) : v[2];
            x = anchor + (daytime - anchor) * share;
        } else {
            x = v[2] + (daytime - v[2]) * share;
            if (lights && (boost ?? sun < 0.3)) x = Math.Max(x, v[2] + (t?.LightsBoost ?? 5));
        }
        if (!double.IsFinite(x)) return (int)Math.Round(v[2], MidpointRounding.AwayFromZero);   // last guard: the night level
        return (int)Math.Round(Math.Clamp(x, 0, 100), MidpointRounding.AwayFromZero);
    }

    /// Automatic mode while Home Assistant does not answer (the sun fallback). With an autoSwitch it keeps the
    /// last state Home Assistant gave, so an outage never turns Automatic on or off; without a switch, or before
    /// one was ever seen, the local setting decides.
    public static bool AutomaticFallback(bool hasSwitch, bool? lastFromHa, bool local) => hasSwitch ? lastFromHa ?? local : local;

    /// Automatic mode on a tick Home Assistant answered. Its switch decides when it gave a value; a switch it gave
    /// none for (a missing entity, `unavailable`) leaves Automatic as it was, the same as during an outage.
    public static bool AutomaticNow(bool hasSwitch, bool? fromHa, bool? lastFromHa, bool local) =>
        fromHa ?? AutomaticFallback(hasSwitch, lastFromHa, local);

    /// The Automatic state saved from Home Assistant counts only for the autoSwitch it was seen on: a different
    /// entity in the config (or an older save with none recorded) starts again from the local setting.
    public static bool? StoredAutomatic(bool? value, string? entity, string? configured) =>
        !string.IsNullOrEmpty(configured) && entity == configured ? value : null;

    /// The nightLights level in a monitor's levels in effect (a fourth number, 0 or more); null when it has none.
    public static double? NightLightsLevel(double[] v) => v.Length > 3 && v[3] >= 0 ? (double?)v[3] : null;

    /// The room lights for one monitor this tick. Home Assistant's answer while it gives one. In the sun fallback
    /// a monitor with a nightLights level keeps the last state seen (`last`; off when none was seen), as the blind
    /// keeps its last position, so a lit evening does not drop to night during an outage. Every other monitor
    /// counts the lights as off there, as before.
    public static bool RoomLights(bool reported, bool fromHa, bool? last, bool hasNightLights) =>
        fromHa ? reported : hasNightLights && (last ?? false);

    /// How much of a hand-set offset applies (0…1) for the sun now, or null once it is over.
    /// One set by day fades out as the sun goes down and has no effect at night; it ends with the day
    /// (OffsetExpired), so tomorrow starts clean. One set at night ends as the sun comes up. Either way
    /// over 0.3 of the daylight fraction (about half an hour). A daytime one never fades faster than that
    /// half hour from when it was set (`age`, seconds): one set in the last light would otherwise be gone in minutes.
    public static double? OffsetWeight(double sun, double setAt, double? age = null) {
        const double edge = NightOffsetEdge, fade = 1800;
        if (setAt > 0) {
            double w = Math.Min(1, Math.Max(0, sun) / Math.Min(edge, setAt));
            return age is double a && a >= 0 && a < fade ? Math.Max(w, 1 - a / fade) : w;
        }
        return sun >= edge ? null : 1 - sun / edge;
    }

    /// The longest a hand-set offset can live, whatever the sky does (a polar night or day never ends it).
    public const double OffsetMaxAge = 36 * 3600;
    /// A daytime offset older than this when the calendar day changes ends even with the sun up
    /// (a PC that slept through the night wakes into a new day).
    const double DayOffsetCarryOver = 12 * 3600;
    /// The daylight fraction where a night offset has faded out completely.
    public const double NightOffsetEdge = 0.3;

    /// A night offset without a location ends after this long (longer than any night but a polar one).
    const double NightOffsetFallback = 18 * 3600;
    /// How often the sun is sampled between setting an offset and now.
    const double OffsetSampleStep = 600;

    /// An offset that no longer applies, even when no tick ran in between (the PC slept).
    /// With a location it is decided from what the sun did between `OffsetAt` and `now`, sampled every
    /// 10 minutes, not from the current tick: one set at night ends once daylight reached the fade edge
    /// (OffsetWeight) at any point since, so sleeping through a sunrise cannot keep it, while a polar night
    /// does; one set by day ends with the calendar day if the sun set in between, and only a polar day
    /// (the sun never went down) carries it over midnight, for at most 12 hours. Without a location
    /// (possible with Home Assistant as the source) a night offset ends after 18 hours and a day one with
    /// the calendar day. Every offset ends after 36 hours. `dayOf` gives the local calendar day of a Unix
    /// time; `sun` is the daylight fraction now.
    public static bool OffsetExpired(Hold s, double now, double sun, Func<double, int> dayOf, (double Lat, double Lon)? place = null, Tuning? tuning = null) {
        if (s.Offset == null || s.OffsetAt is not double at || now <= 0) return false;
        double age = now - at;
        if (age > OffsetMaxAge) return true;
        bool byDay = (s.OffsetSun ?? 0) > 0, newDay = dayOf(now) != dayOf(at);
        if (place is not { } p) return byDay ? newDay : age > NightOffsetFallback;
        var t = tuning ?? new Tuning();
        double lowest = sun, highest = sun;
        for (double x = at; x < now; x += OffsetSampleStep) {
            double f = t.Fraction(Sun.Elevation(DateTimeOffset.FromUnixTimeMilliseconds((long)(x * 1000)), p.Lat, p.Lon));
            lowest = Math.Min(lowest, f); highest = Math.Max(highest, f);
        }
        if (byDay) return newDay && (lowest <= 0 || age > DayOffsetCarryOver);
        return highest >= NightOffsetEdge;
    }

    /// Seconds since the hand-set offset was set; null when unknown.
    static double? OffsetAge(Hold s, double now) => now > 0 && s.OffsetAt is double at ? now - at : null;

    /// The local calendar day of a Unix time.
    public static int LocalDay(double t) => DateOnly.FromDateTime(DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000)).LocalDateTime).DayNumber;

    /// Which brightness a tick should trust after it waited (the monitor read, a write to another monitor).
    /// `atRead` is the level the model held before the wait, `now` what it holds after it. A level that
    /// moved in between came from the user's hand (slider, keys); it is newer than the reading, so it
    /// wins. `held`: the slider is in the user's hand, or was just now (the panel's 1.5 s grace).
    public static bool UserLevelWins(int? atRead, int? now, bool held) => now != null && (held || atRead != now);

    /// The level a tick decides on for one monitor: the model's level when the user set one after the
    /// reading (see UserLevelWins), else the reading.
    public static int? LevelToDecideOn(int? read, int? atRead, int? model, bool held) => UserLevelWins(atRead, model, held) ? model : read;

    /// The level to store after a write of `newLevel`; null keeps the current one. A refused write changes
    /// nothing, and a level the user set while Daylit was writing (or a held slider) is newer than the write.
    public static int? LevelAfterWrite(int? newLevel, bool ok, int? atStart, int? now, bool held) =>
        ok && newLevel != null && !UserLevelWins(atStart, now, held) ? newLevel : null;

    /// One automatic decision for one monitor (Windows rules).
    /// - A change of the HA "set" helper applies once, even when this PC is idle, then is followed like a
    ///   hand-set level. The value seen on the first look is not a command, nor is the same value again
    ///   (a restart of Home Assistant gives the helper a new last_changed).
    /// - A level set by hand keeps its distance from the target: set 52 when the target is 76 and the
    ///   screen follows the target 24 points lower as the blind opens and the sun rises. The distance
    ///   fades at dusk and ends at night (OffsetWeight); a new hand-set level replaces it.
    /// - An idle PC (someone may be using the other machine on these monitors) writes nothing automatic.
    public static Step Decide(int c, int target, (double Value, double Changed)? remote, Hold s, bool auto, bool here, double sun, bool touched = true,
                              bool dragging = false, double now = 0, Func<double, int>? dayOf = null,
                              (double Lat, double Lon)? place = null, Tuning? tuning = null) {
        int? write = null, remoteValue = null;
        bool fromRemote = false;
        if (remote is { } r) {
            if (s.RemoteSeen == null) s = s with { RemoteSeen = r.Changed, RemoteValue = r.Value };
            else if (r.Changed > s.RemoteSeen && s.RemoteValue == r.Value) s = s with { RemoteSeen = r.Changed };
            else if (r.Changed > s.RemoteSeen) {
                int v = (int)Math.Round(Math.Clamp(r.Value, 0, 100), MidpointRounding.AwayFromZero);
                if (c != v) write = v;
                c = v; fromRemote = true; remoteValue = v;
                s = s with { RemoteSeen = r.Changed, RemoteValue = r.Value, LastTarget = target, LastSet = v, Offset = v == target ? null : v - target, OffsetSun = sun, OffsetAt = now };
            }
        }
        int applied = c;
        if (here && OffsetExpired(s, now, sun, dayOf ?? LocalDay, place, tuning)) s = s with { Offset = null, OffsetSun = null, OffsetAt = null };
        if (auto && !fromRemote && here && !dragging) {
            if (s.LastSet is int last && c != last) {
                if (touched || Math.Abs(c - last) > 1)   // moved by hand since the last tick
                    s = s with { Offset = c == target ? null : c - target, OffsetSun = sun, OffsetAt = now };
                else c = last;   // a reading 1 off what Daylit wrote, with no hand on it: the monitor rounding
            }
            int level = target;
            if (s.Offset is int o) {
                if (OffsetWeight(sun, s.OffsetSun ?? sun, OffsetAge(s, now)) is double w)
                    level = Math.Clamp(target + (int)Math.Round(o * w, MidpointRounding.AwayFromZero), 0, 100);
                else s = s with { Offset = null, OffsetSun = null, OffsetAt = null };
            }
            if (c != level) write = level;
            applied = level; c = level;
            s = s with { LastSet = level, LastTarget = target };
        }
        // The badge shows only while the offset changes something (a daytime one rests at night).
        double weight = s.Offset == null ? 0 : OffsetWeight(sun, s.OffsetSun ?? sun, OffsetAge(s, now)) ?? 0;
        return new Step(s, c, write, remoteValue, applied, s.Offset != null && (fromRemote || (auto && weight > 0)));
    }

    /// After a tick sent a level to the monitor (`before`: the state that tick started from). A refused
    /// write applied nothing, so forget it: otherwise the next tick reads the old level, takes the gap
    /// for a hand-set change and stops retrying. A Home Assistant "set" it carried stays pending, so
    /// the next tick applies it again too.
    public static Hold AfterWrite(Hold s, bool ok, Hold before) => ok ? s : s with { LastSet = null, RemoteSeen = before.RemoteSeen, RemoteValue = before.RemoteValue };

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
    /// previous: what the OS shows now (dark = true), passed while there is no earlier answer (start,
    /// config reload, feature switched on). Inside a gap it fills the missing answer so the result
    /// keeps the OS as it is; outside a gap it is ignored. null: a point inside each gap decides.
    public bool WantDark(double elev, double pos, bool hasBlind, bool lightsOn, double bri, double sat, Tuning? t = null, bool? previous = null) {
        t ??= new Tuning();
        hasBlind &= t.Room; lightsOn &= t.Room;
        // Each condition's answer when the sample is outside its gap; null inside it.
        bool? dayNow = hasBlind
            ? elev > t.LightSunAbove && pos >= t.LightBlindAbove ? true : elev < t.DarkSunBelow || pos <= t.DarkBlindBelow ? false : null
            : elev > t.LightSunAbove ? true : elev < t.DarkSunBelow ? false : null;
        bool lit = lightsOn && bri > 0; double pct = bri / 2.55;
        bool? whiteNow = lit && pct >= t.WhiteLightsAbove && sat <= t.WhiteSaturationMax ? true
                       : !lit || pct < t.WhiteLightsBelow || sat > t.WarmSaturationMin ? false : null;
        // In a gap with no earlier answer, take the one that keeps the OS as it is (light: true, dark: false).
        // A condition is left to the default below when the other one already decides the result.
        if (previous is bool dark) {
            bool fillDay = dayNow == null && daylight == null, fillWhite = whiteNow == null && whiteLights == null;
            if (fillDay && (!dark || fillWhite || (whiteNow ?? whiteLights) == false)) daylight = !dark;
            if (fillWhite && (!dark || fillDay || (dayNow ?? daylight) == false)) whiteLights = !dark;
        }
        // Before any answer, a point inside each gap decides (3° and 50% with the defaults).
        double midSun = (t.LightSunAbove + t.DarkSunBelow) / 2 + Math.Min(0.5, (t.LightSunAbove - t.DarkSunBelow) / 4);
        double midBlind = (t.LightBlindAbove + t.DarkBlindBelow) / 2 + Math.Min(5, (t.LightBlindAbove - t.DarkBlindBelow) / 4);
        bool day = dayNow ?? daylight ?? (elev > midSun && (!hasBlind || pos >= midBlind));
        bool white = whiteNow ?? whiteLights ?? false;
        daylight = day; whiteLights = white;
        return !(day || white);
    }
}

/// The one Home Assistant template each tick sends to POST /api/template.
static class HaTemplate {
    /// The configured entities Home Assistant does not have, as far as an answer shows: the autoSwitch (its
    /// `auto` came back null) and the sun entity (its `elev` came back null).
    public static List<string> Missing(HaConfig h, bool elevMissing, bool autoMissing) {
        var r = new List<string>();
        if (!string.IsNullOrEmpty(h.AutoSwitch) && autoMissing) r.Add(h.AutoSwitch);
        if (elevMissing) r.Add(string.IsNullOrWhiteSpace(h.Sun) ? "sun.sun" : h.Sun!);
        return r;
    }

    /// The problem line for those entities, or null when none is missing.
    public static string? NoValueNote(IReadOnlyList<string> ids) => ids.Count == 0 ? null : "Home Assistant gives no value for " + string.Join(", ", ids) + " (missing or unavailable)";

    /// The problem line: a config problem first (the user fixes the file), else the missing entities.
    public static string? ProblemLine(string? config, IReadOnlyList<string> missing) => config ?? NoValueNote(missing);

    static string Num(string? entity, double fallback) =>
        string.IsNullOrWhiteSpace(entity) ? fallback.ToString(CultureInfo.InvariantCulture)
                                          : $"{{{{ states('{entity}') | float({fallback.ToString(CultureInfo.InvariantCulture)}) }}}}";

    /// One row per monitor, in order: [day, blindDown, night, nightLights, set, setChanged]; -1 marks "use the local number" (no entity, or the entity is unknown).
    public static string Build(HaConfig h0, IEnumerable<MonitorHa?> monitors0) {
        // Config.Validate already rejects bad ids; this second filter keeps any that slip through out of the Jinja.
        static string? Ok(string? e) => e != null && Config.IsEntityId(e) ? e : null;
        var h = new HaConfig { Url = h0.Url, TokenName = h0.TokenName, AutoSwitch = Ok(h0.AutoSwitch), Sun = Ok(h0.Sun), Cover = Ok(h0.Cover), Lights = Ok(h0.Lights), Light = Ok(h0.Light) };
        var monitors = monitors0.Select(m => m == null ? null : new MonitorHa {
            Sensor = Ok(m.Sensor), Day = Ok(m.Day), BlindDown = Ok(m.BlindDown), Night = Ok(m.Night), Set = Ok(m.Set), NightLights = Ok(m.NightLights) });
        string pos = h.Cover is { Length: > 0 } cv ? $"state_attr('{cv}','current_position') | float(-1)" : "100";
        string lights = h.Lights is { Length: > 0 } l ? $"is_state('{l}','on') | tojson" : "false | tojson";   // bare false renders as Python False
        string bri = h.Lights is { Length: > 0 } l2 ? $"state_attr('{l2}','brightness') | float(0)" : "0";
        string sat = h.Lights is { Length: > 0 } l3 ? $"(state_attr('{l3}','hs_color') or [0, 100])[1] | float(100)" : "100";
        // A missing or unavailable entity renders null, not false: a typo or an outage must not look like "Automatic is off". states['…'] is None when missing.
        string auto = h.AutoSwitch is { Length: > 0 } a ? $"{{{{ is_state('{a}','on') | tojson if states['{a}'] and states['{a}'].state not in ['unavailable', 'unknown'] else 'null' }}}}" : "null";
        string mons_ = string.Join(", ", monitors.Select(e => {
            string set = e?.Set is { Length: > 0 } st
                ? $"{Num(st, -1)}, {{{{ as_timestamp(states['{st}'].last_changed) if states['{st}'] else 0 }}}}" : "-1, 0";   // states['…']: None when missing; an object id may start with a digit
            return $"[{Num(e?.Day, -1)}, {Num(e?.BlindDown, -1)}, {Num(e?.Night, -1)}, {Num(e?.NightLights, -1)}, {set}]";
        }));
        string lightAge = h.Light is { Length: > 0 } lt
            ? $"{{{{ (now() - states['{lt}'].last_updated).total_seconds() | round(0) if states['{lt}'] else -1 }}}}" : "-1";   // seconds since it last reported; states['…']: an object id may start with a digit
        string lightUnit = h.Light is { Length: > 0 } lu ? $"{{{{ state_attr('{lu}','unit_of_measurement') | tojson }}}}" : "null";   // W, kW, lx…; null when unknown
        string sun = string.IsNullOrWhiteSpace(h.Sun) ? "sun.sun" : h.Sun!;
        return $$$"""
            {"elev": {{ state_attr('{{{sun}}}','elevation') | float if state_attr('{{{sun}}}','elevation') is number else 'null' }},
             "pos": {{ {{{pos}}} }},
             "lights": {{ {{{lights}}} }},
             "auto": {{{auto}}},
             "m": [{{{mons_}}}],
             "bri": {{ {{{bri}}} }},
             "sat": {{ {{{sat}}} }},
             "light": {{{Num(h.Light, -1)}}},
             "lightAge": {{{lightAge}}},
             "lightUnit": {{{lightUnit}}} }
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
    /// A member moved on its own (its monitor's buttons, or Home Assistant): it keeps the new level as its
    /// distance from the group, instead of being pulled back.
    public void Move(string key, int level, int b) { if (Offsets.ContainsKey(key)) Offsets[key] = level - b; }

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
    public sealed record Entry(int? LastSet, int? LastTarget, double Saved, int? Offset = null, double? OffsetSun = null, double? OffsetAt = null);
    public static readonly double MaxAge = 12 * 3600;
    public Dictionary<string, Entry> Entries { get; set; } = new();

    /// Records a monitor's state; one with nothing to remember is removed. Returns whether it changed.
    public bool Record(string key, Hold h, double now) {
        if (h.LastSet == null && h.LastTarget == null) return Entries.Remove(key);
        if (Entries.TryGetValue(key, out var e) && e.LastSet == h.LastSet && e.LastTarget == h.LastTarget && e.Offset == h.Offset
            && e.OffsetSun == h.OffsetSun && e.OffsetAt == h.OffsetAt) return false;   // keep "last decided" time
        Entries[key] = new Entry(h.LastSet, h.LastTarget, now, h.Offset, h.OffsetSun, h.OffsetAt);
        return true;
    }
    /// The state to start a monitor with after a restart, or null when there is none or it is too old.
    public Hold? Restore(string key, double now, double? maxAge = null) =>
        Entries.TryGetValue(key, out var e) && now >= e.Saved && now - e.Saved <= (maxAge ?? MaxAge) ? new Hold(null, e.LastSet, e.LastTarget, e.Offset, e.OffsetSun, e.OffsetAt ?? (e.Offset != null ? e.Saved : null)) : null;   // saved before offsets had a time

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
    /// Whether an HTTP status is a brief outage (502, 503, 504: Home Assistant restarting behind a proxy)
    /// rather than an answer that will not fix itself (403, 404, 500...).
    public static bool Transient(int status) => status is 502 or 503 or 504;
    public static readonly double[] RetryDelays = { 2, 5 };
    public const double ShowAfter = 60;
    public static bool ShouldShow(bool transient, double? downSince, double now) =>
        !transient || (downSince is double since && now - since >= ShowAfter);

    /// While Home Assistant stays down, a reminder in the log this often (seconds).
    public const double LogEvery = 600;
    /// Whether a failing tick writes to the log: the first failure of an outage, a different error,
    /// then one reminder every LogEvery. Not three lines every tick for as long as it lasts.
    public static bool ShouldLog(string message, string? lastMessage, double? lastLogged, double now) =>
        lastLogged is not double at || message != lastMessage || now - at >= LogEvery;
}

/// The name shown for a monitor: Windows and macOS sometimes report an empty one (a display that is
/// still waking up, or one behind an adapter). Never an empty label in the panel or the log.
public static class DisplayName {
    public static string Label(string? name, int index) =>
        string.IsNullOrWhiteSpace(name) ? $"Display {index + 1}" : name.Trim();
}

/// A fixed contrast per monitor (config `contrast`, DDC/CI VCP 0x12). It is written once at start and
/// again after a display change, wake or config reload; never on the regular tick and never automated.
/// Only over DDC: with HDR on (the SDR white level) monitors usually ignore it.
static class ContrastRule {
    /// The value to write now, or null: not configured, not a DDC monitor, or already written since the
    /// last display change. Out-of-range values are clamped to 0…100, like the brightness levels.
    public static int? ToWrite(double? configured, bool ddc, int? written) {
        if (configured is not double c || !double.IsFinite(c) || !ddc) return null;
        int v = (int)Math.Round(Math.Clamp(c, 0, 100), MidpointRounding.AwayFromZero);
        return v == written ? null : v;
    }
    /// The Settings window's contrast box: empty = not set (null), else a whole number 0–100 (a decimal comma
    /// is fine, halves round up). `ok` is false for anything else, so the window can say what is wrong.
    /// The same box when the file may hold a decimal: text equal to what the window loaded (`original`) means
    /// "not edited", so the file keeps its value (`keep`); only an edited box is parsed and rounded.
    public static (bool ok, int? value, bool keep) ParseField(string text, string original) {
        if (text == original) return (true, null, true);
        var (ok, value) = ParseField(text);
        return (ok, value, false);
    }
    public static (bool ok, int? value) ParseField(string text) {
        var t = text.Trim().Replace(',', '.');
        if (t == "") return (true, null);
        if (!double.TryParse(t, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v)
            || !double.IsFinite(v) || v < 0 || v > 100) return (false, null);
        return (true, (int)Math.Round(v, MidpointRounding.AwayFromZero));
    }
}

static class Layout {
    /// Label centres for lines drawn at `ys` (top = 0), moved apart so labels `gap` tall never overlap
    /// and stay inside 0…height. The upper label stays on its line when it can; the lower one moves down.
    public static double[] SpreadLabels(double[] ys, double gap, double height) {
        var order = Enumerable.Range(0, ys.Length).OrderBy(i => ys[i]).ToArray();
        double lo = gap / 2, hi = height - gap / 2;
        var o = order.Select(i => Math.Clamp(ys[i], lo, hi)).ToArray();
        for (int i = 1; i < o.Length; i++) o[i] = Math.Max(o[i], o[i - 1] + gap);
        if (o.Length > 0) o[^1] = Math.Min(o[^1], hi);
        for (int i = o.Length - 2; i >= 0; i--) o[i] = Math.Min(o[i], o[i + 1] - gap);
        var r = new double[ys.Length];
        for (int k = 0; k < order.Length; k++) r[order[k]] = o[k];
        return r;
    }
}

/// Keyboard shortcuts that would fight over the same keys.
static class ShortcutRule {
    /// Indices of the first two combinations with the same modifiers and key, or null.
    public static (int, int)? Clash(IReadOnlyList<(int Mods, int Vk)> combos) {
        for (int i = 0; i < combos.Count; i++)
            for (int j = i + 1; j < combos.Count; j++)
                if (combos[i] == combos[j]) return (i, j);
        return null;
    }
}
