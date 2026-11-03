// Settings file: %APPDATA%\Daylit\config.json. Every key is optional; no file = zero config
// (detected monitors, sliders and hotkeys, no automatic mode). See config.example.json.
using System.IO;
using System.Text.Json;
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

    static readonly JsonSerializerOptions Json = new() {
        PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    /// Never fails: a broken file gives the defaults plus an error to show in the panel.
    public static (Config cfg, string? error) Load() {
        Config c; string? err;
        try {
            if (!File.Exists(PathName)) c = new Config();
            else c = JsonSerializer.Deserialize<Config>(File.ReadAllText(PathName), Json) ?? new Config();
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
            (!Uri.TryCreate(h.Url, UriKind.Absolute, out var u) || (u.Scheme != "http" && u.Scheme != "https")))
            return "config.json: homeAssistant.url is not an http(s) URL";
        if (c.Location is { } l && (l.Latitude is < -90 or > 90 || l.Longitude is < -180 or > 180))
            return "config.json: location latitude/longitude out of range";
        if (c.ManualHold is < 0 or > 100) return "config.json: manualHold must be 0–100";
        if (c.Monitors != null)
            foreach (var m in c.Monitors)
                if (m == null || string.IsNullOrWhiteSpace(m.Match)) return "config.json: every monitor needs a match";
        return null;
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
