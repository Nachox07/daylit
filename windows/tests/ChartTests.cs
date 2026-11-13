using Xunit;

namespace Daylit.Tests;

public class ChartTests {
    static DateTimeOffset At(string iso) => DateTimeOffset.Parse(iso, System.Globalization.CultureInfo.InvariantCulture);
    static List<(double t, double e)> Day(string iso, double lat, double lon = 0, TimeZoneInfo? tz = null) {
        var (start, length) = Chart.DayBounds(At(iso), tz ?? TimeZoneInfo.Utc);
        return Chart.DaySamples(lat, lon, start, length);
    }

    [Fact]
    public void AHandleSitsOnTheMorningCrossingWithTheEveningOneAsItsPartner() {
        var s = Day("2026-06-19T12:00:00Z", 51.48);
        var p = Chart.Place(s, 12);
        Assert.False(p.Parked);
        double partner = p.Partner ?? double.NaN;
        Assert.True(p.At < 0.5); Assert.True(partner > 0.5);
        Assert.Equal(12.0, Chart.Elevation(s, p.At), 0.05);
        Assert.Equal(12.0, Chart.Elevation(s, partner), 0.05);
        // Dragging the evening end puts the handle there and the morning one becomes the partner.
        var e = Chart.Place(s, 12, morning: false);
        Assert.Equal(partner, e.At, 1e-9); Assert.Equal(p.At, e.Partner ?? double.NaN, 1e-9);
    }

    [Fact]
    public void MorningAndEveningAreNotAMirrorAroundNoonOnTheClock() {
        // At 10°E the sun peaks well before 12:00 GMT, so the crossings centre on solar noon instead.
        var s = Day("2026-06-19T12:00:00Z", 51.48, lon: 10);
        var p = Chart.Place(s, 12);
        Assert.True((p.At + (p.Partner ?? double.NaN)) / 2 < 0.48);
    }

    [Fact]
    public void WhenTheSunNeverReachesTheLineTheHandleParksOnThePeak() {
        var s = Day("2026-12-21T12:00:00Z", 70);   // noon about -3.4°: under the 12° line all day
        var p = Chart.Place(s, 12);
        Assert.True(p.Parked); Assert.Null(p.Partner); Assert.False(p.SunAbove);
        Assert.Equal(0.5, p.At, 0.02);
        // A click on it saves nothing; dragging it away saves the sun's height where it lands.
        Assert.Null(Chart.DraggedElevation(s, p.At, day: true, other: -3, parkedAt: p.At));
        Assert.NotNull(Chart.DraggedElevation(s, 0.45, day: true, other: -6, parkedAt: p.At));
    }

    [Fact]
    public void InPolarDayTheNightHandleParksOnTheTrough() {
        var s = Day("2026-06-21T12:00:00Z", 80);   // the sun stays about 13° up at midnight
        var p = Chart.Place(s, -3);
        Assert.True(p.Parked); Assert.True(p.SunAbove);
        Assert.True(p.At < 0.02 || p.At > 0.98);
    }

    [Fact]
    public void TheHandlesNeverCrossAndStayInTheAcceptedRange() {
        var s = Day("2026-06-19T12:00:00Z", 51.48);
        Assert.Equal(2.5, Chart.DraggedElevation(s, 0.1, day: true, other: 2) ?? double.NaN);     // the full-day line stops above night
        Assert.Equal(11.5, Chart.DraggedElevation(s, 0.5, day: false, other: 12) ?? double.NaN);  // and night stops below it
        Assert.Equal(60.0, Chart.DraggedElevation(s, 0.5, day: true, other: -3) ?? double.NaN, 3.0);   // noon here is about 62°: clamped to 60
        double v = Chart.DraggedElevation(s, 0.3, day: true, other: -3) ?? double.NaN;
        Assert.Equal(v * 2, Math.Round(v * 2));                                                   // half-degree steps
    }

    [Fact]
    public void ArrowKeysMoveAHandleHalfADegreeAndPageKeysFive() {
        Assert.Equal(12.5, Chart.SteppedElevation(12, Chart.SmallStep, day: true, other: -3));
        Assert.Equal(7.0, Chart.SteppedElevation(12, -Chart.LargeStep, day: true, other: -3));
        Assert.Equal(-3.5, Chart.SteppedElevation(-3, -Chart.SmallStep, day: false, other: 12));
        Assert.Equal(2.0, Chart.SteppedElevation(-3, Chart.LargeStep, day: false, other: 12));
        // A value typed off the half-degree grid lands back on it.
        Assert.Equal(12.5, Chart.SteppedElevation(12.2, Chart.SmallStep, day: true, other: -3));
    }

    [Fact]
    public void AKeyPressStopsAtTheOtherHandleAndAtTheEndsOfTheRange() {
        Assert.Equal(2.5, Chart.SteppedElevation(4, -Chart.LargeStep, day: true, other: 2));    // full day stays above night
        Assert.Equal(11.5, Chart.SteppedElevation(11.5, Chart.SmallStep, day: false, other: 12)); // night stays below full day
        Assert.Equal(60.0, Chart.SteppedElevation(58, Chart.LargeStep, day: true, other: -3));
        Assert.Equal(30.0, Chart.SteppedElevation(28, Chart.LargeStep, day: false, other: 45));
        Assert.Equal(-18.0, Chart.SteppedElevation(-16, -Chart.LargeStep, day: false, other: 12));
    }

    [Fact]
    public void AKeyPressSavesWhatADragToTheSameHeightWould() {
        var s = Day("2026-06-19T12:00:00Z", 51.48);
        foreach (double t in new[] { 0.1, 0.25, 0.3, 0.5, 0.8 }) {
            double e = Chart.Elevation(s, t);
            Assert.Equal(Chart.DraggedElevation(s, t, day: true, other: -3), Chart.SteppedElevation(e, 0, day: true, other: -3));
            Assert.Equal(Chart.DraggedElevation(s, t, day: false, other: 12), Chart.SteppedElevation(e, 0, day: false, other: 12));
        }
    }

    [Fact]
    public void LeftAndRightWalkTheHandlesAndStopAtTheEnds() {
        Assert.Equal(1, Chart.NextHandle(0, 2, +1));
        Assert.Equal(0, Chart.NextHandle(1, 2, -1));
        Assert.Null(Chart.NextHandle(1, 2, +1));   // past the last: Tab leaves the chart
        Assert.Null(Chart.NextHandle(0, 2, -1));   // before the first: Shift+Tab leaves it
        Assert.Null(Chart.NextHandle(0, 0, +1));
    }

    [Fact]
    public void ClockChangeDaysAre23And25HoursLong() {
        var london = TimeZoneInfo.FindSystemTimeZoneById("Europe/London");
        var spring = Chart.DayBounds(At("2026-03-29T12:00:00Z"), london);
        var autumn = Chart.DayBounds(At("2026-10-25T12:00:00Z"), london);
        Assert.Equal(23 * 3600.0, spring.Length); Assert.Equal(25 * 3600.0, autumn.Length);
    }

    [Fact]
    public void TheExplanationEndsOnTheLevelTheTickSets() {
        var t = new Tuning();
        for (double elev = -10; elev <= 40; elev += 2.5)
            foreach (var pos in new[] { 0.0, 40, 100 })
                foreach (var light in new[] { 1.0, 0.8, 0.35 })
                    foreach (var lights in new[] { false, true }) {
                        int @base = Rules.Target([90, 70, 45], pos, lights, t.Fraction(elev), t, elev < t.LightsBoostSunBelow, light);
                        var d = Chart.Explain(90, 70, 45, elev, pos, lights, t, light, offset: 6);
                        Assert.Equal(Math.Min(@base + 6, 100), d.Level);
                        Assert.True(d.Steps[^1].Final);
                    }
    }

    [Fact]
    public void TheExplanationReadsInTheOrderTheRulesApply() {
        var d = Chart.Explain(90, 70, 45, 30, 40, false, light: 0.8, offset: 6);
        Assert.Equal(new[] { "Blind 40% open", "Sun high", "Cloudy", "Lights", "You" }, d.Steps.Select(x => x.Title));
        Assert.Equal(new[] { "daytime 78", "100% → 78", "daylight 80% → 71", "no effect by day", "+6 → 77" }, d.Steps.Select(x => x.Value));
        Assert.Equal(77, d.Level);
    }

    [Fact]
    public void RoomLightsAtDuskLiftTheNightLevel() {
        var d = Chart.Explain(90, 70, 45, -5, 0, true);
        Assert.Equal(50, d.Level);
        Assert.Equal("on → 50", d.Steps.FirstOrDefault(x => x.Title == "Lights")?.Value);
    }

    [Fact]
    public void WithoutABlindTheFirstStepIsTheDayLevel() {
        var d = Chart.Explain(90, 70, 45, 30, null, false);
        Assert.Equal(new DecisionStep("Day level", "90"), d.Steps[0]);
        Assert.Equal(new DecisionStep("Now", "90", Final: true), d.Steps[^1]);
    }

    [Fact]
    public void ALinkedMonitorEndsOnTheGroupsLevel() {
        var d = Chart.Explain(80, 60, 30, 30, 40, false, linked: 64, leader: "Studio Display");
        Assert.Equal(64, d.Level);
        Assert.Equal(new DecisionStep("Linked to Studio Display", "→ 64", Final: true), d.Steps[^1]);
    }

    [Fact]
    public void WithAutomaticOffTheLastStepIsATarget() {
        var d = Chart.Explain(90, 70, 45, 30, null, false, applying: false);
        Assert.Equal(new DecisionStep("Target", "90", Final: true), d.Steps[^1]);
    }
}
