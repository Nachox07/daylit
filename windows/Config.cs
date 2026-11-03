// Settings file: %APPDATA%\Daylit\config.json. Every key is optional; no file = zero config
// (detected monitors, sliders and hotkeys, no automatic mode). See config.example.json.
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Daylit;

enum Source { Off, Sun, HomeAssistant }

sealed class Location {
    public double Latitude { get; set; }
    public double Longitude { get; set; }
}

sealed class HaConfig {
    public string? Url { get; set; }
    public string? TokenName { get; set; }
    public string? AutoSwitch { get; set; }   // input_boolean; without it, automatic mode is a local setting
    public string? Sun { get; set; }
    public string? Cover { get; set; }
    public string? Lights { get; set; }
}

sealed class MonitorHa {
    public string? Sensor { get; set; }       // published only when set
    public string? Day { get; set; }          // input_number entities; override the local numbers
    public string? BlindDown { get; set; }
    public string? Night { get; set; }
    public string? Set { get; set; }          // input_number: changing it in HA sets this monitor now, even when the PC is idle
}

sealed class MonitorConfig {
    public string? Match { get; set; }        // part of the monitor's name, case-insensitive
    public string? Label { get; set; }
    public string? Control { get; set; }      // macOS only; ignored here (HDR → SDR level, else DDC/CI)
    public double? Day { get; set; }
    public double? BlindDown { get; set; }
    public double? Night { get; set; }
    public MonitorHa? HomeAssistant { get; set; }
}

sealed class Config {
    public string? Source { get; set; }
    public Location? Location { get; set; }
    public int? ManualHold { get; set; }
    public bool? PauseOnBattery { get; set; }   // default for the panel switch (true when missing)
    public HaConfig? HomeAssistant { get; set; }
    public MonitorConfig[]? Monitors { get; set; }

    public const double DefaultDay = 70, DefaultBlindDown = 40, DefaultNight = 20;
    public const int IdleSeconds = 300;       // no input for this long = someone else is using the monitors
    public int Hold => ManualHold ?? 5;
    public string TokenName => string.IsNullOrWhiteSpace(HomeAssistant?.TokenName) ? "daylit-home-assistant" : HomeAssistant!.TokenName!;
    public bool HasHa => !string.IsNullOrWhiteSpace(HomeAssistant?.Url);

    /// The source in effect, after defaults and consistency checks.
    [JsonIgnore] public Source Effective { get; private set; } = Daylit.Source.Off;

    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Daylit");
    public static readonly string PathName = Path.Combine(Dir, "config.json");
    /// The path as %APPDATA%\…, for output a user may paste somewhere (no user name).
    public static string DisplayPath => @"%APPDATA%\Daylit\config.json";

    static readonly JsonSerializerOptions Json = new() {
        PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    /// Never fails: a broken file gives the defaults plus an error to show in the panel.
    public static (Config cfg, string? error) Load() => Load(PathName);

    public static (Config cfg, string? error) Load(string path) {
        Config c; string? err;
        try {
            if (!File.Exists(path)) c = new Config();
            else c = JsonSerializer.Deserialize<Config>(File.ReadAllText(path), Json) ?? new Config();
        } catch (Exception e) {
            return (Resolve(new Config(), out _), "config.json is not valid: " + Short(e.Message));
        }
        err = Validate(c);
        if (err != null) {   // keep what is safe: monitors and hold; drop the source settings
            var safe = new Config { ManualHold = c.ManualHold, PauseOnBattery = c.PauseOnBattery, Monitors = c.Monitors?.Where(m => !string.IsNullOrWhiteSpace(m?.Match)).ToArray() };
            return (Resolve(safe, out _), err);
        }
        return (Resolve(c, out err), err);
    }

    static Config Resolve(Config c, out string? err) {
        err = null;
        var s = c.Source?.Trim().ToLowerInvariant();
        c.Effective = s switch {
            "off" => Daylit.Source.Off,
            "sun" => Daylit.Source.Sun,
            "homeassistant" => Daylit.Source.HomeAssistant,
            null or "" => c.HasHa ? Daylit.Source.HomeAssistant : c.Location != null ? Daylit.Source.Sun : Daylit.Source.Off,
            _ => Daylit.Source.Off,
        };
        if (s is not (null or "" or "off" or "sun" or "homeassistant")) err = $"config.json: unknown source \"{c.Source}\" (use off, sun or homeAssistant)";
        else if (c.Effective == Daylit.Source.HomeAssistant && !c.HasHa) {
            err = "config.json: source is homeAssistant but homeAssistant.url is missing";
            c.Effective = c.Location != null ? Daylit.Source.Sun : Daylit.Source.Off;
        } else if (c.Effective == Daylit.Source.Sun && c.Location == null) {
            err = "config.json: source is sun but location is missing";
            c.Effective = Daylit.Source.Off;
        }
        return c;
    }

    static string? Validate(Config c) {
        if (c.HomeAssistant is { } h && !string.IsNullOrWhiteSpace(h.Url) &&
            (!Uri.TryCreate(h.Url, UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https") || string.IsNullOrEmpty(u.Host)))
            return "config.json: homeAssistant.url is not an http(s) URL";
        // Entity ids are pasted into a Jinja template and URL paths, so only the plain domain.object_id form is accepted.
        var ids = new List<(string key, string? id)>();
        if (c.HomeAssistant is { } ha)
            ids.AddRange([("homeAssistant.autoSwitch", ha.AutoSwitch), ("homeAssistant.sun", ha.Sun),
                          ("homeAssistant.cover", ha.Cover), ("homeAssistant.lights", ha.Lights)]);
        foreach (var m in c.Monitors ?? [])
            if (m?.HomeAssistant is { } mh) {
                string at = $"monitor \"{m.Match}\" homeAssistant.";
                ids.AddRange([(at + "sensor", mh.Sensor), (at + "day", mh.Day), (at + "blindDown", mh.BlindDown),
                              (at + "night", mh.Night), (at + "set", mh.Set)]);
            }
        foreach (var (key, id) in ids)
            if (id != null && !IsEntityId(id)) return $"config.json: {key} is not an entity id like light.office";
        if (c.Location is { } l && (l.Latitude is < -90 or > 90 || l.Longitude is < -180 or > 180))
            return "config.json: location latitude/longitude out of range";
        if (c.ManualHold is < 0 or > 100) return "config.json: manualHold must be 0–100";
        if (c.Monitors != null)
            foreach (var m in c.Monitors)
                if (m == null || string.IsNullOrWhiteSpace(m.Match)) return "config.json: every monitor needs a match";
        return null;
    }

    public static bool IsEntityId(string s) {
        var parts = s.Split('.');
        return parts.Length == 2 && parts.All(p => p.Length > 0 && p.All(ch => ch is (>= 'a' and <= 'z') or (>= '0' and <= '9') or '_'));
    }

    /// True when the token would travel unencrypted beyond the local network: http:// to a host that is
    /// not a private IP, a *.local name or a single-label name.
    public static bool IsCleartextToNonLocal(string url) {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || u.Scheme != "http") return false;
        string host = u.Host.ToLowerInvariant().Trim('[', ']');
        if (host == "localhost" || host.EndsWith(".local") || (!host.Contains('.') && !host.Contains(':'))) return false;
        if (System.Net.IPAddress.TryParse(host, out var ip)) {
            if (System.Net.IPAddress.IsLoopback(ip)) return false;
            if (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6)
                return !(ip.IsIPv6LinkLocal || ip.IsIPv6UniqueLocal || ip.IsIPv6SiteLocal);
            var b = ip.GetAddressBytes();
            return !(b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 169 && b[1] == 254));
        }
        return true;
    }

    static string Short(string s) => s.Length > 140 ? s[..140] + "…" : s;

    /// Written by "Open config file" when there is none yet.
    public const string Starter = """
        {
          "source": "off",
          "manualHold": 5,
          "monitors": []
        }
        """;
}

/// What the settings window owns. Everything else in config.json is kept as it is.
sealed record SettingsEdit(string Source, double? Latitude, double? Longitude, IReadOnlyList<SettingsEdit.Monitor> Monitors,
                           string HaUrl = "", string AutoSwitch = "", string Sun = "", string Cover = "", string Lights = "") {
    /// `Name` is the connected display's name; `SuggestedMatch` is used only when no entry matches it yet.
    public sealed record Monitor(string Name, string SuggestedMatch, string Label, int Day, int BlindDown, int Night);
}

static class ConfigPatch {
    static readonly JsonDocumentOptions Read = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    /// True when the file has // or /* */ comments outside strings, which saving does not keep.
    public static bool HasComments(string text) {
        bool inString = false;
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            if (inString) { if (c == '\\') i++; else if (c == '"') inString = false; continue; }
            if (c == '"') inString = true;
            else if (c == '/' && i + 1 < text.Length && text[i + 1] is '/' or '*') return true;
        }
        return false;
    }

    /// A short, stable part of a monitor name: the model ("AW3821DW") rather than the brand.
    public static string SuggestMatch(string name) =>
        name.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault(t => t.Any(char.IsDigit) && t.Any(char.IsLetter)) ?? name;

    /// The file with the edit applied. Unknown keys, unplugged monitors and per-monitor settings the window
    /// does not show (Home Assistant helpers, control) are kept; comments are not. Throws when the result
    /// would not load, or when the file is not a JSON object.
    public static string Apply(SettingsEdit e, string? original) {
        var root = string.IsNullOrWhiteSpace(original) ? new JsonObject()
                 : JsonNode.Parse(original, documentOptions: Read) as JsonObject ?? throw new InvalidDataException("config.json is not a JSON object");
        root["source"] = e.Source;
        if (e.Latitude is double lat && e.Longitude is double lon) {
            var loc = root["location"] as JsonObject ?? new JsonObject();   // keeps any other key in it
            root.Remove("location");
            loc["latitude"] = Round2(lat); loc["longitude"] = Round2(lon);
            root["location"] = loc;
        } else root.Remove("location");

        var ha = root["homeAssistant"] as JsonObject ?? new JsonObject();
        foreach (var (k, v) in new[] { ("url", e.HaUrl), ("autoSwitch", e.AutoSwitch), ("sun", e.Sun), ("cover", e.Cover), ("lights", e.Lights) }) {
            var t = v.Trim();
            if (t == "") ha.Remove(k); else ha[k] = t;
        }
        root.Remove("homeAssistant");
        if (ha.Count > 0) root["homeAssistant"] = ha;

        if (root["monitors"] is { } raw && (raw is not JsonArray arr || arr.Any(x => x is not JsonObject)))
            throw new InvalidDataException("monitors must be a list of objects; fix it with Open config file");
        var list = root["monitors"] as JsonArray ?? new JsonArray();
        root.Remove("monitors");
        var claimed = new HashSet<JsonObject>();   // an entry matching two connected monitors takes the first one's levels only
        foreach (var m in e.Monitors) {
            var entry = list.OfType<JsonObject>().FirstOrDefault(o =>
                o["match"]?.GetValueKind() == JsonValueKind.String && o["match"]!.GetValue<string>().Trim() is { Length: > 0 } match &&
                m.Name.Contains(match, StringComparison.OrdinalIgnoreCase));
            if (entry != null && !claimed.Add(entry)) continue;
            if (entry == null) { entry = new JsonObject { ["match"] = m.SuggestedMatch }; list.Add(entry); claimed.Add(entry); }
            var label = m.Label.Trim();
            if (label == "" || label == m.Name) entry.Remove("label"); else entry["label"] = label;
            entry["day"] = Math.Clamp(m.Day, 0, 100); entry["blindDown"] = Math.Clamp(m.BlindDown, 0, 100); entry["night"] = Math.Clamp(m.Night, 0, 100);
        }
        if (list.Count > 0) root["monitors"] = list;

        var text = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        string tmp = Path.Combine(Path.GetTempPath(), $"daylit-check-{Guid.NewGuid():N}.json");
        try {
            File.WriteAllText(tmp, text);
            var (_, err) = Config.Load(tmp);
            if (err != null) throw new InvalidDataException(err.Replace("config.json: ", ""));
        } finally { File.Delete(tmp); }
        return text;
    }

    /// Two decimals, written exactly as shown in the window.
    static decimal Round2(double v) { var d = Math.Round((decimal)v, 2, MidpointRounding.AwayFromZero); return d == 0 ? 0m : d; }
}
