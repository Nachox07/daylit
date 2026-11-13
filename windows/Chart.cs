// The brightness chart in Settings → Automatic: today's level hour by hour, two handles that each
// store one sun elevation, and the "How Daylit decides, right now" row. Pure, so it is unit-tested
// (no WPF here: windows/tests compiles this file); BrightnessChart.cs only draws what these return.
// Same as the Mac's DaylitCore/Chart.swift.
using System.Globalization;

namespace Daylit;

/// Where a handle sits on today's chart (fractions of the day, 0 = midnight).
/// At: the crossing the handle is drawn on; Partner: the other crossing of the same elevation (null when
/// the sun crosses it only once today, near the poles). Parked: the sun never crosses this elevation
/// today, so the handle rests on the day's peak (a line above it) or trough (a line below it), and
/// dragging it saves nothing until it leaves that point. SunAbove: for a parked handle, the sun stays
/// above the line all day (false: below it all day).
readonly record struct HandlePlace(double At, double? Partner, bool Parked, bool SunAbove = false);

/// One step of "How Daylit decides, right now", left to right.
sealed record DecisionStep(string Title, string Value, bool Final = false);

/// The level right now and how it got there, in the order the rules apply. `Level` equals what the tick sets.
sealed record Decision(int Level, IReadOnlyList<DecisionStep> Steps);

/// What the monitors see right now, from the last tick, for the Settings chart.
/// Elev: the sun's elevation the tick used (Home Assistant's when it has one). Pos: blind position 0…100,
/// null without a blind. Light: the cloud cap on the sun's share (1: clear or no sensor). Levels: Home
/// Assistant's [day, blindDown, night] per monitor key (-1: no value there). Offsets: a hand-set distance
/// in effect and how much of it applies now, per monitor key. Linked: linked monitors that follow another,
/// and the level they land on; Leader: the monitor they follow. Applying: false when Automatic is off or
/// this PC is idle, so nothing is being set. LightsUsed: the room lights each monitor's target used, per monitor key.
/// SetHelper: a monitor has a Home Assistant "set" helper, which still applies while Automatic is off or the PC is idle.
sealed record LiveInputs(double? Elev = null, double? Pos = null, bool Lights = false, double Light = 1,
                         IReadOnlyDictionary<string, double[]>? Levels = null,
                         IReadOnlyDictionary<string, (int Value, double Weight)>? Offsets = null,
                         IReadOnlyDictionary<string, int>? Linked = null, string Leader = "", bool Applying = true,
                         IReadOnlyDictionary<string, bool>? LightsUsed = null, bool SetHelper = false);

static class Chart {
    static int R(double x) => (int)Math.Round(x, MidpointRounding.AwayFromZero);

    /// The handle for elevation `line`: on the morning crossing (where the sun comes up through the line)
    /// with the evening one as its partner, or parked on the peak or trough when today never crosses it.
    /// `morning` false puts it on the evening crossing instead (the end the user is dragging).
    public static HandlePlace Place(IReadOnlyList<(double t, double e)> s, double line, bool morning = true) {
        var ups = new List<double>(); var downs = new List<double>();
        for (int i = 1; i < s.Count; i++) {
            var (a, b) = (s[i - 1], s[i]);
            if ((a.e < line) == (b.e < line)) continue;
            double t = a.t + (b.t - a.t) * (line - a.e) / (b.e - a.e);
            if (b.e > a.e) ups.Add(t); else downs.Add(t);
        }
        if (ups.Count > 0 && downs.Count > 0)
            return morning ? new HandlePlace(ups[0], downs[^1], false) : new HandlePlace(downs[^1], ups[0], false);
        if (ups.Count > 0) return new HandlePlace(ups[0], null, false);
        if (downs.Count > 0) return new HandlePlace(downs[0], null, false);
        // No crossing: the peak when the whole day is below the line, the trough when it is all above.
        bool allBelow = s.All(p => p.e < line);
        if (s.Count == 0) return new HandlePlace(0.5, null, true, !allBelow);
        var pick = allBelow ? s.MaxBy(p => p.e) : s.MinBy(p => p.e);
        return new HandlePlace(pick.t, null, true, !allBelow);
    }

    /// The sun's elevation at a point of today (linear between samples).
    public static double Elevation(IReadOnlyList<(double t, double e)> s, double t) {
        if (s.Count == 0) return 0;
        if (t <= s[0].t) return s[0].e;
        if (t >= s[^1].t) return s[^1].e;
        int i = 1;
        while (s[i].t < t) i++;
        var (a, b) = (s[i - 1], s[i]);
        return a.e + (b.e - a.e) * (t - a.t) / (b.t - a.t);
    }

    /// What dragging a handle to point `t` of today saves: the sun's elevation there in half-degree steps,
    /// kept in the range tuning accepts and half a degree clear of the other handle, so the two never
    /// cross (`day` true: the full-day line, which stays above the night one). Null for a parked handle
    /// that has not left its resting point: a click on it changes nothing.
    public static double? DraggedElevation(IReadOnlyList<(double t, double e)> s, double t, bool day, double other,
                                           double? parkedAt = null, double slop = 0.01) {
        if (parkedAt is double p && Math.Abs(t - p) < slop) return null;
        double v = Math.Round(Elevation(s, t) * 2, MidpointRounding.AwayFromZero) / 2;
        v = day ? Math.Clamp(v, -18, 60) : Math.Clamp(v, -18, 30);
        return day ? Math.Max(v, other + 0.5) : Math.Min(v, other - 0.5);
    }

    /// The levels in effect: [day, blindDown, night], plus a fourth, nightLights, when the monitor has one.
    /// `local`: [day, blindDown, night], with nightLights as a fourth when the config sets it (below 0: none).
    /// `fromHa`: a template row [day, blindDown, night, nightLights, set, setChanged] or its first four numbers.
    /// Home Assistant's value wins where it has one (>= 0), else the local number.
    public static double[] EffectiveLevels(double[] local, double[]? fromHa) {
        var lv = local.Take(3).Select(Rules.ClampLevel).ToArray();
        if (fromHa != null) for (int k = 0; k < Math.Min(3, Math.Min(fromHa.Length, lv.Length)); k++) if (fromHa[k] >= 0) lv[k] = Rules.ClampLevel(fromHa[k]);
        double? fromRow = fromHa != null && fromHa.Length > 3 && fromHa[3] >= 0 ? (double?)fromHa[3] : null;
        double? own = local.Length > 3 && local[3] >= 0 ? (double?)local[3] : null;
        return (fromRow ?? own) is double nl ? lv.Append(Rules.ClampLevel(nl)).ToArray() : lv;
    }

    /// The level right now and how it got there: the blind picks the daytime level, the sun blends it with
    /// night, clouds cap the sun's share, room lights at dusk lift it off the night level, and a level set
    /// by hand keeps its distance. `pos` null: no blind. `linked`: the level a linked monitor that follows
    /// another lands on (`leader`). `applying` false: Automatic is off or this PC is idle, so it is a target.
    public static Decision Explain(double day, double blindDown, double night, double elev, double? pos, bool lights,
                                   Tuning? tuning = null, double light = 1, int? offset = null, double offsetWeight = 1,
                                   int? linked = null, string leader = "", bool applying = true, double? nightLights = null) {
        var t = tuning ?? new Tuning();
        double p = pos ?? 100;
        double sunShare = t.Fraction(elev);
        bool dusk = elev < t.LightsBoostSunBelow;
        int @base = Rules.Target(nightLights is double nlv ? new[] { day, blindDown, night, nlv } : new[] { day, blindDown, night },
                                 p, lights, sunShare, t, dusk, light);
        double daytime = blindDown + (day - blindDown) * p / 100;
        double share = Math.Min(sunShare, light);
        double blended = night + (daytime - night) * share;
        static string Pct(double x) => string.Create(CultureInfo.InvariantCulture, $"{R(x * 100)}%");
        static string Lvl(double x) => R(Math.Clamp(x, 0, 100)).ToString(CultureInfo.InvariantCulture);
        var steps = new List<DecisionStep>();
        if (pos != null)
            steps.Add(new DecisionStep(p >= 100 ? "Blind open" : p <= 0 ? "Blind closed" : string.Create(CultureInfo.InvariantCulture, $"Blind {R(p)}% open"), "daytime " + Lvl(daytime)));
        else
            steps.Add(new DecisionStep("Day level", Lvl(daytime)));
        string sunTitle = sunShare >= 1 ? "Sun high" : sunShare <= 0 ? "Sun down" : "Sun low";
        steps.Add(new DecisionStep(sunTitle, sunShare <= 0 ? "night " + Lvl(night) : $"{Pct(sunShare)} → {Lvl(night + (daytime - night) * sunShare)}"));
        if (light < 1 && light < sunShare) steps.Add(new DecisionStep("Cloudy", $"daylight {Pct(light)} → {Lvl(blended)}"));
        if (nightLights != null) {
            // Its own lit-evening level: the lights count whenever the sun is not fully up, with no boost.
            bool moved = lights && @base != R(Math.Clamp(blended, 0, 100));
            steps.Add(new DecisionStep("Lights", moved ? string.Create(CultureInfo.InvariantCulture, $"on → {@base}")
                                               : lights ? "on, no effect now" : sunShare < 1 ? "off" : "no effect by day"));
        } else {
            bool lifted = lights && dusk && @base > R(blended);
            steps.Add(new DecisionStep("Lights", lifted ? string.Create(CultureInfo.InvariantCulture, $"on → {@base}")
                                               : lights ? "on, no effect now" : dusk ? "off" : "no effect by day"));
        }
        int level = @base;
        if (linked is int v) {
            // A linked monitor that follows another lands at the group's level, keeping its link distance.
            steps.Add(new DecisionStep(leader == "" ? "Linked" : "Linked to " + leader, "→ " + v.ToString(CultureInfo.InvariantCulture), Final: true));
            return new Decision(v, steps);
        }
        if (offset is int o) {
            int applied = R(o * offsetWeight);
            level = Math.Clamp(@base + applied, 0, 100);
            if (applied != 0) steps.Add(new DecisionStep("You", string.Create(CultureInfo.InvariantCulture, $"{(applied > 0 ? "+" : "")}{applied} → {level}"), Final: true));
        }
        if (!steps.Any(x => x.Final)) steps.Add(new DecisionStep(applying ? "Now" : "Target", level.ToString(CultureInfo.InvariantCulture), Final: true));
        return new Decision(level, steps);
    }

    /// Today in `tz`, from local midnight to the next one (Length in seconds): 23 or 25 hours on the days
    /// the clocks change.
    public static (DateTimeOffset Start, double Length) DayBounds(DateTimeOffset now, TimeZoneInfo tz) {
        var date = TimeZoneInfo.ConvertTime(now, tz).Date;
        DateTimeOffset At(DateTime d) => new(d, tz.GetUtcOffset(d));
        var start = At(date);
        return (start, (At(date.AddDays(1)) - start).TotalSeconds);
    }

    /// The sun's elevation through that day at `steps + 1` even points (every 4 minutes with 360).
    public static List<(double t, double e)> DaySamples(double lat, double lon, DateTimeOffset start, double length, int steps = 360) =>
        Enumerable.Range(0, steps + 1).Select(i => {
            double f = (double)i / steps;
            return (f, Sun.Elevation(start.AddSeconds(f * length), lat, lon));
        }).ToList();
}
