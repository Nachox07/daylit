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
    [System.Runtime.InteropServices.DllImport("user32")] static extern bool AllowSetForegroundWindow(int pid);
    [STAThread]
    static int Main(string[] args) {
        if (Cli.Run(args) is int code) return code;   // --list-monitors, --check-config (see AGENTS.md)
        using var mutex = new Mutex(true, @"Local\Daylit.Tray", out bool first);
        // Starting Daylit again (Start menu, shortcut) opens the running one's panel.
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Daylit.Show");
        if (!first) { AllowSetForegroundWindow(-1 /* ASFW_ANY */); show.Set(); return 0; }   // let the running copy take focus, so its panel closes on an outside click
        ShowSignal = show;
        WF.Application.EnableVisualStyles();   // tray menu
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
#pragma warning disable WPF0001   // Fluent theme API is marked experimental
        app.ThemeMode = ThemeMode.System;   // Windows 11 Fluent controls, following the system light/dark setting
#pragma warning restore WPF0001
        app.DispatcherUnhandledException += (_, e) => { Log.Write("error: " + e.Exception); e.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write("fatal: " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => { Log.Write("task: " + e.Exception); e.SetObserved(); };
        var v = typeof(Controller).Assembly.GetName().Version?.ToString(3);
        Log.Write($"start: Daylit {(v is null or "0.0.0" ? "dev" : v)}");
        _ = new Controller(app);
        app.Run();
        return 0;
    }
}

/// Owns the state and the decisions; the windows only show it.
sealed partial class Controller {
    readonly Application app;
    readonly Dispatcher ui;
    public Config Cfg = new();
    public string? ConfigError;
    public List<Mon> Mons = new();
    public bool AutoOn = true;
    public string Subtitle = "";
    public string? Error;
    /// The daylight sensor's state, for the Settings window (null without a sensor).
    public string? LightStatus { get => lightStatus; private set { if (lightStatus == value) return; lightStatus = value; LightStatusChanged?.Invoke(); } }
    string? lightStatus;
    public event Action? LightStatusChanged;
    /// The last tick's blind, lights, clouds and hand-set distances, for the Settings chart (null before the first one).
    public LiveInputs? Live { get; private set; }
    public event Action? LiveChanged;
    void ClearLive() { if (Live == null) return; Live = null; LiveChanged?.Invoke(); }
    public bool HotkeysOk;
    public bool ThemeKeyOk;
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
    bool? lookDark;
    readonly LookRule look = new();   // light/dark decision with hysteresis (Rules.cs)
    string? lastHaError;
    string? missingNoteShown;       // the missing-entity note last shown, and when it was logged (once, then every 10 minutes)
    DateTime? missingNoteLoggedAt;
    // When Home Assistant stopped answering. The sun takes over only after a minute, so a slow
    // network at sign-in or after wake does not jump the monitors to the fallback levels.
    DateTime? haDownSince;
    DateTime? haLoggedAt;   // when the current outage was last written to the log (HaErrorRule.ShouldLog)

    /// Fixed state and nothing else: no tray, hotkeys, timers, monitors or network (UI snapshots).
    public Controller(Config cfg, List<Mon> mons, string subtitle) {
        app = Application.Current; ui = app.Dispatcher;
        Cfg = cfg; Mons = mons; AutoOn = true; Subtitle = subtitle; HotkeysOk = true;
        tray = null!; panel = null!; keys = null!;
        if (Settings.SyncMonitors) syncOffsets = SyncOffsets.Capture(mons.Select(x => (x.Key, LevelOf(x))));
    }

    /// Snapshots: a partial group, with this monitor taken out.
    public void SnapshotLeave(Mon m) => syncOffsets.Leave(m.Key);

    public Controller(Application app) {
        this.app = app;
        ui = app.Dispatcher;
        Load();
        LoadCorrections();
        panel = new Flyout(this);
        panel.IsVisibleChanged += (_, _) => { if (!panel.IsVisible) panelHidden = DateTime.UtcNow; };

        var menu = new WF.ContextMenuStrip();
        var token = new WF.ToolStripMenuItem("Home Assistant token…", null, (_, _) => AskToken());
        menu.Items.Add("Open Daylit", null, (_, _) => ShowPanel());
        menu.Items.Add("Settings…", null, (_, _) => ShowSettings());
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

        keys = new HotkeyWindow(Hotkey, ToggleDark);
        RegisterShortcuts();

        timer.Tick += (_, _) => _ = Tick("timer");
        idleWatch.Tick += (_, _) => {
            bool idle = Win.IdleSeconds() >= Cfg.Tuned.IdleSeconds;
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
        var previousLights = Cfg.HomeAssistant?.Lights;
        (Cfg, ConfigError) = Config.Load();
        // A removed or changed lights entity must not keep its last state alive through an outage.
        if (Cfg.HomeAssistant?.Lights != previousLights) lastHaLights = null;
        HAClient.Token = Source == Source.HomeAssistant ? Cred.Read(Cfg.TokenName) : null;
        HAClient.LastError = null;
        AutoOn = Settings.Auto;
        lookDark = null; look.Reset();
        // A suggestion worked out under the old config must not be applied under the new one.
        suggestDirty = true; stepCache.Clear(); notNumber.Clear(); suggestEpoch++; Suggestion = null; SuggestError = null;
        foreach (var m in Mons) { m.Spec = Mon.Match(m.D, Cfg.Monitors); m.LastSet = m.LastTarget = m.Published = null; m.ContrastSet = null; }
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

    public void ShowSettings() { panel.Hide(); SettingsWindow.Open(this); }

    public void AskToken() {
        if (Source != Source.HomeAssistant) return;
        panel.Hide();
        var t = TokenDialog.Ask(Cfg.TokenName);
        if (t == null) return;
        if (!Cred.Write(Cfg.TokenName, "homeassistant", t)) {
            Log.Write("token: Credential Manager refused to store it");
            System.Windows.MessageBox.Show("Windows could not save the token in Credential Manager, so Daylit can't use it. Try again from the tray menu.",
                "Daylit", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
            return;
        }
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
        timer.Interval = TimeSpan.FromSeconds(Win.OnBattery ? Cfg.Tuned.BatteryPollSeconds : Cfg.Tuned.PollSeconds);
        timer.Start(); idleWatch.Start();
    }

    // SystemEvents may raise on another thread: always hop to the UI thread.
    void OnPower(object? s, PowerModeChangedEventArgs e) => ui.BeginInvoke(() => {
        if (e.Mode == PowerModes.Resume) { ForgetHandSet(); _ = Later(5000, "wake", ForgetContrast); }   // DDC needs a moment after wake
        else if (e.Mode == PowerModes.StatusChange) {   // plugged in / unplugged
            bool was = timer.IsEnabled;
            StartTimers();
            if (Paused && was) Log.Write("battery: paused");
            if (!Paused && !was && Source != Source.Off) { Log.Write("power: resumed"); _ = Tick("on power"); }
            else if (panel.IsVisible) panel.Sync();
        }
    });
    void OnDisplays(object? s, EventArgs e) => ui.BeginInvoke(() => _ = Later(1500, "displays changed", ForgetContrast));
    /// The configured contrast is written again on the next tick. Called when the delayed tick after a
    /// display change or wake runs, so a tick in between can't use up the write before DDC is ready.
    void ForgetContrast() { foreach (var m in Mons) m.ContrastSet = null; }
    void OnPrefs(object? s, UserPreferenceChangedEventArgs e) => ui.BeginInvoke(() => {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle) {
            tray.Icon = Theme.SunIcon();
            panel.ApplyTheme();
        }
    });
    async Task Later(int ms, string why, Action? first = null) { await Task.Delay(ms); first?.Invoke(); await Tick(why); }

    // After wake or idle the monitor may have been changed elsewhere: its reading is not a hand-set level.
    // A distance set by hand here is kept.
    void ForgetHandSet() { foreach (var m in Mons) m.LastSet = null; }

    /// Back to the automatic level now (the "manual" note in the panel).
    public void Resume(Mon m) {
        m.LastSet = null; m.Offset = null; m.OffsetSun = null; m.OffsetAt = null; m.Manual = false;
        recorder.Drop(m.Key);   // a change waiting to become a suggestion sample ends here too
        Log.Write($"resume: {m.Label} back to automatic");
        _ = Tick("resume");
    }

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
        var m = Mons.FirstOrDefault(x => x.Usable && x.D.Gdi == gdi) ?? Mons.FirstOrDefault(x => x.On);
        if (m == null) { _ = Tick("hotkey"); return; }   // nothing read yet (e.g. DDC was slow at start): read now
        int v = Math.Clamp((m.Cur ?? 50) + (up ? 1 : -1) * (fine ? 1 : 6), 0, 100);   // 50: a monitor that doesn't report its level
        UserSet(m, v);
        panel.Sync();
        osd.Flash(m.Label, v, m.D.Gdi);
    }

    void RegisterShortcuts() {
        // Registered apart, so a taken light/dark combination never stops the brightness ones.
        HotkeysOk = keys.Register(Settings.Up, Settings.Down);
        ThemeKeyOk = keys.RegisterTheme(Settings.ThemeKey);
        Log.Write($"hotkeys: {Shortcut.Pair(Settings.Up, Settings.Down)}" + (HotkeysOk ? "" : " are taken by another app"));
        if (!ThemeKeyOk) Log.Write($"hotkeys: {Settings.ThemeKey} (light/dark) is taken by another app");
    }

    /// The dialog tries each choice live; Cancel (or a failed try) puts the saved keys back.
    public void EditShortcuts() {
        panel.Hide();
        keys.Unregister();   // so pressing the current keys in the dialog records them instead of firing
        ShortcutDialog.Edit(Settings.Up, Settings.Down, Settings.ThemeKey, (up, down, theme) => {
            bool brightnessOk = keys.Register(up, down);
            bool themeOk = keys.RegisterTheme(theme);
            if (!brightnessOk || !themeOk) {
                keys.Unregister();
                return !brightnessOk && !themeOk ? "brightness and light/dark" : !brightnessOk ? "brightness" : "light/dark";
            }
            Settings.Up = up; Settings.Down = down; Settings.ThemeKey = theme;
            return null;
        });
        RegisterShortcuts();
    }

    public void UserSet(Mon m, int v) {
        m.Cur = v; m.UserTouched = DateTime.UtcNow; m.Touched = true; m.WriteSoon(v);
        if (!Settings.SyncMonitors || Mons.Count < 2) return;
        // Sync: the other monitors follow with the offsets captured when sync was switched on.
        AdoptSync();
        var follow = syncOffsets.Follow(m.Key, v, Mons.Select(x => x.Key));
        foreach (var o in Mons)
            if (o != m && o.Usable && follow.TryGetValue(o.Key, out var lv) && o.Cur != lv) { o.Cur = lv; o.Touched = true; o.WriteSoon(lv); }
        panel.Sync();
    }

    SyncOffsets syncOffsets = Settings.SyncOffsets;
    /// Hand-set state kept across restarts, so a restart doesn't jump the monitors to the automatic target.
    readonly SavedHolds holds = Settings.Holds;
    static double Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
    static int LevelOf(Mon m) => m.Cur ?? 50;
    void AdoptSync() {
        if (syncOffsets.Adopt(Mons.Where(x => x.Usable).Select(x => (x.Key, LevelOf(x))).ToList())) Settings.SyncOffsets = syncOffsets;
    }

    public bool IsLinked(Mon m) => Settings.SyncMonitors && Mons.Count > 1 && syncOffsets.IsMember(m.Key);
    /// Linked, and every usable monitor is in the group (false while some were taken out).
    public bool SyncAll => Settings.SyncMonitors && syncOffsets.Members(Mons.Select(x => x.Key)) >= Mons.Count(x => x.Usable);

    /// With three or more monitors: takes one out of the group or puts it back. A group of one is off.
    public void ToggleMember(Mon m) {
        if (!Settings.SyncMonitors) return;
        if (syncOffsets.IsMember(m.Key)) {
            syncOffsets.Leave(m.Key);
            Log.Write($"sync: {m.Label} left the group");
            if (syncOffsets.Members(Mons.Select(x => x.Key)) < 2) { SetSync(false); return; }
        } else {
            syncOffsets.Join(m.Key, Mons.Where(x => x.Usable).Select(x => (x.Key, LevelOf(x))).ToList());
            Log.Write($"sync: {m.Label} joined at {syncOffsets.Offsets.GetValueOrDefault(m.Key)}");
        }
        Settings.SyncOffsets = syncOffsets;
        panel.Sync();
    }

    public void SetSync(bool on) {
        Settings.SyncMonitors = on;
        if (on) {
            // Capture the offsets as they are now: each monitor keeps how much brighter or darker it is.
            syncOffsets = SyncOffsets.Capture(Mons.Where(x => x.Usable).Select(x => (x.Key, LevelOf(x))));
            Settings.SyncOffsets = syncOffsets;
            Log.Write("sync: on " + string.Join(", ", Mons.Select(x => $"{x.Label} {(syncOffsets.Offsets.TryGetValue(x.Key, out var o) ? (o >= 0 ? "+" : "") + o : "-")}")));
        } else Log.Write("sync: off");
        _ = Tick("sync");
    }

    public async void SetAuto(bool on) {
        try {
            AutoOn = on;
            if (Source == Source.HomeAssistant && !string.IsNullOrWhiteSpace(Cfg.HomeAssistant?.AutoSwitch)) await HAClient.SetSwitch(Cfg, on);   // LastHaAuto is saved when Home Assistant's own answer confirms it
            else Settings.Auto = on;
            if (on) foreach (var m in Mons) { m.LastSet = null; m.Offset = null; m.OffsetSun = null; m.OffsetAt = null; recorder.Drop(m.Key); }
            await Tick("automatic " + (on ? "on" : "off"));
        } catch (Exception e) { Log.Write("set auto: " + e); }
    }

    public void SetPause(bool on) {
        Settings.PauseOnBattery = on;
        Log.Write("pause on battery: " + (on ? "on" : "off"));
        StartTimers();
        _ = Tick("pause on battery");
    }

    public void SetLook(bool on) { Settings.AutoLook = on; lookDark = null; look.Reset(); _ = Tick("look"); }
    public void ToggleDark() {
        try { Look.SetDark(!Theme.Dark); } catch (Exception e) { Log.Write("theme: " + e.Message); return; }
        tray.Icon = Theme.SunIcon(); panel.ApplyTheme();
    }

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
            if (m == null) {
                var fresh = new Mon(d, Mon.Match(d, Cfg.Monitors));
                if (holds.Restore(d.Key, Now, Cfg.Tuned.ManualKeepHours * 3600) is Hold h) { fresh.LastSet = h.LastSet; fresh.LastTarget = h.LastTarget; fresh.Offset = h.Offset; fresh.OffsetSun = h.OffsetSun; fresh.OffsetAt = h.OffsetAt; }
                return fresh;
            }
            if (m.D.Hdr != d.Hdr) {   // HDR toggled: brightness now goes through the other control, on a different scale
                Log.Write($"hdr {(d.Hdr ? "on" : "off")}: {m.Label} now uses {(d.Hdr ? "the SDR white level" : "DDC/CI")}");
                m.LastSet = m.LastTarget = m.Published = null;   // not a hand-set level: apply the target again
                m.Offset = null; m.OffsetSun = null; m.OffsetAt = null;   // and an offset on the old scale means nothing on the new one
                m.ContrastSet = null;   // back on DDC: write the configured contrast again
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

    /// With Home Assistant down, the sun drives the target but the levels and the blind stay the last ones
    /// Home Assistant gave: a network blip must not swap them for the defaults and move the screens.
    Inputs SunInputs(IReadOnlyList<Mon> mons) {
        var l = Cfg.Location!;
        bool keep = Source == Source.HomeAssistant;   // a sun-only config uses its own levels
        return new Inputs(Sun.Elevation(DateTimeOffset.UtcNow, l.Latitude, l.Longitude), keep ? lastHaPos ?? 100 : 100, false, 0, 100,
                          mons.Select(m => Chart.EffectiveLevels(m.LocalLevels, keep ? m.HaLevels : null)).ToArray(),
                          keep ? Rules.AutomaticFallback(!string.IsNullOrWhiteSpace(Cfg.HomeAssistant?.AutoSwitch), Settings.LastHaAuto(Cfg.HomeAssistant?.AutoSwitch), Settings.Auto) : null,   // an outage keeps the last Automatic state
                          keep && lastHaPos != null);
    }
    double? lastHaPos;
    bool? lastHaLights;   // the room lights Home Assistant last gave: a monitor with nightLights keeps them while it is down

    // MARK: light sensor

    /// The light sensor's clear-sky reference, rebuilt from its Home Assistant history once a day.
    LightReference lightRef = new();
    DateTime? lightRefAt;
    bool lightRefBusy;
    /// Which sensor, unit and place the reference belongs to: a new one starts learning again.
    string lightRefFor = "";
    /// The sensor's unit and since when its history is in it, kept across restarts.
    LightUnit? lightUnit = Settings.LightUnit;
    /// The scale in use, smoothed, and when it last moved.
    double? lightNow;
    /// The cap in use now (1 without a sensor), for the Settings window's "right now" preview.
    public double LightNow => lightNow ?? 1;
    DateTime? lightAt;

    /// Runs beside the tick (the history call can take seconds); its state changes land on the UI thread.
    async Task RefreshLightReference(string entity, Location loc) {
        if (lightRefBusy) return;
        var unit = lightUnit is { } lu && lu.Sensor == entity ? lu : new LightUnit(entity, "", 0);
        string key = $"{entity} {unit.Unit} {loc.Latitude.ToString(System.Globalization.CultureInfo.InvariantCulture)} {loc.Longitude.ToString(System.Globalization.CultureInfo.InvariantCulture)}";
        if (key != lightRefFor) { lightRef = new(); lightRefAt = null; lightRefFor = key; }
        // Hourly while there is no reference, or only hours of it since a unit change; then daily.
        bool young = unit.HistoryDays(10, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) < 1;
        if (lightRefAt is DateTime at && !LightHistoryRule.Due((DateTime.UtcNow - at).TotalSeconds, !lightRef.IsEmpty, young)) return;
        lightRefBusy = true;
        try {
            lightRefAt = DateTime.UtcNow;
            var (body, cause) = await HAClient.History(Cfg, entity, unit.HistoryDays(10, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0));
            if (body != null) {
                var samples = await Task.Run(() => LightRules.Samples(body, loc.Latitude, loc.Longitude, unit.Since));
                if (key != lightRefFor) return;   // the config changed meanwhile
                var fresh = new LightReference(samples);
                Log.Write($"light: clear-sky reference from {samples.Count} readings, {fresh.Bins.Count} steps of the sky" +
                          (fresh.IsEmpty ? " (not enough history, trying again in an hour)" : ""));
                if (!fresh.IsEmpty) lightRef = fresh;
                else if (lightRef.IsEmpty) LightStatus = "Not enough history in Home Assistant yet: trying again in an hour.";
                else RetryLightSoon(young);   // an odd answer does not replace a good reference
            } else {
                Log.Write($"light: could not read its history ({cause ?? "no answer"}), trying again in an hour");
                if (lightRef.IsEmpty) LightStatus = "Could not read the sensor's history from Home Assistant: trying again in an hour.";
                RetryLightSoon(young);
            }
        } catch (Exception e) { Log.Write("light: " + e.Message); RetryLightSoon(young); }
        finally { lightRefBusy = false; }
    }

    /// Keeps the sensor's unit; a change (W to kW) makes the reference learn again from now.
    void NoteLightUnit(string e, string? unit) {
        var next = LightUnit.Update(lightUnit, e, unit, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
        if (next == lightUnit) return;
        if (lightUnit is { } was && was.Sensor == e && was.Unit != "" && next.Unit != was.Unit)
            Log.Write($"light: {e} now reports in {next.Unit} (was {was.Unit}), learning its clear sky again from now");
        lightUnit = next;
        Settings.LightUnit = next;
    }

    /// Try the history again in an hour, keeping the reference in use until then.
    void RetryLightSoon(bool young) =>
        lightRefAt = DateTime.UtcNow.AddSeconds(LightHistoryRule.RetryStamp(0, !lightRef.IsEmpty, young));

    /// One step of the light scale toward `goal`, smoothed so a passing cloud does not jump the monitors.
    double StepLight(double goal) {
        var now = DateTime.UtcNow;
        lightNow = LightRules.Smooth(lightNow, goal, lightAt is DateTime at ? (now - at).TotalSeconds : 0);
        lightAt = now;
        return lightNow.Value;
    }

    /// The light scale for this tick (1: clear sky or no sensor). `fromHa`: `s` is a fresh Home Assistant answer.
    Inputs ApplyLight(Inputs s, bool fromHa, out double light) {
        light = 1;
        if (!fromHa) {   // no reading: back to the sun's rule, gently
            if (lightNow != null) {
                light = StepLight(1);
                if (Cfg.HomeAssistant?.Light != null) LightStatus = "Home Assistant is not answering: going back to the sun's height alone.";
            }
            return s;
        }
        if (Cfg.HomeAssistant?.Light is not { } e || !Config.IsEntityId(e) || Cfg.Location is not { } loc) {
            LightStatus = null;
            if (lightNow != null) light = StepLight(1);
            return s;
        }
        NoteLightUnit(e, s.LightUnit);
        _ = RefreshLightReference(e, loc);
        // A sensor that has not reported for 15 minutes is stuck, not dark.
        double? reading = s.Light >= 0 && s.LightAge < 900 ? s.Light : null;
        // The sun here, as the reference was learned (Home Assistant's sun may be set elsewhere).
        double here = Sun.Elevation(DateTimeOffset.UtcNow, loc.Latitude, loc.Longitude);
        double? ratio = lightRefFor.StartsWith($"{e} {lightUnit?.Unit ?? ""} ", StringComparison.Ordinal)
            ? LightRules.Ratio(reading, here, LightRules.SunRising(loc.Latitude, loc.Longitude, DateTimeOffset.UtcNow), lightRef) : null;
        light = StepLight(LightRules.Cap(ratio, Cfg.Tuned.CloudyDaylight / 100));
        if (ratio is double r)
            LightStatus = $"Now {Pct(r)}% of a clear sky, so daylight counts at most {Pct(light)}%.";
        else if (!lightRef.IsEmpty)
            // A solar sensor sits at 0 and stops reporting after sunset: that is night, not a stuck sensor.
            LightStatus = here <= 0 ? "The sun is down: the sensor counts again in the morning."
                : reading == null ? "No reading from the sensor right now: going back to the sun's height alone."
                : "Too little sun to compare right now: the sun's height alone decides.";
        return s with { LightRatio = ratio };
    }
    static int? Tenths(double? r) => r is double v ? (int)Math.Round(v * 10, MidpointRounding.AwayFromZero) : null;
    static int Pct(double v) => (int)Math.Round(v * 100, MidpointRounding.AwayFromZero);

    /// The configured contrast, once per monitor until the next display change, wake or reload. A refused
    /// write is logged and not retried every tick. An idle PC leaves it for when the user is back: the
    /// monitor may be showing another computer.
    async Task ApplyContrast(Mon[] mons) {
        if (Win.IdleSeconds() >= Cfg.Tuned.IdleSeconds) {
            // Pending: the idle watcher ticks when the user is back, also with no source or paused on battery.
            if (mons.Any(m => ContrastRule.ToWrite(m.Spec?.Contrast, !m.D.Hdr, m.ContrastSet) != null)) idleWatch.Start();
            return;
        }
        foreach (var m in mons) {
            if (ContrastRule.ToWrite(m.Spec?.Contrast, !m.D.Hdr, m.ContrastSet) is not int v) continue;
            m.ContrastSet = v;
            var gdi = m.D.Gdi;
            bool ok = await Task.Run(() => { try { return Ddc.Set(gdi, v, Ddc.Contrast); } catch { return false; } });
            Log.Write(ok ? $"contrast: {m.Label} set to {v}"
                         : $"display: {m.Label} did not take contrast {v}; trying again after the next display change, wake or reload");
        }
    }

    async Task TickOnce() {
        RefreshDisplays(await Task.Run(Native.ActiveDisplays));
        var mons = Mons.ToArray();
        await ApplyContrast(mons);
        var beforeRead = mons.Select(m => m.Cur).ToArray();
        var cur = await Task.Run(() => mons.Select(m => { try { return m.Read(); } catch { return (int?)null; } }).ToArray());
        for (int i = 0; i < mons.Length; i++) {
            var r = cur[i];
            if (!mons[i].D.Hdr) {
                mons[i].Reads = mons[i].Reads.AfterRead(r != null);
                r = mons[i].Reads.Current(r, mons[i].Cur ?? 50);   // write-only: the slider is the record of its level
            }
            // A slider drag or key press during the read (or just before it, while the monitor may still show the old level) is newer than the reading.
            mons[i].Cur = Rules.LevelToDecideOn(r, beforeRead[i], mons[i].Cur, mons[i].Dragging || (DateTime.UtcNow - mons[i].UserTouched).TotalSeconds < 1.5);
        }
        Error = ConfigError;

        if (Source == Source.Off) { Subtitle = ""; foreach (var m in mons) m.Manual = false; ClearLive(); return; }
        // Nothing to drive: no polling until a monitor appears (DisplaySettingsChanged ticks again).
        if (mons.Length == 0) { Subtitle = ""; ClearLive(); return; }
        if (Paused) { Subtitle = "Paused on battery"; foreach (var m in mons) m.Manual = false; ClearLive(); return; }

        Inputs? s; bool haDown = false;
        if (Source == Source.HomeAssistant) {
            s = await HAClient.State(Cfg, mons);
            foreach (var delay in HaErrorRule.RetryDelays) {   // a first failure after start, wake or a network switch is usually brief
                if (s != null || !HAClient.Transient) break;
                if (haDownSince == null) Log.Write($"home assistant: retrying in {delay} s ({HAClient.LastCause ?? "no answer"})");   // once, not every tick of an outage
                await Task.Delay(TimeSpan.FromSeconds(delay));
                s = await HAClient.State(Cfg, mons);
            }
            if (s == null) {
                haDown = true;
                var message = HAClient.LastError ?? "unreachable";
                double Secs(DateTime t) => (t - DateTime.UnixEpoch).TotalSeconds;
                if (HaErrorRule.ShouldLog(message, lastHaError, haLoggedAt is { } at ? (double?)Secs(at) : null, Secs(DateTime.UtcNow))) {
                    var still = haLoggedAt != null && message == lastHaError;
                    Log.Write("home assistant: " + message + (HAClient.LastCause is { } cause ? $" ({cause})" : "")
                              + (still ? $", still, for {(int)(DateTime.UtcNow - (haDownSince ?? DateTime.UtcNow)).TotalMinutes} min" : ""));
                    haLoggedAt = DateTime.UtcNow;
                }
                lastHaError = message;
                haDownSince ??= DateTime.UtcNow;
                if (HaErrorRule.ShouldShow(HAClient.Transient, (haDownSince.Value - DateTime.UnixEpoch).TotalSeconds,
                                           (DateTime.UtcNow - DateTime.UnixEpoch).TotalSeconds))
                    Error ??= HAClient.LastError ?? "Cannot reach Home Assistant";
                if (Cfg.Location != null && (DateTime.UtcNow - haDownSince.Value).TotalSeconds >= Cfg.Tuned.HaFallbackSeconds) s = SunInputs(mons);
            }
        } else s = SunInputs(mons);
        var downFor = haDownSince is { } since ? (int)(DateTime.UtcNow - since).TotalMinutes : 0;
        if (!haDown) { haDownSince = null; haLoggedAt = null; }
        if (!haDown && Source == Source.HomeAssistant && s != null) {
            if (s.HasBlind) s = s with { Pos = Rules.BlindPosition(s.Pos, lastHaPos) };
            for (int i = 0; i < mons.Length && i < s.Levels.Length; i++) mons[i].HaLevels = s.FromHa is { } haRow && i < haRow.Length ? haRow[i] : s.Levels[i];
            lastHaPos = s.HasBlind ? s.Pos : null;
            lastHaLights = s.Lights;
            if (s.Auto is bool seenAuto && Settings.LastHaAuto(Cfg.HomeAssistant?.AutoSwitch) != seenAuto) Settings.SetLastHaAuto(seenAuto, Cfg.HomeAssistant?.AutoSwitch);   // kept across restarts for the sun fallback
            if (HaTemplate.NoValueNote(s.Missing) is { } gone) {
                Error = HaTemplate.ProblemLine(ConfigError, s.Missing);
                if (HaErrorRule.ShouldLog(gone, missingNoteShown, missingNoteLoggedAt is { } mt ? (double?)(mt - DateTime.UnixEpoch).TotalSeconds : null, (DateTime.UtcNow - DateTime.UnixEpoch).TotalSeconds)) {
                    Log.Write("home assistant: " + gone); missingNoteLoggedAt = DateTime.UtcNow;
                }
                missingNoteShown = gone;
            } else { missingNoteShown = null; missingNoteLoggedAt = null; }
        }
        if (!haDown && lastHaError != null) { Log.Write("home assistant: ok" + (downFor > 0 ? $" again after {downFor} min" : "")); lastHaError = null; }
        if (s == null) { Subtitle = "Waiting for Home Assistant"; return; }

        s = ApplyLight(s, !haDown && Source == Source.HomeAssistant, out double light);
        // A switch Home Assistant has no value for leaves Automatic as it was, as in an outage.
        var autoEntity = Source == Source.HomeAssistant ? Cfg.HomeAssistant?.AutoSwitch : null;
        AutoOn = Rules.AutomaticNow(!string.IsNullOrWhiteSpace(autoEntity), s.Auto, Settings.LastHaAuto(autoEntity), Settings.Auto);
        double sun = Cfg.Tuned.Fraction(s.Elev);
        bool boost = s.Elev < Cfg.Tuned.LightsBoostSunBelow;
        // The Mac and this PC may share these monitors through input switching. Only the machine in
        // use drives them; coming back applies the current target and publishes again.
        bool here = Win.IdleSeconds() < Cfg.Tuned.IdleSeconds;
        if (here != wasHere) Log.Write(here ? "back: applying targets" : "idle: paused");
        if (here && !wasHere) { ForgetHandSet(); foreach (var m in mons) m.Published = null; }
        wasHere = here;
        if (here) UpdateLook(s, haDown || Source == Source.Sun);   // an idle PC leaves the theme alone too

        // Sync: the first group member that is reporting leads, with its own target and hand-set offset;
        // the others follow the level it lands on, each at its link offset (a hand-set level of theirs is
        // part of that offset, so they keep none of their own).
        if (Settings.SyncMonitors && mons.Length > 1) AdoptSync();
        int li = Settings.SyncMonitors && mons.Length > 1 ? Array.FindIndex(mons, x => x.Cur != null && syncOffsets.IsMember(x.Key)) : -1;
        int? groupBase = null;
        bool holdsChanged = false;
        var lightsUsed = new Dictionary<string, bool>();   // the room lights each monitor's target used (for the Settings chart)
        var linkedNow = new Dictionary<string, int>();   // linked followers: the level they land on (for the Settings chart)
        var order = li >= 0 ? new[] { li }.Concat(Enumerable.Range(0, mons.Length).Where(j => j != li)) : Enumerable.Range(0, mons.Length);
        foreach (int i in order) {
            var m = mons[i];
            m.Manual = false;
            if (m.Cur is not int c) continue;
            // In the sun fallback only a monitor with a nightLights level keeps the last lights state; the others count them as off.
            bool roomLit = Rules.RoomLights(s.Lights, !haDown && Source == Source.HomeAssistant,
                                            Source == Source.HomeAssistant ? lastHaLights : null, Rules.NightLightsLevel(s.Levels[i]) != null);
            lightsUsed[m.Key] = roomLit;
            int target = Rules.Target(s.Levels[i], s.Pos, roomLit, sun, Cfg.Tuned, boost, light);
            var hold = new Hold(m.RemoteSeen, m.LastSet, m.LastTarget, m.Offset, m.OffsetSun, m.OffsetAt, m.RemoteValue);
            bool follower = groupBase != null && syncOffsets.IsMember(m.Key);
            if (groupBase is int b && follower) {
                // Moved on its own (its buttons) since the last tick: that is its new place in the group.
                if (here && AutoOn && m.LastSet is int last && c != last && (m.Touched || Math.Abs(c - last) > 1) && c != syncOffsets.Level(m.Key, b)) {
                    syncOffsets.Move(m.Key, c, b); Settings.SyncOffsets = syncOffsets;
                    Log.Write($"sync: {m.Label} moved by hand, now {(c - b >= 0 ? "+" : "")}{c - b} from the group");
                }
                target = syncOffsets.Level(m.Key, b) ?? target;
                hold = hold with { LastSet = null, Offset = null, OffsetSun = null, OffsetAt = null };
            }
            bool dragging = m.Dragging;   // the slider is in the user's hand
            double tickNow = Now;         // the same time for Decide and for the suggestion samples below
            int clearedAt = offsetCleared.GetValueOrDefault(m.Key);   // see ApplySuggestion
            var step = Rules.Decide(c, target, s.Remote.ElementAtOrDefault(i), hold, AutoOn, here, sun, m.Touched, dragging, tickNow);
            if (groupBase is int gb && follower && step.Remote is int rv) { syncOffsets.Move(m.Key, rv, gb); Settings.SyncOffsets = syncOffsets; }
            if (!dragging) m.Touched = false;
            bool remote = step.Remote != null;
            if (remote && !m.WriteFailing) Log.Write($"remote: {m.Label} {c}% → {step.Remote}% from Home Assistant");
            else if (step.Write is int w && !m.WriteFailing) Log.Write($"auto: {m.Label} {c}% → {w}%");
            bool ok = true;
            if (step.Write is int v) {
                ok = await Task.Run(() => m.Write(v));
                // Logged once when it starts and once when it ends, not every tick while it lasts.
                if (ok == m.WriteFailing)
                    Log.Write(ok ? $"display: {m.Label} takes brightness changes again"
                                 : $"display: {m.Label} did not take brightness {v}%; trying again each tick");
                m.WriteFailing = !ok;
            }
            var st = Rules.AfterWrite(step.State, ok, hold);   // a refused write is retried next tick
            // Apply cleared this monitor's offset while the write was under way: merge that clear into our result.
            bool appliedMeanwhile = offsetCleared.GetValueOrDefault(m.Key) != clearedAt;
            if (appliedMeanwhile) { st = Suggest.AfterApply(st); recorder.Drop(m.Key); }
            if (i == li) groupBase = syncOffsets.Base(m.Key, ok ? step.Applied : c);   // followers go where the leader really is
            if (st.Offset != m.Offset && st.Offset is int o)
                Log.Write($"manual: {m.Label} kept {(o > 0 ? "+" : "")}{o} from the automatic level");
            (m.RemoteSeen, m.RemoteValue, m.LastSet, m.LastTarget, m.Offset, m.OffsetSun, m.OffsetAt) = (st.RemoteSeen, st.RemoteValue, st.LastSet, st.LastTarget, st.Offset, st.OffsetSun, st.OffsetAt);
            // Suggestions (Suggest.cs): a new hand-set level becomes a sample once it has held 5 minutes.
            if (step.Remote != null) {
                // A Home Assistant "set" applied this tick overrides whatever was pending by hand: that change ends here.
                recorder.Drop(m.Key);
            } else if (Suggest.IsHandChange(hold, step.State, step.Remote, tickNow)) {
                var sampleContext = new SampleContext(Follower: follower, WriteFailed: !ok, Idle: !here, Paused: Paused,
                                                      SunFallback: Source == Source.HomeAssistant && haDown);
                // An offset back at 0 (st.Offset == null) passes null, which ends the pending change.
                recorder.HandChanged(m.Key, st.Offset is int handOffset
                    ? Suggest.MakeSample(m.Key, target + handOffset, target, s.Elev, s.Pos, roomLit, light, s.Levels[i], Cfg.Tuned, tickNow, sampleContext)
                    : null);
            }
            if (recorder.Settle(m.Key, AutoOn && st.Offset != null, s.Levels[i], tickNow) is Sample settled) {
                corrections.Add(settled); SaveCorrections(); suggestDirty = true;
            }
            if (holds.Record(m.Key, st, Now)) holdsChanged = true;
            // Not while the slider is held, or when a hand change landed during the write: that level is newer.
            if (Rules.LevelAfterWrite(step.Current, ok, c, m.Cur, m.Dragging) is int written) m.Cur = written;
            m.Manual = step.Manual && !appliedMeanwhile;
            int applied = ok ? step.Applied : c;
            if (follower && here) linkedNow[m.Key] = applied;   // an idle PC sets nothing, so it shows the target instead
            if ((here || remote) && !haDown && Source == Source.HomeAssistant && (m.Published != applied || m.PublishedManual != m.Manual || m.PublishedLight != Tenths(s.LightRatio)) &&
                !string.IsNullOrWhiteSpace(m.Spec?.HomeAssistant?.Sensor)) {
                if (await HAClient.Publish(Cfg, m, applied, target, m.Manual, sun, s) != null) {   // retried next tick if it failed
                    m.Published = applied; m.PublishedManual = m.Manual; m.PublishedLight = Tenths(s.LightRatio);   // steps of 10%, not every tick
                    Log.Write($"publish: {m.Spec!.HomeAssistant!.Sensor} = {applied}" + (m.Manual ? " (manual)" : ""));
                }
            }
        }

        if (holdsChanged) Settings.Holds = holds;

        // What the Settings chart shows as "right now". With Home Assistant down it keeps the levels it last gave.
        var offs = new Dictionary<string, (int Value, double Weight)>();
        foreach (var m in mons)
            if (m.Offset is int o && Rules.OffsetWeight(sun, m.OffsetSun ?? sun, m.OffsetAt is double at ? Now - at : null) is double w) offs[m.Key] = (o, w);
        IReadOnlyDictionary<string, double[]>? haLevels = Source == Source.HomeAssistant ? Live?.Levels : null;
        if (Source == Source.HomeAssistant && !haDown && s.FromHa is { } raw) {
            var fresh = new Dictionary<string, double[]>();
            for (int i = 0; i < mons.Length && i < raw.Length; i++) fresh[mons[i].Key] = raw[i];
            haLevels = fresh;
        }
        bool setHelper = Source == Source.HomeAssistant && !haDown && mons.Any(m => !string.IsNullOrWhiteSpace(m.Spec?.HomeAssistant?.Set));
        Live = new LiveInputs(s.Elev, s.HasBlind ? s.Pos : null, s.Lights, light, haLevels, offs, linkedNow,
                              li >= 0 ? mons[li].Label : "", AutoOn && here, LightsUsed: lightsUsed,
                              SetHelper: setHelper);
        LiveChanged?.Invoke();

        string where = s.Elev >= 0 ? $"{s.Elev:0.0}° above the horizon" : $"{-s.Elev:0.0}° below the horizon";
        Subtitle = !AutoOn ? "Off — sliders and hotkeys" + (setHelper ? ", and the set helper" : " only")
                 : !here ? "Paused — this PC is idle"
                 : haDown ? "Sun · " + where   // the error line under it says Home Assistant is unreachable
                 : Source == Source.Sun ? "Sun · " + where
                 : $"Home Assistant · daylight {(int)Math.Round(sun * 100)}%" + (s.HasBlind ? $" · blind {(int)s.Pos}%" : "") + Rules.LightsNote(s.Lights, s.Bri, s.Sat, Cfg.Tuned)
                   + (s.LightRatio is double lr ? $" · light {Pct(lr)}%" : "");
        await UpdateSuggestion(s, mons, haDown);
    }

    // Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
    // dark otherwise. Each condition has a gap between its on and off thresholds so it doesn't flip
    // back and forth. Only acts when the decision changes, so a manual switch stays until then.
    // With no earlier decision (start, reload, switched on) the current theme settles a reading
    // inside a gap, so a restart doesn't undo a manual switch.
    void UpdateLook(Inputs s, bool sunOnly) {
        if (!Settings.AutoLook) { lookDark = null; look.Reset(); return; }
        bool dark = look.WantDark(s.Elev, s.Pos, s.HasBlind, !sunOnly && s.Lights, s.Bri, s.Sat, Cfg.Tuned, lookDark == null ? Theme.Dark : null);
        if (dark != lookDark) {
            if (!Look.Shows(dark)) {   // already showing it (apps, stock wallpaper): nothing to switch
                Log.Write("theme: " + (dark ? "dark" : "light"));
                Look.SetDark(dark);
                tray.Icon = Theme.SunIcon();
            }
            lookDark = dark;
        }
    }
}
