// Where automatic mode gets its inputs: the sun computed locally, or Home Assistant.
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Daylit;

/// Inputs of one automatic decision. Levels: per monitor [day, blindDown, night].
sealed record Inputs(double Elev, double Pos, bool Lights, double Bri, double Sat, double[][] Levels, bool? Auto, bool HasBlind) {
    /// Per monitor: the HA "set" helper's value and when it last changed (Unix s), or null without one.
    public (double Value, double Changed)?[] Remote { get; init; } = [];
}

/// Solar elevation from latitude/longitude and the clock (low-precision almanac; matches HA's sun.sun to ~0.01°).
static class Sun {
    static double Rad(double d) => d * Math.PI / 180;
    static double Deg(double r) => r * 180 / Math.PI;
    static double Mod(double a, double m) => ((a % m) + m) % m;

    public static double Elevation(DateTimeOffset t, double lat, double lon) {
        double jd = t.ToUnixTimeMilliseconds() / 86400000.0 + 2440587.5, d = jd - 2451545.0;
        double g = Rad(Mod(357.529 + 0.98560028 * d, 360));
        double q = Mod(280.459 + 0.98564736 * d, 360);
        double L = Rad(q + 1.915 * Math.Sin(g) + 0.020 * Math.Sin(2 * g));
        double e = Rad(23.439 - 0.00000036 * d);
        double ra = Deg(Math.Atan2(Math.Cos(e) * Math.Sin(L), Math.Cos(L)));
        double dec = Math.Asin(Math.Sin(e) * Math.Sin(L));
        double gmst = Mod(18.697374558 + 24.06570982441908 * d, 24);
        double ha = Rad(gmst * 15 + lon - ra);
        return Deg(Math.Asin(Math.Sin(Rad(lat)) * Math.Sin(dec) + Math.Cos(Rad(lat)) * Math.Cos(dec) * Math.Cos(ha)));
    }
}

/// Home Assistant REST: one template call per tick returns everything; sensors are posted back.
static class HAClient {
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(6) };
    public static string? Token;
    public static string? LastError;

    record Answer(double elev, double pos, bool lights, bool? auto, double[][] m, double bri = 0, double sat = 100);

    static string Num(string? entity, double fallback) =>
        string.IsNullOrWhiteSpace(entity) ? fallback.ToString(System.Globalization.CultureInfo.InvariantCulture)
                                          : $"{{{{ states('{entity}') | float({fallback.ToString(System.Globalization.CultureInfo.InvariantCulture)}) }}}}";

    /// -1 marks "use the local number" (no entity, or the entity is unknown).
    static string BuildTemplate(HaConfig h, IReadOnlyList<Mon> mons) {
        string pos = h.Cover is { Length: > 0 } cv ? $"state_attr('{cv}','current_position') | float(100)" : "100";
        string lights = h.Lights is { Length: > 0 } l ? $"is_state('{l}','on') | tojson" : "false | tojson";   // bare false renders as Python False
        string bri = h.Lights is { Length: > 0 } l2 ? $"state_attr('{l2}','brightness') | float(0)" : "0";
        string sat = h.Lights is { Length: > 0 } l3 ? $"(state_attr('{l3}','hs_color') or [0, 100])[1] | float(100)" : "100";
        string auto = h.AutoSwitch is { Length: > 0 } a ? $"{{{{ is_state('{a}','on') | tojson }}}}" : "null";
        string mons_ = string.Join(", ", mons.Select(m => {
            var e = m.Spec?.HomeAssistant;
            string set = e?.Set is { Length: > 0 } st
                ? $"{Num(st, -1)}, {{{{ as_timestamp(states.{st}.last_changed) if states.{st} else 0 }}}}" : "-1, 0";   // states.domain.name: None when missing
            return $"[{Num(e?.Day, -1)}, {Num(e?.BlindDown, -1)}, {Num(e?.Night, -1)}, {set}]";
        }));
        string sun = string.IsNullOrWhiteSpace(h.Sun) ? "sun.sun" : h.Sun!;
        return $$$"""
            {"elev": {{ state_attr('{{{sun}}}','elevation') | float(-10) }},
             "pos": {{ {{{pos}}} }},
             "lights": {{ {{{lights}}} }},
             "auto": {{{auto}}},
             "m": [{{{mons_}}}],
             "bri": {{ {{{bri}}} }},
             "sat": {{ {{{sat}}} }} }
            """;
    }

    public static async Task<string?> Call(Config c, string path, object body) {
        if (c.HomeAssistant?.Url is not { } url) { LastError = "Home Assistant is not configured"; return null; }
        if (Token == null) { LastError = "No Home Assistant token (tray menu → Home Assistant token…)"; return null; }
        try {
            using var req = new HttpRequestMessage(HttpMethod.Post, url.TrimEnd('/') + path) {
                Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") };
            req.Headers.Authorization = new("Bearer", Token);
            using var r = await http.SendAsync(req);
            if ((int)r.StatusCode == 401) { LastError = "Home Assistant rejected the token"; return null; }
            if (!r.IsSuccessStatusCode) { LastError = $"Home Assistant answered {(int)r.StatusCode}"; return null; }
            LastError = null;
            return await r.Content.ReadAsStringAsync();
        } catch { LastError = "Cannot reach Home Assistant"; return null; }
    }

    public static async Task<Inputs?> State(Config c, IReadOnlyList<Mon> mons) {
        var h = c.HomeAssistant!;
        var s = await Call(c, "/api/template", new { template = BuildTemplate(h, mons) });
        if (s == null) return null;
        try {
            var a = JsonSerializer.Deserialize<Answer>(s);
            if (a == null || a.m == null || a.m.Length != mons.Count || a.m.Any(v => v == null || v.Length != 5)) {
                LastError = "Unexpected answer from Home Assistant"; return null;
            }
            // Local numbers wherever HA has no value.
            var levels = mons.Select((m, i) => new[] {
                a.m[i][0] >= 0 ? a.m[i][0] : m.Day, a.m[i][1] >= 0 ? a.m[i][1] : m.BlindDown, a.m[i][2] >= 0 ? a.m[i][2] : m.Night }).ToArray();
            var remote = a.m.Select(v => v[3] >= 0 && v[4] > 0 ? ((double, double)?)(v[3], v[4]) : null).ToArray();
            return new Inputs(a.elev, a.pos, a.lights, a.bri, a.sat, levels, a.auto, !string.IsNullOrWhiteSpace(h.Cover)) { Remote = remote };
        } catch { LastError = "Unexpected answer from Home Assistant"; return null; }
    }

    public static Task<string?> Publish(Config c, Mon m, int applied, int target, bool manual, double sun, Inputs s) =>
        Call(c, "/api/states/" + m.Spec!.HomeAssistant!.Sensor, new {
            state = applied,
            attributes = new Dictionary<string, object> {
                ["friendly_name"] = m.Label + " brightness", ["unit_of_measurement"] = "%", ["icon"] = "mdi:monitor",
                ["target"] = target, ["manual"] = manual, ["daylight"] = Math.Round(sun * 100) / 100,
                ["sun_elevation"] = s.Elev, ["blind"] = s.Pos, ["lights"] = s.Lights, ["source"] = "Windows" } });

    public static Task<string?> SetSwitch(Config c, bool on) =>
        Call(c, "/api/services/input_boolean/" + (on ? "turn_on" : "turn_off"), new { entity_id = c.HomeAssistant!.AutoSwitch });
}

/// The Home Assistant token lives in Windows Credential Manager, never in config.json.
static class Cred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL { public uint Flags, Type; public string TargetName; public string? Comment; public long LastWritten;
        public uint BlobSize; public IntPtr Blob; public uint Persist, AttributeCount; public IntPtr Attributes; public string? TargetAlias, UserName; }
    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWriteW(ref CREDENTIAL c, uint flags);
    [DllImport("advapi32")] static extern void CredFree(IntPtr p);

    public static string? Read(string target) {
        if (!CredReadW(target, 1 /* GENERIC */, 0, out var p)) return null;
        try {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            return c.BlobSize == 0 ? null : Marshal.PtrToStringUni(c.Blob, (int)c.BlobSize / 2).Trim();
        } finally { CredFree(p); }
    }
    public static void Write(string target, string user, string secret) {
        var b = Encoding.Unicode.GetBytes(secret); var h = Marshal.AllocHGlobal(b.Length);
        try {
            Marshal.Copy(b, 0, h, b.Length);
            var c = new CREDENTIAL { Type = 1, TargetName = target, UserName = user, BlobSize = (uint)b.Length, Blob = h, Persist = 2 /* LOCAL_MACHINE */ };
            CredWriteW(ref c, 0);
        } finally { Marshal.FreeHGlobal(h); }
    }
}
