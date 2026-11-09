// Monitor detection and brightness control.
//  - HDR on:  Windows "SDR content brightness" (many monitors ignore DDC brightness while HDR is on).
//  - HDR off: DDC/CI brightness (VCP 0x10).
using System.Runtime.InteropServices;

namespace Daylit;

/// One active display path, as Windows sees it (DisplayConfig API).
sealed class Display {
    public string Friendly = "", Gdi = "", DevicePath = "";
    public bool Hdr, Internal;
    internal Native.LUID Adapter;
    internal uint TargetId;
    /// Stable across reboots: the monitor's device path (adapter LUIDs change at every boot), so saved
    /// sync offsets and hand-set levels find the same monitor again.
    public string Key => DevicePath != "" ? DevicePath : $"{Adapter.Hi}:{Adapter.Lo}:{TargetId}";
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
    // Output technologies of built-in panels: INTERNAL, DISPLAYPORT_EMBEDDED, UDI_EMBEDDED.
    static bool IsInternal(int tech) => tech == unchecked((int)0x80000000) || tech == 11 || tech == 13;

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
            list.Add(new Display { Friendly = DisplayName.Label(tn.Friendly, list.Count), Gdi = sn.Gdi ?? "", DevicePath = tn.Path ?? "", Adapter = p.Tgt.Adapter, TargetId = p.Tgt.Id,
                                   Internal = IsInternal(p.Tgt.Tech) || IsInternal(tn.Tech),
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
    /// True when Windows accepted the change.
    public static bool SetSdr(Display d, int v) {
        var w = new WhiteSet { H = H<WhiteSet>(SET_SDR_WHITE, d.Adapter, d.TargetId), Level = (uint)(1000 + Math.Clamp(v, 0, 100) * 50), Final = 1 };
        return Set(ref w) == 0;
    }
}

/// DDC/CI brightness through the Monitor Configuration API. All calls are serialised; they are slow.
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
        GetVCPFeatureAndVCPFeatureReply(h, 0x10, IntPtr.Zero, out uint c, out uint m) && m > 0 && c <= m ? (int)Math.Round(c * 100.0 / m) : null, null);
    /// True when the monitor acknowledged the write. Without a readable maximum, 100 is assumed (the usual VCP 0x10 range).
    public static bool Set(string gdi, int v, byte code = Brightness) => With(gdi, h => {
        uint m = GetVCPFeatureAndVCPFeatureReply(h, code, IntPtr.Zero, out _, out uint max) && max > 0 ? max : 100;
        return SetVCPFeature(h, code, (uint)Math.Round(v * m / 100.0));
    }, false);
    public const byte Brightness = 0x10, Contrast = 0x12;
}

/// A detected external monitor plus its settings from config.json (if any entry matches).
sealed class Mon {
    public Display D;
    public MonitorConfig? Spec;
    public int? Cur, LastSet, LastTarget, Published;
    public int? Offset; public double? OffsetSun, OffsetAt;   // a hand-set level as a distance from the target (Rules.Decide)
    public bool PublishedManual;                // the manual flag last sent to Home Assistant
    public int? PublishedLight;                 // and the sky's clearness, in tenths
    public bool Dragging;                       // its panel slider is held with the mouse
    public bool Touched;                        // moved with the slider or keys since the last tick
    public double? RemoteSeen;                 // last_changed of the HA "set" helper already acted on
    public double? RemoteValue;                // its value then
    public bool Manual;                        // automatic mode is holding a hand-set value
    public DateTime UserTouched;               // last slider / hotkey change; ticks leave the slider alone just after
    public ReadState Reads = ReadState.Unknown; // DDC only: does it report its level (Rules.cs)
    public bool WriteFailing;                  // the last automatic write was refused (logged once, retried each tick)
    public int? ContrastSet;                    // contrast written since the last display change, wake or reload (ContrastRule)
    /// A DDC monitor that has not reported its level yet can still be tried with the slider.
    public bool Untried => !D.Hdr && Reads == ReadState.Unknown && Cur == null;
    public bool Usable => (Cur != null || Untried) && Reads.Usable();
    // Slider and hotkey values: the newest one waiting, and whether a write is under way. One write at a time,
    // always the newest value, so the screen follows a drag as fast as DDC allows.
    readonly object writeLock = new();
    int? want; bool writing;

    public Mon(Display d, MonitorConfig? spec) { D = d; Spec = spec; }
    public string Key => D.Key;
    public string Label => !string.IsNullOrWhiteSpace(Spec?.Label) ? Spec!.Label! : D.Friendly != "" ? D.Friendly : D.Gdi.Replace(@"\\.\", "");
    public bool On => Cur != null;
    public double[]? HaLevels;                 // last [day, blindDown, night] from Home Assistant, for the sun fallback
    public double Day => Spec?.Day ?? Config.DefaultDay;
    public double BlindDown => Spec?.BlindDown ?? Config.DefaultBlindDown;
    public double Night => Spec?.Night ?? Config.DefaultNight;

    public int? Read() => D.Hdr ? Native.GetSdr(D) : Ddc.Get(D.Gdi);
    /// An automatic level; false when the monitor did not take it.
    public bool Write(int v) => D.Hdr ? Native.SetSdr(D, v) : Ddc.Set(D.Gdi, v);
    /// For sliders and hotkeys: HDR applies at once; DDC is slow, so a value that arrives during a write waits
    /// for it and only the newest waiting value is sent.
    public void WriteSoon(int v) {
        var d = D;
        if (d.Hdr) { Native.SetSdr(d, v); return; }
        var ui = SynchronizationContext.Current;   // the answer is recorded on the UI thread
        lock (writeLock) { want = v; if (writing) return; writing = true; }
        Task.Run(() => {
            while (true) {
                int x;
                lock (writeLock) { if (want is not int w) { writing = false; return; } x = w; want = null; }
                bool ok = Ddc.Set(d.Gdi, x);
                if (ui != null) ui.Post(_ => Record(ok), null); else Record(ok);
            }
        });
        void Record(bool ok) {
            var after = Reads.AfterUserWrite(ok);
            if (after == Reads) return;
            Reads = after;
            Log.Write(after == ReadState.WriteOnly ? $"display: {Label} accepts brightness but doesn't report it (write-only)"
                                                   : $"display: {Label} did not accept a brightness change");
        }
    }

    public static MonitorConfig? Match(Display d, MonitorConfig[]? specs) =>
        specs?.FirstOrDefault(s => s.Match is { } m && d.Friendly.Contains(m.Trim(), StringComparison.OrdinalIgnoreCase));
}
