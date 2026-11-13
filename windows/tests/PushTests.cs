using System.Text.Json.Nodes;
using Xunit;

namespace Daylit.Tests;

public class PushConfigTests {
    static (Config cfg, string? error) Load(string json) {
        var p = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json");
        File.WriteAllText(p, json);
        return Config.Load(p);
    }

    [Fact]
    public void PushIsOffWhenTheKeyIsMissing() {
        var (c, err) = Load("""{ "homeAssistant": { "url": "http://example.local:8123" } }""");
        Assert.Null(err);
        Assert.Null(c.HomeAssistant!.Push);
    }

    [Fact]
    public void PushTrueIsRead() {
        var (c, err) = Load("""{ "homeAssistant": { "url": "http://example.local:8123", "push": true } }""");
        Assert.Null(err);
        Assert.True(c.HomeAssistant!.Push);
    }

    [Fact]
    public void PushThatIsNotTrueOrFalseIsAProblemNamingTheKey() {
        var (_, err) = Load("""{ "homeAssistant": { "url": "http://example.local:8123", "push": "yes" } }""");
        Assert.NotNull(err);
        Assert.Contains("push", err!);
    }

    [Fact]
    public void SavingFromSettingsKeepsPush() {
        const string original = """{ "source": "homeAssistant", "homeAssistant": { "url": "http://example.local:8123", "push": true } }""";
        var saved = ConfigPatch.Apply(new SettingsEdit("homeAssistant", null, null, [], HaUrl: "http://example.local:8123"), original);
        Assert.True(JsonNode.Parse(saved)!["homeAssistant"]!["push"]!.GetValue<bool>());
    }
}

public class PushUrlTests {
    [Theory]
    [InlineData("http://example.local:8123", "ws://example.local:8123/api/websocket")]
    [InlineData("https://ha.example.com", "wss://ha.example.com/api/websocket")]
    [InlineData("http://example.local:8123/", "ws://example.local:8123/api/websocket")]
    [InlineData("https://example.local/ha/", "wss://example.local/ha/api/websocket")]
    [InlineData("HTTP://example.local:8123", "ws://example.local:8123/api/websocket")]
    public void TheSocketUrlFollowsTheHomeAssistantUrl(string http, string ws) => Assert.Equal(ws, PushRule.SocketUrl(http)!.AbsoluteUri);

    [Theory]
    [InlineData("ftp://example.local")]
    [InlineData("example.local:8123")]
    [InlineData("")]
    [InlineData(null)]
    public void NotAnHttpUrlGivesNothing(string? http) => Assert.Null(PushRule.SocketUrl(http));
}

public class PushEntityTests {
    static Config With(HaConfig? ha, params MonitorHa?[] mons) =>
        new() { HomeAssistant = ha, Monitors = mons.Select((h, i) => new MonitorConfig { Match = $"M{i}", HomeAssistant = h }).ToArray() };

    [Fact]
    public void EveryConfiguredEntityOnceAndSorted() {
        var ha = new HaConfig { Url = "http://example.local:8123", AutoSwitch = "input_boolean.auto", Sun = "sun.sun", Cover = "cover.blind",
                                Lights = "light.room", Light = "sensor.solar" };
        var left = new MonitorHa { Sensor = "sensor.left", Day = "input_number.day", BlindDown = "input_number.down", Night = "input_number.night",
                                   Set = "input_number.left_set", NightLights = "input_number.lit" };
        var right = new MonitorHa { Day = "input_number.day", Set = "input_number.right_set" };   // shares the day helper
        Assert.Equal(new[] { "cover.blind", "input_boolean.auto", "input_number.day", "input_number.down", "input_number.left_set",
                      "input_number.lit", "input_number.night", "input_number.right_set", "light.room", "sensor.solar", "sun.sun" },
                     PushRule.Entities(With(ha, left, right)));
    }

    [Fact]
    public void UnsetEntitiesAreLeftOutAndTheSunDefaultsToSunSun() =>
        Assert.Equal(new[] { "input_number.night", "sun.sun" },
                     PushRule.Entities(With(new HaConfig { Url = "http://example.local:8123" }, null, new MonitorHa { Night = "input_number.night" })));

    [Fact]
    public void AnEmptySunIsSunSunAsInTheTemplate() =>
        Assert.Equal(new[] { "sun.sun" }, PushRule.Entities(With(new HaConfig { Url = "http://example.local:8123", Sun = "" })));

    [Fact]
    public void ThePublishedSensorIsNeverFollowed() =>
        Assert.DoesNotContain("sensor.left", PushRule.Entities(With(new HaConfig { Url = "http://example.local:8123" }, new MonitorHa { Sensor = "sensor.left" })));

    [Fact]
    public void NoHomeAssistantNoEntities() => Assert.Empty(PushRule.Entities(new Config()));
}

public class PushParseTests {
    [Fact]
    public void AuthMessages() {
        Assert.Equal(PushKind.AuthRequired, PushRule.Parse("""{"type":"auth_required","ha_version":"2026.11.0"}""").Kind);
        Assert.Equal(PushKind.AuthOk, PushRule.Parse("""{"type":"auth_ok","ha_version":"2026.11.0"}""").Kind);
        var m = PushRule.Parse("""{"type":"auth_invalid","message":"Invalid access token or password"}""");
        Assert.Equal(PushKind.AuthInvalid, m.Kind);
        Assert.Equal("Invalid access token or password", m.Reason);
    }

    [Fact]
    public void ResultSuccessAndFailure() {
        var ok = PushRule.Parse("""{"id":1,"type":"result","success":true,"result":null}""");
        Assert.Equal((PushKind.Result, 1, true), (ok.Kind, ok.Id, ok.Ok));
        var no = PushRule.Parse("""{"id":1,"type":"result","success":false,"error":{"code":"invalid_format","message":"x"}}""");
        Assert.Equal((PushKind.Result, 1, false), (no.Kind, no.Id, no.Ok));
    }

    [Fact]
    public void Pong() => Assert.Equal(PushKind.Pong, PushRule.Parse("""{"id":7,"type":"pong"}""").Kind);

    static string[] EventIds(string json) {
        var m = PushRule.Parse(json);
        Assert.Equal(PushKind.Event, m.Kind);
        return m.Ids!.OrderBy(i => i, StringComparer.Ordinal).ToArray();
    }

    [Fact]
    public void TheFirstEventListsEveryEntityUnderA() =>
        Assert.Equal(new[] { "cover.blind", "sun.sun" }, EventIds("""{"id":1,"type":"event","event":{"a":{"cover.blind":{"s":"open","a":{"current_position":100},"c":"01J","lc":1763000000.1},"sun.sun":{"s":"above_horizon","a":{"elevation":20.5},"c":"01K","lc":1763000000.2,"lu":1763000100.3}}}}"""));

    [Fact]
    public void AChangeUnderC() =>
        Assert.Equal(new[] { "light.room" }, EventIds("""{"id":1,"type":"event","event":{"c":{"light.room":{"+":{"s":"off","lc":1763000200.5,"c":"01L","a":{"brightness":null}},"-":{"a":["hs_color"]}}}}}"""));

    [Fact]
    public void ARemovalUnderR() =>
        Assert.Equal(new[] { "input_number.night" }, EventIds("""{"id":1,"type":"event","event":{"r":["input_number.night"]}}"""));

    [Fact]
    public void AllThreeInOneEvent() =>
        Assert.Equal(new[] { "light.a", "light.b", "light.c" }, EventIds("""{"id":1,"type":"event","event":{"a":{"light.a":{"s":"on","a":{},"c":"x","lc":1}},"c":{"light.b":{"+":{"s":"on"}}},"r":["light.c"]}}"""));

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("""[{"type":"auth_ok"}]""")]
    [InlineData("""{"type":"something_new"}""")]
    [InlineData("""{"no":"type"}""")]
    [InlineData("""{"type":"result","success":true}""")]
    [InlineData("""{"type":"event"}""")]
    [InlineData("""{"type":"auth_ok" """)]
    public void AnythingElseIsOther(string text) => Assert.Equal(PushKind.Other, PushRule.Parse(text).Kind);
}

public class PushMessageTests {
    [Fact]
    public void TheAuthMessageCarriesTheTokenAsAccessToken() {
        var o = (JsonObject)JsonNode.Parse(PushRule.AuthMessage("abc\"def\\ghi"))!;
        Assert.Equal("auth", (string?)o["type"]);
        Assert.Equal("abc\"def\\ghi", (string?)o["access_token"]);
        Assert.Equal(2, o.Count);
    }

    [Fact]
    public void SubscribeNamesTheEntities() {
        var o = JsonNode.Parse(PushRule.SubscribeMessage(1, ["light.room", "sun.sun"]))!;
        Assert.Equal(1, (int)o["id"]!);
        Assert.Equal("subscribe_entities", (string?)o["type"]);
        Assert.Equal(new[] { "light.room", "sun.sun" }, o["entity_ids"]!.AsArray().Select(x => (string)x!).ToArray());
    }

    [Fact]
    public void Ping() {
        var o = JsonNode.Parse(PushRule.PingMessage(4))!;
        Assert.Equal(4, (int)o["id"]!);
        Assert.Equal("ping", (string?)o["type"]);
    }

    [Fact]
    public void RejectedLogLineNeverIncludesServerMessage() {
        var m = PushRule.Parse("""{"type":"auth_invalid","message":"echoed by a proxy"}""");
        Assert.Equal("echoed by a proxy", m.Reason);
        Assert.DoesNotContain(m.Reason!, PushRule.RejectedLine);
        Assert.DoesNotContain(m.Reason!, PushRule.RejectedProblem);
    }

    [Fact]
    public void LogLinesCarryNoToken() {
        const string token = "a-token-that-must-not-appear";
        _ = PushRule.AuthMessage(token);
        foreach (var line in new[] { PushRule.ConnectedLine(12), PushRule.LostLine("no pong", 5), PushRule.RejectedLine,
                                     PushRule.OffLine, PushRule.RejectedProblem })
            Assert.DoesNotContain(token, line);
        Assert.Equal("push: connected (12 entities)", PushRule.ConnectedLine(12));
        Assert.Equal("push: lost (no pong), retrying in 5s", PushRule.LostLine("no pong", 5));
        Assert.Equal("push: off", PushRule.OffLine);
        Assert.Equal("push: token rejected", PushRule.RejectedLine);
    }
}

public class PushDecisionTests {
    static readonly HashSet<string> Subscribed = ["cover.blind", "light.room", "input_number.day", "input_number.set", "sun.sun", "sensor.solar"];
    static PushTick D(string[] changed, double? lastTick = 1000, double now = 1010) =>
        PushRule.Decide(changed, Subscribed, "sensor.solar", lastTick, now);

    [Theory]
    [InlineData("cover.blind")]
    [InlineData("light.room")]
    [InlineData("input_number.day")]
    [InlineData("input_number.set")]
    [InlineData("sun.sun")]
    public void CoverLightsAndHelpersTickAtOnce(string id) => Assert.Equal(PushTick.Now, D([id]));

    [Fact]
    public void ADaylightOnlyChangeWaitsUntilAMinuteAfterTheLastTick() => Assert.Equal(PushTick.After(50), D(["sensor.solar"], 1000, 1010));

    [Fact]
    public void ADaylightOnlyChangeTicksWhenTheLastTickIsAMinuteOld() {
        Assert.Equal(PushTick.Now, D(["sensor.solar"], 1000, 1060));
        Assert.Equal(PushTick.Now, D(["sensor.solar"], null));
    }

    [Fact]
    public void AMixTicksAtOnce() => Assert.Equal(PushTick.Now, D(["sensor.solar", "cover.blind"]));

    [Fact]
    public void AnUnknownEntityIsIgnored() {
        Assert.Equal(PushTick.Ignore, D(["light.kitchen"]));
        Assert.Equal(PushTick.Ignore, D([]));
    }

    [Fact]
    public void AnUnknownEntityNextToTheDaylightSensorStillCountsAsDaylightOnly() =>
        Assert.Equal(PushTick.After(50), D(["sensor.solar", "light.kitchen"]));

    [Fact]
    public void WithoutADaylightSensorEverythingTicksAtOnce() =>
        Assert.Equal(PushTick.Now, PushRule.Decide(["sensor.solar"], Subscribed, null, 1000, 1001));
}

public class PushTimerTests {
    [Fact]
    public void ABurstRunsOneTickAndEachChangeExtendsTheWindow() {
        var t = new PushTimer();
        Assert.True(t.Add(PushTick.Now, 100));
        Assert.Equal((double?)101, t.Due);
        Assert.True(t.Add(PushTick.Now, 100.3));
        Assert.Equal(101.3, t.Due!.Value, 9);
        Assert.True(t.Add(PushTick.Now, 100.9));
        Assert.Equal(101.9, t.Due!.Value, 9);
    }

    [Fact]
    public void ASingleChangeTicksAfterOneSecond() {
        var t = new PushTimer();
        t.Add(PushTick.Now, 100);
        Assert.Equal((double?)101, t.Due);
    }

    [Fact]
    public void TheWindowIsCappedAtThreeSecondsAfterTheFirstChange() {
        var t = new PushTimer();
        t.Add(PushTick.Now, 100);
        t.Add(PushTick.Now, 100.8); t.Add(PushTick.Now, 101.6); t.Add(PushTick.Now, 102.4);
        Assert.Equal(103, t.Due!.Value, 9);
        Assert.False(t.Add(PushTick.Now, 102.9));
        Assert.Equal(103, t.Due!.Value, 9);
    }

    [Fact]
    public void AStreamOverFiveSecondsTicksAtMostEveryThreeSeconds() {
        var t = new PushTimer(); var fired = new List<double>();
        for (double now = 100; now < 105; now += 0.5) {
            t.Add(PushTick.Now, now);
            if (t.Due is double d && d <= now + 0.5) { fired.Add(d); t.Clear(); }
        }
        Assert.Equal(103, fired[0], 9);
        for (int i = 1; i < fired.Count; i++) Assert.True(fired[i] - fired[i - 1] >= 1);
        Assert.True(fired.Count <= 2);
    }

    [Fact]
    public void ADaylightWaitDoesNotPushBackATickAlreadyDue() {
        var t = new PushTimer();
        t.Add(PushTick.Now, 100);
        Assert.False(t.Add(PushTick.After(50), 100.5));
        Assert.Equal((double?)101, t.Due);
    }

    [Fact]
    public void AChangeBringsAWaitingDaylightTickForward() {
        var t = new PushTimer();
        Assert.True(t.Add(PushTick.After(50), 100));
        Assert.Equal((double?)150, t.Due);
        Assert.True(t.Add(PushTick.Now, 110));
        Assert.Equal((double?)111, t.Due);
    }

    [Fact]
    public void IgnoreChangesNothingAndClearEmpties() {
        var t = new PushTimer();
        Assert.False(t.Add(PushTick.Ignore, 100));
        Assert.Null(t.Due);
        t.Add(PushTick.Now, 100); t.Clear();
        Assert.Null(t.Due);
    }
}

public class PushTimingTests {
    [Fact]
    public void Backoff() => Assert.Equal(new double[] { 2, 5, 15, 60, 60, 60, 60 }, Enumerable.Range(0, 7).Select(PushRule.RetryDelay).ToArray());

    [Fact]
    public void PollIsFiveMinutesWhileHealthyOnMainsAndBattery() {
        Assert.Equal(300, PushRule.PollInterval(true, false, new Tuning()));
        Assert.Equal(300, PushRule.PollInterval(true, true, new Tuning()));
    }

    [Fact]
    public void PollIsTodaysWhenNotHealthy() {
        Assert.Equal(30, PushRule.PollInterval(false, false, new Tuning()));
        Assert.Equal(120, PushRule.PollInterval(false, true, new Tuning()));
    }

    [Fact]
    public void ALongerConfiguredPollIsKeptWhileHealthy() =>
        Assert.Equal(900, PushRule.PollInterval(true, true, new Tuning { Timing = new() { BatteryPollSeconds = 900 } }));

    [Fact]
    public void TheDaylightLimitIsTheNormalPollIntervalWhenLongerThanAMinute() {
        var mains = PushRule.DaylightLimit(false, new Tuning());
        var battery = PushRule.DaylightLimit(true, new Tuning());
        Assert.Equal(60, mains);
        Assert.Equal(120, battery);
        var subscribed = new HashSet<string> { "sensor.solar", "light.room" };
        Assert.Equal(PushTick.After(110), PushRule.Decide(["sensor.solar"], subscribed, "sensor.solar", 1000, 1010, battery));
        Assert.Equal(PushTick.Now, PushRule.Decide(["sensor.solar"], subscribed, "sensor.solar", 1000, 1120, battery));
    }

    [Fact]
    public void PingIsEveryTwoMinutesOnBatteryAndEveryMinuteOnMains() {
        Assert.Equal(60, PushRule.PingInterval(false));
        Assert.Equal(120, PushRule.PingInterval(true));
    }

    [Fact]
    public void AuthHasTenSecondsToComplete() {
        Assert.False(PushRule.AuthTimedOut(9.9, false));
        Assert.True(PushRule.AuthTimedOut(10, false));
        Assert.False(PushRule.AuthTimedOut(60, true));
    }

    [Fact]
    public void TheSocketIsOpenOnlyWhenEverythingAllowsIt() {
        Assert.True(PushRule.Wanted(true, Source.HomeAssistant, false, true, true));
        Assert.False(PushRule.Wanted(null, Source.HomeAssistant, false, true, true));
        Assert.False(PushRule.Wanted(false, Source.HomeAssistant, false, true, true));
        Assert.False(PushRule.Wanted(true, Source.Sun, false, true, true));
        Assert.False(PushRule.Wanted(true, Source.HomeAssistant, true, true, true));
        Assert.False(PushRule.Wanted(true, Source.HomeAssistant, false, false, true));
        Assert.False(PushRule.Wanted(true, Source.HomeAssistant, false, true, false));
    }
}
