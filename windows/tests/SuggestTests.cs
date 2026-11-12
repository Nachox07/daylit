using System.Text.Json.Nodes;
using Xunit;

namespace Daylit.Tests;

/// Samples for the suggestion tests: generic monitor, levels as given, Auto from the real target.
static class SuggestData {
    public const double T0 = 1_793_577_600;   // 2026-11-02 00:00 UTC
    /// Days counted in UTC, so the tests do not depend on the machine's time zone.
    public static int UtcDay(double t) => (int)Math.Floor(t / 86400);
    public static Sample Make(int day, double hour, double elev, double p, int chosen, double[] levels, string monitor = "m", bool lights = false) {
        var t = new Tuning();
        double s = t.Fraction(elev);
        int auto = Rules.Target(levels, p * 100, lights, s, t, elev < t.LightsBoostSunBelow);
        return new Sample(monitor, chosen, auto, s, p, elev, lights, levels, T0 + day * 86400 + hour * 3600);
    }
}

public class SuggestCandidateTests {
    static readonly double[] Levels = [100, 78, 75];

    [Fact]
    public void WeightsSplitDaylightBetweenTheBlindLevelsAndTheRestToNight() {
        var w = Suggest.Weights(1, 0.35);
        Assert.Equal(0.35, w[0], 1e-9); Assert.Equal(0.65, w[1], 1e-9); Assert.Equal(0, w[2], 1e-9);
        var dusk = Suggest.Weights(0.4, 1);
        Assert.Equal(0.4, dusk[0], 1e-9); Assert.Equal(0, dusk[1], 1e-9); Assert.Equal(0.6, dusk[2], 1e-9);
    }

    [Fact]
    public void ABlindExactlyFortyPercentOpenStillCountsForBlindDown() {
        Assert.True(Suggest.Dominates(SuggestData.Make(0, 9, 30, 0.45, 70, Levels), Level.BlindDown));    // weight 0.55
        Assert.False(Suggest.Dominates(SuggestData.Make(0, 9, 30, 0.46, 70, Levels), Level.BlindDown));   // weight 0.54
        Assert.True(Suggest.Dominates(SuggestData.Make(0, 9, 30, 0.40, 70, Levels), Level.BlindDown));
    }

    [Fact]
    public void ALevelNeedsDominantSamplesOnThreeDifferentDays() {
        var twoDays = new[] { 0, 0, 1, 1 }.Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();
        Assert.Empty(Suggest.Candidates(twoDays, SuggestData.UtcDay));
        var threeDays = twoDays.Append(SuggestData.Make(2, 9, 30, 0.35, 70, Levels)).ToList();
        Assert.Equal(new[] { Level.BlindDown }, Suggest.Candidates(threeDays, SuggestData.UtcDay));
    }

    [Fact]
    public void WithoutABlindBlindDownIsNeverACandidate() {
        // No blind: the position is always 100, so blind down carries no weight.
        var days = Enumerable.Range(0, 5).Select(d => SuggestData.Make(d, 12, 30, 1, 70, Levels)).ToList();
        Assert.Equal(new[] { Level.Day }, Suggest.Candidates(days, SuggestData.UtcDay));
    }

    [Fact]
    public void NightNeedsEveningSamples() {
        var evenings = Enumerable.Range(0, 3).Select(d => SuggestData.Make(d, 19, -6, 0, 60, Levels)).ToList();
        Assert.Equal(new[] { Level.Night }, Suggest.Candidates(evenings, SuggestData.UtcDay));
    }
}

public class SuggestFitTests {
    [Fact]
    public void ExactSyntheticDataRecoversTheLevels() {
        // Every mix of sun and blind, from levels 90 / 50 / 30, many times over so the pull hardly counts.
        double[] truth = [90, 50, 30];
        var t = new Tuning();
        var samples = new List<Sample>();
        for (int r = 0; r < 25; r++)
            foreach (var elev in new[] { -3.0, 4.5, 12, 30 })
                foreach (var p in new[] { 0.0, 0.5, 1 }) {
                    double s = t.Fraction(elev);
                    var w = Suggest.Weights(s, p);
                    double chosen = w[0] * truth[0] + w[1] * truth[1] + w[2] * truth[2];
                    samples.Add(new Sample("m", (int)Math.Round(chosen, MidpointRounding.AwayFromZero), 0, s, p, elev, false, [70, 40, 20], 0));
                }
        var f = Suggest.Fit(samples, [70, 40, 20], [Level.Day, Level.BlindDown, Level.Night]);
        Assert.Equal(90, f[0], 1.0); Assert.Equal(50, f[1], 1.0); Assert.Equal(30, f[2], 1.0);
    }

    [Fact]
    public void ALevelThatIsNotACandidateStaysPut() {
        double[] levels = [100, 78, 75];
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, levels)).ToList();
        var f = Suggest.Fit(samples, levels, [Level.BlindDown]);
        Assert.Equal(100, f[0]); Assert.Equal(75, f[2]);
        Assert.True(f[1] < 78);
    }

    [Fact]
    public void ThePullKeepsASingleSampleNearTheCurrentValue() {
        // Alone, this sample asks for blind down ≈ 43 ((60 − 0.3 · 100) / 0.7). One sample against the
        // pull of the current 78 moves it less than halfway.
        double[] levels = [100, 78, 75];
        var f = Suggest.Fit([SuggestData.Make(0, 9, 20, 0.3, 60, levels)], levels, [Level.BlindDown]);
        Assert.Equal(66.443, f[1], 0.01);
        Assert.True(f[1] > (42.857 + 78) / 2);
    }

    [Fact]
    public void AFitIsClampedToTheRange() {
        double[] levels = [100, 78, 75];
        var high = Enumerable.Range(0, 12).Select(d => SuggestData.Make(d % 3, 12, 30, 1, 99, levels)).ToList();
        Assert.True(Suggest.Fit(high, levels, [Level.Day])[0] <= 100);
    }
}
