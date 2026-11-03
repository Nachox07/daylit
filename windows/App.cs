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
        Log.Write($"start: Daylit {typeof(Controller).Assembly.GetName().Version?.ToString(3) ?? "dev"}");
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
    bool? lookDark;
    readonly LookRule look = new();   // light/dark decision with hysteresis (Rules.cs)
    string? lastHaError;
    // When Home Assistant stopped answering. The sun takes over only after a minute, so a slow
    // network at sign-in or after wake does not jump the monitors to the fallback levels.
    DateTime? haDownSince;

    /// Fixed state and nothing else: no tray, hotkeys, timers, monitors or network (UI snapshots).
    public Controller(Config cfg, List<Mon> mons, string subtitle) {
        app = Application.Current; ui = app.Dispatcher;
        Cfg = cfg; Mons = mons; AutoOn = true; Subtitle = subtitle; HotkeysOk = true;
        tray = null!; panel = null!; keys = null!;
    }

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
        lookDark = null; look.Reset();
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
        var m = Mons.FirstOrDefault(x => x.Usable && x.D.Gdi == gdi) ?? Mons.FirstOrDefault(x => x.On);
        if (m == null) { _ = Tick("hotkey"); return; }   // nothing read yet (e.g. DDC was slow at start): read now
        int v = Math.Clamp((m.Cur ?? 50) + (up ? 1 : -1) * (fine ? 1 : 6), 0, 100);   // 50: a monitor that doesn't report its level
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

    public void UserSet(Mon m, int v) {
        m.Cur = v; m.UserTouched = DateTime.UtcNow; m.WriteSoon(v);
        if (!Settings.SyncMonitors || Mons.Count < 2) return;
        // Sync: the other monitors follow with the offsets captured when sync was switched on.
        AdoptSync();
        var follow = syncOffsets.Follow(m.Key, v, Mons.Select(x => x.Key));
        foreach (var o in Mons)
            if (o != m && o.Usable && follow.TryGetValue(o.Key, out var lv) && o.Cur != lv) { o.Cur = lv; o.WriteSoon(lv); }
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

    public void SetLook(bool on) { Settings.AutoLook = on; lookDark = null; look.Reset(); _ = Tick("look"); }
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
            if (m == null) {
                var fresh = new Mon(d, Mon.Match(d, Cfg.Monitors));
                if (holds.Restore(d.Key, Now) is var (ls, lt)) { fresh.LastSet = ls; fresh.LastTarget = lt; }
                return fresh;
            }
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

    /// With Home Assistant down, the sun drives the target but the levels and the blind stay the last ones
    /// Home Assistant gave: a network blip must not swap them for the defaults and move the screens.
    Inputs SunInputs(IReadOnlyList<Mon> mons) {
        var l = Cfg.Location!;
        return new Inputs(Sun.Elevation(DateTimeOffset.UtcNow, l.Latitude, l.Longitude), lastHaPos ?? 100, false, 0, 100,
                          mons.Select(m => m.HaLevels ?? new[] { m.Day, m.BlindDown, m.Night }).ToArray(), null, lastHaPos != null);
    }
    double? lastHaPos;

    async Task TickOnce() {
        RefreshDisplays(await Task.Run(Native.ActiveDisplays));
        var mons = Mons.ToArray();
        var cur = await Task.Run(() => mons.Select(m => { try { return m.Read(); } catch { return (int?)null; } }).ToArray());
        for (int i = 0; i < mons.Length; i++) {
            var r = cur[i];
            if (!mons[i].D.Hdr) {
                mons[i].Reads = mons[i].Reads.AfterRead(r != null);
                r = mons[i].Reads.Current(r, mons[i].Cur ?? 50);   // write-only: the slider is the record of its level
            }
            mons[i].Cur = r;
        }
        Error = ConfigError;

        if (Source == Source.Off) { Subtitle = ""; foreach (var m in mons) m.Manual = false; return; }
        // Nothing to drive: no polling until a monitor appears (DisplaySettingsChanged ticks again).
        if (mons.Length == 0) { Subtitle = ""; return; }
        if (Paused) { Subtitle = "Paused on battery"; foreach (var m in mons) m.Manual = false; return; }

        Inputs? s; bool haDown = false;
        if (Source == Source.HomeAssistant) {
            s = await HAClient.State(Cfg, mons);
            foreach (var delay in HaErrorRule.RetryDelays) {   // a first failure after start, wake or a network switch is usually brief
                if (s != null || !HAClient.Transient) break;
                Log.Write($"home assistant: retrying in {delay} s ({HAClient.LastCause ?? "no answer"})");
                await Task.Delay(TimeSpan.FromSeconds(delay));
                s = await HAClient.State(Cfg, mons);
            }
            if (s == null) {
                haDown = true;
                Log.Write("home assistant: " + (HAClient.LastError ?? "unreachable") + (HAClient.LastCause is { } cause ? $" ({cause})" : ""));
                lastHaError = HAClient.LastError;
                haDownSince ??= DateTime.UtcNow;
                if (HaErrorRule.ShouldShow(HAClient.Transient, (haDownSince.Value - DateTime.UnixEpoch).TotalSeconds,
                                           (DateTime.UtcNow - DateTime.UnixEpoch).TotalSeconds))
                    Error ??= HAClient.LastError ?? "Cannot reach Home Assistant";
                if (Cfg.Location != null && (DateTime.UtcNow - haDownSince.Value).TotalSeconds >= 60) s = SunInputs(mons);
            }
        } else s = SunInputs(mons);
        if (!haDown) haDownSince = null;
        if (!haDown && Source == Source.HomeAssistant && s != null) {
            for (int i = 0; i < mons.Length && i < s.Levels.Length; i++) mons[i].HaLevels = s.Levels[i];
            lastHaPos = s.HasBlind ? s.Pos : null;
        }
        if (!haDown && lastHaError != null) { Log.Write("home assistant: ok"); lastHaError = null; }
        if (s == null) { Subtitle = "Waiting for Home Assistant"; return; }

        AutoOn = s.Auto ?? Settings.Auto;
        double sun = Sun.Fraction(s.Elev);
        // The Mac and this PC may share these monitors through input switching. Only the machine in
        // use drives them; coming back applies the current target and publishes again.
        bool here = Win.IdleSeconds() < Config.IdleSeconds;
        if (here != wasHere) Log.Write(here ? "back: applying targets" : "idle: paused");
        if (here && !wasHere) { ForgetHandSet(); foreach (var m in mons) m.Published = null; }
        wasHere = here;
        if (here) UpdateLook(s, haDown || Source == Source.Sun);   // an idle PC leaves the theme alone too

        // Sync: the first monitor that is reporting drives the group; the others keep their offsets.
        var synced = new Dictionary<string, int>();
        if (Settings.SyncMonitors && mons.Length > 1 && Array.FindIndex(mons, x => x.Cur != null) is int li && li >= 0) {
            AdoptSync();
            synced = syncOffsets.Targets(mons[li].Key, Rules.Target(s.Levels[li], s.Pos, s.Lights, sun), mons.Select(x => x.Key));
        }
        bool holdsChanged = false;
        for (int i = 0; i < mons.Length; i++) {
            var m = mons[i];
            m.Manual = false;
            if (m.Cur is not int c) continue;
            int target = synced.TryGetValue(m.Key, out var st) ? st : Rules.Target(s.Levels[i], s.Pos, s.Lights, sun);
            var step = Rules.Decide(c, target, s.Remote.ElementAtOrDefault(i), new Hold(m.RemoteSeen, m.LastSet, m.LastTarget), AutoOn, here, Cfg.Hold);
            (m.RemoteSeen, m.LastSet, m.LastTarget) = (step.State.RemoteSeen, step.State.LastSet, step.State.LastTarget);
            if (holds.Record(m.Key, m.LastSet, m.LastTarget, Now)) holdsChanged = true;
            bool remote = step.Remote != null;
            if (remote) Log.Write($"remote: {m.Label} {c}% → {step.Remote}% from Home Assistant");
            else if (step.Write is int w) Log.Write($"auto: {m.Label} {c}% → {w}%");
            if (step.Write is int v) await Task.Run(() => m.Write(v));
            m.Cur = step.Current; m.Manual = step.Manual;
            int applied = step.Applied;
            if ((here || remote) && !haDown && Source == Source.HomeAssistant && m.Published != applied &&
                !string.IsNullOrWhiteSpace(m.Spec?.HomeAssistant?.Sensor)) {
                if (await HAClient.Publish(Cfg, m, applied, target, m.Manual, sun, s) != null) {   // retried next tick if it failed
                    m.Published = applied;
                    Log.Write($"publish: {m.Spec!.HomeAssistant!.Sensor} = {applied}" + (m.Manual ? " (manual)" : ""));
                }
            }
        }

        if (holdsChanged) Settings.Holds = holds;

        string where = s.Elev >= 0 ? $"{s.Elev:0.0}° above the horizon" : $"{-s.Elev:0.0}° below the horizon";
        Subtitle = !AutoOn ? "Off — sliders and hotkeys only"
                 : !here ? "Paused — this PC is idle"
                 : haDown ? "Sun · " + where   // the error line under it says Home Assistant is unreachable
                 : Source == Source.Sun ? "Sun · " + where
                 : $"Home Assistant · daylight {(int)Math.Round(sun * 100)}%" + (s.HasBlind ? $" · blind {(int)s.Pos}%" : "") + Rules.LightsNote(s.Lights, s.Bri, s.Sat);
    }

    // Light mode when daylight comes in (sun up, blind open) or the room lights are bright and white;
    // dark otherwise. Each condition has a gap between its on and off thresholds so it doesn't flip
    // back and forth. Only acts when the decision changes, so a manual switch stays until then.
    void UpdateLook(Inputs s, bool sunOnly) {
        if (!Settings.AutoLook) { lookDark = null; look.Reset(); return; }
        bool dark = look.WantDark(s.Elev, s.Pos, s.HasBlind, !sunOnly && s.Lights, s.Bri, s.Sat);
        if (dark != lookDark) {
            Log.Write("theme: " + (dark ? "dark" : "light"));
            Look.SetDark(dark);
            lookDark = dark;
            tray.Icon = Theme.SunIcon();
        }
    }
}
