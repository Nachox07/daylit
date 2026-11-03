// Command-line helpers for setting Daylit up (by hand or by an AI agent; see AGENTS.md).
// Daylit is a GUI app, so pipe its output to wait for it:  Daylit.exe --list-monitors | Out-String
//   --list-monitors   connected monitors as JSON, with the "match" text to use in config.json
//   --check-config    validates %APPDATA%\Daylit\config.json against the connected monitors
// Both print JSON on stdout and exit 0 when fine, 1 when something needs fixing.
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Daylit;

static class Cli {
    [DllImport("kernel32")] static extern bool AttachConsole(int pid);

    static readonly JsonSerializerOptions Out = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };   // readable quotes and accents

    /// Null when the arguments are not a CLI command (start the tray app as usual).
    public static int? Run(string[] args) {
        var cmd = args.FirstOrDefault()?.ToLowerInvariant();
        if (cmd is not ("--list-monitors" or "--check-config" or "--help" or "-h" or "/?")) return null;
        AttachConsole(-1);   // so the output shows when run from a terminal without a pipe
        var (json, code) = cmd switch {
            "--list-monitors" => ListMonitors(),
            "--check-config" => CheckConfig(),
            _ => (Help, 0),
        };
        Console.Out.WriteLine(json);
        Console.Out.Flush();
        return code;
    }

    const string Help = """
        Daylit — monitor brightness from the sun or Home Assistant.
          Daylit.exe                  start the tray app
          Daylit.exe --list-monitors  connected monitors as JSON (use "match" in config.json)
          Daylit.exe --check-config   validate %APPDATA%\Daylit\config.json
        Pipe the output to wait for it, e.g.  Daylit.exe --list-monitors | Out-String
        """;

    /// A short, stable part of the monitor name: the model ("AW3821DW") rather than the brand.
    static string SuggestMatch(string friendly) {
        var model = friendly.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault(t => t.Any(char.IsDigit) && t.Any(char.IsLetter));
        return model ?? friendly;
    }

    static (string, int) ListMonitors() {
        var (cfg, _) = Config.Load();
        var list = Native.ActiveDisplays().Select(d => {
            var m = new Mon(d, Mon.Match(d, cfg.Monitors));
            int? level = null;
            if (!d.Internal) try { level = m.Read(); } catch { }
            return new {
                name = d.Friendly,
                match = SuggestMatch(d.Friendly),
                display = d.Gdi,
                builtIn = d.Internal,
                hdr = d.Hdr,
                control = d.Internal ? "none (built-in screens are left to Windows)" : d.Hdr ? "sdr-white-level" : "ddc",
                brightness = level,
                controllable = !d.Internal && level != null,
                configuredAs = m.Spec?.Label ?? m.Spec?.Match,
            };
        }).ToList();
        return (JsonSerializer.Serialize(new { monitors = list }, Out), 0);
    }

    static (string, int) CheckConfig() {
        bool exists = File.Exists(Config.PathName);
        var (cfg, error) = Config.Load();
        var displays = Native.ActiveDisplays().Where(d => !d.Internal).ToList();
        var problems = new List<string>();
        if (error != null) problems.Add(error);
        var monitors = (cfg.Monitors ?? []).Select(m => {
            var hit = displays.FirstOrDefault(d => Mon.Match(d, [m]) != null);
            var ha = m.HomeAssistant;
            if (ha != null && cfg.Effective != Source.HomeAssistant)
                problems.Add($"monitor \"{m.Match}\" has homeAssistant entities but the source is {cfg.Effective}");
            return new { match = m.Match, label = m.Label, connected = hit?.Friendly };
        }).ToList();
        bool tokenStored = cfg.Effective == Source.HomeAssistant && Cred.Read(cfg.TokenName) != null;   // presence only, never printed
        var notes = new List<string>();
        if (!exists) notes.Add("no config.json: Daylit runs with sliders and hotkeys only");
        foreach (var m in monitors.Where(m => m.connected == null)) notes.Add($"monitor \"{m.match}\" is not connected right now (fine if it is used elsewhere)");
        if (cfg.Effective == Source.HomeAssistant && !tokenStored)
            notes.Add($"no Home Assistant token stored yet as \"{cfg.TokenName}\": the app asks for it on start (the user pastes it)");
        if (cfg.Effective == Source.HomeAssistant && cfg.HomeAssistant?.Url is { } haUrl && Config.IsCleartextToNonLocal(haUrl))
            notes.Add("homeAssistant.url is http:// to a host outside the local network: the token travels unencrypted; use https://");
        var result = new {
            ok = problems.Count == 0,
            path = Config.DisplayPath,
            exists,
            source = cfg.Effective.ToString(),
            problems,
            notes,
            monitors,
            homeAssistant = cfg.Effective == Source.HomeAssistant ? new { url = cfg.HomeAssistant?.Url, tokenName = cfg.TokenName, tokenStored } : null,
        };
        return (JsonSerializer.Serialize(result, Out), problems.Count == 0 ? 0 : 1);
    }
}
