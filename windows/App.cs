// Daylit for Windows — tray app that keeps external monitors at the right brightness through the
// day. Works with no configuration (sliders, hotkeys); automatic mode follows the sun computed
// locally, or Home Assistant (sun, a window blind, room lights). Same behaviour as mac/; see README.md.
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using WF = System.Windows.Forms;

namespace Daylit;

static class Program {
    public static EventWaitHandle? ShowSignal;
    [STAThread]
    static int Main(string[] args) {
        if (Cli.Run(args) is int code) return code;   // --list-monitors, --check-config (see AGENTS.md)
        using var mutex = new Mutex(true, @"Local\Daylit.Tray", out bool first);
        // Starting Daylit again (Start menu, shortcut) opens the running one's panel.
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Daylit.Show");
        if (!first) { show.Set(); return 0; }
        ShowSignal = show;
        WF.Application.EnableVisualStyles();   // tray menu
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
#pragma warning disable WPF0001   // Fluent theme API is marked experimental
        app.ThemeMode = ThemeMode.System;   // Windows 11 Fluent controls, following the system light/dark setting
#pragma warning restore WPF0001
        app.DispatcherUnhandledException += (_, e) => { Log.Write("error: " + e.Exception); e.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write("fatal: " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => { Log.Write("task: " + e.Exception); e.SetObserved(); };
        _ = new Controller(app);
        app.Run();
        return 0;
    }
}

/// Owns the state and the decisions; the windows only show it.
sealed class Controller {
    readonly Application app;
    readonly Dispatcher ui;
    public Config Cfg = new();
    public string? ConfigError;
    public List<Mon> Mons = new();
    public bool AutoOn = true;
    public string Subtitle = "";
    public string? Error;
    public bool HotkeysOk;
    public Source Source => Cfg.Effective;
    public bool PauseOnBattery => Settings.PauseOnBattery ?? Cfg.PauseOnBattery ?? true;
    /// On battery with the pause switch on: no automatic work at all (sliders and hotkeys still work).
    public bool Paused => PauseOnBattery && Win.HasBattery && Win.OnBattery;

    readonly WF.NotifyIcon tray;
    readonly Flyout panel;
    readonly Osd osd = new();
    readonly HotkeyWindow keys;
    readonly DispatcherTimer timer = new(), idleWatch = new() { Interval = TimeSpan.FromSeconds(2) };
    DateTime panelHidden;
    bool busy, again, wasHere = true, wasIdle;
    bool? lookDark, daylight, whiteLights;
    string? lastHaError;
    // When Home Assistant stopped answering. The sun takes over only after a minute, so a slow
    // network at sign-in or after wake does not jump the monitors to the fallback levels.
    DateTime? haDownSince;

    public Controller(Application app) {
        this.app = app;
        ui = app.Dispatcher;
        Load();
        panel = new Flyout(this);
        panel.IsVisibleChanged += (_, _) => { if (!panel.IsVisible) panelHidden = DateTime.UtcNow; };

        var menu = new WF.ContextMenuStrip();
        var token = new WF.ToolStripMenuItem("Home Assistant token…", null, (_, _) => AskToken());
        menu.Items.Add("Open Daylit", null, (_, _) => ShowPanel());
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add("Open config file", null, (_, _) => OpenConfig());
        menu.Items.Add("Reload config", null, (_, _) => Reload());
        menu.Items.Add("Keyboard shortcuts…", null, (_, _) => EditShortcuts());
        menu.Items.Add(token);
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Quit());
        menu.Opening += (_, _) => token.Visible = Source == Source.HomeAssistant;
        tray = new WF.NotifyIcon { Icon = Theme.SunIcon(), Text = "Daylit", Visible = true, ContextMenuStrip = menu };
        tray.MouseClick += (_, e) => { if (e.Button == WF.MouseButtons.Left) TogglePanel(); };

        keys = new HotkeyWindow(Hotkey);
        RegisterShortcuts();

        timer.Tick += (_, _) => _ = Tick("timer");
        idleWatch.Tick += (_, _) => {
            bool idle = Win.IdleSeconds() >= Config.IdleSeconds;
            if (wasIdle && !idle) _ = Tick("back from idle");
            wasIdle = idle;
        };
        SystemEvents.PowerModeChanged += OnPower;
        SystemEvents.DisplaySettingsChanged += OnDisplays;
        SystemEvents.UserPreferenceChanged += OnPrefs;

        StartTimers();
        _ = Tick("start");
        if (Program.ShowSignal is { } sig)
            new Thread(() => { while (sig.WaitOne()) ui.BeginInvoke(ShowPanel); }) { IsBackground = true, Name = "show signal" }.Start();
        if (Source == Source.HomeAssistant && HAClient.Token == null) ui.BeginInvoke(AskToken);
    }

    // MARK: configuration

    void Load() {
        (Cfg, ConfigError) = Config.Load();
        HAClient.Token = Source == Source.HomeAssistant ? Cred.Read(Cfg.TokenName) : null;
        HAClient.LastError = null;
        AutoOn = Settings.Auto;
        lookDark = daylight = whiteLights = null;
        foreach (var m in Mons) { m.Spec = Mon.Match(m.D, Cfg.Monitors); m.LastSet = m.LastTarget = m.Published = null; }
        Log.Write($"config: source {Source}" + (ConfigError != null ? $" — {ConfigError}" : ""));
    }

    public void Reload() {
        Load();
        panel.Rebuild();
        StartTimers();
        _ = Tick("reload");
        if (Source == Source.HomeAssistant && HAClient.Token == null) AskToken();
    }

    public void OpenConfig() {
        try {
            Directory.CreateDirectory(Config.Dir);
            if (!File.Exists(Config.PathName)) File.WriteAllText(Config.PathName, Config.Starter);
            try { Process.Start(new ProcessStartInfo(Config.PathName) { UseShellExecute = true }); }
            catch { Process.Start(new ProcessStartInfo("notepad.exe", $"\"{Config.PathName}\"") { UseShellExecute = true }); }
        } catch (Exception e) { Log.Write("open config: " + e.Message); }
    }

    public void AskToken() {
        if (Source != Source.HomeAssistant) return;
        panel.Hide();
        var t = TokenDialog.Ask(Cfg.TokenName);
        if (t == null) return;
        Cred.Write(Cfg.TokenName, "homeassistant", t);
        HAClient.Token = t;
        _ = Tick("token");
    }

    public void Quit() {
        timer.Stop(); idleWatch.Stop();
        SystemEvents.PowerModeChanged -= OnPower;
        SystemEvents.DisplaySettingsChanged -= OnDisplays;
        SystemEvents.UserPreferenceChanged -= OnPrefs;
        keys.Dispose();
        tray.Visible = false; tray.Dispose();
        app.Shutdown();
    }

    // MARK: timing

    /// 30 s on mains power, 2 min on battery. Nothing periodic when there is no automatic source.
    void StartTimers() {
        if (Source == Source.Off || Paused) { timer.Stop(); idleWatch.Stop(); return; }
        timer.Interval = TimeSpan.FromSeconds(Win.OnBattery ? 120 : 30);
        timer.Start(); idleWatch.Start();
    }

    // SystemEvents may raise on another thread: always hop to the UI thread.
    void OnPower(object? s, PowerModeChangedEventArgs e) => ui.BeginInvoke(() => {
        if (e.Mode == PowerModes.Resume) { ForgetHandSet(); _ = Later(5000, "wake"); }   // DDC needs a moment after wake
        else if (e.Mode == PowerModes.StatusChange) {   // plugged in / unplugged
            bool was = timer.IsEnabled;
            StartTimers();
            if (Paused && was) Log.Write("battery: paused");
            if (!Paused && !was && Source != Source.Off) { Log.Write("power: resumed"); _ = Tick("on power"); }
            else if (panel.IsVisible) panel.Sync();
        }
    });
    void OnDisplays(object? s, EventArgs e) => ui.BeginInvoke(() => _ = Later(1500, "displays changed"));
    void OnPrefs(object? s, UserPreferenceChangedEventArgs e) => ui.BeginInvoke(() => {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle) {
            tray.Icon = Theme.SunIcon();
            panel.ApplyTheme();
        }
    });
    async Task Later(int ms, string why) { await Task.Delay(ms); await Tick(why); }

    void ForgetHandSet() { foreach (var m in Mons) m.LastSet = null; }

    // MARK: panel, keys, sliders

    void TogglePanel() {
        if (panel.IsVisible) { panel.Hide(); return; }
        if ((DateTime.UtcNow - panelHidden).TotalMilliseconds < 300) return;   // this click just closed it
        ShowPanel();
    }
    void ShowPanel() { panel.ShowAtTray(); _ = Tick("panel"); }

    /// Ctrl+Alt+PageUp/PageDown: change the monitor holding the focused window. Shift = steps of 1.
    void Hotkey(bool up, bool fine) {
        var gdi = Win.ForegroundScreen();
        var m = Mons.FirstOrDefault(x => x.On && x.D.Gdi == gdi) ?? Mons.FirstOrDefault(x => x.On);
        if (m == null) { _ = Tick("hotkey"); return; }   // nothing read yet (e.g. DDC was slow at start): read now
        int v = Math.Clamp(m.Cur!.Value + (up ? 1 : -1) * (fine ? 1 : 6), 0, 100);
        UserSet(m, v);
        panel.Sync();
        osd.Flash(m.Label, v, m.D.Gdi);
    }

    void RegisterShortcuts() {
        HotkeysOk = keys.Register(Settings.Up, Settings.Down);
        Log.Write($"hotkeys: {Shortcut.Pair(Settings.Up, Settings.Down)}" + (HotkeysOk ? "" : " are taken by another app"));
    }

    /// The dialog tries each choice live; Cancel (or a failed try) puts the saved keys back.
    public void EditShortcuts() {
        panel.Hide();
        keys.Unregister();   // so pressing the current keys in the dialog records them instead of firing
        ShortcutDialog.Edit(Settings.Up, Settings.Down, (up, down) => {
            if (!keys.Register(up, down)) { keys.Unregister(); return false; }
            Settings.Up = up; Settings.Down = down;
            return true;
        });
        RegisterShortcuts();
    }

    public void UserSet(Mon m, int v) { m.Cur = v; m.UserTouched = DateTime.UtcNow; m.WriteSoon(v); }

    public async void SetAuto(bool on) {
        try {
            AutoOn = on;
            if (Source == Source.HomeAssistant && !string.IsNullOrWhiteSpace(Cfg.HomeAssistant?.AutoSwitch)) await HAClient.SetSwitch(Cfg, on);
            else Settings.Auto = on;
            if (on) ForgetHandSet();
            await Tick("automatic " + (on ? "on" : "off"));
        } catch (Exception e) { Log.Write("set auto: " + e); }
    }

    public void SetPause(bool on) {
        Settings.PauseOnBattery = on;
        Log.Write("pause on battery: " + (on ? "on" : "off"));
        StartTimers();
        _ = Tick("pause on battery");
    }

    public void SetLook(bool on) { Settings.AutoLook = on; lookDark = daylight = whiteLights = null; _ = Tick("look"); }
    public void ToggleDark() { Look.SetDark(!Theme.Dark); tray.Icon = Theme.SunIcon(); panel.ApplyTheme(); }

    // MARK: the decision

    /// Runs on the UI thread; display IO goes to the thread pool. Overlapping requests collapse into one rerun.
    public async Task Tick(string why) {
        if (busy) { again = true; return; }
        busy = true;
        try {
            do { again = false; await TickOnce(); } while (again);
        } catch (Exception e) {
            Log.Write($"tick ({why}): {e}");
        } finally {
            busy = false;
            var on = Mons.Where(m => m.On).Select(m => $"{m.Label} {m.Cur}%");
            var tip = "Daylit · " + (on.Any() ? string.Join(" · ", on) : "no external monitor");
            tray.Text = tip.Length > 127 ? tip[..127] : tip;
            if (panel.IsVisible) panel.Sync();
        }
    }

    void RefreshDisplays(List<Display> found) {
        var ext = found.Where(d => !d.Internal).ToList();
        var next = ext.Select(d => {
            var m = Mons.FirstOrDefault(x => x.Key == d.Key);
            if (m == null) return new Mon(d, Mon.Match(d, Cfg.Monitors));
            if (m.D.Hdr != d.Hdr) {   // HDR toggled: brightness now goes through the other control, on a different scale
                Log.Write($"hdr {(d.Hdr ? "on" : "off")}: {m.Label} now uses {(d.Hdr ? "the SDR white level" : "DDC/CI")}");
                m.LastSet = m.LastTarget = m.Published = null;   // not a hand-set level: apply the target again
            }
            m.D = d; m.Spec = Mon.Match(d, Cfg.Monitors);
            return m;
        }).ToList();
        bool changed = next.Count != Mons.Count || next.Where((m, i) => !ReferenceEquals(m, Mons[i])).Any();
        Mons = next;
        if (changed) {
            Log.Write("monitors: " + (ext.Count == 0 ? "none" : string.Join(", ", ext.Select(d => $"{d.Friendly} [{d.Gdi}{(d.Hdr ? ", HDR" : "")}]"))));
            panel.Rebuild();
        }
    }

    static int Target(double[] v, Inputs s, double sun) {   // v = [day, blindDown, night]
        double daytime = v[1] + (v[0] - v[1]) * s.Pos / 100;
        double x = v[2] + (daytime - v[2]) * sun;
        if (s.Lights && sun < 0.3) x = Math.Max(x, v[2] + 5);
        return (int)Math.Round(Math.Clamp(x, 0, 100), MidpointRounding.AwayFromZero);
    }

    Inputs SunInputs(IReadOnlyList<Mon> mons) {
        var l = Cfg.Location!;
        return new Inputs(Sun.Elevation(DateTimeOffset.UtcNow, l.Latitude, l.Longitude), 100, false, 0, 100,
                          mons.Select(m => new[] { m.Day, m.BlindDown, m.Night }).ToArray(), null, false);
    }

    async Task TickOnce() {
        RefreshDisplays(await Task.Run(Native.ActiveDisplays));
        var mons = Mons.ToArray();
        var cur = await Task.Run(() => mons.Select(m => { try { return m.Read(); } catch { return (int?)null; } }).ToArray());
        for (int i = 0; i < mons.Length; i++) mons[i].Cur = cur[i];
        Error = ConfigError;

        if (Source == Source.Off) { Subtitle = ""; foreach (var m in mons) m.Manual = false; return; }
        // Nothing to drive: no polling until a monitor appears (DisplaySettingsChanged ticks again).
        if (mons.Length == 0) { Subtitle = ""; return; }
        if (Paused) { Subtitle = "Paused on battery"; foreach (var m in mons) m.Manual = false; return; }

        Inputs? s; bool haDown = false;
        if (Source == Source.HomeAssistant) {
            s = await HAClient.State(Cfg, mons);
            if (s == null) {
                haDown = true;
                if (lastHaError != HAClient.LastError) Log.Write("home assistant: " + (HAClient.LastError ?? "unreachable"));
                lastHaError = HAClient.LastError;
                Error ??= HAClient.LastError ?? "Cannot reach Home Assistant";
                haDownSince ??= DateTime.UtcNow;
                if (Cfg.Location != null && (DateTime.UtcNow - haDownSince.Value).TotalSeconds >= 60) s = SunInputs(mons);
            }
        } else s = SunInputs(mons);
        if (!haDown) haDownSince = null;
        if (!haDown && lastHaError != null) { Log.Write("home assistant: ok"); lastHaError = null; }
        if (s == null) { Subtitle = "Waiting for Home Assistant"; return; }

        AutoOn = s.Auto ?? Settings.Auto;
        double sun = Math.Clamp((s.Elev + 3) / 15, 0, 1);
        // The Mac and this PC may share these monitors through input switching. Only the machine in
        // use drives them; coming back applies the current target and publishes again.
        bool here = Win.IdleSeconds() < Config.IdleSeconds;
        if (here != wasHere) Log.Write(here ? "back: applying targets" : "idle: paused");
        if (here && !wasHere) { ForgetHandSet(); foreach (var m in mons) m.Published = null; }
        wasHere = here;
        if (here) UpdateLook(s, haDown || Source == Source.Sun);   // an idle PC leaves the theme alone too

        for (int i = 0; i < mons.Length; i++) {
            var m = mons[i];
            m.Manual = false;
            if (m.Cur is not int c) continue;
            int target = Target(s.Levels[i], s, sun);
            // Set from Home Assistant: acts once per change of the helper, even when this PC is idle
            // (e.g. dimming from the phone while away). Then it is a hand-set level like any other.
            bool remote = false;
            if (s.Remote.ElementAtOrDefault(i) is { } r) {
                if (m.RemoteSeen == null) m.RemoteSeen = r.Changed;   // first look: an old value is not a command
                else if (r.Changed > m.RemoteSeen) {
                    m.RemoteSeen = r.Changed;
                    int v = (int)Math.Round(Math.Clamp(r.Value, 0, 100), MidpointRounding.AwayFromZero);
                    Log.Write($"remote: {m.Label} {c}% → {v}% from Home Assistant");
                    if (c != v) await Task.Run(() => m.Write(v));
                    m.Cur = c = v; remote = true;
                    m.LastTarget = target; m.LastSet = v == target ? null : target;   // held as hand-set until the target moves
                }
            }
            int applied = c;
            if (AutoOn) {
                bool handSet = m.LastSet != null && c != m.LastSet;
                if (remote || (handSet && Math.Abs(target - (m.LastTarget ?? target)) < Cfg.Hold)) m.Manual = true;
                else if (here) {
                    if (c != target) { Log.Write($"auto: {m.Label} {c}% → {target}%"); await Task.Run(() => m.Write(target)); }
                    applied = target; m.Cur = target; m.LastSet = target; m.LastTarget = target;
                }
            }
            if ((here || remote) && !haDown && Source == Source.HomeAssistant && m.Published != applied &&
                !string.IsNullOrWhiteSpace(m.Spec?.HomeAssistant?.Sensor)) {
                if (await HAClient.Publish(Cfg, m, applied, target, m.Manual, sun, s) != null) {   // retried next tick if it failed
                    m.Published = applied;
                    Log.Write($"publish: {m.Spec!.HomeAssistant!.Sensor} = {applied}" + (m.Manual ? " (manual)" : ""));
                }
            }
        }

        string where = s.Elev >= 0 ? $"{s.Elev:0.0}° above the horizon" : $"{-s.Elev:0.0}° below the horizon";
        Subtitle = !AutoOn ? "Off — sliders and hotkeys only"
                 : !here ? "Paused — this PC is idle"
                 : haDown ? "Home Assistant unreachable — using the sun · " + where
                 : Source == Source.Sun ? "Sun · " + where
                 : $"Home Assistant · daylight {(int)Math.Round(sun * 100)}%" + (s.HasBlind ? $" · blind {(int)s.Pos}%" : "") + LightsNote(s);
    }

    /// "lights 80% white" / "lights 40% warm": the colour matters for light/dark mode, so show it.
    static string LightsNote(Inputs s) {
        if (!s.Lights) return "";
        if (s.Bri <= 0) return " · lights on";
        string tone = s.Sat <= 35 ? " white" : s.Sat > 45 ? " warm" : "";
        return $" · lights {(int)Math.Round(s.Bri / 2.55)}%{tone}";
    }

    // Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
    // dark otherwise. Each condition has a gap between its on and off thresholds so it doesn't flip
    // back and forth. Only acts when the decision changes, so a manual switch stays until then.
    void UpdateLook(Inputs s, bool sunOnly) {
        if (!Settings.AutoLook) { lookDark = daylight = whiteLights = null; return; }
        daylight = s.HasBlind
            ? s.Elev > 4 && s.Pos >= 55 ? true : s.Elev < 1 || s.Pos <= 35 ? false : daylight ?? (s.Elev > 3 && s.Pos >= 50)
            : s.Elev > 4 ? true : s.Elev < 1 ? false : daylight ?? s.Elev > 3;
        bool lit = !sunOnly && s.Lights && s.Bri > 0;   // brightness 0-255; hs saturation 0 = white, ~60+ = warm
        whiteLights = lit && s.Bri >= 200 && s.Sat <= 35 ? true : !lit || s.Bri < 170 || s.Sat > 45 ? false : whiteLights ?? false;
        bool dark = !(daylight.Value || whiteLights.Value);
        if (dark != lookDark) {
            Log.Write("theme: " + (dark ? "dark" : "light"));
            Look.SetDark(dark);
            lookDark = dark;
            tray.Icon = Theme.SunIcon();
        }
    }
}
