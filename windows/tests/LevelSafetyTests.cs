using Xunit;

namespace Daylit.Tests;

public class LevelSafetyTests {
    static string Write(string text) {
        var p = Path.Combine(Path.GetTempPath(), $"daylit-test-{Guid.NewGuid()}.json");
        File.WriteAllText(p, text);
        return p;
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(50.0)]
    [InlineData(100.0)]
    public void HugeLevelsGiveAValidTargetInsteadOfNaN(double pos) {
        int v = Rules.Target([1e308, -1e308, 20], pos, false, 1);
        Assert.InRange(v, 0, 100);
    }

    [Fact]
    public void HugeLevelsClampToTheNearestEnd() {
        Assert.Equal(100, Rules.Target([1e308, -1e308, 20], 100, false, 1));
        Assert.Equal(0, Rules.Target([1e308, -1e308, 20], 0, false, 1));
    }

    [Fact]
    public void NonFiniteInputsNeverBreakTarget() {
        Assert.Equal(100, Rules.Target([double.NaN, double.PositiveInfinity, double.NegativeInfinity, double.NaN], double.NaN, true, 1));
        Assert.Equal(20, Rules.Target([70, 40, 20], 100, false, double.NaN));          // sun not a number: night
        Assert.Equal(70, Rules.Target([70, 40, 20], 100, false, 1, light: double.NaN)); // a light scale that is not a number caps nothing
    }

    [Fact]
    public void HomeAssistantLevelAbove100IsClamped() {
        var lv = Chart.EffectiveLevels([70, 40, 20], [200, 300, 400, 250, -1, 0]);
        Assert.Equal(new[] { 100.0, 100, 100, 100 }, lv);
        Assert.Equal(100, Rules.Target(lv, 50, false, 1));
    }

    [Fact]
    public void LocalLevelsAreClampedToo() =>
        Assert.Equal(new[] { 100.0, 0, 0, 100 }, Chart.EffectiveLevels([1e308, -1e308, double.NaN, 150], null));

    [Fact]
    public void InRangeLevelsPassThrough() =>
        Assert.Equal(new[] { 80.0, 40, 30 }, Chart.EffectiveLevels([70, 40, 20], [80, -1, 30, -1, -1, 0]));

    [Theory]
    [InlineData("day", "101")]
    [InlineData("day", "-1")]
    [InlineData("blindDown", "1e308")]
    [InlineData("blindDown", "-1e308")]
    [InlineData("night", "101")]
    [InlineData("night", "-1")]
    public void ALocalLevelOutsideZeroToHundredIsAProblem(string key, string v) =>
        Assert.Equal($"config.json: monitor \"Dell\" {key} is 0 to 100",
                     Config.Load(Write($$"""{ "monitors": [ { "match": "Dell", "{{key}}": {{v}} } ] }""")).error);

    [Theory]
    [InlineData("day")]
    [InlineData("blindDown")]
    [InlineData("night")]
    public void ZeroAndHundredAreFine(string key) {
        Assert.Null(Config.Load(Write($$"""{ "monitors": [ { "match": "Dell", "{{key}}": 0 } ] }""")).error);
        Assert.Null(Config.Load(Write($$"""{ "monitors": [ { "match": "Dell", "{{key}}": 100 } ] }""")).error);
    }
}

public class HaMissingEntityTests {
    [Fact]
    public void TheTemplateRendersNullForAMissingAutoSwitchAndSun() {
        var t = HaTemplate.Build(new HaConfig { Url = "http://x", AutoSwitch = "input_boolean.auto", Sun = "sun.home" }, []);
        Assert.Contains("is_state('input_boolean.auto','on') | tojson if states['input_boolean.auto'] and states['input_boolean.auto'].state not in ['unavailable', 'unknown'] else 'null'", t);
        Assert.Contains("state_attr('sun.home','elevation') | float if state_attr('sun.home','elevation') is number else 'null'", t);
        Assert.Contains("state_attr('sun.sun','elevation') is number", HaTemplate.Build(new HaConfig { Url = "http://x" }, []));
    }

    [Fact]
    public void MissingEntitiesAreNamedInTheProblemLine() {
        var h = new HaConfig { Url = "http://x", AutoSwitch = "input_boolean.auto", Sun = "sun.home" };
        var ids = HaTemplate.Missing(h, elevMissing: true, autoMissing: true);
        Assert.Equal(new[] { "input_boolean.auto", "sun.home" }, ids);
        Assert.Equal("Home Assistant gives no value for input_boolean.auto, sun.home (missing or unavailable)", HaTemplate.NoValueNote(ids));
    }

    [Fact]
    public void NullAutoIsNormalWithoutAnAutoSwitch() {
        Assert.Equal(new[] { "sun.sun" }, HaTemplate.Missing(new HaConfig { Url = "http://x" }, elevMissing: true, autoMissing: true));
        Assert.Empty(HaTemplate.Missing(new HaConfig { Url = "http://x", AutoSwitch = "input_boolean.auto" }, false, false));
        Assert.Null(HaTemplate.NoValueNote(Array.Empty<string>()));
    }
}

public class AutomaticNowTests {
    [Fact]
    public void HomeAssistantsAnswerWins() {
        Assert.False(Rules.AutomaticNow(true, false, true, true));
        Assert.True(Rules.AutomaticNow(true, true, false, false));
    }

    [Fact]
    public void AMissingSwitchKeepsTheLastHomeAssistantValue() {
        Assert.False(Rules.AutomaticNow(true, null, false, true));
        Assert.True(Rules.AutomaticNow(true, null, null, true));
        Assert.False(Rules.AutomaticNow(false, null, true, false));
    }
}

public class StoredAutomaticTests {
    [Fact]
    public void TheValueCountsForTheEntityItWasSeenOn() =>
        Assert.Equal<bool?>(false, Rules.StoredAutomatic(false, "input_boolean.a", "input_boolean.a"));

    [Fact]
    public void AnotherOrUnknownEntityIgnoresTheValue() {
        Assert.Null(Rules.StoredAutomatic(false, "input_boolean.a", "input_boolean.b"));
        Assert.Null(Rules.StoredAutomatic(false, null, "input_boolean.a"));
        Assert.Null(Rules.StoredAutomatic(false, "input_boolean.a", null));
    }
}

public class ProblemLineTests {
    [Fact]
    public void AConfigProblemComesBeforeAMissingEntity() {
        Assert.Equal("config.json: bad", HaTemplate.ProblemLine("config.json: bad", ["x.y"]));
        Assert.Equal("Home Assistant gives no value for x.y (missing or unavailable)", HaTemplate.ProblemLine(null, ["x.y"]));
        Assert.Null(HaTemplate.ProblemLine(null, []));
    }
}

public class AutomaticFallbackTests {
    [Fact]
    public void AnOutageKeepsWhatHomeAssistantLastSaid() {
        Assert.False(Rules.AutomaticFallback(true, false, true));   // off in Home Assistant stays off
        Assert.True(Rules.AutomaticFallback(true, true, false));
    }

    [Fact]
    public void WithoutAStateSeenOrASwitchTheLocalSettingDecides() {
        Assert.True(Rules.AutomaticFallback(true, null, true));
        Assert.False(Rules.AutomaticFallback(false, true, false));
    }
}
