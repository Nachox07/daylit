// Suggest new levels from repeated hand changes. Pure: no WPF or Win32, so windows/tests runs every rule here.
// The app records a Sample for each deliberate correction, keeps them in corrections.json and asks
// Suggest.SuggestionFor for a change to offer in the panel. Same rules on macOS (mac/Sources/DaylitCore/Suggest.swift).
using System.Globalization;
using System.Text.Json;

namespace Daylit;

/// The levels of a monitor, in the order Rules.Target and the config use them: day, blind down, night and the
/// optional lights-on night level (nightLights).
enum Level { Day = 0, BlindDown = 1, Night = 2, NightLights = 3 }

static class LevelText {
    public static readonly Level[] All = [Level.Day, Level.BlindDown, Level.Night, Level.NightLights];
    /// As the panel says it.
    public static string Name(this Level l) => l switch {
        Level.Day => "day", Level.BlindDown => "blind down", Level.Night => "night", _ => "lights on" };
    /// The config key: monitors[].day / blindDown / night / nightLights.
    public static string Key(this Level l) => l switch {
        Level.Day => "day", Level.BlindDown => "blindDown", Level.Night => "night", _ => "nightLights" };
    /// When this level is the one that counts most.
    public static string Situation(this Level l) => l switch {
        Level.Day => "with the blind open", Level.BlindDown => "with the blind partly or fully down",
        Level.Night => "when the room is dim", _ => "with the lights on" };
}

/// One deliberate correction by hand. Monitor: the monitor's key (the same key the hold state uses); Chosen: the
/// level the user set; Auto: the automatic target then; S: the daylight fraction the target used,
/// min(Fraction(elev), light); P: blind position / 100; Elev, Lights: so scoring can rerun the target;
/// Levels: [day, blindDown, night] in effect then, plus nightLights when the monitor has one; At: Unix seconds.
sealed record Sample(string Monitor, int Chosen, int Auto, double S, double P, double Elev, bool Lights, double[] Levels, double At) {
    // A record compares arrays by reference: compare the levels by value.
    public bool Equals(Sample? o) => o is not null && Monitor == o.Monitor && Chosen == o.Chosen && Auto == o.Auto && S == o.S && P == o.P &&
                                     Elev == o.Elev && Lights == o.Lights && At == o.At && Levels.SequenceEqual(o.Levels);
    public override int GetHashCode() => HashCode.Combine(Monitor, Chosen, Auto, At);
}

static partial class Suggest {
    /// Day or blind down "carries most of the weight" in a sample from this weight (0.55, so a blind exactly 40% open still counts).
    public const double Dominant = 0.55;
    /// Night or the lights-on level carries most of the weight when its weight is the largest of the four and at
    /// least this much (with the lights on at dusk the two share what daylight leaves, so neither reaches 0.55).
    public const double DimDominant = 0.45;
    /// A level is a candidate only with dominant samples on this many local days.
    public const int MinDays = 3;

    /// How much each level counts in the target for a sample: [day, blindDown, night], summing to 1.
    public static double[] Weights(double s, double p) => [s * p, s * (1 - p), 1 - s];

    /// How much each level counts in the target for a sample: [day, blindDown, night, nightLights], summing to 1.
    /// With a nightLights level and the lights on, what daylight leaves is split between night (sun high) and
    /// nightLights (sun down): [s·p, s·(1−p), (1−s)·sun, (1−s)·(1−sun)], sun the elevation's own daylight
    /// fraction (no cloud cap). Otherwise [s·p, s·(1−p), 1−s, 0].
    public static double[] Weights(Sample x, bool nightLights, Tuning? t = null) {
        var w = Weights(x.S, x.P);
        if (!nightLights || !x.Lights) return [w[0], w[1], w[2], 0];
        double sun = (t ?? new Tuning()).Fraction(x.Elev);
        return [w[0], w[1], w[2] * sun, w[2] * (1 - sun)];
    }

    /// Whether `level` carries most of the weight in this sample (with the levels the sample was taken with).
    public static bool Dominates(Sample x, Level level, Tuning? t = null) {
        var w = Weights(x, Rules.NightLightsLevel(x.Levels) != null, t);
        double v = w[(int)level];
        if (level is Level.Day or Level.BlindDown) return v >= Dominant - 1e-9;
        // A tie for the largest weight counts for neither.
        return v >= DimDominant - 1e-9 && Enumerable.Range(0, w.Length).All(k => k == (int)level || v > w[k] + 1e-9);
    }

    /// The levels the samples can tell apart: dominant samples on at least MinDays different local days.
    public static List<Level> Candidates(IReadOnlyList<Sample> samples, Func<double, int>? dayOf = null, Tuning? t = null) {
        Func<double, int> day = dayOf ?? Rules.LocalDay;
        return LevelText.All.Where(l => samples.Where(x => Dominates(x, l, t)).Select(x => day(x.At)).Distinct().Count() >= MinDays).ToList();
    }
}

static partial class Suggest {
    /// Least squares for the candidate levels, the others held at their current values, with a pull of
    /// weight 1 toward the current value (as one extra sample at the current level):
    ///     minimise Σ (chosen − x·L)² + Σ_candidates (L_k − current_k)²
    /// The weights come from `levels` (four with nightLights), not from the levels each sample was taken with.
    /// Returns all the levels, each fitted one clamped to 0–100 (not rounded: see RoundToStep).
    public static double[] Fit(IReadOnlyList<Sample> samples, double[] levels, IReadOnlyList<Level> candidates, Tuning? t = null) {
        bool hasNl = Rules.NightLightsLevel(levels) != null;
        // nightLights can only be fitted on a monitor that has one.
        int[] c = candidates.Select(l => (int)l).Where(k => k < 3 || hasNl).ToArray();
        int n = c.Length;
        if (n == 0 || levels.Length is < 3 or > 4) return (double[])levels.Clone();
        var a = new double[n, n];
        var b = new double[n];
        foreach (var x in samples) {
            var w = Weights(x, hasNl, t);
            double y = x.Chosen;
            for (int k = 0; k < levels.Length; k++) if (!c.Contains(k)) y -= w[k] * levels[k];
            for (int i = 0; i < n; i++) {
                b[i] += w[c[i]] * y;
                for (int j = 0; j < n; j++) a[i, j] += w[c[i]] * w[c[j]];
            }
        }
        for (int i = 0; i < n; i++) { a[i, i] += 1; b[i] += levels[c[i]]; }   // the pull toward the current value
        var solved = Solve(a, b);
        var o = (double[])levels.Clone();
        for (int i = 0; i < n; i++) o[c[i]] = Math.Clamp(solved[i], 0, 100);
        return o;
    }

    /// Gaussian elimination with partial pivoting. The pull adds 1 to the diagonal, so the matrix is
    /// positive definite and no pivot is 0. Changes `a` and `b`.
    static double[] Solve(double[,] a, double[] b) {
        int n = b.Length;
        for (int col = 0; col < n; col++) {
            int piv = col;
            for (int r = col + 1; r < n; r++) if (Math.Abs(a[r, col]) > Math.Abs(a[piv, col])) piv = r;
            if (piv != col) {
                for (int k = 0; k < n; k++) (a[col, k], a[piv, k]) = (a[piv, k], a[col, k]);
                (b[col], b[piv]) = (b[piv], b[col]);
            }
            for (int r = 0; r < n; r++) {
                if (r == col) continue;
                double f = a[r, col] / a[col, col];
                for (int k = col; k < n; k++) a[r, k] -= f * a[col, k];
                b[r] -= f * b[col];
            }
        }
        var x = new double[n];
        for (int i = 0; i < n; i++) x[i] = b[i] / a[i, i];
        return x;
    }
}

/// The values a level can be stored as. A Home Assistant input_number has its own min, max and step;
/// a local level is a whole number 0–100.
readonly record struct NumberStep(double Min, double Max, double Step) {
    public static readonly NumberStep Whole = new(0, 100, 1);

    /// From the answer to GET /api/states/<input_number>: its min, max and step attributes. null when one is missing.
    public static NumberStep? Parse(string? json) {
        try {
            using var d = JsonDocument.Parse(json ?? "");
            if (d.RootElement.ValueKind != JsonValueKind.Object || !d.RootElement.TryGetProperty("attributes", out var a)
                || a.ValueKind != JsonValueKind.Object) return null;
            if (!Num(a, "min", out double lo) || !Num(a, "max", out double hi) || !Num(a, "step", out double st) || st <= 0 || hi < lo) return null;
            return new NumberStep(lo, hi, st);
        } catch (JsonException) { return null; }
    }

    static bool Num(JsonElement o, string key, out double v) {
        v = 0;
        return o.TryGetProperty(key, out var e) && e.ValueKind == JsonValueKind.Number && e.TryGetDouble(out v);
    }
}

static partial class Suggest {
    /// The nearest value `st` accepts, inside both its range and 0–100. Halves round up.
    /// null when `st` cannot be used: a step that is not positive, min above max, a non-finite number, or a range outside 0–100.
    public static double? RoundToStep(double v, NumberStep st) {
        if (!double.IsFinite(v) || !double.IsFinite(st.Min) || !double.IsFinite(st.Max) || !double.IsFinite(st.Step) ||
            st.Step <= 0 || st.Min > st.Max || st.Max < 0 || st.Min > 100) return null;
        double lo = Math.Max(st.Min, 0), hi = Math.Min(st.Max, 100);
        double first = Math.Ceiling((lo - st.Min) / st.Step - 1e-9), last = Math.Floor((hi - st.Min) / st.Step + 1e-9);
        if (last < first) return Math.Min(Math.Max(v, lo), hi);   // a step coarser than the range: just clamp
        double n = Math.Min(Math.Max(Math.Round((v - st.Min) / st.Step, MidpointRounding.AwayFromZero), first), last);
        return Math.Round((st.Min + n * st.Step) * 1e6, MidpointRounding.AwayFromZero) / 1e6;   // no 61.500000001 from the multiplication
    }
}

/// One level to change: from its current value to the proposed one. Added: the monitor has no such level yet
/// (only nightLights): Apply adds it at To, and From is the same value (what the lights give now).
readonly record struct LevelChange(Level Level, double From, double To, bool Added = false);

/// What the panel offers for one monitor. Monitor: its key; Changes: the main level (the one that moves most)
/// first; Amount: how far the user moves it, the mean of chosen − auto where the main level dominates, rounded,
/// no sign; Lower: the user lowers it (true) or raises it; Samples, Days: the hand changes behind it.
sealed record Suggestion(string Monitor, IReadOnlyList<LevelChange> Changes, int Amount, bool Lower, int Samples, int Days) {
    // A record compares lists by reference: compare the changes by value.
    public bool Equals(Suggestion? o) => o is not null && Monitor == o.Monitor && Amount == o.Amount && Lower == o.Lower &&
                                         Samples == o.Samples && Days == o.Days && Changes.SequenceEqual(o.Changes);
    public override int GetHashCode() => HashCode.Combine(Monitor, Amount, Lower, Samples, Days);

    public Level Main => Changes[0].Level;
    /// "blind down 78 → 62, day 100 → 95"; an added level reads "lights on 80 (new)".
    public string ChangeText => string.Join(", ", Changes.Select(ch =>
        ch.Added ? $"{ch.Level.Name()} {Fmt(ch.To)} (new)" : $"{ch.Level.Name()} {Fmt(ch.From)} → {Fmt(ch.To)}"));
    /// The panel line: "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62?"
    public string Sentence(string label) => $"You {(Lower ? "lower" : "raise")} {label} by about {Amount} {Main.Situation()}. Set {ChangeText}?";
    /// "suggest: Monitor blind down 78 → 62 (12 changes on 4 days)"
    public string LogLine(string label) => $"suggest: {label} {ChangeText} ({Samples} changes on {Days} days)";

    /// Up to two decimals, trailing zeros trimmed: 62.25 → "62.25", 62.5 → "62.5", 62 → "62". Culture-independent.
    public static string Fmt(double v) => Math.Round(v, 2, MidpointRounding.AwayFromZero).ToString("0.##", CultureInfo.InvariantCulture);
}

static partial class Suggest {
    /// A proposed level must move at least this much after rounding...
    public const double MinMove = 5;
    /// ...and the proposed levels must lower the mean absolute error by at least this much.
    public const double MinGain = 3;
    /// "Not now" hides a monitor's suggestions this long (seconds).
    public const double NotNow = 7 * 86400;

    /// The two level lists are the same (an input_number may hold decimals).
    public static bool SameLevels(double[]? a, double[]? b) =>
        a != null && b != null && a.Length == b.Length && a.Zip(b).All(p => Math.Abs(p.First - p.Second) < 1e-6);

    /// The real target (boost, clamp, rounding) for a sample's moment with other levels. S holds the cloud cap, passed
    /// as `light` beside the elevation's own fraction; the boost rule is the tick's: the sun below lightsBoostSunBelow.
    public static int Rerun(Sample x, double[] levels, Tuning t) =>
        Rules.Target(levels, x.P * 100, x.Lights, t.Fraction(x.Elev), t, x.Elev < t.LightsBoostSunBelow, x.S);

    /// Mean of |target − chosen| over the samples, with `levels`.
    public static double MeanAbsError(IReadOnlyList<Sample> samples, double[] levels, Tuning? t = null) {
        if (samples.Count == 0) return 0;
        t ??= new Tuning();
        var tuning = t;
        return samples.Sum(x => (double)Math.Abs(Rerun(x, levels, tuning) - x.Chosen)) / samples.Count;
    }

    /// The change to offer for one monitor, or null.
    /// all: every recorded sample (other monitors' and stale ones are ignored here); levels: the monitor's
    /// [day, blindDown, night] now, plus nightLights when it has one; steps: per level [day, blindDown, night,
    /// nightLights], what it can be stored as, null = it comes from Home Assistant and is unavailable now (for a
    /// monitor without nightLights, a fourth step means one may be added: the room lights come from Home Assistant;
    /// three steps = never); dismissedUntil: "Not now" was clicked, nothing until this time.
    public static Suggestion? SuggestionFor(string monitor, IReadOnlyList<Sample> all, double[] levels, NumberStep?[] steps, double now,
                                            double? dismissedUntil, Tuning? t = null, Func<double, int>? dayOf = null) {
        if (dismissedUntil is double d && now < d) return null;
        if (levels.Length is < 3 or > 4 || steps.Length is < 3 or > 4) return null;
        t ??= new Tuning();
        Func<double, int> day = dayOf ?? Rules.LocalDay;
        var mine = DropOld(all, now).Where(x => x.Monitor == monitor && SameLevels(x.Levels, levels)).ToList();
        var cand = Candidates(mine, day, t).Where(l => (int)l < steps.Length && steps[(int)l] != null).ToList();
        if (cand.Count == 0) return null;
        var (baseLevels, baseChanges) = Proposal(mine, levels, cand, steps, t);
        (double[] Levels, List<LevelChange> Changes)? picked = null;
        // Lowering night on a monitor without nightLights would lower its lit evenings too (the boost sits on top of
        // night). Offer the pair instead: add nightLights where the lights put it today (night + the boost) and
        // lower night, refitted and scored with the four-level rule. A lit evening stays where it is.
        if (Rules.NightLightsLevel(levels) == null && levels.Length == 3 && steps.Length == 4 && steps[3] is { } nlStep
            && baseChanges.Any(ch => ch.Level == Level.Night && ch.To < ch.From)
            && RoundToStep(levels[2] + t.LightsBoost, nlStep) is double start) {
            double[] four = [.. levels, start];
            var pair = Proposal(mine, four, cand.Where(l => l != Level.NightLights).ToList(), steps, t);
            if (pair.Changes.Any(ch => ch.Level == Level.Night && ch.To < ch.From)) {
                pair.Changes.Add(new LevelChange(Level.NightLights, start, start, true));
                if (Gain(mine, levels, pair.Levels, t) >= MinGain - 1e-9) picked = pair;
            }
        }
        if (picked == null && baseChanges.Count > 0 && Gain(mine, levels, baseLevels, t) >= MinGain - 1e-9) picked = (baseLevels, baseChanges);
        if (picked is not { } chosen) return null;
        var changes = chosen.Changes;
        var main = changes[0];   // the one that moves most; the first of them on a tie
        foreach (var ch in changes) if (Math.Abs(ch.To - ch.From) > Math.Abs(main.To - main.From)) main = ch;
        var mainLevel = main.Level;
        var ordered = new List<LevelChange> { main };
        ordered.AddRange(changes.Where(ch => ch.Level != mainLevel));
        // The sentence follows the change: only the samples that pull the same way as the proposal count for the amount.
        bool lower = main.To < main.From;
        var agree = mine.Where(x => Dominates(x, mainLevel, t) && (lower ? x.Chosen < x.Auto : x.Chosen > x.Auto)).ToList();
        if (agree.Count == 0) return null;
        double mean = agree.Sum(x => (double)Math.Abs(x.Chosen - x.Auto)) / agree.Count;
        return new Suggestion(monitor, ordered, (int)Math.Round(mean, MidpointRounding.AwayFromZero), lower,
                              mine.Count, mine.Select(x => day(x.At)).Distinct().Count());
    }

    /// The fitted candidates rounded to their steps, keeping those that move at least MinMove: the levels they give
    /// (`levels` with those replaced) and the changes, in candidate order.
    static (double[] Levels, List<LevelChange> Changes) Proposal(IReadOnlyList<Sample> samples, double[] levels, IReadOnlyList<Level> candidates,
                                                                 NumberStep?[] steps, Tuning t) {
        var fitted = Fit(samples, levels, candidates, t);
        var proposed = (double[])levels.Clone();
        var changes = new List<LevelChange>();
        foreach (var l in candidates) {
            if ((int)l >= levels.Length || steps[(int)l] is not { } st || RoundToStep(fitted[(int)l], st) is not double v) continue;
            if (Math.Abs(v - levels[(int)l]) >= MinMove - 1e-9) {
                proposed[(int)l] = v;
                changes.Add(new LevelChange(l, levels[(int)l], v));
            }
        }
        return (proposed, changes);
    }

    /// How much the mean absolute error falls from `from` to `to` (each scored with its own rule: three or four levels).
    static double Gain(IReadOnlyList<Sample> samples, double[] from, double[] to, Tuning t) =>
        MeanAbsError(samples, from, t) - MeanAbsError(samples, to, t);
}

/// Why a tick's hand change is not a sample (each of these hides what the user really wanted).
/// Follower: a linked follower, its level comes from the leader; WriteFailed: this tick's write to the monitor
/// failed; Idle: this PC is idle; Paused: paused on battery; SunFallback: the source is Home Assistant but it is
/// down, the sun is standing in.
readonly record struct SampleContext(bool Follower = false, bool WriteFailed = false, bool Idle = false, bool Paused = false, bool SunFallback = false);

/// Hand changes waiting to settle, one per monitor. A change becomes a sample after Suggest.SettleSeconds with
/// no further hand change on that monitor, while its offset is still held.
sealed class Recorder {
    readonly Dictionary<string, Sample> pending = new();
    public IReadOnlyDictionary<string, Sample> Pending => pending;

    /// A hand change on `monitor` this tick. `sample` is null when the tick may not be recorded (see
    /// Suggest.MakeSample) or the user put it back to automatic: either way it ends the gesture before it.
    public void HandChanged(string monitor, Sample? sample) {
        if (sample == null) pending.Remove(monitor); else pending[monitor] = sample;
    }

    /// Every tick, per monitor. Returns the sample that became final now, if any.
    /// held: the hand-set offset is still set and automatic mode is on (false drops the pending change);
    /// levels: the monitor's levels now (a change drops it too).
    public Sample? Settle(string monitor, bool held, double[] levels, double now) {
        if (!pending.TryGetValue(monitor, out var p)) return null;
        if (!held || !Suggest.SameLevels(p.Levels, levels)) { pending.Remove(monitor); return null; }
        if (now - p.At < Suggest.SettleSeconds) return null;
        pending.Remove(monitor);
        return p;
    }

    /// Forget a monitor's pending change.
    public void Drop(string monitor) => pending.Remove(monitor);
}

static partial class Suggest {
    /// A hand change becomes a sample after this long with no further one (seconds).
    public const double SettleSeconds = 300;

    /// The room lights' boost decided the target (it lifted the level above the blend).
    public static bool BoostDecides(double[] l, double elev, double pos, bool lights, Tuning t, double light) {
        if (!lights || elev >= t.LightsBoostSunBelow || l.Length != 3) return false;
        double s = Math.Min(t.Fraction(elev), light);
        double daytime = l[1] + (l[0] - l[1]) * pos / 100;
        return l[2] + t.LightsBoost > l[2] + (daytime - l[2]) * s;
    }

    /// The sample for a tick where Decide recorded a new hand-set level, or null when it may not be recorded:
    /// see SampleContext, the lights boost deciding the target, or chosen / auto at 0 or 100 (the clamp hides
    /// the true wish). A monitor with nightLights records its lit evenings too: the four-level weights explain them. pos is the blind position 0–100 (100 without a blind), light the cloud cap (1 without a sensor).
    public static Sample? MakeSample(string monitor, int chosen, int auto, double elev, double pos, bool lights, double light,
                                     double[] levels, Tuning t, double now, SampleContext context) {
        if (context.Follower || context.WriteFailed || context.Idle || context.Paused || context.SunFallback) return null;
        if (levels.Length is < 3 or > 4 || !levels.All(double.IsFinite) || !double.IsFinite(elev) || !double.IsFinite(pos) || !double.IsFinite(light) ||
            chosen < 1 || chosen > 99 || auto < 1 || auto > 99) return null;
        if (BoostDecides(levels, elev, pos, lights, t, light)) return null;
        return new Sample(monitor, chosen, auto, Math.Min(t.Fraction(elev), light), Math.Clamp(pos, 0, 100) / 100, elev, lights, levels, now);
    }

    /// Whether this tick's Decide took a new hand-set level (moved by hand): it stamps OffsetAt with now.
    /// A level from the Home Assistant "set" helper (`remote`) stamps it too, but is not a hand change.
    public static bool IsHandChange(Hold before, Hold after, int? remote, double now) =>
        remote == null && now > 0 && after.OffsetAt == now && before.OffsetAt != now;

    /// The hold state after Apply: the hand-set offset is cleared, or it would be applied again on top of the
    /// new level (target 85, set 70, new level gives 70: the monitor would go to 55).
    public static Hold AfterApply(Hold h) => h with { LastSet = null, Offset = null, OffsetSun = null, OffsetAt = null };
}

/// corrections.json: {"samples": [...]}.
sealed record CorrectionsFile(List<Sample>? Samples);

static partial class Suggest {
    /// Samples older than this are dropped on load and on save (seconds).
    public const double MaxAge = 14 * 86400;

    /// Without the samples older than MaxAge or dated more than a day ahead (a corrupt At).
    public static List<Sample> DropOld(IEnumerable<Sample> samples, double now) => samples.Where(x => now - x.At <= MaxAge && x.At <= now + 86400).ToList();

    /// Without the samples whose levels differ from their monitor's levels now (`current`, by monitor key):
    /// after Apply, a change in Settings or of a Home Assistant helper, a level starts from fresh evidence.
    /// Monitors not in `current` (unplugged) keep theirs.
    public static List<Sample> DropStale(IEnumerable<Sample> samples, IReadOnlyDictionary<string, double[]> current) =>
        samples.Where(x => !current.TryGetValue(x.Monitor, out var lv) || SameLevels(lv, x.Levels)).ToList();

    static readonly JsonSerializerOptions Json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true,
        RespectRequiredConstructorParameters = true };

    /// The samples in corrections.json; none when it is missing or broken. Entries without three or four levels are skipped.
    public static List<Sample> Decode(string? text) {
        if (string.IsNullOrWhiteSpace(text)) return new List<Sample>();
        try {
            var f = JsonSerializer.Deserialize<CorrectionsFile>(text, Json);
            return f?.Samples?.Where(x => x is not null && x.Monitor is not null && x.Levels is { Length: 3 or 4 }).ToList() ?? new List<Sample>();
        } catch (JsonException) { return new List<Sample>(); }   // includes a sample missing a required key, as Swift rejects the file
    }

    /// corrections.json's content.
    public static string Encode(IEnumerable<Sample> samples) => JsonSerializer.Serialize(new CorrectionsFile(samples.Where(Storable).ToList()), Json);

    /// A sample with a NaN or infinite number cannot be written as JSON: it is left out and the rest is kept.
    static bool Storable(Sample x) => double.IsFinite(x.S) && double.IsFinite(x.P) && double.IsFinite(x.Elev) && double.IsFinite(x.At) &&
                                      x.Levels is { Length: 3 or 4 } && x.Levels.All(double.IsFinite);
}
