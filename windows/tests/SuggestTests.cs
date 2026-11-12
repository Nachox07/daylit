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

public class SuggestRoundingTests {
    [Fact]
    public void ALocalLevelRoundsToAWholeNumber() {
        Assert.Equal(61, Suggest.RoundToStep(61.42, NumberStep.Whole));
        Assert.Equal(62, Suggest.RoundToStep(61.5, NumberStep.Whole));
        Assert.Equal(0, Suggest.RoundToStep(-3, NumberStep.Whole));
        Assert.Equal(100, Suggest.RoundToStep(104, NumberStep.Whole));
    }

    [Fact]
    public void AHomeAssistantLevelRoundsToItsStepInsideItsRange() {
        var st = new NumberStep(10, 90, 5);
        Assert.Equal(60, Suggest.RoundToStep(62.4, st));
        Assert.Equal(65, Suggest.RoundToStep(63, st));
        Assert.Equal(10, Suggest.RoundToStep(3, st));
        Assert.Equal(90, Suggest.RoundToStep(97, st));
        Assert.Equal(61.5, Suggest.RoundToStep(61.3, new NumberStep(0, 100, 0.5)));
        Assert.Equal(100, Suggest.RoundToStep(120, new NumberStep(0, 255, 1)));   // never above 100
    }

    [Fact]
    public void TheStepIsReadFromTheEntityAttributes() {
        Assert.Equal((NumberStep?)new NumberStep(10, 90, 5),
            NumberStep.Parse("""{"entity_id": "input_number.x", "state": "62.0", "attributes": {"min": 10, "max": 90, "step": 5, "mode": "slider"}}"""));
        Assert.Null(NumberStep.Parse("""{"state": "62.0", "attributes": {"min": 0}}"""));
        Assert.Null(NumberStep.Parse("""{"state": "62.0", "attributes": {"min": 0, "max": 100, "step": 0}}"""));
        Assert.Null(NumberStep.Parse("not json"));
    }
}

public class SuggestTriggerTests {
    static readonly double[] Levels = [100, 78, 75];
    static readonly NumberStep?[] Local = [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole];
    static readonly double Later = SuggestData.T0 + 5 * 86400;

    [Fact]
    public void ScoringRunsTheRealTargetIncludingTheLightsBoost() {
        // Sun 0° (daylight 0.2), lights on: the blend gives 30.4, the boost lifts it to 35.
        var x = new Sample("m", 35, 35, 0.2, 1, 0, true, [32, 32, 30], 0);
        Assert.Equal(0, Suggest.MeanAbsError([x], [32, 32, 30]));
        Assert.Equal(5, Suggest.MeanAbsError([x with { Lights = false }], [32, 32, 30]));
    }

    [Fact]
    public void AMoveUnderFivePointsIsNotProposed() {
        // Blind fully down, three days at 74 against 78: the fit gives 75, which would cut the error from 4 to 1.
        var samples = Enumerable.Range(0, 3).Select(d => SuggestData.Make(d, 9, 30, 0, 74, Levels)).ToList();
        Assert.Equal(75, Suggest.Fit(samples, Levels, [Level.BlindDown])[1], 1e-9);
        Assert.Equal(3, Suggest.MeanAbsError(samples, Levels) - Suggest.MeanAbsError(samples, [100, 75, 75]));
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void AMoveThatDoesNotCutTheErrorByThreeIsNotProposed() {
        // Half the changes ask for 20 less, half for none: blind down moves 11, but the mean error stays 10.
        var samples = Enumerable.Range(0, 3).SelectMany(d => new[] { 66, 86 }.Select(c => SuggestData.Make(d, 9, 30, 0.35, c, Levels))).ToList();
        Assert.Equal(67, Math.Round(Suggest.Fit(samples, Levels, [Level.BlindDown])[1], MidpointRounding.AwayFromZero));
        Assert.Equal(10, Suggest.MeanAbsError(samples, [100, 67, 75]));
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void AClearPatternIsProposedWithItsSentence() {
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();   // auto 86
        var s = Suggest.SuggestionFor("m", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay);
        Assert.NotNull(s);
        Assert.Equal(new[] { Level.BlindDown }, s!.Changes.Select(c => c.Level));
        Assert.Equal(16, s.Amount);
        Assert.True(s.Lower);
        Assert.Equal(4, s.Days);
        Assert.Equal(4, s.Samples);
        string to = Suggestion.Fmt(s.Changes[0].To);
        Assert.Equal($"You lower Monitor by about 16 with the blind partly or fully down. Set blind down 78 → {to}?", s.Sentence("Monitor"));
        Assert.Equal($"suggest: Monitor blind down 78 → {to} (4 changes on 4 days)", s.LogLine("Monitor"));
    }

    [Fact]
    public void OtherMonitorsAndUnavailableLevelsAreLeftOut() {
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();
        Assert.Null(Suggest.SuggestionFor("other", samples, Levels, Local, Later, null, dayOf: SuggestData.UtcDay));
        // Blind down comes from Home Assistant and is unavailable right now.
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, [NumberStep.Whole, null, NumberStep.Whole], Later, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void NotNowHidesTheSuggestionForSevenDays() {
        var samples = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Levels)).ToList();
        double until = Later + Suggest.NotNow;
        Assert.Equal(7 * 86400, Suggest.NotNow);
        Assert.Null(Suggest.SuggestionFor("m", samples, Levels, Local, until - 60, until, dayOf: SuggestData.UtcDay));
        Assert.NotNull(Suggest.SuggestionFor("m", samples, Levels, Local, until, until, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void TwoLevelsAreListedMainFirst() {
        var s = new Suggestion("m", [new LevelChange(Level.BlindDown, 78, 62), new LevelChange(Level.Day, 100, 95)], 12, true, 12, 4);
        Assert.Equal("You lower Monitor by about 12 with the blind partly or fully down. Set blind down 78 → 62, day 100 → 95?", s.Sentence("Monitor"));
        Assert.Equal("62.5", Suggestion.Fmt(62.5));
        var up = new Suggestion("m", [new LevelChange(Level.Night, 20, 30)], 8, false, 3, 3);
        Assert.Equal("You raise Monitor by about 8 in the evening. Set night 20 → 30?", up.Sentence("Monitor"));
    }
}

public class SuggestRecorderTests {
    static readonly double[] Levels = [100, 78, 75];

    [Fact]
    public void AChangeSettlesAfterFiveMinutes() {
        var r = new Recorder();
        var x = SuggestData.Make(0, 9, 30, 0.35, 70, Levels);
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", true, Levels, x.At + 299));
        Assert.Equal(x, r.Settle("m", true, Levels, x.At + 300));
        Assert.Null(r.Settle("m", true, Levels, x.At + 330));   // once
    }

    [Fact]
    public void ASecondChangeWithinFiveMinutesReplacesTheFirst() {
        var r = new Recorder();
        var first = SuggestData.Make(0, 9, 30, 0.35, 70, Levels);
        var second = first with { Chosen = 66, At = first.At + 120 };
        r.HandChanged("m", first);
        Assert.Null(r.Settle("m", true, Levels, first.At + 60));
        r.HandChanged("m", second);
        Assert.Null(r.Settle("m", true, Levels, first.At + 300));   // 3 minutes after the second
        Assert.Equal(66, r.Settle("m", true, Levels, second.At + 300)?.Chosen);
    }

    [Fact]
    public void AClearedOffsetDropsThePendingChange() {
        var r = new Recorder();
        var x = SuggestData.Make(0, 9, 30, 0.35, 70, Levels);
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", false, Levels, x.At + 60));
        Assert.Null(r.Settle("m", true, Levels, x.At + 400));
        // A level change drops it too.
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", true, [100, 62, 75], x.At + 400));
        Assert.Empty(r.Pending);
        // And so does an excluded change (or one put back) right after it.
        r.HandChanged("m", x);
        r.HandChanged("m", null);
        Assert.Null(r.Settle("m", true, Levels, x.At + 400));
    }

    static Sample? Make(int chosen = 70, int auto = 86, double elev = 30, bool lights = false, double[]? levels = null, SampleContext context = default) =>
        Suggest.MakeSample("m", chosen, auto, elev, 35, lights, 1, levels ?? Levels, new Tuning(), 1000, context);

    [Fact]
    public void AnOrdinaryHandChangeIsASample() {
        var x = Suggest.MakeSample("m", 70, 86, 30, 35, false, 0.8, Levels, new Tuning(), 1000, new SampleContext());
        Assert.Equal(new Sample("m", 70, 86, 0.8, 0.35, 30, false, Levels, 1000), x);
    }

    [Fact]
    public void EachExclusionIsNotRecorded() {
        Assert.NotNull(Make());
        Assert.Null(Make(context: new SampleContext(Follower: true)));
        Assert.Null(Make(context: new SampleContext(WriteFailed: true)));
        Assert.Null(Make(context: new SampleContext(Idle: true)));
        Assert.Null(Make(context: new SampleContext(Paused: true)));
        Assert.Null(Make(context: new SampleContext(SunFallback: true)));
        Assert.Null(Make(0)); Assert.Null(Make(100));
        Assert.Null(Make(auto: 0)); Assert.Null(Make(auto: 100));
        // The lights boost decided the target: sun 0°, lights on, night 30 + 5 above the blend.
        Assert.Null(Make(40, auto: 35, elev: 0, lights: true, levels: [32, 32, 30]));
        Assert.NotNull(Make(40, auto: 35, elev: 0, lights: false, levels: [32, 32, 30]));
    }

    [Fact]
    public void AHomeAssistantSetIsNotAHandChange() {
        var before = new Hold(null, 80, 80);
        var after = new Hold(null, 50, 80, -30, 1, 1000);
        Assert.True(Suggest.IsHandChange(before, after, null, 1000));
        Assert.False(Suggest.IsHandChange(before, after, 50, 1000));
        Assert.False(Suggest.IsHandChange(after, after, null, 1030));   // held from an earlier tick
    }

    [Fact]
    public void DecideMarksAHandChangeWithItsTime() {
        var before = new Hold(null, 86, 86);
        var step = Rules.Decide(70, 86, null, before, true, true, 1, touched: true, now: 1000, dayOf: _ => 0);
        Assert.Equal(-16, step.State.Offset);
        Assert.True(Suggest.IsHandChange(before, step.State, step.Remote, 1000));
    }

    [Fact]
    public void ApplyClearsTheOffsetSoTheCorrectionIsNotDoubled() {
        // Target 85, the user set 70 (offset −15). The new levels give 70.
        var held = new Hold(null, 70, 85, -15, 1, 1000);
        var kept = Rules.Decide(70, 70, null, held, true, true, 1, touched: false, now: 1060, dayOf: _ => 0);
        Assert.Equal(55, kept.Applied);   // what would happen without clearing
        var cleared = Rules.Decide(70, 70, null, Suggest.AfterApply(held), true, true, 1, touched: false, now: 1060, dayOf: _ => 0);
        Assert.Equal(70, cleared.Applied);
        Assert.Null(cleared.Write);
        Assert.Null(cleared.State.Offset);
    }
}

public class SuggestStoreTests {
    [Fact]
    public void StaleSamplesAreDroppedWhenTheLevelsChange() {
        var old = SuggestData.Make(0, 9, 30, 0.35, 70, [100, 78, 75]);
        var fresh = SuggestData.Make(1, 9, 30, 0.35, 70, [100, 62, 75]);
        var unplugged = SuggestData.Make(0, 9, 30, 0.35, 70, [90, 50, 30], monitor: "other");
        var kept = Suggest.DropStale([old, fresh, unplugged], new Dictionary<string, double[]> { ["m"] = [100, 62, 75] });
        Assert.Equal(new[] { fresh, unplugged }, kept);
        // A suggestion only counts samples taken with the levels in effect now.
        Assert.True(Suggest.SameLevels([100, 62.0000001, 75], [100, 62, 75]));
        Assert.False(Suggest.SameLevels([100, 62.5, 75], [100, 62, 75]));
    }

    [Fact]
    public void SamplesOlderThanFourteenDaysAreDropped() {
        double now = SuggestData.T0 + 20 * 86400;
        var a = SuggestData.Make(5, 9, 30, 0.35, 70, [100, 78, 75]);   // 15 days old
        var b = SuggestData.Make(7, 9, 30, 0.35, 70, [100, 78, 75]);   // 13 days old
        Assert.Equal(new[] { b }, Suggest.DropOld([a, b], now));
    }

    [Fact]
    public void SamplesSurviveTheFile() {
        var x = SuggestData.Make(0, 9, 30, 0.35, 70, [100, 78, 75]);
        Assert.Equal(new[] { x }, Suggest.Decode(Suggest.Encode([x])));
        string text = Suggest.Encode([x]);
        foreach (var key in new[] { "\"monitor\"", "\"chosen\"", "\"auto\"", "\"s\"", "\"p\"", "\"elev\"", "\"lights\"", "\"levels\"", "\"at\"" })
            Assert.Contains(key, text);
        Assert.Empty(Suggest.Decode(null));
        Assert.Empty(Suggest.Decode("broken"));
        Assert.Empty(Suggest.Decode("""{"samples": [{"monitor": "m", "chosen": 70, "auto": 86, "s": 1, "p": 0.35, "elev": 30, "lights": false, "levels": [100, 78], "at": 0}]}"""));
    }
}

/// Anonymised from one real week: every morning the user lowered the monitor 6–15 points with the blind
/// 30–40% open, with the levels day 100 / blind down 78 / night 75.
public class SuggestFixtureTests {
    static readonly double[] Week = [100, 78, 75];
    static List<Sample> WeekSamples() {
        var l = Week;
        return [
            // Mornings, full daylight, the blind 30–40% open: about 15 lower than the automatic level.
            SuggestData.Make(0, 8.5, 20, 0.30, 70, l), SuggestData.Make(0, 9.5, 24, 0.35, 72, l),
            SuggestData.Make(1, 8.5, 20, 0.35, 70, l), SuggestData.Make(1, 9.0, 22, 0.40, 74, l),
            SuggestData.Make(2, 8.5, 20, 0.30, 71, l), SuggestData.Make(2, 9.5, 24, 0.35, 70, l),
            SuggestData.Make(3, 8.5, 20, 0.35, 72, l), SuggestData.Make(3, 9.0, 22, 0.30, 73, l),
            SuggestData.Make(4, 8.5, 20, 0.40, 75, l), SuggestData.Make(4, 9.5, 24, 0.35, 70, l),
            // Midday with the blind 60% open: a small lowering.
            SuggestData.Make(1, 13, 30, 0.60, 88, l), SuggestData.Make(3, 13, 30, 0.60, 89, l),
            // Late afternoon, blind open, sun low: raised a little.
            SuggestData.Make(1, 16, 9, 1, 98, l),
        ];
    }

    [Fact]
    public void TheWeekHasTheAutomaticLevelsTheUserSaw() =>
        Assert.Equal(new[] { 85, 86, 86, 87, 85, 86, 86, 85, 87, 86, 91, 91, 95 }, WeekSamples().Select(x => x.Auto));

    [Fact]
    public void TheWeekProposesALowerBlindDownOnly() {
        var samples = WeekSamples();
        Assert.Equal(new[] { Level.BlindDown }, Suggest.Candidates(samples, SuggestData.UtcDay));
        Assert.Equal(61.42, Suggest.Fit(samples, Week, [Level.BlindDown])[1], 0.01);
        Assert.Equal(11.54, Suggest.MeanAbsError(samples, Week), 0.01);
        Assert.Equal(3.31, Suggest.MeanAbsError(samples, [100, 61, 75]), 0.01);
        var s = Suggest.SuggestionFor("m", samples, Week, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                      SuggestData.T0 + 5 * 86400, null, dayOf: SuggestData.UtcDay);
        Assert.NotNull(s);
        Assert.Equal(new[] { Level.BlindDown }, s!.Changes.Select(c => c.Level));   // night not proposed, day not raised
        double to = s.Changes[0].To;
        Assert.True(to <= 78 - 5);
        Assert.InRange(to, 45, 65);
        Assert.Equal(61, to);
        Assert.Equal(14, s.Amount);
        Assert.Equal("You lower Monitor by about 14 with the blind partly or fully down. Set blind down 78 → 61?", s.Sentence("Monitor"));
        Assert.Equal("suggest: Monitor blind down 78 → 61 (13 changes on 5 days)", s.LogLine("Monitor"));
    }

    [Fact]
    public void TheDayAfterRecordsTwoChangesAndFitsBlindDownLower() {
        // Levels day 95 / blind down 62 / night 75. Two changes held, a third was put back within 3 minutes.
        double[] l = [95, 62, 75];
        var first = SuggestData.Make(5, 8.5, 20, 0.40, 63, l);     // 75 → 63
        var putBack = SuggestData.Make(5, 11, 22, 0.40, 69, l);    // 75 → 69, then back
        var second = SuggestData.Make(5, 15, 4.5, 0.58, 72, l);    // 78 → 72, low afternoon sun
        Assert.Equal(new[] { 75, 75, 78 }, new[] { first.Auto, putBack.Auto, second.Auto });
        var r = new Recorder();
        var finals = new List<Sample>();
        void Ticks(double start, double seconds, bool held) {
            for (double t = start + 30; t <= start + seconds; t += 30)
                if (r.Settle("m", held, l, t) is Sample f) finals.Add(f);
        }
        r.HandChanged("m", first); Ticks(first.At, 600, true);
        r.HandChanged("m", putBack); Ticks(putBack.At, 150, true);
        r.HandChanged("m", null);      // put back to automatic at +3 min: Decide clears the offset
        Ticks(putBack.At + 180, 600, false);
        r.HandChanged("m", second); Ticks(second.At, 600, true);
        Assert.Equal(new[] { 63, 72 }, finals.Select(x => x.Chosen));
        // One day is not enough to suggest...
        Assert.Empty(Suggest.Candidates(finals, SuggestData.UtcDay));
        Assert.Null(Suggest.SuggestionFor("m", finals, l, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                          second.At + 600, null, dayOf: SuggestData.UtcDay));
        // ...but the fit points the right way: blind down lower.
        double bd = Suggest.Fit(finals, l, [Level.BlindDown])[1];
        Assert.Equal(55.88, bd, 0.01);
        Assert.InRange(bd, 35, 57);
    }

    /// The three situations a proposal must leave alone unless the samples cover them: a sunny day with the
    /// blind fully down, a sunny day with it open, an evening with the lights on.
    static readonly (Level Level, double Elev, double Pos, bool Lights)[] References = [
        (Level.BlindDown, 30, 0, false), (Level.Day, 30, 100, false), (Level.Night, -6, 100, true),
    ];
    static int ReferenceTarget(double[] l, (Level Level, double Elev, double Pos, bool Lights) r) {
        var t = new Tuning();
        return Rules.Target(l, r.Pos, r.Lights, t.Fraction(r.Elev), t, r.Elev < t.LightsBoostSunBelow);
    }

    [Fact]
    public void CloudyMorningsMakeNoSuggestion() {
        // The day after's two held changes, replayed on three days with thin daylight (0.5–0.7) at levels 95 / 62 / 75.
        // At blind 40% day and blind down mix to 75.2, the same as night: no level explains the change.
        double[] l = [95, 62, 75];
        var elevs = new[] { (Morning: 4.5, Afternoon: 7.5), (Morning: 6.0, Afternoon: 6.0), (Morning: 7.5, Afternoon: 4.5) };
        var samples = elevs.SelectMany((e, d) => new[] {
            SuggestData.Make(6 + d, 9, e.Morning, 0.40, 63, l), SuggestData.Make(6 + d, 15, e.Afternoon, 0.58, 72, l) }).ToList();
        Assert.Equal(new[] { 75, 79, 75, 79, 75, 78 }, samples.Select(x => x.Auto));
        Assert.Empty(Suggest.Candidates(samples, SuggestData.UtcDay));   // no level reaches 0.55 of the weight
        Assert.Null(Suggest.SuggestionFor("m", samples, l, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                          SuggestData.T0 + 10 * 86400, null, dayOf: SuggestData.UtcDay));
    }

    [Fact]
    public void ReferencesStayPut() {
        // Every fixture that suggests: the evening with the lights on, and the situation of each level not
        // proposed, keep their target within 3 points.
        var clear = Enumerable.Range(0, 4).Select(d => SuggestData.Make(d, 9, 30, 0.35, 70, Week)).ToList();
        foreach (var samples in new[] { WeekSamples(), clear }) {
            var s = Suggest.SuggestionFor("m", samples, Week, [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole],
                                          SuggestData.T0 + 5 * 86400, null, dayOf: SuggestData.UtcDay);
            Assert.NotNull(s);   // the fixture should suggest
            var after = (double[])Week.Clone();
            foreach (var ch in s!.Changes) after[(int)ch.Level] = ch.To;
            var proposed = s.Changes.Select(ch => ch.Level).ToHashSet();
            foreach (var r in References.Where(x => x.Level == Level.Night || !proposed.Contains(x.Level)))
                Assert.InRange(Math.Abs(ReferenceTarget(after, r) - ReferenceTarget(Week, r)), 0, 3);
            Assert.Equal(80, ReferenceTarget(after, References[2]));    // evening: night 75 + the lights' 5
            Assert.Equal(100, ReferenceTarget(after, References[1]));   // sunny, blind open: day 100
        }
    }
}

public class SuggestConfigTests {
    [Fact]
    public void ApplyWritesOneLocalLevelAndKeepsEverythingElse() {
        const string file = """
            { "source": "sun", "location": { "latitude": 51.48, "longitude": 0.00 }, "custom": true,
              "monitors": [ { "match": "Monitor", "label": "Desk", "day": 100, "blindDown": 78, "night": 75, "contrast": 60 },
                            { "match": "Other", "day": 50 } ] }
            """;
        string text = ConfigPatch.SetLevels(new Dictionary<string, int> { ["blindDown"] = 61 }, "Generic Monitor", "Monitor", file);
        var root = JsonNode.Parse(text)!.AsObject();
        var mons = root["monitors"]!.AsArray();
        Assert.Equal(2, mons.Count);
        Assert.Equal(61, mons[0]!["blindDown"]!.GetValue<int>());
        Assert.Equal(100, mons[0]!["day"]!.GetValue<int>());
        Assert.Equal(75, mons[0]!["night"]!.GetValue<int>());
        Assert.Equal("Desk", mons[0]!["label"]!.GetValue<string>());
        Assert.Equal(60, mons[0]!["contrast"]!.GetValue<int>());
        Assert.Equal(50, mons[1]!["day"]!.GetValue<int>());
        Assert.True(root["custom"]!.GetValue<bool>());
        Assert.Contains("51.48", text);
        Assert.DoesNotContain("51.479", text);
    }

    [Fact]
    public void ApplyAddsAnEntryForAMonitorWithoutOne() {
        string text = ConfigPatch.SetLevels(new Dictionary<string, int> { ["blindDown"] = 30, ["day"] = 65 }, "Generic Monitor", "Monitor",
                                            """{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0 } }""");
        var mons = JsonNode.Parse(text)!["monitors"]!.AsArray();
        Assert.Single(mons);
        Assert.Equal("Monitor", mons[0]!["match"]!.GetValue<string>());
        Assert.Equal(30, mons[0]!["blindDown"]!.GetValue<int>());
        Assert.Equal(65, mons[0]!["day"]!.GetValue<int>());
        Assert.Null(mons[0]!["night"]);
    }

    [Fact]
    public void ApplyRefusesAFileThatIsNotAnObject() {
        Assert.Throws<InvalidDataException>(() => ConfigPatch.SetLevels(new Dictionary<string, int> { ["day"] = 60 }, "Monitor", "Monitor", "[1]"));
        Assert.Throws<InvalidDataException>(() => ConfigPatch.SetLevels(new Dictionary<string, int> { ["day"] = 60 }, "Monitor", "Monitor", """{ "monitors": 3 }"""));
    }
}
