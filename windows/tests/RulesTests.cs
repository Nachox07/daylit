using Xunit;

namespace Daylit.Tests;

public class SunTests {
    static DateTimeOffset Utc(string s) => DateTimeOffset.Parse(s, System.Globalization.CultureInfo.InvariantCulture);

    // Expected values: NOAA Solar Calculator algorithm (gml.noaa.gov/grad/solcalc), geometric elevation
    // without refraction, computed independently of Daylit's formula. Daylit agrees to about 0.005°.
    const double GreenwichLat = 51.4769, GreenwichLon = -0.0005;   // Royal Observatory Greenwich

    [Theory]
    [InlineData("2024-06-21T12:00:00Z", GreenwichLat, GreenwichLon, 61.958)]    // June solstice noon
    [InlineData("2024-12-21T12:00:00Z", GreenwichLat, GreenwichLon, 15.084)]    // December solstice noon
    [InlineData("2024-12-21T00:00:00Z", GreenwichLat, GreenwichLon, -61.959)]   // December solstice midnight
    [InlineData("2024-03-20T06:00:00Z", GreenwichLat, GreenwichLon, -1.109)]    // equinox, just before sunrise
    [InlineData("2024-03-20T12:07:00Z", 0, 0, 89.834)]                          // equator, equinox noon
    [InlineData("2024-09-22T15:00:00Z", -33.8568, 151.2153, -52.095)]           // Sydney, 01:00 local
    public void MatchesNoaaReference(string utc, double lat, double lon, double expected) =>
        Assert.Equal(expected, Sun.Elevation(Utc(utc), lat, lon), 0.05);

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

    [Theory]
    [InlineData("light.office_2", true)]
    [InlineData("light", false)] [InlineData("light.", false)] [InlineData(".x", false)] [InlineData("light.Office", false)]
    [InlineData("light.a.b", false)] [InlineData("light.x')}}{{ 7*7 }}", false)] [InlineData("light.x }}", false)]
    [InlineData("light.x\n", false)] [InlineData("light.x y", false)] [InlineData("", false)]
    public void EntityIdShape(string id, bool ok) => Assert.Equal(ok, Config.IsEntityId(id));

    [Fact]
    public void InjectedEntityIdIsRejectedAndNotUsed() {
        var (c, err) = Config.Load(Write("""{ "homeAssistant": { "url": "http://ha.local:8123", "cover": "cover.x')}}{{ 7*7 }}{{('" }, "monitors": [ { "match": "DELL", "day": 60 } ] }"""));
        Assert.Contains("homeAssistant.cover", err);
        Assert.Null(c.HomeAssistant);                 // source settings dropped
        Assert.Equal(Source.Off, c.Effective);
        Assert.Equal(60, c.Monitors![0].Day);          // monitors kept
    }

    [Fact]
    public void InjectedMonitorEntityIsRejected() {
        var (_, err) = Config.Load(Write("""{ "homeAssistant": { "url": "http://ha.local:8123" }, "monitors": [ { "match": "DELL", "homeAssistant": { "sensor": "sensor.a/../../api/services" } } ] }"""));
        Assert.Contains("homeAssistant.sensor", err);
    }

    [Theory]
    [InlineData("http://192.168.1.20:8123", false)] [InlineData("http://10.0.0.2", false)] [InlineData("http://172.20.1.1", false)]
    [InlineData("http://homeassistant.local:8123", false)] [InlineData("http://homeassistant:8123", false)]
    [InlineData("http://localhost:8123", false)] [InlineData("http://[fd00::1]:8123", false)] [InlineData("https://ha.example.com", false)]
    [InlineData("http://ha.example.com", true)] [InlineData("http://203.0.113.5:8123", true)]
    [InlineData("http://10.1.2.3.example.com", true)] [InlineData("http://fd.example.com", true)]
    [InlineData("http://[2001:db8::1]:8123", true)] [InlineData("http://[::1]:8123", false)] [InlineData("http://[fe80::1]", false)]
    public void CleartextNote(string url, bool warn) => Assert.Equal(warn, Config.IsCleartextToNonLocal(url));
}

public class TemplateTests {
    [Fact]
    public void TemplateDropsAnyBadIdThatSlipsThrough() {
        var t = HaTemplate.Build(new HaConfig { Url = "http://x", Cover = "cover.x')}}{{ 7*7 }}" }, [new MonitorHa { Day = "input_number.d'}}" }]);
        Assert.DoesNotContain("7*7", t);
        Assert.DoesNotContain("input_number.d'", t);
        Assert.Contains("\"pos\": {{ 100 }}", t);
    }

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

public class WriteOnlyTests {
    [Fact] public void UnreadableMonitorIsLeftAloneUntilTheUserWrites() {
        Assert.Null(ReadState.Unknown.AfterRead(false).Current(null, 50));   // may be showing the Mac
        Assert.True(ReadState.Unknown.Usable());                            // the slider can still be tried
    }
    [Fact] public void AcceptedUserWriteMakesItWriteOnly() {
        var s = ReadState.Unknown.AfterUserWrite(true);
        Assert.Equal(ReadState.WriteOnly, s);
        Assert.Equal(64, s.Current(null, 64));                               // the slider is the record of its level
        Assert.Equal(ReadState.WriteOnly, s.AfterRead(false));
    }
    [Fact] public void RefusedUserWriteMakesItSilent() {
        var s = ReadState.Unknown.AfterUserWrite(false);
        Assert.Equal(ReadState.Silent, s);
        Assert.False(s.Usable());
        Assert.Equal(ReadState.WriteOnly, s.AfterUserWrite(true));
    }
    [Fact] public void AReadingAlwaysWins() {
        Assert.Equal(ReadState.Readable, ReadState.WriteOnly.AfterRead(true));
        Assert.Equal(30, ReadState.Readable.Current(30, 70));
        Assert.Null(ReadState.Readable.AfterRead(false).Current(null, 70));   // stopped answering: another computer
        Assert.Equal(ReadState.Readable, ReadState.Readable.AfterUserWrite(true));
    }
    [Fact] public void WriteOnlyFollowsTargetUntilMovedByHand() {
        var auto = Rules.Decide(60, 72, null, new Hold(null, 60, 60), true, true, 5);
        Assert.Equal(72, auto.Write);
        Assert.False(auto.Manual);
        var held = Rules.Decide(40, 74, null, auto.State, true, true, 5);   // slider moved to 40 by hand
        Assert.Null(held.Write);
        Assert.True(held.Manual);
    }
}

public class SyncTests {
    static SyncOffsets Two(int a, int b) => SyncOffsets.Capture(new[] { ("a", a), ("b", b) });

    [Fact]
    public void CaptureKeepsOffsetsFromTheFirstMonitor() {
        var s = SyncOffsets.Capture(new[] { ("a", 60), ("b", 40), ("c", 75) });
        Assert.Equal(new Dictionary<string, int> { ["a"] = 0, ["b"] = -20, ["c"] = 15 }, s.Offsets);
    }

    [Fact]
    public void MovingOneMovesTheOthersBySameAmount() {
        var s = Two(60, 40);
        Assert.Equal(new Dictionary<string, int> { ["b"] = 50 }, s.Follow("a", 70, new[] { "a", "b" }));
        Assert.Equal(new Dictionary<string, int> { ["a"] = 30 }, s.Follow("b", 10, new[] { "a", "b" }));
    }

    [Fact]
    public void ClampingDoesNotLoseTheOffset() {
        var s = Two(60, 40);
        Assert.Equal(0, s.Follow("a", 10, new[] { "a", "b" })["b"]);
        Assert.Equal(30, s.Follow("a", 50, new[] { "a", "b" })["b"]);
        Assert.Equal(100, s.Follow("b", 100, new[] { "a", "b" })["a"]);
    }

    [Fact]
    public void AutomaticTargetFromTheLeader() {
        var s = Two(60, 45);
        Assert.Equal(new Dictionary<string, int> { ["a"] = 80, ["b"] = 65 }, s.Targets("a", 80, new[] { "a", "b" }));
        Assert.Equal(new Dictionary<string, int> { ["b"] = 20 }, s.Targets("b", 20, new[] { "b" }));
    }

    [Fact]
    public void NewMonitorJoinsAtItsCurrentOffset() {
        var s = Two(60, 40);
        Assert.True(s.Adopt(new[] { ("a", 70), ("c", 50) }));
        Assert.Equal(-20, s.Offsets["c"]);
        Assert.Equal(-20, s.Offsets["b"]);
        Assert.False(s.Adopt(new[] { ("a", 70), ("c", 50) }));   // nothing new
    }

    [Fact]
    public void GroupStartsAgainWhenNoKnownMonitorIsConnected() {
        var s = Two(60, 40);
        Assert.True(s.Adopt(new[] { ("x", 30), ("y", 50) }));
        Assert.Equal(new Dictionary<string, int> { ["x"] = 0, ["y"] = 20 }, s.Offsets);
    }

    [Fact]
    public void UnknownMonitorIsIndependent() {
        var s = SyncOffsets.Capture(new[] { ("a", 60) });
        Assert.Empty(s.Follow("z", 30, new[] { "a", "z" }));
        Assert.Empty(s.Follow("a", 30, new[] { "a", "z" }));
    }

    // Saved hand-set state

    [Fact]
    public void SavedHoldRestoresWithinMaxAgeAndKeepsTheHandSetLevel() {
        var saved = new SavedHolds();
        Assert.True(saved.Record("A", 70, 70, 1000));
        var back = SavedHolds.FromJson(saved.ToJson());
        var r = back.Restore("A", 1000 + 3600);
        Assert.Equal((70, 70), (r!.Value.LastSet, r.Value.LastTarget));
        // At 40 (set by hand before the restart), target barely moved: kept, nothing written.
        var step = Rules.Decide(40, 72, null, new Hold(null, r.Value.LastSet, r.Value.LastTarget), true, true, 5);
        Assert.Null(step.Write);
        Assert.True(step.Manual);
    }

    [Fact]
    public void WithoutSavedHoldARestartAppliesTheTarget() {
        var step = Rules.Decide(40, 72, null, new Hold(null, null, null), true, true, 5);
        Assert.Equal(72, step.Write);
    }

    [Fact]
    public void SavedHoldExpiresAndEmptyStateIsDropped() {
        var saved = new SavedHolds();
        saved.Record("A", 70, 70, 0);
        Assert.Null(saved.Restore("A", SavedHolds.MaxAge + 1));
        Assert.Null(saved.Restore("B", 10));
        Assert.False(saved.Record("A", 70, 70, 50));   // unchanged: keeps the original time
        Assert.True(saved.Record("A", null, null, 60));
        Assert.Empty(saved.Entries);
        Assert.NotNull(SavedHolds.FromJson("not json"));
    }
}
