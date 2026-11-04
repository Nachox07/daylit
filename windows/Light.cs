// An optional light sensor from Home Assistant (solar panel power, or an outdoor lux sensor) tells a
// cloudy day from a clear one. The sun's height alone says "bright day" on an overcast morning too.
// No WPF, WinForms or Win32 here, so windows/tests runs it on any OS. Same rules as mac/ (DaylitCore/Light.swift).
using System.Globalization;
using System.Text.Json;

namespace Daylit;

/// One history reading: the sun's elevation and direction at that moment, and the value.
record struct LightSample(double Elev, bool Morning, double Value);

/// What the sensor reads under a clear sky, learned from its own history: the 90th percentile of the
/// readings in each 2° step of sun elevation, mornings and afternoons apart (panels face one way, so
/// 20° in the morning and 20° in the afternoon read differently). Ten days of history is enough.
sealed class LightReference {
    public const double Step = 2;
    public const int MinSamples = 4;
    public Dictionary<string, double> Bins { get; }

    public LightReference() => Bins = new();

    public LightReference(IEnumerable<LightSample> samples) {
        var groups = new Dictionary<string, List<double>>();
        foreach (var s in samples)
            if (s.Elev > 0 && double.IsFinite(s.Value) && s.Value >= 0) {
                var k = Key(s.Elev, s.Morning);
                if (!groups.TryGetValue(k, out var list)) groups[k] = list = new();
                list.Add(s.Value);
            }
        Bins = groups.Where(g => g.Value.Count >= MinSamples).ToDictionary(g => g.Key, g => {
            var sorted = g.Value.Order().ToList();
            return sorted[Math.Min(sorted.Count - 1, (int)Math.Round((sorted.Count - 1) * 0.9, MidpointRounding.AwayFromZero))];
        }).Where(b => b.Value > 0).ToDictionary(b => b.Key, b => b.Value);   // a step that only ever read 0 (the sensor was off) tells nothing
    }

    static string Key(double elev, bool morning) => (morning ? "am" : "pm") + (int)Math.Floor(elev / Step);
    public double? ClearSky(double elev, bool morning) => Bins.TryGetValue(Key(elev, morning), out var v) ? v : null;
    /// The largest clear-sky reading in the same half of the day.
    public double Largest(bool morning) => Bins.Where(b => b.Key.StartsWith(morning ? "am" : "pm", StringComparison.Ordinal))
                                               .Select(b => b.Value).DefaultIfEmpty(0).Max();
    public bool IsEmpty => Bins.Count == 0;
}

static class LightRules {
    /// How clear the sky is now, 0…1, or null when the reading tells nothing: no reference for this part of
    /// the sky, a reference too small to compare with (the sun barely up on the panels), or a reading of
    /// exactly 0 while there is a reference, which is a fault (inverter off), not a cloud.
    public static double? Ratio(double? value, double elev, bool morning, LightReference r) {
        if (value is not double v || !double.IsFinite(v) || v <= 0 || elev <= 0 || r.ClearSky(elev, morning) is not double clear
            || clear < r.Largest(morning) * 0.05) return null;
        return Math.Min(1, v / clear);
    }

    /// The most daylight can count (0…1) under this sky: 1 when clear (or with no reading), down to `floor`
    /// when fully overcast. Brightness uses the smaller of this and the sun's own daylight fraction, so at
    /// dawn and dusk, when the sun gives less anyway, nothing changes, and the level only ever rises with the sun.
    public static double Cap(double? ratio, double floor) => ratio is double r ? floor + (1 - floor) * Math.Clamp(r, 0, 1) : 1;

    /// Moves the scale in use toward the newest one, so a passing cloud does not jump the monitors:
    /// dimming over about 2 minutes, brightening over about 5. `dt`: seconds since the last step.
    public static double Smooth(double? previous, double next, double dt) {
        if (previous is not double p) return next;
        double tau = next < p ? 120 : 300;
        return p + (next - p) * (1 - Math.Exp(-Math.Max(dt, 0) / tau));
    }

    /// Whether the sun is still climbing at `t` (morning) or going down (afternoon).
    public static bool SunRising(double lat, double lon, DateTimeOffset t) =>
        Sun.Elevation(t.AddSeconds(300), lat, lon) > Sun.Elevation(t, lat, lon);

    /// The readings in a Home Assistant history answer (GET /api/history/period, minimal_response), each
    /// with the sun's elevation and direction at that moment. Readings that are not numbers are skipped.
    public static List<LightSample> Samples(string history, double lat, double lon) {
        var r = new List<LightSample>();
        try {
            using var doc = JsonDocument.Parse(history);
            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0) return r;
            var series = doc.RootElement[0];
            if (series.ValueKind != JsonValueKind.Array) return r;
            foreach (var row in series.EnumerateArray()) {
                if (row.ValueKind != JsonValueKind.Object
                    || !row.TryGetProperty("state", out var st) || st.ValueKind != JsonValueKind.String
                    || !double.TryParse(st.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
                    || !row.TryGetProperty("last_changed", out var ts) || ts.ValueKind != JsonValueKind.String
                    || !DateTimeOffset.TryParse(ts.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d)) continue;
                double e = Sun.Elevation(d, lat, lon);
                if (e <= 0) continue;
                r.Add(new LightSample(e, SunRising(lat, lon, d), v));
            }
        } catch (JsonException) { return new(); }
        return r;
    }
}
