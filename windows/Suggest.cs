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
