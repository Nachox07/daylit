// Daylit for Windows — tray app that keeps external monitors at the right brightness, driven by
// Home Assistant (sun, a window blind, room lights). Same contract as mac/Daylit.swift; see README.md.
//  - HDR on:  Windows "SDR content brightness" (many monitors ignore DDC brightness while HDR is on).
//  - HDR off: DDC/CI brightness (VCP 0x10).
//  - Settings live in %APPDATA%\Daylit\config.json; the token in Windows Credential Manager.
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace Daylit;

record MonitorConfig(string match, string label, string sensor, string day, string blindDown, string night, string? control = null);

record Config(string homeAssistantUrl, string autoSwitch, MonitorConfig[] monitors, string? tokenName = null, string? sun = null,
              string? cover = null, string? lights = null, int? manualHold = null) {
    public const int PublishIdleSeconds = 300; // only publish to HA while someone is using this PC
    public string Token => tokenName ?? "daylit-home-assistant";
    public int Hold => manualHold ?? 5;        // a hand-set value stays until the automatic target moves this much

    public static readonly string PathName = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Daylit", "config.json");
    public static Config? Current;
    public static string? Error;
    public static void Load() {
        try {
            var c = JsonSerializer.Deserialize<Config>(File.ReadAllText(PathName));
            Error = c == null ? "Empty config.json" : Validate(c);
            Current = Error == null ? c : null;
        }
        catch (FileNotFoundException) { Error = $"Missing {PathName} (see config.example.json)"; }
        catch (DirectoryNotFoundException) { Error = $"Missing {PathName} (see config.example.json)"; }
        catch (Exception e) { Error = "Invalid config.json: " + e.Message; }
    }
    // System.Text.Json leaves missing constructor values null even when declared non-nullable.
    static string? Validate(Config c) {
        if (string.IsNullOrWhiteSpace(c.homeAssistantUrl) || !Uri.TryCreate(c.homeAssistantUrl, UriKind.Absolute, out _))
            return "config.json: homeAssistantUrl is missing or not a URL";
        if (string.IsNullOrWhiteSpace(c.autoSwitch)) return "config.json: autoSwitch is missing";
        if (c.monitors == null || c.monitors.Length == 0) return "config.json: no monitors";
        foreach (var m in c.monitors)
            if (m == null || new[] { m.match, m.label, m.sensor, m.day, m.blindDown, m.night }.Any(string.IsNullOrWhiteSpace))
                return "config.json: every monitor needs match, label, sensor, day, blindDown and night";
        return null;
    }
}

/// m: per monitor [day, blindDown, night]; bri/sat: the room light's brightness (0-255) and colour saturation.
record HAState(double elev, double pos, bool lights, bool auto, double[][] m, double bri = 0, double sat = 100);

static class Program {
    [STAThread]
    static void Main() {
        using var mutex = new Mutex(true, @"Local\Daylit.Tray", out bool first);
        if (!first) return;
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Config.Load();
        Application.Run(new App());
    }
}

// MARK: displays

/// One active display path, as Windows sees it (DisplayConfig API).
sealed class Display {
    public string Friendly = "", Gdi = "";
    public bool Hdr;
    internal Native.LUID Adapter;
    internal uint TargetId;
}

static class Native {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Lo; public int Hi; }
    [StructLayout(LayoutKind.Sequential)] struct PathSource { public LUID Adapter; public uint Id, ModeIdx, Status; }
    [StructLayout(LayoutKind.Sequential)] struct Rational { public uint N, D; }
    [StructLayout(LayoutKind.Sequential)] struct PathTarget { public LUID Adapter; public uint Id, ModeIdx; public int Tech, Rot, Scale; public Rational Refresh; public int ScanLine, Available; public uint Status; }
    [StructLayout(LayoutKind.Sequential)] struct PathInfo { public PathSource Src; public PathTarget Tgt; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] struct Header { public int Type, Size; public LUID Adapter; public uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TargetName { public Header H; public uint Flags; public int Tech; public ushort Mfg, Product; public uint Connector;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Friendly; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Path; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SourceName { public Header H; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Gdi; }
    [StructLayout(LayoutKind.Sequential)] struct ColorInfo { public Header H; public uint Value; public int Encoding; public uint Bits; }
    [StructLayout(LayoutKind.Sequential)] struct WhiteGet { public Header H; public uint Level; }
    [StructLayout(LayoutKind.Sequential)] struct WhiteSet { public Header H; public uint Level; public byte Final; }

    [DllImport("user32")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
    [DllImport("user32")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PathInfo[] paths, ref uint nm, [Out] byte[] modes, IntPtr topology);
    [DllImport("user32", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int Get(ref TargetName r);
    [DllImport("user32", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int Get(ref SourceName r);
    [DllImport("user32", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int Get(ref ColorInfo r);
    [DllImport("user32", EntryPoint = "DisplayConfigGetDeviceInfo")] static extern int Get(ref WhiteGet r);
    [DllImport("user32", EntryPoint = "DisplayConfigSetDeviceInfo")] static extern int Set(ref WhiteSet r);

    const int GET_SOURCE_NAME = 1, GET_TARGET_NAME = 2, GET_ADVANCED_COLOR = 9, GET_SDR_WHITE = 11;
    const int SET_SDR_WHITE = unchecked((int)0xFFFFFFEE);   // undocumented; what the Settings slider uses

    static Header H<T>(int type, LUID adapter, uint id) => new() { Type = type, Size = Marshal.SizeOf<T>(), Adapter = adapter, Id = id };

    public static List<Display> ActiveDisplays() {
        var list = new List<Display>();
        if (GetDisplayConfigBufferSizes(2 /* QDC_ONLY_ACTIVE_PATHS */, out uint np, out uint nm) != 0) return list;
        var paths = new PathInfo[np]; var modes = new byte[nm * 64];
        if (QueryDisplayConfig(2, ref np, paths, ref nm, modes, IntPtr.Zero) != 0) return list;
        for (int i = 0; i < np; i++) {
            var p = paths[i];
            var tn = new TargetName { H = H<TargetName>(GET_TARGET_NAME, p.Tgt.Adapter, p.Tgt.Id) };
            var sn = new SourceName { H = H<SourceName>(GET_SOURCE_NAME, p.Src.Adapter, p.Src.Id) };
            var ci = new ColorInfo { H = H<ColorInfo>(GET_ADVANCED_COLOR, p.Tgt.Adapter, p.Tgt.Id) };
            if (Get(ref tn) != 0 || Get(ref sn) != 0) continue;
            list.Add(new Display { Friendly = tn.Friendly ?? "", Gdi = sn.Gdi ?? "", Adapter = p.Tgt.Adapter, TargetId = p.Tgt.Id,
                                   Hdr = Get(ref ci) == 0 && (ci.Value & 2) != 0 });
        }
        return list;
    }

    // SDR content brightness: level 1000..6000 (80..480 nits) = Settings slider 0..100.
    public static int? GetSdr(Display d) {
        var w = new WhiteGet { H = H<WhiteGet>(GET_SDR_WHITE, d.Adapter, d.TargetId) };
        if (Get(ref w) != 0 || w.Level < 1000) return null;
        return (int)Math.Round((w.Level - 1000) / 50.0, MidpointRounding.AwayFromZero);
    }
    public static void SetSdr(Display d, int v) {
        var w = new WhiteSet { H = H<WhiteSet>(SET_SDR_WHITE, d.Adapter, d.TargetId), Level = (uint)(1000 + Math.Clamp(v, 0, 100) * 50), Final = 1 };
        Set(ref w);
    }
}

/// DDC/CI brightness through the Monitor Configuration API.
static class Ddc {
    delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, IntPtr rc, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MonitorInfoEx { public int Size; public RECT Monitor, Work; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Physical { public IntPtr H; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Desc; }

    [DllImport("user32")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr h, ref MonitorInfoEx mi);
    [DllImport("dxva2")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] Physical[] a);
    [DllImport("dxva2")] static extern bool DestroyPhysicalMonitors(uint n, Physical[] a);
    [DllImport("dxva2")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
    [DllImport("dxva2")] static extern bool SetVCPFeature(IntPtr h, byte code, uint v);
    static readonly object gate = new();

    public static string? DeviceOf(IntPtr hMon) {
        var mi = new MonitorInfoEx { Size = Marshal.SizeOf<MonitorInfoEx>() };
        return GetMonitorInfoW(hMon, ref mi) ? mi.Device : null;
    }
    static T With<T>(string gdi, Func<IntPtr, T> f, T fallback) {
        lock (gate) {
            IntPtr hm = IntPtr.Zero;
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, _, _, _) => { if (DeviceOf(h) == gdi) hm = h; return true; }, IntPtr.Zero);
            if (hm == IntPtr.Zero || !GetNumberOfPhysicalMonitorsFromHMONITOR(hm, out uint n) || n == 0) return fallback;
            var a = new Physical[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, n, a)) return fallback;
            try { return f(a[0].H); } finally { DestroyPhysicalMonitors(n, a); }
        }
    }
    public static int? Get(string gdi) => With<int?>(gdi, h =>
        GetVCPFeatureAndVCPFeatureReply(h, 0x10, IntPtr.Zero, out uint c, out uint m) && m > 0 ? (int)Math.Round(c * 100.0 / m) : null, null);
    public static void Set(string gdi, int v) => With(gdi, h => {
        if (GetVCPFeatureAndVCPFeatureReply(h, 0x10, IntPtr.Zero, out _, out uint m) && m > 0) SetVCPFeature(h, 0x10, (uint)Math.Round(v * m / 100.0));
        return 0;
    }, 0);
}

sealed class Mon {
    public readonly MonitorConfig Spec;
    public Display? D;
    public int? Cur, LastSet, LastTarget, Published;
    CancellationTokenSource? pending;
    public Mon(MonitorConfig s) => Spec = s;
    public bool On => D != null && Cur != null;

    public int? Read() => D == null ? null : D.Hdr ? Native.GetSdr(D) : Ddc.Get(D.Gdi);
    public void Write(int v) { if (D == null) return; if (D.Hdr) Native.SetSdr(D, v); else Ddc.Set(D.Gdi, v); }
    /// For sliders and hotkeys: HDR applies at once; DDC is slow, so it is debounced.
    public void WriteSoon(int v) {
        var d = D; if (d == null) return;
        if (d.Hdr) { Native.SetSdr(d, v); return; }
        pending?.Cancel(); var cts = pending = new CancellationTokenSource();
        Task.Delay(150, cts.Token).ContinueWith(t => { if (!t.IsCanceled) Ddc.Set(d.Gdi, v); }, TaskScheduler.Default);
    }
}

// MARK: Home Assistant

static class HAClient {
    static readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(6) };
    public static string? Token;
    public static string? LastError;

    /// One template call returns everything a tick needs.
    static string BuildTemplate(Config c) {
        string pos = c.cover is { } cv ? $"state_attr('{cv}','current_position') | float(100)" : "100";
        string lights = c.lights is { } l ? $"is_state('{l}','on') | tojson" : "false | tojson";   // bare false renders as Python False
        string bri = c.lights is { } l2 ? $"state_attr('{l2}','brightness') | float(0)" : "0";
        string sat = c.lights is { } l3 ? $"(state_attr('{l3}','hs_color') or [0, 100])[1] | float(100)" : "100";
        string mons = string.Join(", ", c.monitors.Select(m =>
            $"[{{{{ states('{m.day}') | float(70) }}}}, {{{{ states('{m.blindDown}') | float(40) }}}}, {{{{ states('{m.night}') | float(20) }}}}]"));
        return $$$"""
            {"elev": {{ state_attr('{{{c.sun ?? "sun.sun"}}}','elevation') | float(-10) }},
             "pos": {{ {{{pos}}} }},
             "lights": {{ {{{lights}}} }},
             "auto": {{ is_state('{{{c.autoSwitch}}}','on') | tojson }},
             "m": [{{{mons}}}],
             "bri": {{ {{{bri}}} }},
             "sat": {{ {{{sat}}} }} }
            """;
    }
    static string? template;

    public static async Task<string?> Call(string path, object body) {
        var c = Config.Current;
        if (c == null) { LastError = Config.Error; return null; }
        if (Token == null) { LastError = "No Home Assistant token (right-click → Token)"; return null; }
        try {
            using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(new Uri(c.homeAssistantUrl), path)) {
                Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") };
            req.Headers.Authorization = new("Bearer", Token);
            using var r = await http.SendAsync(req);
            if ((int)r.StatusCode == 401) { LastError = "Home Assistant rejected the token (right-click → Token)"; return null; }
            if (!r.IsSuccessStatusCode) { LastError = $"Home Assistant answered {(int)r.StatusCode}"; return null; }
            LastError = null;
            return await r.Content.ReadAsStringAsync();
        } catch { LastError = "Cannot reach Home Assistant"; return null; }
    }
    public static async Task<HAState?> State() {
        if (Config.Current is not { } c) { LastError = Config.Error; return null; }
        template ??= BuildTemplate(c);
        var s = await Call("/api/template", new { template });
        if (s == null) return null;
        try {
            var st = JsonSerializer.Deserialize<HAState>(s);
            if (st == null || st.m == null || st.m.Length != c.monitors.Length || st.m.Any(v => v == null || v.Length != 3)) { LastError = "Unexpected answer from Home Assistant"; return null; }
            return st;
        } catch { LastError = "Unexpected answer from Home Assistant"; return null; }
    }
}

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

// MARK: small Windows helpers

static class Win {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint Size, Time; }
    [DllImport("user32")] static extern bool GetLastInputInfo(ref LASTINPUTINFO l);
    [DllImport("user32")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("dwmapi")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static double IdleSeconds() {
        var l = new LASTINPUTINFO { Size = 8 };
        return GetLastInputInfo(ref l) ? unchecked((uint)Environment.TickCount - l.Time) / 1000.0 : 0;
    }
    /// GDI name (\\.\DISPLAYn) of the screen holding the focused window.
    public static string? ForegroundScreen() => Ddc.DeviceOf(MonitorFromWindow(GetForegroundWindow(), 2 /* NEAREST */));
    public static void RoundCorners(IntPtr h) { int v = 2; DwmSetWindowAttribute(h, 33, ref v, 4); }

    public static bool StartsWithWindows {
        get => Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue("Daylit") != null;
        set {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue("Daylit", $"\"{Environment.ProcessPath}\""); else k.DeleteValue("Daylit", false);
        }
    }
}

static class Theme {
    const string Key = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    public static bool Dark => Registry.GetValue(Key, "AppsUseLightTheme", 1) is int i && i == 0;
    static bool DarkTaskbar => !(Registry.GetValue(Key, "SystemUsesLightTheme", 0) is int i && i == 1);
    public static Color Back => Dark ? Color.FromArgb(32, 32, 32) : Color.FromArgb(249, 249, 249);
    public static Color Fore => Dark ? Color.White : Color.FromArgb(26, 26, 26);
    public static Color Dim => Dark ? Color.FromArgb(160, 160, 160) : Color.FromArgb(96, 96, 96);
    public static Color Accent => Color.FromArgb(255, 176, 32);

    public static Icon SunIcon() {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var c = DarkTaskbar ? Color.White : Color.FromArgb(32, 32, 32);
            using var pen = new Pen(c, 2.6f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            using var br = new SolidBrush(c);
            g.FillEllipse(br, 10, 10, 12, 12);
            for (int i = 0; i < 8; i++) {
                double a = i * Math.PI / 4;
                g.DrawLine(pen, 16 + (float)Math.Cos(a) * 10, 16 + (float)Math.Sin(a) * 10, 16 + (float)Math.Cos(a) * 14, 16 + (float)Math.Sin(a) * 14);
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}

/// Light/dark mode from daylight and the room lights. (Warm screen is left to Windows Night Light.)
static class Look {
    const string Pers = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    [DllImport("user32", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageTimeoutW(IntPtr h, uint msg, IntPtr w, string l, uint flags, uint timeout, out IntPtr r);

    public static bool Enabled {
        get => Registry.CurrentUser.OpenSubKey(@"Software\Daylit")?.GetValue("AutoLook") is not int i || i == 1;
        set { using var k = Registry.CurrentUser.CreateSubKey(@"Software\Daylit"); k.SetValue("AutoLook", value ? 1 : 0, RegistryValueKind.DWord); }
    }

    public static void SetDark(bool dark) {
        SetWallpaper(dark);
        using var k = Registry.CurrentUser.CreateSubKey(Pers);
        int v = dark ? 0 : 1;
        if (k.GetValue("AppsUseLightTheme") is int a && a == v && k.GetValue("SystemUsesLightTheme") is int b && b == v) return;
        k.SetValue("AppsUseLightTheme", v, RegistryValueKind.DWord);
        k.SetValue("SystemUsesLightTheme", v, RegistryValueKind.DWord);
        SendMessageTimeoutW((IntPtr)0xFFFF, 0x1A /* WM_SETTINGCHANGE */, IntPtr.Zero, "ImmersiveColorSet", 2, 1000, out _);
    }

    // Windows 11's own bloom wallpapers: img0 is the light one, img19 the dark one.
    // Only swaps between those two, so a custom wallpaper is never replaced.
    static readonly string WallDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"Web\Wallpaper\Windows");
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern bool SystemParametersInfoW(uint action, uint param, string value, uint flags);
    static void SetWallpaper(bool dark) {
        string light = Path.Combine(WallDir, "img0.jpg"), darkImg = Path.Combine(WallDir, "img19.jpg");
        var cur = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop")?.GetValue("WallPaper") as string ?? "";
        bool isStock = cur.Equals(light, StringComparison.OrdinalIgnoreCase) || cur.Equals(darkImg, StringComparison.OrdinalIgnoreCase);
        string want = dark ? darkImg : light;
        if (!isStock || cur.Equals(want, StringComparison.OrdinalIgnoreCase) || !File.Exists(want)) return;
        SystemParametersInfoW(0x14 /* SPI_SETDESKWALLPAPER */, 0, want, 3 /* update ini + broadcast */);
    }
}

// MARK: app

sealed class App : ApplicationContext {
    public readonly List<Mon> Mons = (Config.Current?.monitors ?? Array.Empty<MonitorConfig>()).Select(s => new Mon(s)).ToList();
    public bool AutoOn = true;
    public string StatusText = Config.Error ?? "Connecting…";
    public bool HotkeysOk;
    readonly NotifyIcon tray;
    readonly PanelForm panel;
    readonly Osd osd = new();
    readonly HotkeyWindow keys;
    readonly System.Windows.Forms.Timer timer = new() { Interval = 5000 };
    DateTime panelHidden;
    bool busy, wasHere;

    public App() {
        panel = new PanelForm(this);
        panel.VisibleChanged += (_, _) => { if (!panel.Visible) panelHidden = DateTime.UtcNow; };
        var menu = new ContextMenuStrip();
        menu.Items.Add("Switch light / dark mode", null, (_, _) => ToggleDark());
        menu.Items.Add("Home Assistant token…", null, (_, _) => AskToken());
        menu.Items.Add("Quit", null, (_, _) => ExitThread());
        tray = new NotifyIcon { Icon = Theme.SunIcon(), Text = "Daylit", Visible = true, ContextMenuStrip = menu };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) TogglePanel(); };
        keys = new HotkeyWindow(Hotkey);
        HotkeysOk = keys.Ok;
        if (Config.Current is { } cfg) {
            HAClient.Token = Cred.Read(cfg.Token);
            if (HAClient.Token == null) AskToken();
        }
        timer.Tick += async (_, _) => await Tick();
        timer.Start();
        _ = Tick();
    }

    protected override void ExitThreadCore() {
        timer.Stop(); keys.Dispose(); tray.Visible = false; tray.Dispose();
        base.ExitThreadCore();
    }

    void AskToken() {
        if (Config.Current is not { } cfg) return;
        var t = TokenDialog.Ask(cfg.Token);
        if (t == null) return;
        Cred.Write(cfg.Token, "homeassistant", t);
        HAClient.Token = t;
        _ = Tick();
    }

    void TogglePanel() {
        if (panel.Visible) { panel.Hide(); return; }
        if ((DateTime.UtcNow - panelHidden).TotalMilliseconds < 300) return;   // this click just closed it
        panel.Sync();
        panel.ShowNear(Cursor.Position);
    }

    /// Ctrl+Alt+PageUp/PageDown: change the monitor holding the focused window. Shift = steps of 1.
    void Hotkey(bool up, bool fine) {
        var gdi = Win.ForegroundScreen();
        var m = Mons.FirstOrDefault(x => x.On && x.D!.Gdi == gdi) ?? Mons.FirstOrDefault(x => x.On);
        if (m == null) return;
        int v = Math.Clamp(m.Cur!.Value + (up ? 1 : -1) * (fine ? 1 : 6), 0, 100);
        m.Cur = v; m.WriteSoon(v);
        panel.Sync();
        osd.Flash(m.Spec.label, v, m.D!.Gdi);
    }

    public void UserSet(Mon m, int v) { m.Cur = v; m.WriteSoon(v); }

    public void SetAuto(bool on) {
        AutoOn = on;
        if (Config.Current is { } c) _ = HAClient.Call("/api/services/input_boolean/" + (on ? "turn_on" : "turn_off"), new { entity_id = c.autoSwitch });
        if (on) { foreach (var m in Mons) m.LastSet = null; _ = Tick(); }
    }

    static int Round(double v) => (int)Math.Round(v, MidpointRounding.AwayFromZero);

    // Light mode when daylight comes in (sun up, blind open) or the office lights are bright and white;
    // dark otherwise, including night with dim or orange lights. Each condition has a gap between its
    // on and off thresholds so it doesn't flip back and forth. Daylit only acts when the decision changes,
    // so a manual switch stays until the next change.
    bool? lookDark, daylight, whiteLights;
    public string LookText = "";
    void UpdateLook(HAState s) {
        if (!Look.Enabled) { lookDark = daylight = whiteLights = null; LookText = ""; return; }
        daylight = s.elev > 4 && s.pos >= 55 ? true : s.elev < 1 || s.pos <= 35 ? false : daylight ?? (s.elev > 3 && s.pos >= 50);
        // brightness 0-255; hs saturation 0 = white, ~60+ = warm orange
        bool lit = s.lights && s.bri > 0;
        whiteLights = lit && s.bri >= 200 && s.sat <= 35 ? true : !lit || s.bri < 170 || s.sat > 45 ? false : whiteLights ?? false;
        bool dark = !(daylight.Value || whiteLights.Value);
        if (dark != lookDark) {
            Look.SetDark(dark);
            lookDark = dark;
            tray.Icon = Theme.SunIcon();
        }
        LookText = dark ? "Dark mode" : whiteLights.Value && !daylight.Value ? "Light mode (white lights)" : "Light mode";
    }
    /// Manual switch; it stays until the automatic decision next changes.
    public void ToggleDark() {
        Look.SetDark(!Theme.Dark);
        tray.Icon = Theme.SunIcon();
        panel.Sync();
    }
    public void SetLook(bool on) { Look.Enabled = on; lookDark = null; _ = Tick(); }

    async Task Tick() {
        if (busy) return; busy = true;
        try {
            var displays = await Task.Run(Native.ActiveDisplays);
            foreach (var m in Mons) m.D = displays.FirstOrDefault(d => d.Friendly.Contains(m.Spec.match, StringComparison.OrdinalIgnoreCase));
            var cur = await Task.Run(() => Mons.Select(m => m.Read()).ToArray());
            for (int i = 0; i < Mons.Count; i++) Mons[i].Cur = cur[i];

            var s = await HAClient.State();
            if (s == null) { StatusText = HAClient.LastError ?? "Cannot reach Home Assistant"; return; }
            AutoOn = s.auto;
            UpdateLook(s);
            // Daytime value slides between "blind down" and "blind up" with the blind position;
            // the sun then blends it with the night value (0 below -3°, full daytime from 12°).
            double sun = Math.Clamp((s.elev + 3) / 15, 0, 1);
            int T(double[] v) {   // v = [day, blindDown, night]
                double daytime = v[1] + (v[0] - v[1]) * s.pos / 100;
                double x = v[2] + (daytime - v[2]) * sun;
                if (s.lights && sun < 0.3) x = Math.Max(x, v[2] + 5);
                return Round(Math.Clamp(x, 0, 100));
            }
            bool someoneHere = Win.IdleSeconds() < Config.PublishIdleSeconds;
            // Coming back to this PC: publish again even if nothing changed, in case another machine wrote meanwhile.
            if (someoneHere && !wasHere) foreach (var m in Mons) m.Published = null;
            wasHere = someoneHere;
            var notes = new List<string>();
            for (int i = 0; i < Mons.Count; i++) {
                var m = Mons[i];
                if (m.Cur is not int c) continue;
                int target = T(s.m[i]);
                int applied = c; bool manual = false;
                if (s.auto) {
                    bool handSet = m.LastSet != null && c != m.LastSet;
                    if (handSet && Math.Abs(target - (m.LastTarget ?? target)) < Config.Current!.Hold) {
                        manual = true;
                    } else {
                        if (c != target) await Task.Run(() => m.Write(target));
                        applied = target; m.Cur = target; m.LastSet = target; m.LastTarget = target;
                    }
                    notes.Add(manual ? "manual" : $"auto {target}%");
                }
                // A Mac on the same monitors publishes the same sensors; only the machine in use reports, so they don't overwrite each other.
                if (m.Published != applied && someoneHere) {
                    var ok = await HAClient.Call("/api/states/" + m.Spec.sensor, new {
                        state = applied,
                        attributes = new Dictionary<string, object> {
                            ["friendly_name"] = m.Spec.label + " brightness", ["unit_of_measurement"] = "%", ["icon"] = "mdi:monitor",
                            ["target"] = target, ["manual"] = manual, ["daylight"] = Math.Round(sun * 100) / 100,
                            ["sun_elevation"] = s.elev, ["blind"] = s.pos, ["lights"] = s.lights, ["source"] = "Windows" } });
                    if (ok != null) m.Published = applied;
                }
            }
            StatusText = (s.auto ? $"Sun {(int)(sun * 100)}% · blind {(int)s.pos}% · " + string.Join(" · ", notes) : "Automatic mode off")
                       + (LookText != "" ? "\n" + LookText : "");
        } finally {
            busy = false;
            var on = Mons.Where(m => m.On).Select(m => $"{m.Spec.label} {m.Cur}%");
            var tip = "Daylit · " + (on.Any() ? string.Join(" · ", on) : "no configured monitors");
            tray.Text = tip.Length > 127 ? tip[..127] : tip;
            if (panel.Visible) panel.Sync();
        }
    }
}

// MARK: UI

sealed class PanelForm : Form {
    readonly App app;
    readonly List<(Mon m, Panel row, Label value, TrackBar bar)> rows = new();
    readonly Label hint, status;
    readonly CheckBox auto, look, login;
    readonly Button modeBtn;
    bool? paintedDark;
    bool syncing;
    public bool Dragging;

    public PanelForm(App app) {
        this.app = app;
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        Font = new Font("Segoe UI", 9.75f); BackColor = Theme.Back; ForeColor = Theme.Fore;
        Padding = new Padding(14); AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
        const int W = 300;
        var flow = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true,
                                         AutoSizeMode = AutoSizeMode.GrowAndShrink, Location = new Point(14, 14), Margin = Padding.Empty };

        foreach (var m in app.Mons) {
            var row = new Panel { Size = new Size(W, 58), Margin = new Padding(0, 0, 0, 4) };
            var name = new Label { Text = "☀  " + m.Spec.label, AutoSize = true, Location = new Point(0, 2) };
            var value = new Label { Text = "–", AutoSize = false, Size = new Size(60, 20), Location = new Point(W - 60, 2), TextAlign = ContentAlignment.TopRight };
            var bar = new TrackBar { Minimum = 0, Maximum = 100, TickStyle = TickStyle.None, AutoSize = false, Size = new Size(W, 30),
                                     Location = new Point(0, 24), SmallChange = 1, LargeChange = 6, BackColor = Theme.Back };
            bar.Scroll += (_, _) => { value.Text = bar.Value + "%"; app.UserSet(m, bar.Value); };
            bar.MouseDown += (_, _) => Dragging = true;
            bar.MouseUp += (_, _) => Dragging = false;
            row.Controls.AddRange(new Control[] { name, value, bar });
            rows.Add((m, row, value, bar));
            flow.Controls.Add(row);
        }
        hint = new Label { Tag = "dim", AutoSize = true, MaximumSize = new Size(W, 0), ForeColor = Theme.Dim, Font = new Font("Segoe UI", 8.25f), Margin = new Padding(0, 0, 0, 8) };
        auto = new CheckBox { Text = "Automatic (sun, blind, lights)", AutoSize = true, Margin = new Padding(0, 0, 0, 2) };
        auto.CheckedChanged += (_, _) => { if (!syncing) app.SetAuto(auto.Checked); };
        look = new CheckBox { Text = "Dark mode from sun, blind and lights", AutoSize = true, Margin = new Padding(0, 0, 0, 2) };
        look.CheckedChanged += (_, _) => { if (!syncing) app.SetLook(look.Checked); };
        status = new Label { Tag = "dim", AutoSize = true, MaximumSize = new Size(W, 0), ForeColor = Theme.Dim, Font = new Font("Segoe UI", 8.25f), Margin = new Padding(0, 0, 0, 10) };
        var line = new Label { BorderStyle = BorderStyle.Fixed3D, Size = new Size(W, 2), Margin = new Padding(0, 0, 0, 8) };
        var bottom = new Panel { Size = new Size(W, 28), Margin = Padding.Empty };
        login = new CheckBox { Text = "Open at sign-in", AutoSize = true, Location = new Point(0, 3), Font = new Font("Segoe UI", 8.25f) };
        login.CheckedChanged += (_, _) => { if (!syncing) Win.StartsWithWindows = login.Checked; };
        var quit = new Button { Text = "Quit", Size = new Size(70, 26), Location = new Point(W - 70, 0), FlatStyle = FlatStyle.System };
        quit.Click += (_, _) => app.ExitThread();
        bottom.Controls.AddRange(new Control[] { login, quit });
        modeBtn = new Button { Size = new Size(W, 30), Margin = new Padding(0, 0, 0, 10), FlatStyle = FlatStyle.Flat };
        modeBtn.FlatAppearance.BorderColor = Theme.Dim;
        modeBtn.Click += (_, _) => app.ToggleDark();
        flow.Controls.AddRange(new Control[] { hint, auto, look, status, modeBtn, line, bottom });
        Controls.Add(flow);
        ResumeLayout(true);
        Deactivate += (_, _) => Hide();
    }

    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Win.RoundCorners(Handle); }

    public void Sync() {
        syncing = true;
        if (paintedDark != Theme.Dark) { Recolor(this); paintedDark = Theme.Dark; }
        modeBtn.Text = Theme.Dark ? "☀  Switch to light mode" : "☾  Switch to dark mode";
        bool any = false;
        foreach (var (m, row, value, bar) in rows) {
            row.Visible = m.On; any |= m.On;
            if (m.Cur is int c) { if (!Dragging) bar.Value = Math.Clamp(c, 0, 100); value.Text = c + "%"; }
        }
        hint.Text = !any ? "None of the configured monitors is connected to this PC."
                  : app.HotkeysOk ? "Ctrl+Alt+PgUp / PgDn: the screen with the active window · + Shift = fine steps"
                  : "Ctrl+Alt+PgUp/PgDn are taken by another app.";
        auto.Checked = app.AutoOn;
        look.Checked = Look.Enabled;
        status.Text = app.StatusText;
        login.Checked = Win.StartsWithWindows;
        syncing = false;
    }

    static void Recolor(Control c) {
        if (c is not Button) { c.BackColor = Theme.Back; c.ForeColor = c.Tag as string == "dim" ? Theme.Dim : Theme.Fore; }
        else { c.BackColor = Theme.Dark ? Color.FromArgb(50, 50, 50) : Color.FromArgb(232, 232, 232); c.ForeColor = Theme.Fore; }
        foreach (Control k in c.Controls) Recolor(k);
    }

    public void ShowNear(Point p) {
        var wa = Screen.FromPoint(p).WorkingArea;
        Show();   // size is known once shown (AutoSize)
        Location = new Point(wa.Right - Width - 12, wa.Bottom - Height - 12);
        Activate();
    }
}

/// On-screen indicator for hotkey changes, like the Mac HUD.
sealed class Osd : Form {
    string label = ""; int value;
    readonly System.Windows.Forms.Timer fade = new() { Interval = 30 };
    DateTime shownAt;

    public Osd() {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        BackColor = Theme.Back; DoubleBuffered = true;
        Size = new Size(LogicalToDeviceUnits(240), LogicalToDeviceUnits(68));
        fade.Tick += (_, _) => {
            if ((DateTime.UtcNow - shownAt).TotalMilliseconds < 1200) return;
            Opacity -= 0.1;
            if (Opacity <= 0.05) { fade.Stop(); Hide(); }
        };
    }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x80 | 0x08000000 | 0x20 | 0x8; return cp; }   // toolwindow, noactivate, click-through, topmost
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Win.RoundCorners(Handle); }

    public void Flash(string l, int v, string gdi) {
        label = l; value = v;
        var b = (Screen.AllScreens.FirstOrDefault(s => s.DeviceName == gdi) ?? Screen.PrimaryScreen!).Bounds;
        Location = new Point(b.Left + (b.Width - Width) / 2, b.Bottom - (int)(b.Height * 0.12) - Height);
        Opacity = 0.97; shownAt = DateTime.UtcNow;
        if (!Visible) Show();
        Invalidate(); fade.Start();
    }

    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int pad = LogicalToDeviceUnits(14);
        using var f = new Font("Segoe UI", 10.5f);
        using var fg = new SolidBrush(Theme.Fore);
        g.DrawString("☀  " + label, f, fg, pad, pad - 2);
        var pct = value + "%"; var sz = g.MeasureString(pct, f);
        g.DrawString(pct, f, fg, Width - pad - sz.Width, pad - 2);
        int barY = Height - pad - LogicalToDeviceUnits(6), barW = Width - 2 * pad, barH = LogicalToDeviceUnits(6);
        using var track = new SolidBrush(Theme.Dark ? Color.FromArgb(70, 70, 70) : Color.FromArgb(215, 215, 215));
        using var fill = new SolidBrush(Theme.Accent);
        Pill(g, track, pad, barY, barW, barH);
        if (value > 0) Pill(g, fill, pad, barY, Math.Max(barH, barW * value / 100), barH);
    }
    static void Pill(Graphics g, Brush b, int x, int y, int w, int h) {
        using var p = new GraphicsPath();
        p.AddArc(x, y, h, h, 90, 180); p.AddArc(x + w - h, y, h, h, 270, 180); p.CloseFigure();
        g.FillPath(b, p);
    }
}

sealed class HotkeyWindow : NativeWindow, IDisposable {
    [DllImport("user32")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const uint ALT = 1, CTRL = 2, SHIFT = 4, PGUP = 0x21, PGDN = 0x22;
    readonly Action<bool, bool> on;
    public readonly bool Ok;

    public HotkeyWindow(Action<bool, bool> on) {
        this.on = on;
        CreateHandle(new CreateParams { Parent = new IntPtr(-3) });   // message-only window
        Ok = RegisterHotKey(Handle, 1, CTRL | ALT, PGUP) & RegisterHotKey(Handle, 2, CTRL | ALT, PGDN)
           & RegisterHotKey(Handle, 3, CTRL | ALT | SHIFT, PGUP) & RegisterHotKey(Handle, 4, CTRL | ALT | SHIFT, PGDN);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) { int id = (int)m.WParam; on(id is 1 or 3, id >= 3); }
        base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i <= 4; i++) UnregisterHotKey(Handle, i); DestroyHandle(); }
}

static class TokenDialog {
    public static string? Ask(string target) {
        using var f = new Form { Text = "Daylit — Home Assistant token", FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterScreen,
                                 MinimizeBox = false, MaximizeBox = false, TopMost = true, Font = new Font("Segoe UI", 9.75f),
                                 AutoScaleDimensions = new SizeF(96F, 96F), AutoScaleMode = AutoScaleMode.Dpi, ClientSize = new Size(470, 140) };
        var l = new Label { Text = "Paste a Home Assistant long-lived access token (Profile → Security).\nIt is stored in Windows Credential Manager as \"" + target + "\".",
                            Location = new Point(12, 10), Size = new Size(446, 44) };
        var t = new TextBox { Location = new Point(12, 60), Width = 446, UseSystemPasswordChar = true };
        var ok = new Button { Text = "Save", DialogResult = DialogResult.OK, Location = new Point(302, 100), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(383, 100), Width = 75 };
        f.AcceptButton = ok; f.CancelButton = cancel;
        f.Controls.AddRange(new Control[] { l, t, ok, cancel });
        return f.ShowDialog() == DialogResult.OK && t.Text.Trim().Length > 0 ? t.Text.Trim() : null;
    }
}
