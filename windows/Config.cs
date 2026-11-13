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
    public string? Light { get; set; }        // optional outdoor light sensor (solar power W, or lux): a cloudy day dims the monitors
}

sealed class MonitorHa {
    public string? Sensor { get; set; }       // published only when set
    public string? Day { get; set; }          // input_number entities; override the local numbers
    public string? BlindDown { get; set; }
    public string? Night { get; set; }
    public string? NightLights { get; set; }  // optional input_number: the level after sunset with the room lights on
    public string? Set { get; set; }          // input_number: changing it in HA sets this monitor now, even when the PC is idle
}

sealed class MonitorConfig {
    public string? Match { get; set; }        // part of the monitor's name, case-insensitive
    public string? Label { get; set; }
    public string? Control { get; set; }      // macOS only; ignored here (HDR → SDR level, else DDC/CI)
    public double? Day { get; set; }
    public double? BlindDown { get; set; }
    public double? Night { get; set; }
    public double? NightLights { get; set; }  // optional: after sunset with the room lights on (none: night + the lights boost)
    public double? Contrast { get; set; }     // fixed contrast 0–100 over DDC/CI (VCP 0x12), set at start and after a display change
    public MonitorHa? HomeAssistant { get; set; }
}

sealed class Config {
    public string? Source { get; set; }
    public Location? Location { get; set; }
    public bool? PauseOnBattery { get; set; }   // default for the panel switch (true when missing)
    public HaConfig? HomeAssistant { get; set; }
    public MonitorConfig[]? Monitors { get; set; }
    public Tuning? Tuning { get; set; }
    [JsonIgnore] public Tuning Tuned => Tuning ?? new Tuning();

    public const double DefaultDay = 70, DefaultBlindDown = 40, DefaultNight = 20;
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
        if (err != null) {   // keep what is safe: monitors and local settings; drop the source settings
            var safe = new Config { PauseOnBattery = c.PauseOnBattery, Monitors = c.Monitors?.Where(m => !string.IsNullOrWhiteSpace(m?.Match)).ToArray() };
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
                          ("homeAssistant.cover", ha.Cover), ("homeAssistant.lights", ha.Lights), ("homeAssistant.light", ha.Light)]);
        // Its clear-sky reference comes from history, which needs the sun's position at each reading.
        if (c.HomeAssistant?.Light is { Length: > 0 } && c.Location == null) return "config.json: homeAssistant.light needs a location";
        foreach (var m in c.Monitors ?? [])
            if (m?.HomeAssistant is { } mh) {
                string at = $"monitor \"{m.Match}\" homeAssistant.";
                ids.AddRange([(at + "sensor", mh.Sensor), (at + "day", mh.Day), (at + "blindDown", mh.BlindDown),
                              (at + "night", mh.Night), (at + "set", mh.Set), (at + "nightLights", mh.NightLights)]);
            }
        foreach (var m in c.Monitors ?? [])
            foreach (var (key, lv) in new[] { ("day", m?.Day), ("blindDown", m?.BlindDown), ("night", m?.Night) })
                if (lv is double d && !(double.IsFinite(d) && d >= 0 && d <= 100))
                    return $"config.json: monitor \"{m!.Match}\" {key} is 0 to 100";
        foreach (var m in c.Monitors ?? [])
            if (m?.NightLights is double nlv && !(double.IsFinite(nlv) && nlv >= 0 && nlv <= 100))
                return $"config.json: monitor \"{m.Match}\" nightLights is 0 to 100";
        foreach (var (key, id) in ids)
            if (id != null && !IsEntityId(id)) return $"config.json: {key} is not an entity id like light.office";
        if (c.Location is { } l && (l.Latitude is < -90 or > 90 || l.Longitude is < -180 or > 180))
            return "config.json: location latitude/longitude out of range";
        if (c.Tuning?.Validate() is { } bad) return bad;
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
          "monitors": []
        }
        """;
}

/// What the settings window owns. Everything else in config.json is kept as it is.
sealed record SettingsEdit(string Source, double? Latitude, double? Longitude, IReadOnlyList<SettingsEdit.Monitor> Monitors,
                           string HaUrl = "", string AutoSwitch = "", string Sun = "", string Cover = "", string Lights = "",
                           IReadOnlyDictionary<string, double>? Tuning = null, bool? ThemeRoom = null) {
    /// `Name` is the connected display's name; `SuggestedMatch` is used only when no entry matches it yet.
    /// `ContrastEditable`: the window shows a contrast box for it (DDC only); otherwise `contrast` in the file is kept.
    /// `Contrast` null = not set: the key is removed. `NightLightsEditable`: the window shows the Lights on box;
    /// otherwise `nightLights` in the file is kept. `NightLights` null = not set: the key is removed.
    public sealed record Monitor(string Name, string SuggestedMatch, string Label, int Day, int BlindDown, int Night,
                                 int? Contrast = null, bool ContrastEditable = false,
                                 int? NightLights = null, bool NightLightsEditable = false);
    /// homeAssistant.light: the daylight sensor.
    public string Light { get; init; } = "";
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
    /// does not show (Home Assistant helpers, control, contrast and nightLights where they have no box) are kept; comments are not. Throws when the result
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
        foreach (var (k, v) in new[] { ("url", e.HaUrl), ("autoSwitch", e.AutoSwitch), ("sun", e.Sun), ("cover", e.Cover), ("lights", e.Lights), ("light", e.Light) }) {
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
            if (m.ContrastEditable) {
                if (m.Contrast is int ct) entry["contrast"] = Math.Clamp(ct, 0, 100); else entry.Remove("contrast");
            }
            if (m.NightLightsEditable) {
                if (m.NightLights is int lit) entry["nightLights"] = Math.Clamp(lit, 0, 100); else entry.Remove("nightLights");
            }
        }
        if (list.Count > 0) root["monitors"] = list;

        // Tuning: a known key is written only where it differs from its default; unknown keys are kept.
        var tune = root["tuning"] as JsonObject ?? new JsonObject();
        root.Remove("tuning");
        foreach (var f in TuningField.All) {
            var group = tune[f.Group] as JsonObject ?? new JsonObject();
            tune.Remove(f.Group);
            if (e.Tuning != null && e.Tuning.TryGetValue(f.Id, out var v) && v != f.Default)
                group[f.Key] = v == Math.Round(v) ? (JsonNode)(long)v : (JsonNode)(decimal)v;
            else group.Remove(f.Key);
            if (group.Count > 0) tune[f.Group] = group;
        }
        var theme = tune["theme"] as JsonObject ?? new JsonObject();
        tune.Remove("theme");
        if (e.ThemeRoom == false) theme["room"] = false; else theme.Remove("room");
        if (theme.Count > 0) tune["theme"] = theme;
        if (tune.Count > 0) root["tuning"] = tune;

        var text = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        string tmp = Path.Combine(Path.GetTempPath(), $"daylit-check-{Guid.NewGuid():N}.json");
        try {
            File.WriteAllText(tmp, text);
            var (_, err) = Config.Load(tmp);
            if (err != null) throw new InvalidDataException(err.Replace("config.json: ", ""));
        } finally { File.Delete(tmp); }
        return text;
    }

    /// The file with some of one monitor's local levels changed (keys "day", "blindDown", "night"; whole numbers,
    /// clamped to 0–100) and everything else kept, as a suggestion's Apply needs. The entry is found as Apply finds
    /// it (its match is part of `display`, the monitor's name); without one, an entry with `suggestedMatch` is added.
    /// Comments are not kept (check HasComments first). Throws when the file is not a JSON object or the result would not load.
    public static string SetLevels(IReadOnlyDictionary<string, int> levels, string display, string suggestedMatch, string? original) {
        var root = string.IsNullOrWhiteSpace(original) ? new JsonObject()
                 : JsonNode.Parse(original, documentOptions: Read) as JsonObject ?? throw new InvalidDataException("config.json is not a JSON object");
        if (root["monitors"] is { } raw && (raw is not JsonArray arr || arr.Any(x => x is not JsonObject)))
            throw new InvalidDataException("monitors must be a list of objects; fix it with Open config file");
        var list = root["monitors"] as JsonArray ?? new JsonArray();
        root.Remove("monitors");
        var entry = list.OfType<JsonObject>().FirstOrDefault(o =>
            o["match"]?.GetValueKind() == JsonValueKind.String && o["match"]!.GetValue<string>().Trim() is { Length: > 0 } match &&
            display.Contains(match, StringComparison.OrdinalIgnoreCase));
        if (entry == null) { entry = new JsonObject { ["match"] = suggestedMatch }; list.Add(entry); }
        foreach (var (k, v) in levels)
            if (k is "day" or "blindDown" or "night") entry[k] = Math.Clamp(v, 0, 100);
        root["monitors"] = list;
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

/// The numbers behind the rules, from config.json's optional "tuning" block. Every key is optional; a missing
/// one keeps the value Daylit has always used. Same keys and defaults as the Mac (DaylitCore/Tuning.swift).
sealed class Tuning {
    public sealed class BrightnessPart { public double? SunNight { get; set; } public double? SunDay { get; set; }
                                         public double? LightsBoost { get; set; } public double? LightsBoostSunBelow { get; set; }
                                         public double? CloudyDaylight { get; set; } }   // with a light sensor: how much of the daylight part a fully overcast sky keeps (%)
    public sealed class ThemePart { public double? LightSunAbove { get; set; } public double? DarkSunBelow { get; set; }
                                    public double? LightBlindAbove { get; set; } public double? DarkBlindBelow { get; set; }
                                    public double? WhiteLightsAbove { get; set; } public double? WhiteLightsBelow { get; set; }
                                    public double? WhiteSaturationMax { get; set; } public double? WarmSaturationMin { get; set; }
                                    public bool? Room { get; set; } }
    public sealed class TimingPart { public double? PollSeconds { get; set; } public double? BatteryPollSeconds { get; set; }
                                     public double? IdleSeconds { get; set; } public double? HaFallbackSeconds { get; set; }
                                     public double? ManualKeepHours { get; set; } }
    public BrightnessPart? Brightness { get; set; }
    public ThemePart? Theme { get; set; }
    public TimingPart? Timing { get; set; }

    public double SunNight => Brightness?.SunNight ?? -3;
    public double SunDay => Brightness?.SunDay ?? 12;
    public double LightsBoost => Brightness?.LightsBoost ?? 5;
    public double LightsBoostSunBelow => Brightness?.LightsBoostSunBelow ?? 1.5;
    public double CloudyDaylight => Brightness?.CloudyDaylight ?? 35;
    public double LightSunAbove => Theme?.LightSunAbove ?? 4;
    public double DarkSunBelow => Theme?.DarkSunBelow ?? 1;
    public double LightBlindAbove => Theme?.LightBlindAbove ?? 55;
    public double DarkBlindBelow => Theme?.DarkBlindBelow ?? 35;
    public double WhiteLightsAbove => Theme?.WhiteLightsAbove ?? 78.4;
    public double WhiteLightsBelow => Theme?.WhiteLightsBelow ?? 66.6;
    public double WhiteSaturationMax => Theme?.WhiteSaturationMax ?? 35;
    public double WarmSaturationMin => Theme?.WarmSaturationMin ?? 45;
    public bool Room => Theme?.Room ?? true;
    public double PollSeconds => Timing?.PollSeconds ?? 30;
    public double BatteryPollSeconds => Timing?.BatteryPollSeconds ?? 120;
    public double IdleSeconds => Timing?.IdleSeconds ?? 300;
    public double HaFallbackSeconds => Timing?.HaFallbackSeconds ?? 60;
    public double ManualKeepHours => Timing?.ManualKeepHours ?? 12;

    /// Sun elevation → 0 (night) … 1 (full day).
    public double Fraction(double elev) => Math.Clamp((elev - SunNight) / (SunDay - SunNight), 0, 1);

    /// First impossible value, or null.
    public string? Validate() {
        static string F(double v) => v.ToString(System.Globalization.CultureInfo.InvariantCulture);
        string? Range(double v, double lo, double hi, string key) => v >= lo && v <= hi ? null : $"config.json: tuning.{key} must be {F(lo)}–{F(hi)}";
        string?[] checks = [
            Range(SunNight, -18, 30, "brightness.sunNight"), Range(SunDay, -18, 60, "brightness.sunDay"),
            SunDay > SunNight ? null : "config.json: tuning.brightness.sunDay must be above sunNight",
            Range(LightsBoost, 0, 100, "brightness.lightsBoost"), Range(LightsBoostSunBelow, -18, 60, "brightness.lightsBoostSunBelow"),
            Range(CloudyDaylight, 0, 100, "brightness.cloudyDaylight"),
            Range(LightSunAbove, -18, 60, "theme.lightSunAbove"), Range(DarkSunBelow, -18, 60, "theme.darkSunBelow"),
            LightSunAbove >= DarkSunBelow ? null : "config.json: tuning.theme.lightSunAbove must not be below darkSunBelow",
            Range(LightBlindAbove, 0, 100, "theme.lightBlindAbove"), Range(DarkBlindBelow, 0, 100, "theme.darkBlindBelow"),
            LightBlindAbove >= DarkBlindBelow ? null : "config.json: tuning.theme.lightBlindAbove must not be below darkBlindBelow",
            Range(WhiteLightsAbove, 0, 100, "theme.whiteLightsAbove"), Range(WhiteLightsBelow, 0, 100, "theme.whiteLightsBelow"),
            WhiteLightsAbove >= WhiteLightsBelow ? null : "config.json: tuning.theme.whiteLightsAbove must not be below whiteLightsBelow",
            Range(WhiteSaturationMax, 0, 100, "theme.whiteSaturationMax"), Range(WarmSaturationMin, 0, 100, "theme.warmSaturationMin"),
            WarmSaturationMin >= WhiteSaturationMax ? null : "config.json: tuning.theme.warmSaturationMin must not be below whiteSaturationMax",
            Range(PollSeconds, 5, 3600, "timing.pollSeconds"), Range(BatteryPollSeconds, 5, 3600, "timing.batteryPollSeconds"),
            Range(IdleSeconds, 30, 86400, "timing.idleSeconds"), Range(HaFallbackSeconds, 0, 3600, "timing.haFallbackSeconds"),
            Range(ManualKeepHours, 0, 168, "timing.manualKeepHours"),
        ];
        return checks.FirstOrDefault(c => c != null);
    }
}

/// One number the settings window shows: where it lives in "tuning", its label, unit and default (same list as the Mac).
sealed record TuningField(string Group, string Key, string Label, string Unit, double Default) {
    public string Id => Group + "." + Key;
    public static readonly TuningField[] Appearance = [
        new("theme", "lightSunAbove", "Light once the sun is above", "°", 4),
        new("theme", "darkSunBelow", "Dark again below", "°", 1),
        new("theme", "lightBlindAbove", "Light needs the blind open at least", "%", 55),
        new("theme", "darkBlindBelow", "Dark at or below", "%", 35),
        new("theme", "whiteLightsAbove", "White lights count as daylight from", "%", 78.4),
        new("theme", "whiteLightsBelow", "…and stop counting below", "%", 66.6),
        new("theme", "whiteSaturationMax", "White: colour saturation up to", "", 35),
        new("theme", "warmSaturationMin", "Warm: colour saturation above", "", 45),
    ];
    public static readonly TuningField[] Tuning = [
        new("brightness", "sunNight", "Night level at or below", "°", -3),
        new("brightness", "sunDay", "Full day level from", "°", 12),
        new("brightness", "lightsBoost", "Room lights at dusk add", "points", 5),
        new("brightness", "lightsBoostSunBelow", "…while the sun is below", "°", 1.5),
        new("brightness", "cloudyDaylight", "Under a fully overcast sky, daylight counts at most", "%", 35),
        new("timing", "pollSeconds", "Check every", "s", 30),
        new("timing", "batteryPollSeconds", "Check on battery every", "s", 120),
        new("timing", "idleSeconds", "Idle (another computer may be in use) after", "s", 300),
        new("timing", "haFallbackSeconds", "Sun takes over when Home Assistant is down for", "s", 60),
        new("timing", "manualKeepHours", "Keep hand-set levels after a restart for", "h", 12),
    ];
    public static IEnumerable<TuningField> All => Appearance.Concat(Tuning);

    /// The values set in a config's tuning block, keyed "group.key".
    public static Dictionary<string, double> SetValues(Tuning? t) {
        var d = new Dictionary<string, double>();
        void Add(string k, double? v) { if (v is double x) d[k] = x; }
        Add("brightness.sunNight", t?.Brightness?.SunNight); Add("brightness.sunDay", t?.Brightness?.SunDay);
        Add("brightness.lightsBoost", t?.Brightness?.LightsBoost); Add("brightness.lightsBoostSunBelow", t?.Brightness?.LightsBoostSunBelow);
        Add("brightness.cloudyDaylight", t?.Brightness?.CloudyDaylight);
        Add("theme.lightSunAbove", t?.Theme?.LightSunAbove); Add("theme.darkSunBelow", t?.Theme?.DarkSunBelow);
        Add("theme.lightBlindAbove", t?.Theme?.LightBlindAbove); Add("theme.darkBlindBelow", t?.Theme?.DarkBlindBelow);
        Add("theme.whiteLightsAbove", t?.Theme?.WhiteLightsAbove); Add("theme.whiteLightsBelow", t?.Theme?.WhiteLightsBelow);
        Add("theme.whiteSaturationMax", t?.Theme?.WhiteSaturationMax); Add("theme.warmSaturationMin", t?.Theme?.WarmSaturationMin);
        Add("timing.pollSeconds", t?.Timing?.PollSeconds); Add("timing.batteryPollSeconds", t?.Timing?.BatteryPollSeconds);
        Add("timing.idleSeconds", t?.Timing?.IdleSeconds); Add("timing.haFallbackSeconds", t?.Timing?.HaFallbackSeconds);
        Add("timing.manualKeepHours", t?.Timing?.ManualKeepHours);
        return d;
    }
}
