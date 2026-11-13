using Xunit;

namespace Daylit.Tests;

public class NightLightsTargetTests {
    // The spec's example monitor: day 95, blind down 62, night 60, lights on 80.
    static readonly double[] Four = [95, 62, 60, 80];
    static int T(double elev, double pos, bool lights, double light = 1) {
        var t = new Tuning();
        return Rules.Target(Four, pos, lights, t.Fraction(elev), t, elev < t.LightsBoostSunBelow, light);
    }

    /// The target rule before the optional nightLights level, copied as it was: the regression guard.
    static int TargetBefore(double[] v, double pos, bool lights, double sun, Tuning? t = null, bool? boost = null, double light = 1) {
        double daytime = v[1] + (v[0] - v[1]) * pos / 100;
        double x = v[2] + (daytime - v[2]) * Math.Min(sun, light);
        if (lights && (boost ?? sun < 0.3)) x = Math.Max(x, v[2] + (t?.LightsBoost ?? 5));
        return (int)Math.Round(Math.Clamp(x, 0, 100), MidpointRounding.AwayFromZero);
    }

    [Fact]
    public void WithoutNightLightsTheTargetIsExactlyAsBefore() {
        var custom = new Tuning { Brightness = new() { LightsBoost = 12, LightsBoostSunBelow = 4 } };
        double[][] all = [[70, 40, 20], [95, 62, 75], [100, 78, 75], [30, 50, 90], [0, 0, 0], [100, 100, 100]];
        int checkedCount = 0;
        foreach (var t in new[] { new Tuning(), custom })
            foreach (var v in all)
                for (double e = -12; e <= 40; e += 0.5)
                    foreach (var pos in new[] { 0.0, 25, 40, 58, 100 })
                        foreach (var lights in new[] { false, true })
                            foreach (var light in new[] { 0.2, 0.5, 0.8, 1 }) {
                                double sun = t.Fraction(e);
                                bool boost = e < t.LightsBoostSunBelow;
                                Assert.Equal(TargetBefore(v, pos, lights, sun, t, boost, light), Rules.Target(v, pos, lights, sun, t, boost, light));
                                Assert.Equal(TargetBefore(v, pos, lights, sun, t, null, light), Rules.Target(v, pos, lights, sun, t, null, light));
                                checkedCount++;
                            }
        Assert.Equal(2 * 6 * 105 * 5 * 2 * 4, checkedCount);
    }

    [Fact]
    public void LightsOffBlendsTowardNightWithNoBoost() {
        var t = new Tuning();
        for (double e = -10; e <= 20; e += 0.5)
            foreach (var pos in new[] { 0.0, 40, 100 })
                Assert.Equal(TargetBefore([95, 62, 60], pos, false, t.Fraction(e), t, e < t.LightsBoostSunBelow), T(e, pos, false));
        Assert.Equal(60, T(-10, 100, false));   // dark, lights off: night, not night + 5
    }

    [Fact]
    public void LightsOnWithTheSunHighChangeNothing() {
        foreach (var pos in new[] { 0.0, 40, 58, 100 })
            foreach (var light in new[] { 0.3, 0.5, 1 })
                Assert.Equal(T(30, pos, false, light), T(30, pos, true, light));
    }

    [Fact]
    public void LightsOnWithTheSunDownGiveTheLightsOnLevel() {
        foreach (var e in new[] { -3.0, -6, -20 })
            foreach (var pos in new[] { 0.0, 100 })
                Assert.Equal(80, T(e, pos, true));
    }

    [Fact]
    public void TheDuskTransitionHasNoStep() {
        foreach (var pos in new[] { 0.0, 40, 100 })
            foreach (var light in new[] { 0.5, 1 }) {
                int prev = T(-6, pos, true, light);
                for (int i = 1; i <= 260; i++) {   // -6° to 20° in steps of 0.1°
                    int now = T(-6 + i / 10.0, pos, true, light);
                    Assert.True(Math.Abs(now - prev) <= 2, $"pos {pos} light {light} at {-6 + i / 10.0}°");
                    prev = now;
                }
            }
    }

    [Fact]
    public void TheExampleValues() {
        // A cloudy morning: the sun is high but clouds cap daylight at half.
        Assert.Equal(68, T(30, 40, true, 0.5));    // 67.6
        Assert.Equal(71, T(30, 58, true, 0.5));    // 70.57 (the spec rounds this to 70)
        Assert.Equal(70, T(30, 58, true, 0.49));   // 70.36
        Assert.Equal(79, T(30, 100, true, 0.55));  // 79.25
        Assert.Equal(80, T(-10, 100, true));       // a dark evening with the lights on
        // The same cloudy morning before: night 75 kept it at 75 or more.
        Assert.Equal(75, Rules.Target([95, 62, 75], 40, true, 1, new Tuning(), false, 0.5));
    }
}

public class NightLightsLevelsTests {
    [Fact]
    public void HomeAssistantValueWinsWhenZeroOrMore() {
        Assert.Equal(new double[] { 70, 40, 20, 65 }, Chart.EffectiveLevels([70, 40, 20, 50], [-1, -1, -1, 65, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20, 0 }, Chart.EffectiveLevels([70, 40, 20, 50], [-1, -1, -1, 0, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20, 50 }, Chart.EffectiveLevels([70, 40, 20, 50], [-1, -1, -1, -1, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20, 65 }, Chart.EffectiveLevels([70, 40, 20], [-1, -1, -1, 65, -1, 0]));
    }

    [Fact]
    public void WithNoValueThereIsNoNightLights() {
        Assert.Equal(new double[] { 70, 40, 20 }, Chart.EffectiveLevels([70, 40, 20], [-1, -1, -1, -1, -1, 0]));
        Assert.Equal(new double[] { 70, 40, 20 }, Chart.EffectiveLevels([70, 40, 20], null));
        Assert.Equal(new double[] { 70, 40, 20 }, Chart.EffectiveLevels([70, 40, 20, -1], null));
        Assert.Null(Rules.NightLightsLevel([70, 40, 20]));
        Assert.Equal(80, Rules.NightLightsLevel([70, 40, 20, 80]));
    }
}

public class NightLightsFallbackTests {
    [Fact]
    public void HomeAssistantsAnswerIsUsedWhileItGivesOne() {
        foreach (var has in new[] { false, true }) {
            Assert.True(Rules.RoomLights(true, true, false, has));
            Assert.False(Rules.RoomLights(false, true, true, has));
        }
    }

    [Fact]
    public void AMonitorWithNightLightsKeepsTheLastLightsStateWhileHomeAssistantIsDown() {
        Assert.True(Rules.RoomLights(false, false, true, true));
        Assert.False(Rules.RoomLights(false, false, false, true));
        Assert.False(Rules.RoomLights(false, false, null, true));   // none seen yet: off
    }

    [Fact]
    public void AMonitorWithoutNightLightsCountsTheLightsAsOffInTheFallbackAsBefore() =>
        Assert.False(Rules.RoomLights(false, false, true, false));

    [Fact]
    public void ALitEveningDoesNotDropToNightDuringAnOutage() {
        bool lit = Rules.RoomLights(false, false, true, true);
        var t = new Tuning();
        Assert.Equal(80, Rules.Target([95, 62, 60, 80], 100, lit, t.Fraction(-10), t, true));
    }
}

public class NightLightsConfigTests {
    static string Write(string text) {
        var p = Path.Combine(Path.GetTempPath(), $"daylit-test-{Guid.NewGuid()}.json");
        File.WriteAllText(p, text);
        return p;
    }
    static System.Text.Json.Nodes.JsonObject Json(string s) => (System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse(s)!;
    static readonly SettingsEdit.Monitor Dell = new("DELL U2723QE", "U2723QE", "Left", 95, 62, 60);
    const string Original = """{ "monitors": [ { "match": "U2723QE", "night": 60, "nightLights": 80, "control": "ddc", "homeAssistant": { "nightLights": "input_number.lit" } } ] }""";

    [Fact]
    public void LoadsTheLocalLevelAndTheHelper() {
        var (c, err) = Config.Load(Write("""{ "monitors": [ { "match": "Dell", "night": 60, "nightLights": 80, "homeAssistant": { "nightLights": "input_number.lit" } } ] }"""));
        Assert.Null(err);
        Assert.Equal(80, c.Monitors![0].NightLights);
        Assert.Equal("input_number.lit", c.Monitors![0].HomeAssistant!.NightLights);
    }

    [Fact]
    public void WithoutTheKeyThereIsNoLevel() =>
        Assert.Null(Config.Load(Write("""{ "monitors": [ { "match": "Dell", "night": 60 } ] }""")).cfg.Monitors![0].NightLights);

    [Theory]
    [InlineData("-1")]
    [InlineData("101")]
    public void ALevelOutsideZeroToHundredIsAProblem(string v) =>
        Assert.Equal("config.json: monitor \"Dell\" nightLights is 0 to 100",
                     Config.Load(Write($$"""{ "monitors": [ { "match": "Dell", "nightLights": {{v}} } ] }""")).error);

    [Fact]
    public void ZeroAndHundredAreFine() {
        Assert.Null(Config.Load(Write("""{ "monitors": [ { "match": "Dell", "nightLights": 0 } ] }""")).error);
        Assert.Null(Config.Load(Write("""{ "monitors": [ { "match": "Dell", "nightLights": 100 } ] }""")).error);
    }

    [Fact]
    public void AHelperThatIsNotAnEntityIdIsAProblem() =>
        Assert.Equal("config.json: monitor \"Dell\" homeAssistant.nightLights is not an entity id like light.office",
                     Config.Load(Write("""{ "monitors": [ { "match": "Dell", "homeAssistant": { "nightLights": "lit" } } ] }""")).error);

    [Fact]
    public void SettingsSavesTheLevelAndKeepsEveryOtherKey() {
        var m = Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { NightLights = 85, NightLightsEditable = true }]), Original))["monitors"]![0]!;
        Assert.Equal(85, (int)m["nightLights"]!);
        Assert.Equal("ddc", (string)m["control"]!);
        Assert.Equal("input_number.lit", (string)m["homeAssistant"]!["nightLights"]!);
    }

    [Fact]
    public void AnEmptyBoxRemovesTheKey() =>
        Assert.Null(Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { NightLights = null, NightLightsEditable = true }]), Original))["monitors"]![0]!["nightLights"]);

    [Fact]
    public void WithoutTheBoxTheFileKeepsItsLevel() =>
        Assert.Equal(80, (int)Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell]), Original))["monitors"]![0]!["nightLights"]!);

    [Fact]
    public void AValueOutOfRangeIsClamped() =>
        Assert.Equal(100, (int)Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { NightLights = 140, NightLightsEditable = true }]), Original))["monitors"]![0]!["nightLights"]!);
}

public class NightLightsHomeAssistantTests {
    [Fact]
    public void TheTemplateAsksForTheHelperAsTheFourthNumber() =>
        Assert.Contains("[-1, -1, -1, {{ states('input_number.lit') | float(-1) }}, -1, 0]",
                        HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { NightLights = "input_number.lit" }]));

    [Fact]
    public void AMonitorWithoutTheHelperGetsMinusOneThere() =>
        Assert.Contains("[{{ states('input_number.d') | float(-1) }}, -1, -1, -1, -1, 0]",
                        HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { Day = "input_number.d" }]));

    [Fact]
    public void ABadHelperIdIsDroppedFromTheTemplate() =>
        Assert.DoesNotContain("input_number.x", HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { NightLights = "input_number.x'}}" }]));
}

public class NightLightsSuggestTests {
    static readonly double[] Four = [95, 62, 60, 80];
    static Sample? Make(double elev, bool lights, double[] levels) =>
        Suggest.MakeSample("m", 70, 75, elev, 40, lights, 1, levels, new Tuning(), 1000, new SampleContext());

    [Theory]
    [InlineData(-10.0)]
    [InlineData(0.0)]
    [InlineData(5.0)]
    [InlineData(11.9)]
    // The four-level weights explain these ticks, so they are recorded like any other.
    public void LitTwilightOnAMonitorWithNightLightsIsASample(double elev) => Assert.True(Make(elev, true, Four)?.Lights);

    [Fact]
    public void SamplesWithTheLightsOffOrTheSunFullyUp() {
        Assert.Equal(Four, Make(5, false, Four)!.Levels);
        Assert.Equal(Four, Make(12, true, Four)!.Levels);
    }

    [Fact]
    public void AMonitorWithoutNightLightsStillRecordsThoseTicks() =>
        Assert.NotNull(Make(5, true, [95, 62, 60]));   // at 5° the boost no longer applies, so the three-level rule decides

    [Fact]
    public void ChangingNightLightsMakesOlderSamplesStale() {
        var x = Make(30, false, Four)!;
        Assert.Empty(Suggest.DropStale([x], new Dictionary<string, double[]> { ["m"] = [95, 62, 60, 85] }));
        Assert.Empty(Suggest.DropStale([x], new Dictionary<string, double[]> { ["m"] = [95, 62, 60] }));
        Assert.Single(Suggest.DropStale([x], new Dictionary<string, double[]> { ["m"] = Four }));
        var r = new Recorder();
        r.HandChanged("m", x);
        Assert.Null(r.Settle("m", true, [95, 62, 60, 85], x.At + 400));
    }

    [Fact]
    public void TheFitKeepsNightLightsAsItIs() {
        var samples = Enumerable.Range(0, 6).Select(i => new Sample("m", 55, 62, 1, 0, 30, false, Four, i * 86400.0)).ToList();
        var fitted = Suggest.Fit(samples, Four, [Level.BlindDown]);
        Assert.Equal(4, fitted.Length);
        Assert.Equal(80, fitted[3]);
        Assert.Equal(56, fitted[1], 2);   // (6 · 55 + 62) / 7
    }

    [Fact]
    public void FourLevelSamplesSurviveTheFile() {
        var x = Make(30, false, Four)!;
        Assert.Equal(new[] { x }, Suggest.Decode(Suggest.Encode([x])));
    }
}

public class NightLightsExplainTests {
    [Fact]
    public void TheLightsStepShowsTheLightsOnLevel() {
        var d = Chart.Explain(95, 62, 60, -10, 100, true, nightLights: 80);
        Assert.Equal(80, d.Level);
        Assert.Equal("on → 80", d.Steps.First(s => s.Title == "Lights").Value);
    }

    [Fact]
    public void LightsOffShowOffUntilTheSunIsFullyUp() {
        Assert.Equal("off", Chart.Explain(95, 62, 60, 5, 100, false, nightLights: 80).Steps.First(s => s.Title == "Lights").Value);
        Assert.Equal("no effect by day", Chart.Explain(95, 62, 60, 30, 100, false, nightLights: 80).Steps.First(s => s.Title == "Lights").Value);
    }

    [Fact]
    public void TheLevelEqualsTheTarget() {
        var t = new Tuning();
        for (double e = -8; e <= 20; e += 0.5)
            foreach (var lights in new[] { false, true })
                Assert.Equal(Rules.Target([95, 62, 60, 80], 40, lights, t.Fraction(e), t, e < t.LightsBoostSunBelow, 0.7),
                             Chart.Explain(95, 62, 60, e, 40, lights, light: 0.7, nightLights: 80).Level);
    }
}

public class FieldUnchangedTests {
    [Fact]
    public void UntouchedTextKeepsTheFilesValue() {
        var r = ContrastRule.ParseField("72.5", "72.5");
        Assert.True(r.ok); Assert.True(r.keep); Assert.Null(r.value);
        Assert.True(ContrastRule.ParseField("", "").keep);
    }

    [Fact]
    public void AnEditedBoxIsParsedAndRounded() {
        var r = ContrastRule.ParseField("73.4", "72.5");
        Assert.True(r.ok); Assert.False(r.keep); Assert.Equal(73, r.value);
        Assert.Null(ContrastRule.ParseField("", "72.5").value);
        Assert.False(ContrastRule.ParseField("", "72.5").keep);
        Assert.False(ContrastRule.ParseField("x", "72.5").ok);
    }
}

/// A sample as the app records it: daylight capped by `light`, Auto from the real target with these levels.
static class Recorded {
    public static Sample Make(int day, double hour, double elev, double p, bool lights, int chosen, double[] l, double light = 1) {
        var t = new Tuning();
        double s = Math.Min(t.Fraction(elev), light);
        int auto = Rules.Target(l, p * 100, lights, t.Fraction(elev), t, elev < t.LightsBoostSunBelow, light);
        return new Sample("m", chosen, auto, s, p, elev, lights, l, SuggestData.T0 + day * 86400 + hour * 3600);
    }
}

public class NightLightsWeightTests {
    static readonly double[] Four = [95, 62, 60, 80];
    static readonly double[] Three = [95, 62, 60];

    static void Same(double[] want, double[] got) {
        Assert.Equal(want.Length, got.Length);
        for (int k = 0; k < want.Length; k++) Assert.Equal(want[k], got[k], 1e-9);
    }

    [Fact]
    public void WithTheLightsOnWhatDaylightLeavesIsSplitBetweenNightAndLightsOn() {
        // Sun at 3° (daylight 0.4), blind open, lights on: 0.6 left, 40% of it to night and 60% to lights on.
        var x = Recorded.Make(0, 18, 3, 1, true, 70, Four);
        var w = Suggest.Weights(x, true);
        Same([0.4, 0, 0.24, 0.36], w);
        Assert.Equal(1, w.Sum(), 1e-9);
        Same([0.4, 0, 0.6, 0], Suggest.Weights(x with { Lights = false }, true));
        Same([0.4, 0, 0.6, 0], Suggest.Weights(x, false));
    }

    [Fact]
    public void TheWeightsGiveTheTarget() {
        // The fit is only right when the weights are the target's own blend: check them against it everywhere.
        foreach (double elev in new[] { -8.0, -3, 0, 3, 6, 9, 12, 30 })
            foreach (double p in new[] { 0.0, 0.4, 1 })
                foreach (double light in new[] { 0.3, 1 })
                    foreach (bool lights in new[] { false, true }) {
                        var x = Recorded.Make(0, 12, elev, p, lights, 50, Four, light);
                        var w = Suggest.Weights(x, true);
                        double blend = w.Zip(Four).Sum(z => z.First * z.Second);
                        Assert.True(Math.Abs(blend - x.Auto) <= 0.5, $"elev {elev} p {p} light {light} lights {lights}: {blend} vs {x.Auto}");
                    }
    }

    [Fact]
    public void NightAndLightsOnCountFromPointFourFiveWhenTheirsIsTheLargestWeight() {
        // A cloudy morning, daylight held to half, blind 40% open: night 0.5, day 0.2, blind down 0.3.
        Assert.True(Suggest.Dominates(Recorded.Make(0, 9, 20, 0.4, false, 63, Three, 0.5), Level.Night));
        // Daylight 0.56: night 0.44, under the bar.
        Assert.False(Suggest.Dominates(Recorded.Make(0, 9, 20, 0.4, false, 63, Three, 0.56), Level.Night));
        // A dark evening with the lights on: all of it is the lights-on level, none night.
        var lit = Recorded.Make(0, 20, -6, 1, true, 72, Four);
        Assert.True(Suggest.Dominates(lit, Level.NightLights));
        Assert.False(Suggest.Dominates(lit, Level.Night));
        // The same evening on a monitor without the level: night, as before.
        Assert.True(Suggest.Dominates(Recorded.Make(0, 20, -6, 1, true, 72, Three), Level.Night));
        // An even split (no daylight counted, sun at 4.5°: half to each) counts for neither.
        var even = Recorded.Make(0, 17, 4.5, 1, true, 70, Four, 0);
        Assert.False(Suggest.Dominates(even, Level.Night));
        Assert.False(Suggest.Dominates(even, Level.NightLights));
        // Day and blind down keep their 0.55 bar: 0.5 of day is not enough even when it is the largest.
        Assert.False(Suggest.Dominates(Recorded.Make(0, 12, 4.5, 1, false, 70, Three), Level.Day));
    }

    [Fact]
    public void TheFitRecoversAllFourLevels() {
        double[] truth = [90, 50, 30, 70];
        var samples = new List<Sample>();
        for (int i = 0; i < 20; i++)
            foreach (double elev in new[] { -6.0, 0, 4.5, 9, 30 })
                foreach (double p in new[] { 0.0, 0.5, 1 })
                    foreach (bool lights in new[] { false, true }) {
                        var x = Recorded.Make(0, 12, elev, p, lights, 0, [70, 40, 20, 60]);
                        var w = Suggest.Weights(x, true);
                        samples.Add(x with { Chosen = (int)Math.Round(w.Zip(truth).Sum(z => z.First * z.Second), MidpointRounding.AwayFromZero) });
                    }
        var f = Suggest.Fit(samples, [70, 40, 20, 60], [Level.Day, Level.BlindDown, Level.Night, Level.NightLights]);
        for (int k = 0; k < 4; k++) Assert.True(Math.Abs(f[k] - truth[k]) <= 1, $"level {k}: {f[k]}");
    }

    [Fact]
    public void AMonitorWithoutNightLightsNeverFitsOne() {
        var lit = Enumerable.Range(0, 6).Select(d => Recorded.Make(d, 20, -6, 1, true, 50, Three)).ToList();
        Assert.DoesNotContain(Level.NightLights, Suggest.Candidates(lit, SuggestData.UtcDay));
        Assert.Equal(Three, Suggest.Fit(lit, Three, [Level.NightLights]));
    }

    [Fact]
    public void SamplesSavedBeforeKeepLoadingAndCountTheSame() {
        // A corrections.json written before the four-level fit: a lights-on sample in full daylight on a monitor
        // with nightLights (the only lit sample it recorded then) and a three-level one.
        const string text = """
        {"samples": [
          {"monitor": "m", "chosen": 70, "auto": 75, "s": 1, "p": 0.4, "elev": 30, "lights": true, "levels": [95, 62, 60, 80], "at": 1793577600},
          {"monitor": "m", "chosen": 70, "auto": 86, "s": 1, "p": 0.35, "elev": 30, "lights": false, "levels": [100, 78, 75], "at": 1793577600}
        ]}
        """;
        var got = Suggest.Decode(text);
        Assert.Equal(2, got.Count);
        // Sun fully up: the lights add nothing, so the sample weighs what it did with three levels.
        Same([.. Suggest.Weights(1, 0.4), 0], Suggest.Weights(got[0], true));
        Assert.Equal(got, Suggest.Decode(Suggest.Encode(got)));
    }
}

/// Cloudy mornings and lit evenings: the user wants a dimmer room darker and a lit evening a little lower.
public class NightLightsSuggestionTests {
    static readonly double[] Four = [95, 62, 60, 80];
    static readonly double[] Three = [95, 62, 60];
    static readonly NumberStep?[] Whole = [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole, NumberStep.Whole];   // a local nightLights, or one that may be added
    /// Sunny, blind fully down; sunny, blind open; a dark evening with the lights on.
    static readonly (double Elev, double Pos, bool Lights)[] References = [(30, 0, false), (30, 100, false), (-6, 100, true)];
    static int T(double[] l, (double Elev, double Pos, bool Lights) r) {
        var t = new Tuning();
        return Rules.Target(l, r.Pos, r.Lights, t.Fraction(r.Elev), t, r.Elev < t.LightsBoostSunBelow);
    }
    static double[] Applied(double[] l, Suggestion s) {
        var o = l.ToList();
        foreach (var c in s.Changes) { if ((int)c.Level < o.Count) o[(int)c.Level] = c.To; else o.Add(c.To); }
        return o.ToArray();
    }
    static Suggestion? Suggest4(List<Sample> samples, double[] levels, NumberStep?[]? steps = null) =>
        Suggest.SuggestionFor("m", samples, levels, steps ?? Whole, SuggestData.T0 + 6 * 86400, null, null, SuggestData.UtcDay);
    /// Two cloudy mornings (daylight held to half, blind 40% open, lights off) at 63 and two lit evenings at 72, on four days.
    static List<Sample> Week(double[] l, int morning = 63, int evening = 72) =>
        Enumerable.Range(0, 4).SelectMany(d => new[] {
            Recorded.Make(d, 8.5, 15, 0.4, false, morning, l, 0.5), Recorded.Make(d, 9.5, 20, 0.4, false, morning, l, 0.5),
            Recorded.Make(d, 20, -6, 1, true, evening, l), Recorded.Make(d, 21, -12, 1, true, evening, l) }).ToList();

    [Fact]
    public void CloudyMorningsAndLitEveningsSuggestNightAndLightsOn() {
        var samples = Week(Four);
        Assert.Equal(new[] { 68, 68, 80, 80 }, samples.Take(4).Select(x => x.Auto));
        Assert.Equal(new[] { Level.Night, Level.NightLights }, Suggest.Candidates(samples, SuggestData.UtcDay));
        var s = Suggest4(samples, Four);
        Assert.NotNull(s);
        var after = Applied(Four, s);
        // Within a few points of what the user chose (the pull toward today's levels keeps them a little short):
        Assert.Equal(54, after[2]);   // a 63 on the cloudy mornings asks for night 51
        Assert.Equal(73, after[3]);   // the lit evenings were set to 72
        Assert.Equal("You lower Monitor by about 8 with the lights on. Set lights on 80 → 73, night 60 → 54?", s.Sentence("Monitor"));
        // Sunny days do not change.
        foreach (var r in References.Take(2)) Assert.Equal(T(Four, r), T(after, r));
    }

    [Fact]
    public void AMonitorWithoutNightLightsIsOfferedOneBesideALowerNight() {
        // The same cloudy mornings on a monitor without the level; lit evenings were fine at night + the boost (65).
        var samples = Week(Three).Where(x => !x.Lights).ToList();
        var s = Suggest4(samples, Three);
        Assert.NotNull(s);
        Assert.Equal(new[] { Level.Night, Level.NightLights }, s.Changes.Select(c => c.Level));
        Assert.Equal(new LevelChange(Level.NightLights, 65, 65, true), s.Changes[1]);
        var after = Applied(Three, s);
        Assert.Equal(4, after.Length);
        // The lit evening keeps its level, and sunny days do not change.
        Assert.Equal(65, T(Three, References[2]));
        Assert.Equal(T(Three, References[2]), T(after, References[2]));
        foreach (var r in References.Take(2)) Assert.Equal(T(Three, r), T(after, r));
        Assert.Equal("You lower Monitor by about 5 when the room is dim. Set night 60 → 54, lights on 65 (new)?", s.Sentence("Monitor"));
    }

    [Fact]
    public void WithoutALightsOnStepOnlyNightIsOffered() {
        // Three steps, or none for the fourth: the room lights do not come from Home Assistant, so no level is added.
        var samples = Week(Three).Where(x => !x.Lights).ToList();
        foreach (var steps in new[] { Whole.Take(3).ToArray(), [NumberStep.Whole, NumberStep.Whole, NumberStep.Whole, null] })
            Assert.Equal(new[] { Level.Night }, Suggest4(samples, Three, steps)!.Changes.Select(c => c.Level));
    }

    [Fact]
    public void ARaisedNightIsOfferedAlone() {
        var s = Suggest4(Week(Three, morning: 76).Where(x => !x.Lights).ToList(), Three);
        Assert.Equal(new[] { Level.Night }, s!.Changes.Select(c => c.Level));
        Assert.False(s.Lower);
    }

    [Fact]
    public void TheLightsOnLevelReadsWithTheLightsOn() {
        var s = new Suggestion("m", [new LevelChange(Level.NightLights, 80, 72)], 8, true, 8, 4);
        Assert.Equal("You lower Monitor by about 8 with the lights on. Set lights on 80 → 72?", s.Sentence("Monitor"));
        var pair = new Suggestion("m", [new LevelChange(Level.Night, 60, 51), new LevelChange(Level.NightLights, 65, 65, true)], 5, true, 8, 4);
        Assert.Equal("You lower Monitor by about 5 when the room is dim. Set night 60 → 51, lights on 65 (new)?", pair.Sentence("Monitor"));
        Assert.Equal("suggest: Monitor night 60 → 51, lights on 65 (new) (8 changes on 4 days)", pair.LogLine("Monitor"));
    }

    [Fact]
    public void ApplyWritesTheLightsOnLevelBesideNight() {
        const string file = """{ "source": "sun", "location": { "latitude": 51.48, "longitude": 0 }, "monitors": [ { "match": "Monitor", "night": 60 } ] }""";
        string text = ConfigPatch.SetLevels(new Dictionary<string, int> { ["night"] = 51, ["nightLights"] = 65 }, "Generic Monitor", "Monitor", file);
        var mon = System.Text.Json.Nodes.JsonNode.Parse(text)!["monitors"]![0]!;
        Assert.Equal(51, (int)mon["night"]!);
        Assert.Equal(65, (int)mon["nightLights"]!);
    }
}
