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
    public void NoSampleWhileTheLightsAreOnAndTheSunIsNotFullyUp(double elev) => Assert.Null(Make(elev, true, Four));

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
