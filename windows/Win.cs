// Small Windows helpers: idle time, focused screen, sign-in start, DWM window styling, theme,
// persisted settings, light/dark mode switching and a small log.
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using SD = System.Drawing;
using SD2 = System.Drawing.Drawing2D;

namespace Daylit;

static class Win {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint Size, Time; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32")] static extern bool GetLastInputInfo(ref LASTINPUTINFO l);
    [DllImport("user32")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32")] static extern int GetWindowLongW(IntPtr h, int i);
    [DllImport("user32")] static extern int SetWindowLongW(IntPtr h, int i, int v);
    [DllImport("dwmapi")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static double IdleSeconds() {
        var l = new LASTINPUTINFO { Size = 8 };
        return GetLastInputInfo(ref l) ? unchecked((uint)Environment.TickCount - l.Time) / 1000.0 : 0;
    }
    /// GDI name (\\.\DISPLAYn) of the screen holding the focused window.
    public static string? ForegroundScreen() => Ddc.DeviceOf(MonitorFromWindow(GetForegroundWindow(), 2 /* NEAREST */));

    /// Desktops report no system battery: the pause-on-battery switch is hidden there.
    public static bool HasBattery => !System.Windows.Forms.SystemInformation.PowerStatus.BatteryChargeStatus.HasFlag(System.Windows.Forms.BatteryChargeStatus.NoSystemBattery);
    public static bool OnBattery => System.Windows.Forms.SystemInformation.PowerStatus.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Offline;

    public static bool StartsWithWindows {
        get => Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue("Daylit") != null;
        set {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue("Daylit", $"\"{Environment.ProcessPath}\""); else k.DeleteValue("Daylit", false);
        }
    }

    /// Windows 11 22H2+ draws system backdrops (acrylic/Mica) behind a window.
    /// Windows 11 22H2+ with "Transparency effects" on (Settings → Personalization → Colors).
    public static bool HasBackdrop => Environment.OSVersion.Version.Build >= 22621
        && !(Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "EnableTransparency", 1) is int t && t == 0);

    public static void RoundCorners(IntPtr h) { int v = 2 /* DWMWCP_ROUND */; DwmSetWindowAttribute(h, 33, ref v, 4); }
    public static void DarkFrame(IntPtr h, bool dark) { int v = dark ? 1 : 0; DwmSetWindowAttribute(h, 20, ref v, 4); }
    /// 3 = DWMSBT_TRANSIENTWINDOW (acrylic, what Windows uses for flyouts).
    public static bool Backdrop(IntPtr h, int type = 4 /* DWMSBT_TABBEDWINDOW: Mica Alt */) => HasBackdrop && DwmSetWindowAttribute(h, 38, ref type, 4) == 0;

    /// Click-through, never activated, not in Alt+Tab.
    public static void MakeOverlay(IntPtr h) {
        const int GWL_EXSTYLE = -20, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
        SetWindowLongW(h, GWL_EXSTYLE, GetWindowLongW(h, GWL_EXSTYLE) | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    }

    /// Moves a window, in physical pixels, so its top-left lands where `place` says for its current size.
    /// Run twice: moving to a monitor with another DPI makes WPF resize the window.
    public static void Place(IntPtr h, Func<int, int, (int x, int y)> place) {
        for (int i = 0; i < 2; i++) {
            if (!GetWindowRect(h, out var r)) return;
            var (x, y) = place(r.R - r.L, r.B - r.T);
            SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 /* NOSIZE */ | 0x0004 /* NOZORDER */ | 0x0010 /* NOACTIVATE */);
        }
    }
}

/// Settings kept in HKCU\Software\Daylit (not in config.json, because the app changes them).
static class Settings {
    const string Key = @"Software\Daylit";
    static bool Get(string name, bool dflt) => Registry.CurrentUser.OpenSubKey(Key)?.GetValue(name) is int i ? i == 1 : dflt;
    static void Set(string name, bool v) { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue(name, v ? 1 : 0, RegistryValueKind.DWord); }
    /// Automatic mode when it is not a Home Assistant switch.
    public static bool Auto { get => Get("Auto", true); set => Set("Auto", value); }
    /// The Automatic state Home Assistant last gave (null: none seen yet): the sun fallback uses it, so an outage never flips Automatic.
    public static bool? LastHaAuto {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("LastHaAuto") is int i ? i == 1 : null;
        set { if (value is bool v) Set("LastHaAuto", v); }
    }
    /// Light/dark mode from daylight and room lights.
    public static bool AutoLook { get => Get("AutoLook", true); set => Set("AutoLook", value); }
    /// Pause on battery, once changed in the panel; null = use the config's pauseOnBattery (default on).
    public static bool? PauseOnBattery {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("PauseOnBattery") is int i ? i == 1 : null;
        set { if (value is bool v) Set("PauseOnBattery", v); }
    }

    /// "Sync monitors" and the offsets captured when it was switched on (JSON: monitor key → offset).
    public static bool SyncMonitors { get => SyncOverride ?? Get("SyncMonitors", false); set => Set("SyncMonitors", value); }
    /// Snapshots: a fixed value instead of the registry.
    public static bool? SyncOverride;
    public static SyncOffsets SyncOffsets {
        get {
            if (SyncOverride != null) return new SyncOffsets();   // snapshots never read or write the registry
            var s = new SyncOffsets();
            try {
                var k = Registry.CurrentUser.OpenSubKey(Key);
                if (k?.GetValue("SyncOffsets") is string j) s.Offsets = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, int>>(j) ?? new();
                if (k?.GetValue("SyncExcluded") is string x) s.Excluded = System.Text.Json.JsonSerializer.Deserialize<HashSet<string>>(x) ?? new();
            } catch { }
            return s;
        }
        set {
            if (SyncOverride != null) return;
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k.SetValue("SyncOffsets", System.Text.Json.JsonSerializer.Serialize(value.Offsets));
            k.SetValue("SyncExcluded", System.Text.Json.JsonSerializer.Serialize(value.Excluded));
        }
    }

    /// Hand-set levels kept across restarts (JSON, see SavedHolds).
    public static SavedHolds Holds {
        get => SavedHolds.FromJson(Registry.CurrentUser.OpenSubKey(Key)?.GetValue("Holds") as string);
        set { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue("Holds", value.ToJson()); }
    }

    /// The light sensor's unit and since when its history is in it (JSON, see LightUnit).
    public static LightUnit? LightUnit {
        get {
            try { return Registry.CurrentUser.OpenSubKey(Key)?.GetValue("LightUnit") is string j ? System.Text.Json.JsonSerializer.Deserialize<LightUnit>(j) : null; }
            catch { return null; }
        }
        set { if (value != null) { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue("LightUnit", System.Text.Json.JsonSerializer.Serialize(value)); } }
    }

    /// "Not now" on a suggestion: per monitor key, no suggestion until then (Unix seconds; JSON).
    public static Dictionary<string, double> SuggestDismissed {
        get {
            try {
                return Registry.CurrentUser.OpenSubKey(Key)?.GetValue("SuggestDismissed") is string j
                    ? System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, double>>(j) ?? new Dictionary<string, double>()
                    : new Dictionary<string, double>();
            } catch { return new Dictionary<string, double>(); }
        }
        set {
            try { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue("SuggestDismissed", System.Text.Json.JsonSerializer.Serialize(value)); }
            catch (Exception e) { Log.Write("suggest: could not remember Not now: " + e.Message); }
        }
    }

    static int GetInt(string name, int dflt) => Registry.CurrentUser.OpenSubKey(Key)?.GetValue(name) is int i ? i : dflt;
    static void SetInt(string name, int v) { using var k = Registry.CurrentUser.CreateSubKey(Key); k.SetValue(name, v, RegistryValueKind.DWord); }
    /// Brightness hotkeys, set from the panel (Keyboard shortcuts…). Shift is added for fine steps.
    public static Shortcut Up {
        get => new(GetInt("UpMods", Shortcut.DefaultUp.Mods), GetInt("UpKey", Shortcut.DefaultUp.Vk));
        set { SetInt("UpMods", value.Mods); SetInt("UpKey", value.Vk); }
    }
    public static Shortcut Down {
        get => new(GetInt("DownMods", Shortcut.DefaultDown.Mods), GetInt("DownKey", Shortcut.DefaultDown.Vk));
        set { SetInt("DownMods", value.Mods); SetInt("DownKey", value.Vk); }
    }
    /// Light/dark mode hotkey (no Shift variant).
    public static Shortcut ThemeKey {
        get => new(GetInt("ThemeMods", Shortcut.DefaultTheme.Mods), GetInt("ThemeKey", Shortcut.DefaultTheme.Vk));
        set { SetInt("ThemeMods", value.Mods); SetInt("ThemeKey", value.Vk); }
    }
}

static class Theme {
    const string Key = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    /// Snapshots force light or dark instead of reading the system setting.
    public static bool? Force;
    public static bool Dark => Force ?? (Registry.GetValue(Key, "AppsUseLightTheme", 1) is int i && i == 0);
    static bool DarkTaskbar => !(Registry.GetValue(Key, "SystemUsesLightTheme", 0) is int i && i == 1);

    [DllImport("user32")] static extern bool DestroyIcon(IntPtr h);
    static SD.Icon? lastIcon, olderIcon;

    /// Tray icon: a sun drawn in the taskbar's text colour. Icons are released two calls later,
    /// when the tray surely no longer shows them.
    public static SD.Icon SunIcon() {
        using var bmp = new SD.Bitmap(32, 32);
        using (var g = SD.Graphics.FromImage(bmp)) {
            g.SmoothingMode = SD2.SmoothingMode.AntiAlias;
            var c = DarkTaskbar ? SD.Color.White : SD.Color.FromArgb(32, 32, 32);
            using var pen = new SD.Pen(c, 2.6f) { StartCap = SD2.LineCap.Round, EndCap = SD2.LineCap.Round };
            using var br = new SD.SolidBrush(c);
            g.FillEllipse(br, 10, 10, 12, 12);
            for (int i = 0; i < 8; i++) {
                double a = i * Math.PI / 4;
                g.DrawLine(pen, 16 + (float)Math.Cos(a) * 10, 16 + (float)Math.Sin(a) * 10, 16 + (float)Math.Cos(a) * 14, 16 + (float)Math.Sin(a) * 14);
            }
        }
        var h = bmp.GetHicon();
        var icon = (SD.Icon)SD.Icon.FromHandle(h).Clone();
        DestroyIcon(h);
        olderIcon?.Dispose();
        olderIcon = lastIcon; lastIcon = icon;
        return icon;
    }
}

/// Light/dark mode from daylight and the room lights. (Warm screen is left to Windows Night Light.)
static class Look {
    const string Pers = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    [DllImport("user32", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, string l, uint flags, uint timeout, out IntPtr r);

    /// Whether Windows already shows this mode: apps and (a stock) wallpaper. The taskbar and Start theme
    /// (SystemUsesLightTheme) is the user's own choice and is never touched.
    public static bool Shows(bool dark) {
        using var k = Registry.CurrentUser.OpenSubKey(Pers);
        return ThemeIs(k, dark) && WallpaperToSet(dark) == null;
    }
    static bool ThemeIs(RegistryKey? k, bool dark) {
        int v = dark ? 0 : 1;
        return k?.GetValue("AppsUseLightTheme") is int a && a == v;
    }

    public static void SetDark(bool dark) {
        SetWallpaper(dark);
        using var k = Registry.CurrentUser.CreateSubKey(Pers);
        int v = dark ? 0 : 1;
        if (ThemeIs(k, dark)) return;
        k.SetValue("AppsUseLightTheme", v, RegistryValueKind.DWord);
        SendMessageTimeoutW((IntPtr)0xFFFF, 0x1A /* WM_SETTINGCHANGE */, IntPtr.Zero, "ImmersiveColorSet", 2, 1000, out _);
    }

    // Windows 11's own bloom wallpapers: img0 is the light one, img19 the dark one.
    // Only swaps between those two, so a custom wallpaper is never replaced.
    static readonly string WallDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"Web\Wallpaper\Windows");
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern bool SystemParametersInfoW(uint action, uint param, string value, uint flags);
    /// The stock wallpaper to switch to, or null when there is nothing to swap.
    static string? WallpaperToSet(bool dark) {
        string light = Path.Combine(WallDir, "img0.jpg"), darkImg = Path.Combine(WallDir, "img19.jpg");
        using var desk = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop");
        var cur = desk?.GetValue("WallPaper") as string ?? "";
        bool isStock = cur.Equals(light, StringComparison.OrdinalIgnoreCase) || cur.Equals(darkImg, StringComparison.OrdinalIgnoreCase);
        string want = dark ? darkImg : light;
        return !isStock || cur.Equals(want, StringComparison.OrdinalIgnoreCase) || !File.Exists(want) ? null : want;
    }
    static void SetWallpaper(bool dark) {
        if (WallpaperToSet(dark) is string want)
            SystemParametersInfoW(0x14 /* SPI_SETDESKWALLPAPER */, 0, want, 3 /* update ini + broadcast */);
    }
}

/// %LOCALAPPDATA%\Daylit\daylit.log, kept small. For "why did it do that?" questions.
static class Log {
    static readonly string Path_ = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Daylit", "daylit.log");
    static readonly object gate = new();
    public static void Write(string msg) {
        try {
            lock (gate) {
                Directory.CreateDirectory(Path.GetDirectoryName(Path_)!);
                if (File.Exists(Path_) && new FileInfo(Path_).Length > 512 * 1024) File.Move(Path_, Path_ + ".old", true);
                File.AppendAllText(Path_, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {msg}{Environment.NewLine}");
            }
        } catch { }
    }
}
