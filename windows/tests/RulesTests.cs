using Xunit;

namespace Daylit.Tests;

public class SunTests {
    static DateTimeOffset Utc(string s) => DateTimeOffset.Parse(s, System.Globalization.CultureInfo.InvariantCulture);

    [Fact]
    public void MatchesHomeAssistantAtNight() {
        // Home Assistant's sun.sun reported -10.0° at this time and place (Greenwich).
        Assert.Equal(-10.0, Sun.Elevation(Utc("2026-01-01T00:00:00Z"), 51.4769, -0.0005), 0.05);
    }

    [Fact]
    public void EquatorAtEquinoxNoonIsOverhead() {
        // March equinox 2024: declination ≈ 0, so at the equator the noon sun (≈12:07 UTC at longitude 0) is near 90°.
        Assert.Equal(90, Sun.Elevation(Utc("2024-03-20T12:07:00Z"), 0, 0), 0.5);
    }

    [Fact]
    public void SummerSolsticeNoon() {
        // Noon elevation = 90° − latitude + declination; on the June solstice declination = 23.44°.
        Assert.Equal(90 - 51.4769 + 23.44, Sun.Elevation(Utc("2026-06-21T12:20:00Z"), 51.4769, -0.0005), 0.3);
    }

    [Theory]
    [InlineData(-10, 0)] [InlineData(-3, 0)] [InlineData(4.5, 0.5)] [InlineData(12, 1)] [InlineData(60, 1)]
    public void DaylightFraction(double elev, double expected) => Assert.Equal(expected, Sun.Fraction(elev), 1e-9);
}

public class TargetTests {
    static readonly double[] Levels = [80, 40, 20];   // day, blindDown, night
    static int T(double elev, double pos, bool lights) => Rules.Target(Levels, pos, lights, Sun.Fraction(elev));

    [Fact] public void NightUsesNightLevel() => Assert.Equal(20, T(-20, 100, false));
    [Fact] public void FullDayBlindOpenUsesDayLevel() => Assert.Equal(80, T(30, 100, false));
    [Fact] public void FullDayBlindClosedUsesBlindDownLevel() => Assert.Equal(40, T(30, 0, false));
    [Fact] public void BlindHalfOpenIsHalfway() => Assert.Equal(60, T(30, 50, false));
    [Fact] public void TwilightBlendsDayAndNight() => Assert.Equal(50, T(4.5, 100, false));
    [Fact] public void LightsAtNightAddFive() => Assert.Equal(25, T(-20, 100, true));
    [Fact] public void LightsInDaylightChangeNothing() => Assert.Equal(80, T(30, 100, true));

    [Fact]
    public void ClampsToRange() {
        Assert.Equal(100, Rules.Target([150, 150, 120], 100, false, 1));
        Assert.Equal(0, Rules.Target([-10, -10, -10], 0, false, 0));
    }
}

public class DecideTests {
    static Step D(int c, int target, (double, double)? remote = null, Hold s = default, bool auto = true, bool here = true, int hold = 5) =>
        Rules.Decide(c, target, remote, s, auto, here, hold);

    [Fact]
    public void AppliesTargetAndRemembersIt() {
        var s = D(50, 70);
        Assert.Equal(70, s.Write);
        Assert.Equal(70, s.Applied);
        Assert.Equal(70, s.Current);
        Assert.False(s.Manual);
        Assert.Equal(new Hold(null, 70, 70), s.State);
    }

    [Fact] public void NoWriteWhenAlreadyAtTarget() => Assert.Null(D(70, 70).Write);

    [Fact]
    public void HandSetLevelIsHeldWhileTargetMovesLessThanHold() {
        var s = D(50, 73, s: new Hold(null, 70, 70));
        Assert.Null(s.Write);
        Assert.True(s.Manual);
        Assert.Equal(50, s.Applied);
    }

    [Fact]
    public void HandSetLevelIsReplacedOnceTargetMovesByHold() {
        var s = D(50, 75, s: new Hold(null, 70, 70));
        Assert.Equal(75, s.Write);
        Assert.False(s.Manual);
    }

    [Fact]
    public void IdlePcWritesNothingAutomatic() {
        var s = D(50, 70, here: false);
        Assert.Null(s.Write);
        Assert.Equal(50, s.Applied);
    }

    [Fact]
    public void AutomaticOffNeverWrites() {
        var s = D(50, 70, auto: false);
        Assert.Null(s.Write);
        Assert.False(s.Manual);
    }

    [Fact]
    public void FirstLookAtSetHelperIsNotACommand() {
        var s = D(70, 70, remote: (30, 1000));
        Assert.Null(s.Remote);
        Assert.Equal(1000, s.State.RemoteSeen);
    }

    [Fact]
    public void SetHelperChangeAppliesEvenWhenIdleAndIsHeld() {
        var s = D(70, 70, remote: (30, 2000), s: new Hold(1000, 70, 70), here: false);
        Assert.Equal(30, s.Remote);
        Assert.Equal(30, s.Write);
        Assert.Equal(30, s.Current);
        Assert.True(s.Manual);
        Assert.Equal(2000, s.State.RemoteSeen);
        var next = D(30, 70, s: s.State);   // the next tick at the same target keeps 30
        Assert.Null(next.Write);
        Assert.True(next.Manual);
    }

    [Fact]
    public void SetHelperUnchangedDoesNothing() {
        var s = D(70, 70, remote: (30, 1000), s: new Hold(1000, 70, 70));
        Assert.Null(s.Remote);
        Assert.Null(s.Write);
    }
}

public class LookTests {
    [Fact] public void DaylightWithOpenBlindIsLight() => Assert.False(new LookRule().WantDark(20, 100, true, false, 0, 0));
    [Fact] public void NightIsDark() => Assert.True(new LookRule().WantDark(-10, 100, true, false, 0, 0));
    [Fact] public void ClosedBlindIsDark() => Assert.True(new LookRule().WantDark(20, 20, true, false, 0, 0));
    [Fact] public void BrightWhiteLightsAtNightAreLight() => Assert.False(new LookRule().WantDark(-10, 0, true, true, 230, 10));
    [Fact] public void WarmLightsAtNightStayDark() => Assert.True(new LookRule().WantDark(-10, 0, true, true, 230, 70));
    [Fact] public void WithoutBlindOnlyTheSunCounts() => Assert.False(new LookRule().WantDark(10, 0, false, false, 0, 0));

    [Fact]
    public void InTheGapThePreviousAnswerStays() {
        var r = new LookRule();
        Assert.False(r.WantDark(10, 100, true, false, 0, 0));   // light
        Assert.False(r.WantDark(2, 100, true, false, 0, 0));    // gap: stays light
        Assert.True(r.WantDark(0.5, 100, true, false, 0, 0));   // below 1°: dark
        Assert.True(r.WantDark(2, 100, true, false, 0, 0));     // gap: stays dark
    }

    [Theory]
    [InlineData(false, 200, 0, "")]
    [InlineData(true, 0, 0, " · lights on")]
    [InlineData(true, 204, 10, " · lights 80% white")]
    [InlineData(true, 102, 70, " · lights 40% warm")]
    [InlineData(true, 255, 40, " · lights 100%")]
    public void LightsNote(bool on, double bri, double sat, string expected) => Assert.Equal(expected, Rules.LightsNote(on, bri, sat));
}

public class ConfigTests {
    static string Write(string text) {
        var p = Path.Combine(Path.GetTempPath(), $"daylit-test-{Guid.NewGuid()}.json");
        File.WriteAllText(p, text);
        return p;
    }

    [Fact]
    public void MissingFileGivesDefaultsAndNoError() {
        var (c, err) = Config.Load(Path.Combine(Path.GetTempPath(), "no-such-dir", "config.json"));
        Assert.Null(err);
        Assert.Equal(Source.Off, c.Effective);
    }

    [Fact]
    public void BrokenJsonIsReportedAndDefaultsUsed() {
        var (c, err) = Config.Load(Write("{ \"source\": "));
        Assert.NotNull(err);
        Assert.StartsWith("config.json is not valid", err);
        Assert.Equal(Source.Off, c.Effective);
    }

    [Fact]
    public void ExampleConfigLoads() {
        var (c, err) = Config.Load(Path.Combine(AppContext.BaseDirectory, "config.example.json"));
        Assert.Null(err);
        Assert.Equal(Source.HomeAssistant, c.Effective);
        Assert.Equal(2, c.Monitors!.Length);
        Assert.NotNull(c.Location);
    }

    [Theory]
    [InlineData("{}", "Off")]
    [InlineData("""{ "location": { "latitude": 1, "longitude": 2 } }""", "Sun")]
    [InlineData("""{ "homeAssistant": { "url": "http://ha.local:8123" } }""", "HomeAssistant")]
    // Source is internal to the app, so the expected value is its name.
    public void SourceDefaults(string json, string expected) => Assert.Equal(expected, Config.Load(Write(json)).cfg.Effective.ToString());

    [Theory]
    [InlineData("""{ "source": "sun" }""", "Off")]
    [InlineData("""{ "source": "homeAssistant", "location": { "latitude": 1, "longitude": 2 } }""", "Sun")]
    [InlineData("""{ "source": "moon" }""", "Off")]
    [InlineData("""{ "homeAssistant": { "url": "ftp://x" } }""", "Off")]
    [InlineData("""{ "location": { "latitude": 120, "longitude": 2 } }""", "Off")]
    [InlineData("""{ "monitors": [ { "label": "no match" } ] }""", "Off")]
    public void ProblemsAreReported(string json, string fallback) {
        var (c, err) = Config.Load(Write(json));
        Assert.NotNull(err);
        Assert.Equal(fallback, c.Effective.ToString());
    }
}

public class TemplateTests {
    [Fact]
    public void NoAutoSwitchRendersJsonNull() {
        var t = HaTemplate.Build(new HaConfig { Url = "http://x" }, []);
        Assert.Contains("\"auto\": null,", t);
        Assert.Contains("sun.sun", t);
        Assert.Contains("\"pos\": {{ 100 }}", t);
        Assert.Contains("\"lights\": {{ false | tojson }}", t);
    }

    [Fact]
    public void EntitiesAppearOneRowPerMonitor() {
        var h = new HaConfig { Url = "http://x", AutoSwitch = "input_boolean.auto", Cover = "cover.blind", Lights = "light.room" };
        var t = HaTemplate.Build(h, [new MonitorHa { Day = "input_number.d", Set = "input_number.s" }, null]);
        Assert.Contains("is_state('input_boolean.auto','on') | tojson", t);
        Assert.Contains("state_attr('cover.blind','current_position')", t);
        Assert.Contains("state_attr('light.room','brightness')", t);
        Assert.Contains("[{{ states('input_number.d') | float(-1) }}, -1, -1, ", t);
        Assert.Contains("states.input_number.s.last_changed", t);
        Assert.Contains("[-1, -1, -1, -1, 0]", t);   // a monitor without HA entities still gets its row
    }
}
