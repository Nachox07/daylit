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
    /// The light sensor's reading (-1: none or not a number) and seconds since it last reported (-1: no sensor).
    public double Light { get; init; } = -1;
    public double LightAge { get; init; } = -1;
    /// Its unit_of_measurement (W, kW, lx…); null when unknown.
    public string? LightUnit { get; init; }
    /// How clear the sky is, 0…1, when the light sensor says.
    public double? LightRatio { get; init; }
    /// Per monitor: Home Assistant's own [day, blindDown, night] (-1 where it has no value), for the Settings
    /// chart; null when these inputs did not come from Home Assistant.
    public double[][]? FromHa { get; init; }
}

/// Home Assistant REST: one template call per tick returns everything; sensors are posted back.
static class HAClient {
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(6) };
    public static string? Token;
    public static string? LastError;
    /// The underlying cause of the last failure (exception or HTTP status), for the log.
    public static string? LastCause;
    /// The last failure was a connection problem that usually clears by itself (see HaErrorRule).
    public static bool Transient;

    record Answer(double elev, double pos, bool lights, bool? auto, double[][] m, double bri = 0, double sat = 100, double light = -1, double lightAge = -1, string? lightUnit = null);

    public static async Task<string?> Call(Config c, string path, object body) {
        if (c.HomeAssistant?.Url is not { } url) { LastError = "Home Assistant is not configured"; Transient = false; return null; }
        if (Token == null) { LastError = "No Home Assistant token (tray menu → Home Assistant token…)"; Transient = false; return null; }
        try {
            using var req = new HttpRequestMessage(HttpMethod.Post, url.TrimEnd('/') + path) {
                Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") };
            req.Headers.Authorization = new("Bearer", Token);
            using var r = await http.SendAsync(req);
            Transient = false;
            if ((int)r.StatusCode == 401) { LastError = "Home Assistant rejected the token"; LastCause = "HTTP 401"; return null; }
            if (!r.IsSuccessStatusCode) { LastError = $"Home Assistant answered {(int)r.StatusCode}"; LastCause = $"HTTP {(int)r.StatusCode}"; return null; }
            LastError = null; LastCause = null;
            return await r.Content.ReadAsStringAsync();
        } catch (Exception e) {
            LastError = "Cannot reach Home Assistant"; Transient = true;
            var inner = e.InnerException ?? e;
            LastCause = $"{inner.GetType().Name}: {inner.Message}";
            return null;
        }
    }

    public static async Task<Inputs?> State(Config c, IReadOnlyList<Mon> mons) {
        var h = c.HomeAssistant!;
        var s = await Call(c, "/api/template", new { template = HaTemplate.Build(h, mons.Select(m => m.Spec?.HomeAssistant)) });
        if (s == null) return null;
        try {
            var a = JsonSerializer.Deserialize<Answer>(s);
            if (a == null || a.m == null || a.m.Length != mons.Count || a.m.Any(v => v == null || v.Length != 5)) {
                LastError = "Unexpected answer from Home Assistant"; Transient = false; return null;
            }
            // Local numbers wherever HA has no value.
            var levels = mons.Select((m, i) => new[] {
                a.m[i][0] >= 0 ? a.m[i][0] : m.Day, a.m[i][1] >= 0 ? a.m[i][1] : m.BlindDown, a.m[i][2] >= 0 ? a.m[i][2] : m.Night }).ToArray();
            var remote = a.m.Select(v => v[3] >= 0 && v[4] > 0 ? ((double, double)?)(v[3], v[4]) : null).ToArray();
            return new Inputs(a.elev, a.pos, a.lights, a.bri, a.sat, levels, a.auto, !string.IsNullOrWhiteSpace(h.Cover)) { Remote = remote, Light = a.light, LightAge = a.lightAge, LightUnit = a.lightUnit, FromHa = a.m.Select(v => v[..3]).ToArray() };
        } catch { LastError = "Unexpected answer from Home Assistant"; Transient = false; return null; }
    }

    static readonly HttpClient slow = new() { Timeout = TimeSpan.FromSeconds(60) };

    /// The last `days` of a sensor's history, as Home Assistant returns it, or the cause of the failure.
    /// Leaves LastError and Transient alone: it runs beside the tick, which reads them.
    public static async Task<(string? Body, string? Cause)> History(Config c, string entity, double days) {
        if (c.HomeAssistant?.Url is not { } url || Token == null) return (null, "not configured");
        static string Iso(DateTimeOffset t) =>
            t.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture).Replace("+", "%2B");   // "+" would read as a space
        var end = DateTimeOffset.UtcNow; var start = end.AddDays(-days);
        string path = $"/api/history/period/{Iso(start)}?end_time={Iso(end)}&filter_entity_id={entity}&minimal_response&no_attributes";
        try {
            using var req = new HttpRequestMessage(HttpMethod.Get, url.TrimEnd('/') + path);
            req.Headers.Authorization = new("Bearer", Token);
            using var r = await slow.SendAsync(req);
            if (!r.IsSuccessStatusCode) return (null, $"HTTP {(int)r.StatusCode}");
            return (await r.Content.ReadAsStringAsync(), null);
        } catch (Exception e) {
            var inner = e.InnerException ?? e;
            return (null, $"{inner.GetType().Name}: {inner.Message}");
        }
    }

    public static Task<string?> Publish(Config c, Mon m, int applied, int target, bool manual, double sun, Inputs s) =>
        !Config.IsEntityId(m.Spec!.HomeAssistant!.Sensor ?? "") ? Task.FromResult<string?>(null) :
        Call(c, "/api/states/" + m.Spec!.HomeAssistant!.Sensor, new {
            state = applied,
            attributes = new Dictionary<string, object?> {
                ["friendly_name"] = m.Label + " brightness", ["unit_of_measurement"] = "%", ["icon"] = "mdi:monitor",
                ["target"] = target, ["manual"] = manual, ["offset"] = m.Offset ?? 0, ["daylight"] = Math.Round(sun * 100) / 100,
                ["light"] = s.LightRatio is double lr ? Math.Round(lr * 100, MidpointRounding.AwayFromZero) / 100 : null,   // how clear the sky is
                ["sun_elevation"] = s.Elev, ["blind"] = s.Pos, ["lights"] = s.Lights, ["source"] = "Windows" } });

    /// input_number/set_value: a level from an accepted suggestion (Suggest.cs). null when it failed (see LastError).
    public static Task<string?> SetNumber(Config c, string entity, double value) =>
        !Config.IsEntityId(entity) ? Task.FromResult<string?>(null) :
        Call(c, "/api/services/input_number/set_value", new { entity_id = entity, value });

    /// An input_number's min, max and step, so a suggestion rounds to a value it accepts; null when Home Assistant
    /// does not answer or the entity has none. Leaves LastError and Transient alone, like History.
    public static async Task<NumberStep?> GetNumberStep(Config c, string entity) {
        if (c.HomeAssistant?.Url is not { } url || Token == null || !Config.IsEntityId(entity)) return null;
        try {
            using var req = new HttpRequestMessage(HttpMethod.Get, url.TrimEnd('/') + "/api/states/" + entity);
            req.Headers.Authorization = new("Bearer", Token);
            using var r = await http.SendAsync(req);
            return r.IsSuccessStatusCode ? NumberStep.Parse(await r.Content.ReadAsStringAsync()) : null;
        } catch { return null; }
    }

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
    /// False when Windows refused to store it (the caller must not treat the token as saved).
    public static bool Write(string target, string user, string secret) {
        var b = Encoding.Unicode.GetBytes(secret); var h = Marshal.AllocHGlobal(b.Length);
        try {
            Marshal.Copy(b, 0, h, b.Length);
            var c = new CREDENTIAL { Type = 1, TargetName = target, UserName = user, BlobSize = (uint)b.Length, Blob = h, Persist = 2 /* LOCAL_MACHINE */ };
            return CredWriteW(ref c, 0);
        } finally { Marshal.FreeHGlobal(h); }
    }
}
