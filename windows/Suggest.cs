// Suggest new levels from repeated hand changes. Pure: no WPF or Win32, so windows/tests runs every rule here.
// The app records a Sample for each deliberate correction, keeps them in corrections.json and asks
// Suggest.SuggestionFor for a change to offer in the panel. Same rules on macOS (mac/Sources/DaylitCore/Suggest.swift).
using System.Globalization;
using System.Text.Json;

namespace Daylit;

/// The three levels of a monitor, in the order Rules.Target and the config use them.
enum Level { Day = 0, BlindDown = 1, Night = 2 }

static class LevelText {
    public static readonly Level[] All = [Level.Day, Level.BlindDown, Level.Night];
    /// As the panel says it.
    public static string Name(this Level l) => l switch { Level.Day => "day", Level.BlindDown => "blind down", _ => "night" };
    /// The config key: monitors[].day / blindDown / night.
    public static string Key(this Level l) => l switch { Level.Day => "day", Level.BlindDown => "blindDown", _ => "night" };
    /// When this level is the one that counts most.
    public static string Situation(this Level l) => l switch {
        Level.Day => "with the blind open", Level.BlindDown => "with the blind partly or fully down", _ => "in the evening" };
}

/// One deliberate correction by hand. Monitor: the monitor's key (the same key the hold state uses); Chosen: the
/// level the user set; Auto: the automatic target then; S: the daylight fraction the target used,
/// min(Fraction(elev), light); P: blind position / 100; Elev, Lights: so scoring can rerun the target;
/// Levels: [day, blindDown, night] in effect then; At: Unix seconds.
sealed record Sample(string Monitor, int Chosen, int Auto, double S, double P, double Elev, bool Lights, double[] Levels, double At) {
    // A record compares arrays by reference: compare the levels by value.
    public bool Equals(Sample? o) => o is not null && Monitor == o.Monitor && Chosen == o.Chosen && Auto == o.Auto && S == o.S && P == o.P &&
                                     Elev == o.Elev && Lights == o.Lights && At == o.At && Levels.SequenceEqual(o.Levels);
    public override int GetHashCode() => HashCode.Combine(Monitor, Chosen, Auto, At);
}

static partial class Suggest {
    /// A level "carries most of the weight" in a sample from this weight (0.55, so a blind exactly 40% open still counts).
    public const double Dominant = 0.55;
    /// A level is a candidate only with dominant samples on this many local days.
    public const int MinDays = 3;

    /// How much each level counts in the target for a sample: [day, blindDown, night], summing to 1.
    public static double[] Weights(double s, double p) => [s * p, s * (1 - p), 1 - s];

    /// Whether `level` carries most of the weight in this sample.
    public static bool Dominates(Sample x, Level level) => Weights(x.S, x.P)[(int)level] >= Dominant - 1e-9;

    /// The levels the samples can tell apart: dominant samples on at least MinDays different local days.
    public static List<Level> Candidates(IReadOnlyList<Sample> samples, Func<double, int>? dayOf = null) {
        Func<double, int> day = dayOf ?? Rules.LocalDay;
        return LevelText.All.Where(l => samples.Where(x => Dominates(x, l)).Select(x => day(x.At)).Distinct().Count() >= MinDays).ToList();
    }
}

static partial class Suggest {
    /// Least squares for the candidate levels, the others held at their current values, with a pull of
    /// weight 1 toward the current value (as one extra sample at the current level):
    ///     minimise Σ (chosen − x·L)² + Σ_candidates (L_k − current_k)²
    /// Returns all three levels, each fitted one clamped to 0–100 (not rounded: see RoundToStep).
    public static double[] Fit(IReadOnlyList<Sample> samples, double[] levels, IReadOnlyList<Level> candidates) {
        int[] c = candidates.Select(l => (int)l).ToArray();
        int n = c.Length;
        if (n == 0 || levels.Length != 3) return (double[])levels.Clone();
        var a = new double[n, n];
        var b = new double[n];
        foreach (var x in samples) {
            var w = Weights(x.S, x.P);
            double y = x.Chosen;
            for (int k = 0; k < 3; k++) if (!c.Contains(k)) y -= w[k] * levels[k];
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
    public static double RoundToStep(double v, NumberStep st) {
        double lo = Math.Max(st.Min, 0), hi = Math.Min(st.Max, 100);
        double first = Math.Ceiling((lo - st.Min) / st.Step - 1e-9), last = Math.Floor((hi - st.Min) / st.Step + 1e-9);
        if (last < first) return Math.Min(Math.Max(v, lo), hi);   // a step coarser than the range: just clamp
        double n = Math.Min(Math.Max(Math.Round((v - st.Min) / st.Step, MidpointRounding.AwayFromZero), first), last);
        return Math.Round((st.Min + n * st.Step) * 1e6, MidpointRounding.AwayFromZero) / 1e6;   // no 61.500000001 from the multiplication
    }
}

/// One level to change: from its current value to the proposed one.
readonly record struct LevelChange(Level Level, double From, double To);

/// What the panel offers for one monitor. Monitor: its key; Changes: the main level (the one that moves most)
/// first; Amount: how far the user moves it, the mean of chosen − auto where the main level dominates, rounded,
/// no sign; Lower: the user lowers it (true) or raises it; Samples, Days: the hand changes behind it.
sealed record Suggestion(string Monitor, IReadOnlyList<LevelChange> Changes, int Amount, bool Lower, int Samples, int Days) {
    // A record compares lists by reference: compare the changes by value.
    public bool Equals(Suggestion? o) => o is not null && Monitor == o.Monitor && Amount == o.Amount && Lower == o.Lower &&
                                         Samples == o.Samples && Days == o.Days && Changes.SequenceEqual(o.Changes);
    public override int GetHashCode() => HashCode.Combine(Monitor, Amount, Lower, Samples, Days);

    public Level Main => Changes[0].Level;
    /// "blind down 78 → 62, day 100 → 95"
    public string ChangeText => string.Join(", ", Changes.Select(ch => $"{ch.Level.Name()} {Fmt(ch.From)} → {Fmt(ch.To)}"));
    /// The panel line: "You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62?"
    public string Sentence(string label) => $"You {(Lower ? "lower" : "raise")} {label} by about {Amount} {Main.Situation()}. Set {ChangeText}?";
    /// "suggest: Monitor blind down 78 → 62 (12 changes on 4 days)"
    public string LogLine(string label) => $"suggest: {label} {ChangeText} ({Samples} changes on {Days} days)";

    /// A whole number without decimals, otherwise one decimal (an input_number with step 0.5).
    public static string Fmt(double v) => v == Math.Round(v) ? ((long)v).ToString(CultureInfo.InvariantCulture) : v.ToString("0.0", CultureInfo.InvariantCulture);
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

    /// The real target (boost, clamp, rounding) for a sample's moment with other levels. S already holds the
    /// cloud cap, so light is 1; the boost rule is the tick's: the sun below lightsBoostSunBelow.
    public static int Rerun(Sample x, double[] levels, Tuning t) =>
        Rules.Target(levels, x.P * 100, x.Lights, x.S, t, x.Elev < t.LightsBoostSunBelow, 1);

    /// Mean of |target − chosen| over the samples, with `levels`.
    public static double MeanAbsError(IReadOnlyList<Sample> samples, double[] levels, Tuning? t = null) {
        if (samples.Count == 0) return 0;
        t ??= new Tuning();
        var tuning = t;
        return samples.Sum(x => (double)Math.Abs(Rerun(x, levels, tuning) - x.Chosen)) / samples.Count;
    }

    /// The change to offer for one monitor, or null.
    /// all: every recorded sample (other monitors' and stale ones are ignored here); levels: the monitor's
    /// [day, blindDown, night] now; steps: per level, what it can be stored as, null = it comes from Home
    /// Assistant and is unavailable now; dismissedUntil: "Not now" was clicked, nothing until this time.
    public static Suggestion? SuggestionFor(string monitor, IReadOnlyList<Sample> all, double[] levels, NumberStep?[] steps, double now,
                                            double? dismissedUntil, Tuning? t = null, Func<double, int>? dayOf = null) {
        if (dismissedUntil is double d && now < d) return null;
        if (levels.Length != 3 || steps.Length != 3) return null;
        t ??= new Tuning();
        Func<double, int> day = dayOf ?? Rules.LocalDay;
        var mine = all.Where(x => x.Monitor == monitor && SameLevels(x.Levels, levels)).ToList();
        var cand = Candidates(mine, day).Where(l => steps[(int)l] != null).ToList();
        if (cand.Count == 0) return null;
        var fitted = Fit(mine, levels, cand);
        var proposed = (double[])levels.Clone();
        var changes = new List<LevelChange>();
        foreach (var l in cand) {
            double v = RoundToStep(fitted[(int)l], steps[(int)l]!.Value);
            if (Math.Abs(v - levels[(int)l]) >= MinMove - 1e-9) {
                proposed[(int)l] = v;
                changes.Add(new LevelChange(l, levels[(int)l], v));
            }
        }
        if (changes.Count == 0) return null;
        double gain = MeanAbsError(mine, levels, t) - MeanAbsError(mine, proposed, t);
        if (gain < MinGain - 1e-9) return null;
        var main = changes[0];   // the one that moves most; the first of them on a tie
        foreach (var ch in changes) if (Math.Abs(ch.To - ch.From) > Math.Abs(main.To - main.From)) main = ch;
        var mainLevel = main.Level;
        var ordered = new List<LevelChange> { main };
        ordered.AddRange(changes.Where(ch => ch.Level != mainLevel));
        var dom = mine.Where(x => Dominates(x, mainLevel)).ToList();
        double mean = dom.Sum(x => (double)(x.Chosen - x.Auto)) / Math.Max(dom.Count, 1);
        return new Suggestion(monitor, ordered, (int)Math.Round(Math.Abs(mean), MidpointRounding.AwayFromZero), mean < 0,
                              mine.Count, mine.Select(x => day(x.At)).Distinct().Count());
    }
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
    /// the true wish). pos is the blind position 0–100 (100 without a blind), light the cloud cap (1 without a sensor).
    public static Sample? MakeSample(string monitor, int chosen, int auto, double elev, double pos, bool lights, double light,
                                     double[] levels, Tuning t, double now, SampleContext context) {
        if (context.Follower || context.WriteFailed || context.Idle || context.Paused || context.SunFallback) return null;
        if (levels.Length != 3 || chosen < 1 || chosen > 99 || auto < 1 || auto > 99) return null;
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

    /// Without the samples older than MaxAge.
    public static List<Sample> DropOld(IEnumerable<Sample> samples, double now) => samples.Where(x => now - x.At <= MaxAge).ToList();

    /// Without the samples whose levels differ from their monitor's levels now (`current`, by monitor key):
    /// after Apply, a change in Settings or of a Home Assistant helper, a level starts from fresh evidence.
    /// Monitors not in `current` (unplugged) keep theirs.
    public static List<Sample> DropStale(IEnumerable<Sample> samples, IReadOnlyDictionary<string, double[]> current) =>
        samples.Where(x => !current.TryGetValue(x.Monitor, out var lv) || SameLevels(lv, x.Levels)).ToList();

    static readonly JsonSerializerOptions Json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true };

    /// The samples in corrections.json; none when it is missing or broken. Entries without three levels are skipped.
    public static List<Sample> Decode(string? text) {
        if (string.IsNullOrWhiteSpace(text)) return new List<Sample>();
        try {
            var f = JsonSerializer.Deserialize<CorrectionsFile>(text, Json);
            return f?.Samples?.Where(x => x is not null && x.Monitor is not null && x.Levels is { Length: 3 }).ToList() ?? new List<Sample>();
        } catch (JsonException) { return new List<Sample>(); }
    }

    /// corrections.json's content.
    public static string Encode(IEnumerable<Sample> samples) => JsonSerializer.Serialize(new CorrectionsFile(samples.ToList()), Json);
}
