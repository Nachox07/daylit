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

public class UserLevelWinsTests {
    [Fact] public void ALevelSetByHandDuringTheWaitBeatsTheOlderReading() => Assert.True(Rules.UserLevelWins(40, 52, false));
    [Fact] public void AnUnchangedLevelKeepsTheReading() => Assert.False(Rules.UserLevelWins(40, 40, false));
    [Fact] public void ADraggedSliderIsNeverOverriddenByAReading() {
        Assert.True(Rules.UserLevelWins(40, 40, true));
        Assert.True(Rules.UserLevelWins(40, 63, true));
    }
    [Fact] public void NothingToTrustWithoutALevel() => Assert.False(Rules.UserLevelWins(null, null, true));
    [Fact] public void AHandChangeDuringTheWaitBecomesAnOffsetInsteadOfBeingOverwritten() {
        var hold = new Hold(null, 40, 40, null, null, null, null);
        int c = Rules.LevelToDecideOn(40, 40, 52, false)!.Value;
        Assert.Equal(52, c);
        var step = Rules.Decide(c, 40, null, hold, auto: true, here: true, sun: 1, touched: true);
        Assert.Equal(12, step.State.Offset);
        Assert.Null(step.Write);
    }
    [Fact] public void TheReadingStandsWhenNothingMovedTheLevel() => Assert.Equal(41, Rules.LevelToDecideOn(41, 40, 40, false));
    [Fact] public void ADraggedSliderHoldsItsLevelAndMakesNoAutomaticWrite() {
        var hold = new Hold(null, 40, 40, null, null, null, null);
        int c = Rules.LevelToDecideOn(40, 40, 63, true)!.Value;
        Assert.Equal(63, c);
        var step = Rules.Decide(c, 40, null, hold, auto: true, here: true, sun: 1, touched: true, dragging: true);
        Assert.Null(step.Write);
        Assert.Null(step.State.Offset);
    }
    [Fact] public void AWriteOverwritesTheLevelOnlyWhenItWasUntouchedMeanwhile() {
        Assert.Equal(70, Rules.LevelAfterWrite(70, true, 40, 40, false));
        Assert.Null(Rules.LevelAfterWrite(70, true, 40, 55, false));    // moved by hand during the write
        Assert.Null(Rules.LevelAfterWrite(70, true, 40, 40, true));     // slider held
        Assert.Null(Rules.LevelAfterWrite(70, false, 40, 40, false));   // refused
    }
}

public class SunSpanTests {
    /// A day's elevations every 10 minutes from local midnight, as the sun curve samples them.
    static List<(double t, double e)> Day(double lat, double lon, string start) {
        var d = DateTimeOffset.Parse(start, System.Globalization.CultureInfo.InvariantCulture);
        return Enumerable.Range(0, 145).Select(i => (i / 144.0, Sun.Elevation(d.AddSeconds(i * 600), lat, lon))).ToList();
    }
    static string Clock(double t) { int m = (int)Math.Round(t * 1440, MidpointRounding.AwayFromZero); return $"{m / 60:00}:{m % 60:00}"; }
    static string Label(List<(double t, double e)> s, double e, bool below = false) => Sun.SpanLabel(Sun.Spans(s, e, below), Clock);

    [Fact]
    public void AnOrdinaryDayRisesAndSets() {
        var s = Day(51.48, 0, "2026-03-20T00:00:00Z");   // Greenwich, equinox, UTC
        Assert.Equal("06:08 – 18:08", Label(s, 0));
        Assert.Equal("until 06:08 · from 18:08", Label(s, 0, below: true));
        Assert.Equal("not today", Label(s, 60));
        Assert.Equal("all day", Label(s, 60, below: true));
    }

    [Fact]
    public void AMidnightSunDipIsLabelledInTheOrderItHappens() {
        // Tromsø at midsummer, local time UTC+2: the sun never sets, and its lowest point is about 00:45,
        // after local midnight. A line between the midnight height and that minimum is crossed going
        // down first and coming back up later, so "above" is everything but a short dip.
        var s = Day(69.65, 18.96, "2026-06-20T22:00:00Z");
        double line = (s[0].e + s.Min(x => x.e)) / 2;
        var above = Sun.Spans(s, line);
        Assert.Equal(2, above.Count);
        Assert.Equal(0, above[0].From); Assert.Equal(1, above[^1].To);
        Assert.True(above[0].To < above[1].From);
        var dip = Sun.Spans(s, line, below: true);
        Assert.Single(dip);
        Assert.Equal($"until {Clock(dip[0].From)} · from {Clock(dip[0].To)}", Label(s, line));
        Assert.Equal($"{Clock(dip[0].From)} – {Clock(dip[0].To)}", Label(s, line, below: true));
        Assert.True(dip[0].From < dip[0].To);
        // Polar day: above the horizon all day.
        Assert.Equal("all day", Label(s, 0));
        Assert.Equal("not today", Label(s, 0, below: true));
    }
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
    static Step D(int c, int target, (double, double)? remote = null, Hold s = default, bool auto = true, bool here = true, double sun = 1, bool touched = true) =>
        Rules.Decide(c, target, remote, s, auto, here, sun, touched);

    [Fact]
    public void AMonitorReadingOneOffIsNotAHandSetLevel() {
        var st = new Hold(null, 45, 45);
        var s = D(46, 45, s: st, touched: false);   // Daylit wrote 45, the monitor reports 46
        Assert.Null(s.Write); Assert.Null(s.State.Offset); Assert.False(s.Manual);
        Assert.Equal(1, D(46, 45, s: st, touched: true).State.Offset);    // one step with the keys counts
        Assert.Equal(2, D(47, 45, s: st, touched: false).State.Offset);   // the monitor's own buttons count
    }

    [Fact]
    public void ARefusedWriteIsRetriedAndNotMistakenForAHandSetLevel() {
        var first = D(40, 70, touched: false);
        Assert.Equal(70, first.Write);
        // The monitor refused the write and still reads 40 on the next tick.
        var next = D(40, 70, s: Rules.AfterWrite(first.State, false, default), touched: false);
        Assert.Equal(70, next.Write);
        Assert.Null(next.State.Offset); Assert.False(next.Manual);
        // A write that went through is remembered as usual.
        Assert.Equal(first.State, Rules.AfterWrite(first.State, true, default));
    }

    [Fact]
    public void ARefusedHomeAssistantSetStaysPending() {
        // Automatic mode off: only the "set" helper writes. It changed to 70; the monitor refused it.
        var st = new Hold(100, null, null);
        var first = D(40, 50, remote: (70, 200), s: st, auto: false);
        Assert.Equal(70, first.Write);
        var next = D(40, 50, remote: (70, 200), s: Rules.AfterWrite(first.State, false, st), auto: false);
        Assert.Equal(70, next.Write);   // tried again
        // Once it went through, the same "set" is not applied twice.
        Assert.Null(D(70, 50, remote: (70, 200), s: Rules.AfterWrite(next.State, true, st), auto: false).Write);
    }

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
    public void HandSetLevelIsKeptAsADistanceFromTheTarget() {
        var s = D(50, 70, s: new Hold(null, 70, 70));   // automatic set 70; the user chose 50
        Assert.Null(s.Write);
        Assert.True(s.Manual);
        Assert.Equal(-20, s.State.Offset);
        var next = D(50, 81, s: s.State);                // the target rises: still 20 below
        Assert.Equal(61, next.Write);
        Assert.True(next.Manual);
    }

    [Fact]
    public void ACloudyMorningKeepsTheDimmerLevel() {
        // Replays a real morning: the user turned the screen down while the blind opened and the sun rose.
        var st = new Hold(null, 76, 76);
        var s = D(52, 76, s: st, sun: 0.82); st = s.State;
        Assert.Null(s.Write);
        s = D(52, 81, s: st, sun: 0.84); st = s.State; Assert.Equal(57, s.Write);
        s = D(57, 87, s: st, sun: 0.84); st = s.State; Assert.Equal(63, s.Write);
        s = D(63, 92, s: st, sun: 0.96); Assert.Equal(68, s.Write);
        Assert.True(s.Manual);
    }

    [Fact]
    public void AHandSetLevelEqualToTheTargetIsNotManual() {
        var s = D(72, 72, s: new Hold(null, 70, 70));
        Assert.False(s.Manual);
        Assert.Null(s.State.Offset);
    }

    [Fact]
    public void ADaytimeDistanceFadesAtDuskAndRestsAtNight() {
        var st = new Hold(null, 60, 80, -20, 1);
        Assert.Null(D(60, 80, s: st, sun: 1).Write);
        Assert.Equal(60, D(60, 70, s: st, sun: 0.15).Applied);   // half faded: 70 − 10
        var night = D(60, 50, s: st, sun: 0);
        Assert.Equal(50, night.Write);
        Assert.False(night.Manual);
    }

    // Unix days in UTC keep these tests independent of the machine's time zone.
    static double At(int day, double hour) => day * 86400.0 + hour * 3600;
    static int UtcDay(double t) => (int)Math.Floor(t / 86400);
    static Step DN(int c, int target, Hold s, double sun, double now) => Rules.Decide(c, target, null, s, true, true, sun, now: now, dayOf: UtcDay);

    [Fact]
    public void OneMissingSunReadingDoesNotLoseADaytimeDistance() {
        // Home Assistant gave no elevation for one poll, so the sun read as night.
        var st = new Hold(null, 60, 80, -20, 0.9, At(100, 10));
        var s = DN(60, 30, st, 0, At(100, 11)); st = s.State;
        Assert.Equal(30, s.Write);
        s = DN(30, 80, st, 0.9, At(100, 11.1));
        Assert.Equal(60, s.Write);                               // the sun is back, so is the distance
        Assert.True(s.Manual);
    }

    [Fact]
    public void ADaytimeDistanceEndsWithTheDayEvenWithoutANightTick() {
        // Set at 16:00, the computer slept, the next tick is the next morning.
        var s = DN(50, 70, new Hold(null, 50, 70, -20, 0.8, At(100, 16)), 0.5, At(101, 8));
        Assert.Equal(70, s.Write);
        Assert.Null(s.State.Offset);
        Assert.False(s.Manual);
    }

    [Fact]
    public void ALinkedMonitorMovedOnItsOwnKeepsItsNewPlace() {
        var g = SyncOffsets.Capture([("a", 70), ("b", 60)]);
        g.Move("b", 45, 70);
        Assert.Equal(55, g.Level("b", 80));   // 25 below the group now
        g.Move("c", 10, 70);                  // not a member: nothing
        Assert.Null(g.Level("c", 70));
    }

    [Fact]
    public void AnOffsetSavedWithoutATimeCountsFromWhenItWasSaved() {
        var h = new SavedHolds { Entries = { ["m"] = new SavedHolds.Entry(50, 70, 1000, -20, 0.8) } };
        Assert.Equal(1000, h.Restore("m", 2000)?.OffsetAt);
    }

    [Fact]
    public void ANightDistanceLastsAsLongAsItStaysDark() {
        var st = new Hold(null, 30, 50, -20, 0, At(100, 23));
        Assert.NotNull(DN(30, 50, st, 0, At(101, 6)).State.Offset);
        Assert.NotNull(DN(30, 50, st, 0, At(101, 20)).State.Offset);   // a polar night: still dark the next evening
    }

    [Fact]
    public void ANightDistanceEndsWhenDaylightPassesTheFadeEdgeEvenAfterASleep() {
        var st = new Hold(null, 30, 50, -20, 0, At(100, 23));
        Assert.False(Rules.OffsetExpired(st, At(101, 5), 0.29, UtcDay));
        Assert.True(Rules.OffsetExpired(st, At(101, 5), 0.3, UtcDay));
    }

    [Fact]
    public void EveryDistanceEndsAfterThirtySixHours() {
        var night = new Hold(null, 30, 50, -20, 0, At(100, 0));
        Assert.False(Rules.OffsetExpired(night, At(100, 0) + Rules.OffsetMaxAge, 0, UtcDay));
        Assert.True(Rules.OffsetExpired(night, At(100, 0) + Rules.OffsetMaxAge + 1, 0, UtcDay));
        var day = new Hold(null, 30, 50, -20, 1, At(100, 12));
        Assert.True(Rules.OffsetExpired(day, At(100, 12) + Rules.OffsetMaxAge + 1, 1, _ => 7));
    }

    [Fact]
    public void ADaytimeDistanceCarriesPastMidnightWhileTheSunIsStillUp() {
        var st = new Hold(null, 50, 70, -20, 0.8, At(100, 20));
        Assert.False(Rules.OffsetExpired(st, At(101, 1), 0.1, UtcDay));   // polar day, new calendar day
        Assert.True(Rules.OffsetExpired(st, At(101, 1), 0, UtcDay));      // a normal midnight
        Assert.False(Rules.OffsetExpired(st, At(100, 23), 0, UtcDay));    // same day: the fade handles it
    }

    [Fact]
    public void ASavedHoldIsRewrittenWhenOnlyTheOffsetTimeChanges() {
        var saved = new SavedHolds();
        var a = new Hold(null, 40, 70, -30, 1, 900);
        Assert.True(saved.Record("A", a, 1000));
        Assert.False(saved.Record("A", a, 1100));                          // nothing changed
        var again = a with { OffsetAt = 1050, OffsetSun = 0.5 };           // same offset, held again
        Assert.True(saved.Record("A", again, 1100));
        Assert.Equal(again, saved.Restore("A", 1200));
    }

    [Fact]
    public void ANightDistanceEndsAfterSunrise() {
        var st = new Hold(null, 30, 50, -20, 0);
        Assert.Null(D(30, 50, s: st, sun: 0).Write);
        Assert.Equal(50, D(30, 60, s: st, sun: 0.15).Write);
        var day = D(30, 70, s: st, sun: 0.3);
        Assert.Equal(70, day.Write);
        Assert.Null(day.State.Offset);
    }

    [Fact]
    public void TheDistanceIsClampedButKept() {
        var s = D(10, 30, s: new Hold(null, 10, 40, -30, 1));
        Assert.Equal(0, s.Write);
        Assert.Equal(-30, s.State.Offset);
        Assert.Equal(30, D(0, 60, s: s.State).Write);
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
    public void HomeAssistantRestartWithTheSameSetValueIsNotACommand() {
        var first = D(75, 75, remote: (20, 1000));
        var restart = D(75, 75, remote: (20, 5000), s: first.State, here: false);
        Assert.Null(restart.Remote);
        Assert.Null(restart.Write);
        Assert.Null(restart.State.Offset);
        Assert.Equal(5000, restart.State.RemoteSeen);
        var real = D(75, 75, remote: (40, 6000), s: restart.State, here: false);
        Assert.Equal(40, real.Remote);
        Assert.Equal(40, real.State.RemoteValue);
    }

    [Fact]
    public void SetHelperChangeAppliesEvenWhenIdleAndIsHeld() {
        var s = D(70, 70, remote: (30, 2000), s: new Hold(1000, 70, 70), here: false);
        Assert.Equal(30, s.Remote);
        Assert.Equal(30, s.Write);
        Assert.Equal(30, s.Current);
        Assert.True(s.Manual);
        Assert.Equal(2000, s.State.RemoteSeen);
        var next = D(30, 70, s: s.State);   // the next tick at the same target keeps 30, a higher one moves with it
        Assert.Null(next.Write);
        Assert.True(next.Manual);
        Assert.Equal(40, D(30, 80, s: next.State).Write);
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
    [Fact]
    public void WhiteLightsSwitchAtTheSameBrightnessAsBefore() {
        var r = new LookRule();
        Assert.True(r.WantDark(-10, 0, true, true, 199, 10));    // not bright enough yet
        Assert.False(r.WantDark(-10, 0, true, true, 200, 10));   // 200 of 255: light
        Assert.False(r.WantDark(-10, 0, true, true, 170, 10));   // still counts
        Assert.True(r.WantDark(-10, 0, true, true, 169, 10));    // below 170: dark
    }
    [Fact]
    public void ANarrowCustomGapStartsInsideIt() {
        var t = new Tuning { Theme = new() { LightSunAbove = 2, DarkSunBelow = 1.8 } };
        Assert.False(new LookRule().WantDark(1.97, 100, false, false, 0, 0, t));   // upper part of the gap: light
    }
    [Fact]
    public void CloseLinesGetLabelsThatDoNotOverlap() {
        Assert.Equal([80.0, 104.0], Layout.SpreadLabels([80, 90], 24, 170));
        Assert.Equal([104.0, 80.0], Layout.SpreadLabels([90, 80], 24, 170));
        Assert.Equal([20.0, 120.0], Layout.SpreadLabels([20, 120], 24, 170));   // far apart: on their lines
        Assert.Equal([134.0, 158.0], Layout.SpreadLabels([165, 168], 24, 170));  // at the bottom: pushed up
    }
    [Fact] public void WarmLightsAtNightStayDark() => Assert.True(new LookRule().WantDark(-10, 0, true, true, 230, 70));
    [Fact] public void WithoutBlindOnlyTheSunCounts() => Assert.False(new LookRule().WantDark(10, 0, false, false, 0, 0));

    // Sun 16°, blind 40% (inside the default 35–55 gap), lights off: only the daylight condition is undecided.
    [Fact]
    public void AFreshRuleInTheGapKeepsALightScreen() {
        var r = new LookRule();
        Assert.False(r.WantDark(16, 40, true, false, 0, 0, previous: false));
        Assert.False(r.WantDark(16, 40, true, false, 0, 0));   // stays light
    }
    [Fact]
    public void AFreshRuleInTheGapKeepsADarkScreen() {
        var r = new LookRule();
        Assert.True(r.WantDark(16, 40, true, false, 0, 0, previous: true));
        Assert.True(r.WantDark(16, 40, true, false, 0, 0));    // stays dark
    }
    [Fact]
    public void AFreshRuleInTheGapWithoutTheScreenStateUsesTheMidpoint() {
        Assert.True(new LookRule().WantDark(16, 40, true, false, 0, 0, previous: null));    // 40% is under the 50% midpoint
        Assert.False(new LookRule().WantDark(16, 52, true, false, 0, 0, previous: null));   // 52% is over it
    }
    [Fact]
    public void OutsideTheGapTheScreenStateIsIgnored() {
        Assert.False(new LookRule().WantDark(16, 80, true, false, 0, 0, previous: true));   // blind open: light
        Assert.True(new LookRule().WantDark(16, 20, true, false, 0, 0, previous: false));   // blind closed: dark
        Assert.True(new LookRule().WantDark(-10, 40, true, false, 0, 0, previous: false));  // night: dark
    }
    [Fact]
    public void BothConditionsInTheGapFollowTheScreenState() {
        // Lights at 185 of 255 (about 73%, between 66.6 and 78.4) and white: also inside their gap.
        var light = new LookRule(); var dark = new LookRule();
        Assert.False(light.WantDark(16, 40, true, true, 185, 10, previous: false));
        Assert.False(light.WantDark(16, 40, true, true, 185, 10));   // stays light
        Assert.True(dark.WantDark(16, 40, true, true, 185, 10, previous: true));
        Assert.True(dark.WantDark(16, 40, true, true, 185, 10));     // stays dark
        Assert.True(new LookRule().WantDark(16, 40, true, true, 185, 10, previous: null));
    }
    [Fact]
    public void AfterKeepingALightScreenSunsetStillTurnsItDark() {
        var r = new LookRule();
        Assert.False(r.WantDark(16, 40, true, false, 0, 0, previous: false));
        Assert.True(r.WantDark(0.5, 40, true, false, 0, 0));   // sun below 1°: dark
    }
    [Fact]
    public void ADarkScreenUnderBrightWhiteLightsLeavesDaylightToTheMidpoint() {
        // Bright white lights decide light on their own, so the dark screen says nothing about daylight.
        var r = new LookRule();
        Assert.False(r.WantDark(16, 52, true, true, 230, 10, previous: true));
        Assert.False(r.WantDark(16, 52, true, false, 0, 0));   // 52% blind is over the midpoint: light
    }

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
        Assert.Equal(60, c.Monitors![0].Contrast);
        Assert.Null(c.Monitors![1].Contrast);
        Assert.Equal("input_number.daylit_left_night_lights", c.Monitors![0].HomeAssistant!.NightLights);
        Assert.Equal(40, c.Monitors![1].NightLights);
    }

    [Fact]
    public void AnOldConfigWithManualHoldStillLoads() {
        var (c, err) = Config.Load(Write("""{ "source": "sun", "manualHold": 5, "location": { "latitude": 51.48, "longitude": 0.0 } }"""));
        Assert.Null(err);
        Assert.Equal("Sun", c.Effective.ToString());
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
    public void UnavailableBlindKeepsItsLastPosition() {
        Assert.Equal(40, Rules.BlindPosition(40, 70));
        Assert.Equal(40, Rules.BlindPosition(-1, 40));    // dropped off Home Assistant for a moment
        Assert.Equal(100, Rules.BlindPosition(-1, null)); // never seen: counts as open
        Assert.Equal(0, Rules.BlindPosition(0, 40));      // closed is a real position
    }

    [Fact]
    public void ALevelSetInTheLastLightFadesOverHalfAnHour() {
        static double At(double hour) => 100 * 86400 + hour * 3600;
        static int Day(double t) => (int)Math.Floor(t / 86400);
        var s = Rules.Decide(85, 55, null, new Hold(null, 55, 55, null, null, null), true, true, 0.04, true, false, At(18.4), Day);
        Assert.Null(s.Write);
        s = Rules.Decide(85, 55, null, s.State, true, true, 0.01, true, false, At(18.4 + 4.0 / 60), Day);
        Assert.Equal(81, s.Write);                                   // 4 minutes on: most of it, not a quarter
        s = Rules.Decide(81, 55, null, s.State, true, true, 0, true, false, At(18.4 + 15.0 / 60), Day);
        Assert.Equal(70, s.Write);                                   // half way
        s = Rules.Decide(70, 55, null, s.State, true, true, 0, true, false, At(19), Day);
        Assert.Equal(55, s.Write);                                   // gone at night, as a daytime one
        Assert.False(s.Manual);
    }

    [Fact]
    public void EntitiesAppearOneRowPerMonitor() {
        var h = new HaConfig { Url = "http://x", AutoSwitch = "input_boolean.auto", Cover = "cover.blind", Lights = "light.room" };
        var t = HaTemplate.Build(h, [new MonitorHa { Day = "input_number.d", Set = "input_number.s" }, null]);
        Assert.Contains("is_state('input_boolean.auto','on') | tojson", t);
        Assert.Contains("state_attr('cover.blind','current_position') | float(-1)", t);   // unavailable is not "open"
        Assert.Contains("state_attr('light.room','brightness')", t);
        Assert.Contains("[{{ states('input_number.d') | float(-1) }}, -1, -1, ", t);
        Assert.Contains("states['input_number.s'].last_changed", t);
        Assert.Contains("[-1, -1, -1, -1, -1, 0]", t);   // a monitor without HA entities still gets its row
    }

    [Fact]
    public void SetHelperWithDigitFirstNameAvoidsTheDottedForm() {
        // Home Assistant can't parse states.input_number.1st…, and one syntax error fails the whole template.
        var t = HaTemplate.Build(new HaConfig { Url = "http://x" }, [new MonitorHa { Set = "input_number.1st_monitor" }]);
        Assert.Contains("states['input_number.1st_monitor'].last_changed) if states['input_number.1st_monitor']", t);
        Assert.DoesNotContain("states.input_number", t);
    }
}

public class ContrastTests {
    [Fact] public void ConfiguredContrastIsWrittenOverDdc() =>
        Assert.Equal(60, ContrastRule.ToWrite(60, true, null));
    [Fact] public void NothingIsWrittenWithoutAConfiguredValue() =>
        Assert.Null(ContrastRule.ToWrite(null, true, null));
    [Fact] public void HdrMonitorsAreLeftAlone() =>
        Assert.Null(ContrastRule.ToWrite(60, false, null));
    [Fact] public void TheSameValueIsNotWrittenTwiceUntilForgotten() {
        Assert.Null(ContrastRule.ToWrite(60, true, 60));
        Assert.Equal(70, ContrastRule.ToWrite(70, true, 60));   // a reloaded config with a new value
    }
    [Fact] public void OutOfRangeValuesAreClampedAndRounded() {
        Assert.Equal(100, ContrastRule.ToWrite(150, true, null));
        Assert.Equal(0, ContrastRule.ToWrite(-5, true, null));
        Assert.Equal(63, ContrastRule.ToWrite(62.5, true, null));
    }
    [Fact] public void ContrastIsReadFromAMonitorEntry() {
        var p = Path.Combine(Path.GetTempPath(), $"daylit-test-{Guid.NewGuid()}.json");
        File.WriteAllText(p, "{\"monitors\":[{\"match\":\"U2723QE\",\"contrast\":55}]}");
        var (c, err) = Config.Load(p);
        Assert.Null(err);
        Assert.Equal(55, c.Monitors![0].Contrast);
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
        var auto = Rules.Decide(60, 72, null, new Hold(null, 60, 60), true, true, 1);
        Assert.Equal(72, auto.Write);
        Assert.False(auto.Manual);
        var held = Rules.Decide(40, 72, null, auto.State, true, true, 1);   // slider moved to 40 by hand: kept, 32 below
        Assert.Null(held.Write);
        Assert.True(held.Manual);
    }
}

public class SyncTests {
    static SyncOffsets Two(int a, int b) => SyncOffsets.Capture(new[] { ("a", a), ("b", b) });

    [Fact]
    public void ALeavingMonitorStaysOutAndTheOthersKeepTheirOffsets() {
        var s = SyncOffsets.Capture(new[] { ("a", 60), ("b", 40), ("tv", 75) });
        s.Leave("a");
        Assert.Equal(new Dictionary<string, int> { ["b"] = -20, ["tv"] = 15 }, s.Offsets);
        Assert.Equal(new Dictionary<string, int> { ["tv"] = 65 }, s.Follow("b", 30, new[] { "a", "b", "tv" }));
        Assert.Empty(s.Follow("a", 10, new[] { "a", "b", "tv" }));
        s.Adopt(new[] { ("a", 10), ("b", 30), ("tv", 65) });
        Assert.False(s.IsMember("a"));
        Assert.Equal(2, s.Members(new[] { "a", "b", "tv" }));
    }

    [Fact]
    public void RejoiningUsesTheCurrentOffset() {
        var s = Two(60, 40);
        s.Leave("b");
        s.Join("b", new[] { ("a", 50), ("b", 20) });
        Assert.Equal(-30, s.Offsets["b"]);
        Assert.Empty(s.Excluded);
    }

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
        Assert.True(saved.Record("A", new Hold(null, 40, 70, -30, 1, 900), 1000));
        var back = SavedHolds.FromJson(saved.ToJson());
        var r = back.Restore("A", 1000 + 3600);
        Assert.Equal(new Hold(null, 40, 70, -30, 1, 900), r);
        // At 40 (set by hand before the restart): keeps following the target 30 below.
        var step = Rules.Decide(40, 72, null, r!.Value, true, true, 1);
        Assert.Equal(42, step.Write);
        Assert.True(step.Manual);
    }

    [Fact]
    public void WithoutSavedHoldARestartAppliesTheTarget() {
        var step = Rules.Decide(40, 72, null, new Hold(null, null, null), true, true, 1);
        Assert.Equal(72, step.Write);
    }

    [Fact]
    public void HoldsSavedBeforeOffsetsStillLoad() {
        var back = SavedHolds.FromJson("""{"A":{"LastSet":40,"LastTarget":70,"Saved":10}}""");
        Assert.Equal(new Hold(null, 40, 70), back.Restore("A", 20));
    }

    [Fact]
    public void SavedHoldExpiresAndEmptyStateIsDropped() {
        var saved = new SavedHolds();
        saved.Record("A", new Hold(null, 70, 70), 0);
        Assert.Null(saved.Restore("A", SavedHolds.MaxAge + 1));
        Assert.Null(saved.Restore("B", 10));
        Assert.False(saved.Record("A", new Hold(null, 70, 70), 50));   // unchanged: keeps the original time
        Assert.True(saved.Record("A", new Hold(null, null, null), 60));
        Assert.Empty(saved.Entries);
        Assert.NotNull(SavedHolds.FromJson("not json"));
    }
}

public class HaErrorRuleTests {
    [Fact] public void TransientStaysQuietForAMinute() {
        Assert.False(HaErrorRule.ShouldShow(true, null, 100));
        Assert.False(HaErrorRule.ShouldShow(true, 100, 159));
        Assert.True(HaErrorRule.ShouldShow(true, 100, 160));
    }
    [Fact] public void TokenProblemsShowAtOnce() {
        Assert.True(HaErrorRule.ShouldShow(false, null, 0));
        Assert.Equal(new double[] { 2, 5 }, HaErrorRule.RetryDelays);
    }
    [Fact] public void OutageIsLoggedOnceThenEveryTenMinutes() {
        const string m = "Cannot reach Home Assistant";
        Assert.True(HaErrorRule.ShouldLog(m, null, null, 0));
        Assert.False(HaErrorRule.ShouldLog(m, m, 0, 30));
        Assert.False(HaErrorRule.ShouldLog(m, m, 0, 599));
        Assert.True(HaErrorRule.ShouldLog(m, m, 0, 600));
    }
    [Fact] public void ADifferentErrorIsLoggedAtOnce() =>
        Assert.True(HaErrorRule.ShouldLog("Token rejected", "Cannot reach Home Assistant", 0, 30));
    [Fact] public void AnEmptyDisplayNameGetsANumber() {
        Assert.Equal("Display 2", DisplayName.Label("", 1));
        Assert.Equal("Display 1", DisplayName.Label("  ", 0));
        Assert.Equal("DELL S2725QC", DisplayName.Label("DELL S2725QC", 0));
    }
}

public class ConfigPatchTests {
    static readonly SettingsEdit.Monitor Dell = new("DELL U2723QE", "U2723QE", "Left", 80, 45, 15);
    static System.Text.Json.Nodes.JsonObject Json(string s) => (System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse(s)!;

    [Fact]
    public void ContrastBoxWritesAndRemovesTheKeyAndKeepsTheRest() {
        const string original = """{ "monitors": [ { "match": "U2723QE", "control": "ddc", "contrast": 40, "future": 1 } ] }""";
        var m = Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { Contrast = 70, ContrastEditable = true }]), original))["monitors"]![0]!;
        Assert.Equal(70, (int)m["contrast"]!);
        Assert.Equal("ddc", (string)m["control"]!); Assert.Equal(1, (int)m["future"]!);
        var saved = ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell with { Contrast = null, ContrastEditable = true }]), original);
        m = Json(saved)["monitors"]![0]!;
        Assert.Null(m["contrast"]);   // an empty box removes the key
        Assert.Equal(1, (int)m["future"]!);
        var p = Path.Combine(Path.GetTempPath(), $"daylit-test-{Guid.NewGuid()}.json");
        File.WriteAllText(p, saved);
        Assert.Null(Config.Load(p).cfg.Monitors![0].Contrast);
    }

    [Fact]
    public void ContrastWithoutABoxIsKept() {
        var m = Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell]), """{ "monitors": [ { "match": "U2723QE", "contrast": 40 } ] }"""))["monitors"]![0]!;
        Assert.Equal(40, (int)m["contrast"]!);   // an HDR monitor has no box: its contrast stays
    }

    [Fact]
    public void ContrastBoxText() {
        Assert.True(ContrastRule.ParseField("").ok); Assert.Null(ContrastRule.ParseField("  ").value);
        Assert.Equal(60, ContrastRule.ParseField("60").value);
        Assert.Equal(63, ContrastRule.ParseField("62,5").value);
        Assert.Equal(0, ContrastRule.ParseField("0").value);
        Assert.False(ContrastRule.ParseField("101").ok);
        Assert.False(ContrastRule.ParseField("-1").ok);
        Assert.False(ContrastRule.ParseField("high").ok);
    }

    [Fact]
    public void KeepsWhatTheWindowDoesNotOwn() {
        const string original = """
            { // a comment
              "manualHold": 7, "futureKey": [1, 2],
              "homeAssistant": { "url": "http://homeassistant.local:8123", "tokenName": "kc", "cover": "cover.blind" },
              "monitors": [
                { "match": "U2723QE", "control": "ddc", "day": 70, "contrast": 60, "homeAssistant": { "day": "input_number.left_day" } },
                { "match": "Unplugged", "day": 33 }, ],
            }
            """;
        var e = new SettingsEdit("homeAssistant", 51.4769, -0.0005, [Dell], HaUrl: "http://homeassistant.local:8123", Lights: "light.desk");
        var text = ConfigPatch.Apply(e, original);
        var o = Json(text);
        Assert.Equal(7, (int)o["manualHold"]!);
        Assert.NotNull(o["futureKey"]);
        var ha = o["homeAssistant"]!.AsObject();
        Assert.Equal("kc", (string)ha["tokenName"]!);
        Assert.Null(ha["cover"]);
        Assert.Equal("light.desk", (string)ha["lights"]!);
        Assert.Contains("51.48", text); Assert.DoesNotContain("51.479", text);
        Assert.Equal(0m, (decimal)o["location"]!["longitude"]!);
        var mons = o["monitors"]!.AsArray();
        Assert.Equal(2, mons.Count);
        Assert.Equal("ddc", (string)mons[0]!["control"]!);
        Assert.Equal(60, (int)mons[0]!["contrast"]!);
        Assert.Equal("Left", (string)mons[0]!["label"]!);
        Assert.Equal(80, (int)mons[0]!["day"]!);
        Assert.NotNull(mons[0]!["homeAssistant"]);
        Assert.Equal(33, (int)mons[1]!["day"]!);
    }

    [Fact]
    public void ANewMonitorIsAddedWithItsSuggestedMatch() {
        var o = Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [Dell]), null));
        Assert.Equal("U2723QE", (string)o["monitors"]![0]!["match"]!);
        Assert.Null(o["location"]);
        Assert.Null(o["homeAssistant"]);
    }

    [Fact]
    public void AnInvalidResultIsRefused() {
        Assert.ThrowsAny<Exception>(() => ConfigPatch.Apply(new SettingsEdit("homeAssistant", null, null, [], HaUrl: "homeassistant.local"), null));
        Assert.ThrowsAny<Exception>(() => ConfigPatch.Apply(new SettingsEdit("sun", 51.48, 0, [], Lights: "Desk lamp"), null));
        Assert.ThrowsAny<Exception>(() => ConfigPatch.Apply(new SettingsEdit("sun", 51.48, 0, []), "[1]"));
    }

    [Fact]
    public void TwoMonitorsMatchingOneEntryDoNotOverwriteEachOther() {
        var a = new SettingsEdit.Monitor("DELL U2723QE (1)", "U2723QE", "", 80, 40, 20);
        var b = new SettingsEdit.Monitor("DELL U2723QE (2)", "U2723QE", "", 10, 10, 10);
        var o = Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, [a, b]), """{"monitors":[{"match":"U2723QE"}]}"""));
        Assert.Single(o["monitors"]!.AsArray());
        Assert.Equal(80, (int)o["monitors"]![0]!["day"]!);
    }

    [Fact]
    public void LocationKeepsOtherKeysAndCommentsAreDetected() {
        var o = Json(ConfigPatch.Apply(new SettingsEdit("sun", 1, 2, []), """{"location":{"latitude":0,"longitude":0,"note":"x"}}"""));
        Assert.Equal("x", (string)o["location"]!["note"]!);
        Assert.True(ConfigPatch.HasComments("{ // hi\n}"));
        Assert.False(ConfigPatch.HasComments("""{ "a": "//not" }"""));
        Assert.ThrowsAny<Exception>(() => ConfigPatch.Apply(new SettingsEdit("off", null, null, []), """{"monitors":[null,{"match":"A"}]}"""));
    }

    [Fact]
    public void TuningIsWrittenOnlyWhereItDiffersFromTheDefault() {
        var e = new SettingsEdit("off", null, null, [],
            Tuning: new Dictionary<string, double> { ["brightness.sunDay"] = 15, ["theme.lightSunAbove"] = 4, ["timing.pollSeconds"] = 20 },
            ThemeRoom: false);
        var o = Json(ConfigPatch.Apply(e, """{"tuning":{"theme":{"darkSunBelow":0},"future":1}}"""));
        var t = o["tuning"]!.AsObject();
        Assert.Equal(15, (int)t["brightness"]!["sunDay"]!);
        Assert.Equal(20, (int)t["timing"]!["pollSeconds"]!);
        Assert.Null(t["theme"]!["lightSunAbove"]); Assert.Null(t["theme"]!["darkSunBelow"]);
        Assert.False((bool)t["theme"]!["room"]!);
        Assert.Equal(1, (int)t["future"]!);
        Assert.Null(Json(ConfigPatch.Apply(new SettingsEdit("off", null, null, []), """{"tuning":{"theme":{"darkSunBelow":0}}}"""))["tuning"]);
        Assert.ThrowsAny<Exception>(() => ConfigPatch.Apply(new SettingsEdit("off", null, null, [],
            Tuning: new Dictionary<string, double> { ["brightness.sunNight"] = 20, ["brightness.sunDay"] = 10 }), null));
    }

    [Fact]
    public void SuggestsTheModelNumber() => Assert.Equal("AW3821DW", ConfigPatch.SuggestMatch("Dell AW3821DW"));
}

public class TuningTests {
    static Config Parse(string json) {
        string p = Path.Combine(Path.GetTempPath(), $"daylit-tuning-{Guid.NewGuid():N}.json");
        File.WriteAllText(p, json);
        try { var (c, err) = Config.Load(p); Assert.Null(err); return c; } finally { File.Delete(p); }
    }

    [Fact]
    public void DefaultsGiveTheSameResultsAsBefore() {
        var t = new Tuning();
        for (double elev = -10; elev <= 30; elev += 0.5) {
            Assert.Equal(Sun.Fraction(elev), t.Fraction(elev), 12);
            foreach (bool lights in new[] { false, true })
                Assert.Equal(Rules.Target([70, 40, 20], 60, lights, Sun.Fraction(elev)),
                             Rules.Target([70, 40, 20], 60, lights, t.Fraction(elev), t, elev < t.LightsBoostSunBelow));
        }
    }

    [Fact]
    public void CustomValuesMoveTheCurveAndTheBoost() {
        var t = Parse("""{ "tuning": { "brightness": { "sunNight": 0, "sunDay": 20, "lightsBoost": 10, "lightsBoostSunBelow": 0 } } }""").Tuned;
        Assert.Equal(0.5, t.Fraction(10));
        Assert.Equal(30, Rules.Target([70, 40, 20], 100, true, t.Fraction(-5), t, -5 < t.LightsBoostSunBelow));
        Assert.Equal(23, Rules.Target([70, 40, 20], 100, true, t.Fraction(1), t, 1 < t.LightsBoostSunBelow));
    }

    [Fact]
    public void ThemeThresholdsAndRoomSwitch() {
        var t = Parse("""{ "tuning": { "theme": { "lightSunAbove": 10, "darkSunBelow": 6 } } }""").Tuned;
        var look = new LookRule();
        Assert.True(look.WantDark(8, 100, false, false, 0, 0, t));
        Assert.False(look.WantDark(11, 100, false, false, 0, 0, t));
        Assert.False(look.WantDark(8, 100, false, false, 0, 0, t));
        var sunOnly = Parse("""{ "tuning": { "theme": { "room": false } } }""").Tuned;
        Assert.False(new LookRule().WantDark(20, 0, true, false, 0, 0, sunOnly));
    }

    [Fact]
    public void ImpossibleValuesAreRefused() {
        string Err(string json) {
            string p = Path.Combine(Path.GetTempPath(), $"daylit-tuning-{Guid.NewGuid():N}.json");
            File.WriteAllText(p, json);
            try { return Config.Load(p).error ?? ""; } finally { File.Delete(p); }
        }
        Assert.Equal("", Err("""{ "tuning": {} }"""));
        Assert.NotEqual("", Err("""{ "tuning": { "brightness": { "sunNight": 10, "sunDay": 5 } } }"""));
        Assert.NotEqual("", Err("""{ "tuning": { "theme": { "lightSunAbove": 0, "darkSunBelow": 2 } } }"""));
        Assert.Equal("config.json: tuning.timing.pollSeconds must be 5–3600", Err("""{ "tuning": { "timing": { "pollSeconds": 1 } } }"""));
    }
}

public class LightTests {
    static LightReference Ref() {
        // Clear mornings read up to 500 at 10–12°, noon 1600 at 30–32°.
        var s = new List<LightSample>();
        for (int k = 0; k < 10; k++) { s.Add(new(11, true, 50 + k * 50)); s.Add(new(31, true, 1600)); }
        return new LightReference(s);
    }

    [Fact]
    public void TheReferenceIsTheNinetiethPercentileOfEachStep() {
        var r = Ref();
        Assert.Equal(450, r.ClearSky(10.5, true));   // 50…500: the 90th percentile
        Assert.Null(r.ClearSky(10.5, false));         // afternoons are learned apart
        Assert.Null(new LightReference([new(11, true, 400), new(11, true, 400)]).ClearSky(11, true));   // too few
    }

    [Fact]
    public void ACloudyMorningReadsAsAFractionOfClearSky() {
        Assert.Equal(0.1, LightRules.Ratio(45, 11, true, Ref())!.Value, 1e-9);
        Assert.Equal(1, LightRules.Ratio(900, 11, true, Ref()));   // brighter than clear: 1
    }

    [Fact]
    public void AZeroIsAFaultNotACloud() {
        Assert.Null(LightRules.Ratio(0, 31, true, Ref()));
        Assert.Null(LightRules.Ratio(0, 11, true, Ref()));   // a smaller step too
        Assert.Null(LightRules.Ratio(null, 31, true, Ref()));
        Assert.Null(LightRules.Ratio(300, -1, true, Ref()));
    }

    [Fact]
    public void OvercastCapsDaylightAtTheFloor() {
        Assert.Equal(0.35, LightRules.Cap(0, 0.35), 1e-9);
        Assert.Equal(0.675, LightRules.Cap(0.5, 0.35), 1e-9);
        Assert.Equal(1, LightRules.Cap(1, 0.35));
        Assert.Equal(1, LightRules.Cap(null, 0.35));
    }

    [Fact]
    public void AnOvercastDawnNeverDipsAsTheSunRises() {
        // day 70, night 20, fully overcast: the level climbs with the sun and stops at the cap.
        var t = new Tuning();
        var levels = Enumerable.Range(0, 47).Select(k => -3 + k * 0.5)
            .Select(e => Rules.Target([70, 40, 20], 100, false, t.Fraction(e), t, false, 0.35)).ToList();
        Assert.Equal(levels.Order().ToList(), levels);
        Assert.Equal(38, levels[^1]);
    }

    [Fact]
    public void AnEastFacingArrayIsComparedWithinItsOwnHalfOfTheDay() {
        var s = new List<LightSample>();
        for (int k = 0; k < 5; k++) { s.Add(new(11, true, 4000)); s.Add(new(11, false, 150)); }
        Assert.Equal(0.2, LightRules.Ratio(30, 11, false, new LightReference(s))!.Value, 1e-9);
    }

    [Fact]
    public void AStepThatOnlyReadZeroIsNotAReference() =>
        Assert.True(new LightReference(Enumerable.Range(0, 5).Select(_ => new LightSample(31, true, 0))).IsEmpty);

    [Fact]
    public void DimmingIsQuickerThanBrightening() {
        double down = LightRules.Smooth(1, 0.35, 120), up = LightRules.Smooth(0.35, 1, 120);
        Assert.True(down < 1 - 0.6 * 0.65);   // most of the way down in 2 minutes
        Assert.True(up < 0.35 + 0.4 * 0.65);  // under half way up
        Assert.Equal(0.5, LightRules.Smooth(null, 0.5, 0));
    }

    [Fact]
    public void TheLightScaleDimsOnlyTheDaylightPart() {
        // day 70, night 20, full sun: clear 70; overcast keeps 35% of the 50-point daylight part.
        var t = new Tuning();
        Assert.Equal(70, Rules.Target([70, 40, 20], 100, false, t.Fraction(30), t));
        Assert.Equal(38, Rules.Target([70, 40, 20], 100, false, t.Fraction(30), t, light: 0.35));
        Assert.Equal(20, Rules.Target([70, 40, 20], 100, false, t.Fraction(-10), t, light: 0.35));
    }

    [Fact]
    public void HistoryReadingsGetTheSunsPosition() {
        const string json = """
            [[{"entity_id":"sensor.pv","state":"300","last_changed":"2026-06-21T12:00:00+00:00"},
              {"state":"unavailable","last_changed":"2026-06-21T12:01:00+00:00"},
              {"state":"0","last_changed":"2026-06-21T23:00:00.123+00:00"}]]
            """;
        var s = LightRules.Samples(json, 51.48, 0);
        Assert.Single(s);                  // the night reading and the non-number are skipped
        Assert.Equal(300, s[0].Value);
        Assert.True(s[0].Elev > 60);       // midsummer noon at Greenwich
    }

    [Fact]
    public void HistoryFromBeforeAUnitChangeIsSkipped() {
        // The unit changed to kW at 12:00. Home Assistant starts the answer with the state at that moment,
        // still the old 1500 W; only the readings after it count.
        const string json = """
            [[{"entity_id":"sensor.pv_power","state":"1500","last_changed":"2026-06-21T12:00:00+00:00"},
              {"state":"1.5","last_changed":"2026-06-21T12:00:30+00:00"}]]
            """;
        double since = DateTimeOffset.Parse("2026-06-21T12:00:00Z", System.Globalization.CultureInfo.InvariantCulture).ToUnixTimeSeconds();
        Assert.Equal([1.5], LightRules.Samples(json, 51.48, 0, since).Select(x => x.Value));
        Assert.Equal(2, LightRules.Samples(json, 51.48, 0).Count);   // no change: all of it
    }

    [Fact]
    public void ALightSensorNeedsALocation() {
        string Err(string json) {
            string p = Path.Combine(Path.GetTempPath(), $"daylit-light-{Guid.NewGuid():N}.json");
            File.WriteAllText(p, json);
            try { return Config.Load(p).error ?? ""; } finally { File.Delete(p); }
        }
        Assert.Equal("config.json: homeAssistant.light needs a location",
                     Err("""{ "homeAssistant": { "url": "http://homeassistant.local:8123", "light": "sensor.pv_power" } }"""));
        Assert.Equal("", Err("""{ "location": { "latitude": 51.48, "longitude": 0.00 }, "homeAssistant": { "url": "http://homeassistant.local:8123", "light": "sensor.pv_power" } }"""));
    }

    [Fact]
    public void TheTemplateAsksForTheLightSensor() {
        var t = HaTemplate.Build(new HaConfig { Url = "http://x", Light = "sensor.pv_power" }, []);
        Assert.Contains("states('sensor.pv_power') | float(-1)", t);
        Assert.Contains("\"lightAge\"", t);
        Assert.Contains("state_attr('sensor.pv_power','unit_of_measurement')", t);
        Assert.Contains("\"light\": -1", HaTemplate.Build(new HaConfig { Url = "http://x" }, []));
        Assert.Contains("\"lightUnit\": null", HaTemplate.Build(new HaConfig { Url = "http://x" }, []));
    }

    [Fact]
    public void AUnitChangeRestartsLearningFromThatMoment() {
        const double day = 86400, now = 100 * day;
        // First seen: its whole history is trusted.
        var first = LightUnit.Update(null, "sensor.pv_power", "W", now);
        Assert.Equal(new LightUnit("sensor.pv_power", "W", 0), first);
        Assert.Equal(10, first.HistoryDays(10, now));
        // Same unit: nothing changes.
        Assert.Equal(first, LightUnit.Update(first, "sensor.pv_power", "W", now + day));
        // W to kW: the older readings are 1000 times off, so learning starts again from now.
        var kw = LightUnit.Update(first, "sensor.pv_power", "kW", now);
        Assert.Equal(new LightUnit("sensor.pv_power", "kW", now), kw);
        Assert.Equal(2, kw.HistoryDays(10, now + 2 * day), 9);
        Assert.Equal(10, kw.HistoryDays(10, now + 30 * day));
    }

    [Fact]
    public void AMissingUnitIsNotAUnitChange() {
        var w = new LightUnit("sensor.pv_power", "W", 0);
        // The sensor is briefly unavailable and reports no unit: keep what was learned.
        Assert.Equal(w, LightUnit.Update(w, "sensor.pv_power", null, 50));
        Assert.Equal(w, LightUnit.Update(w, "sensor.pv_power", "", 50));
        // No unit known yet (started while it was unavailable): the first real one is adopted, not a change.
        var unknown = LightUnit.Update(null, "sensor.pv_power", null, 50);
        Assert.Equal(w, LightUnit.Update(unknown, "sensor.pv_power", "W", 60));
        // Another sensor starts fresh with its own history.
        Assert.Equal(new LightUnit("sensor.solar_power", "kW", 0), LightUnit.Update(w, "sensor.solar_power", "kW", 50));
    }
}

public class AuditLogicTests {
    static System.Text.Json.Nodes.JsonObject Json(string s) => (System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse(s)!;

    [Fact]
    public void TheLongestMatchingEntryWinsAndTheOrderDoesNotMatter() {
        const string name = "Dell AW3821DW";
        Assert.Equal(1, MonitorMatch.Best(name, ["Dell", "AW3821DW"]));
        Assert.Equal(0, MonitorMatch.Best(name, ["AW3821DW", "Dell"]));
        Assert.Equal(0, MonitorMatch.Best(name, ["Dell", "Dell"]));   // equal: the first
    }

    [Fact]
    public void AMatchIsTrimmedCaseInsensitiveAndNeverEmpty() {
        Assert.Equal(0, MonitorMatch.Best("Dell AW3821DW", ["  aw3821dw "]));
        Assert.Null(MonitorMatch.Best("Dell AW3821DW", ["", "   ", null]));
        Assert.Null(MonitorMatch.Best("Dell AW3821DW", ["LG"]));
        Assert.Equal(1, MonitorMatch.Best("Dell AW3821DW", ["   ", "Dell "]));
    }

    [Fact]
    public void SavingChoosesTheLongestMatchingEntry() {
        const string original = """{ "monitors": [ { "match": "Dell", "day": 10 }, { "match": "AW3821DW", "day": 20 } ] }""";
        var e = new SettingsEdit("off", null, null, [new("Dell AW3821DW", "AW3821DW", "", 77, 40, 20)]);
        var list = Json(ConfigPatch.Apply(e, original))["monitors"]!.AsArray();
        Assert.Equal(10, (int)list[0]!["day"]!);
        Assert.Equal(77, (int)list[1]!["day"]!);
        var applied = Json(ConfigPatch.SetLevels(new Dictionary<string, int> { ["day"] = 55 }, "Dell AW3821DW", "AW3821DW", original))["monitors"]!.AsArray();
        Assert.Equal(55, (int)applied[1]!["day"]!);
    }

    [Fact]
    public void ANullMonitorsListIsAsAbsentForSaveAndApply() {
        const string original = """{ "source": "off", "monitors": null }""";
        var e = new SettingsEdit("off", null, null, [new("DELL U2723QE", "U2723QE", "", 80, 45, 15)]);
        Assert.Single(Json(ConfigPatch.Apply(e, original))["monitors"]!.AsArray());
        var applied = Json(ConfigPatch.SetLevels(new Dictionary<string, int> { ["day"] = 55 }, "DELL U2723QE", "U2723QE", original))["monitors"]!.AsArray();
        Assert.Equal(55, (int)applied[0]!["day"]!);
    }

    [Fact]
    public void TheLightHistoryWaitsAnHourWithoutAReferenceAndADayWithOne() {
        Assert.False(LightHistoryRule.Due(3599, false, false));
        Assert.True(LightHistoryRule.Due(3600, false, false));
        Assert.False(LightHistoryRule.Due(3599, true, true));
        Assert.False(LightHistoryRule.Due(3600, true, false));
        Assert.True(LightHistoryRule.Due(86400, true, false));
        Assert.True(LightHistoryRule.Due(-5, true, false));   // a clock set back
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void ARetryStampMakesTheHistoryDueInAnHourNotOnTheNextTick(bool has, bool young) {
        double now = 1_000_000, stamp = LightHistoryRule.RetryStamp(now, has, young);
        Assert.False(LightHistoryRule.Due(now + 30 - stamp, has, young));
        Assert.True(LightHistoryRule.Due(now + 3600 - stamp, has, young));
    }
}
