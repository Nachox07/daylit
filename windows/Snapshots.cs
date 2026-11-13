// UI snapshots for visual regression tests: the flyout and the on-screen indicator rendered offscreen
// from fixed, made-up state (no monitors, no Home Assistant), light and dark, at 2x.
//   Daylit.exe --render-snapshots <dir> | Out-String              write the PNGs
//   Daylit.exe --compare-snapshots <baseline> <dir> | Out-String  compare, write diff-*.png, exit 1 on a change
// The baselines live in windows/tests/Snapshots and are recorded on CI (see CONTRIBUTING.md).
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Daylit;

static class Snapshots {
    const double Scale = 2;

    public static int Render(string dir) {
        Directory.CreateDirectory(dir);
        var app = Application.Current ?? new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        string tmp = Path.Combine(Path.GetTempPath(), "daylit-snapshot-config.json");
        foreach (var dark in new[] { false, true }) {
            Theme.Force = dark;
#pragma warning disable WPF0001   // Fluent theme API is marked experimental
            app.ThemeMode = dark ? ThemeMode.Dark : ThemeMode.Light;
#pragma warning restore WPF0001
            string mode = dark ? "dark" : "light";
            foreach (var (name, json, mons, sync, subtitle) in Scenes()) {
                File.WriteAllText(tmp, json);
                var (cfg, _) = Config.Load(tmp);
                Settings.SyncOverride = sync;
                var list = mons();
                var controller = new Controller(cfg, list, subtitle);
                if (name.EndsWith("-partial")) controller.SnapshotLeave(list[^1]);   // the last monitor out of the group
                if (name == "panel-one-suggestion")   // made-up evidence, the same scene as the Mac's
                    controller.Suggestion = new Suggestion(list[0].Key, [new LevelChange(Level.BlindDown, 78, 61)], 14, true, 13, 5);
                if (name == "panel-update") {   // made-up release notes, the same scene as the Mac's
                    controller.Update = new UpdateCheck.Available("1.6.0", "https://github.com/Nachox07/daylit/releases/tag/v1.6.0",
                        ["Tell the user when a new version is out", "Mac: steadier DDC writes after wake", "Windows: Settings remembers its size"]);
                    controller.UpdateShown = controller.UpdateExpanded = true;
                }
                var flyout = new Flyout(controller);
                var root = (FrameworkElement)flyout.Content;
                flyout.Content = null;
                Save(Frame(root, 340, Palette.Solid, 8), Path.Combine(dir, $"{name}-{mode}.png"));
                flyout.Close();
            }
            File.WriteAllText(tmp, SettingsJson);
            SettingsWindow.FixedTokenStored = true;
            SettingsWindow.FixedNow = DateTimeOffset.FromUnixTimeSeconds(1_781_870_400);   // 2026-06-19 12:00 UTC
            foreach (var pane in new[] { "displays", "automatic", "homeAssistant", "appearance", "app" }) {
                var settings = new SettingsWindow(new Controller(Config.Load(tmp).cfg, [Fake("LG 27UP850", 72, hdr: true), Fake("Dell U2723QE", 48)], ""), tmp, pane);
                Save(Frame(settings.Detach(), 860, Palette.Solid, 8), Path.Combine(dir, $"settings-{pane.ToLowerInvariant()}-{mode}.png"));
                settings.Close();
            }
            foreach (var (name, chart) in ChartScenes())
                Save(Frame(chart(), 632, Palette.Solid, 0), Path.Combine(dir, $"{name}-{mode}.png"));
            var osd = new Osd();
            Save(Frame(osd.Detach("LG 27UP850", 72), 260, Brushes.Transparent, 0), Path.Combine(dir, $"osd-{mode}.png"));
            osd.Close();
        }
        File.Delete(tmp);
        return 0;
    }

    const string SettingsJson = """
        { "source": "homeAssistant", "location": { "latitude": 51.48, "longitude": 0.00 },
          "homeAssistant": { "url": "http://homeassistant.local:8123", "cover": "cover.office_blind", "lights": "light.office" },
          "monitors": [ { "match": "27UP850", "day": 75, "blindDown": 45, "night": 25 },
                        { "match": "U2723QE", "contrast": 60, "homeAssistant": { "day": "input_number.dell_day" } } ],
          "tuning": { "brightness": { "sunDay": 15 }, "theme": { "lightSunAbove": 6 } } }
        """;

    /// The brightness chart from fixed state: Greenwich (or 80°N), UTC, levels 90 / 70 / 45, a blind 40% open,
    /// clouds capping daylight at 80% and a hand-set +6, unless a scene says otherwise. The Mac draws the same scenes.
    static IEnumerable<(string name, Func<FrameworkElement> chart)> ChartScenes() {
        ChartMonitor[] mons = [new("a", "LG 27UP850", 90, 70, 45), new("b", "Dell U2723QE", 80, 60, 30)];
        var plusSix = new Dictionary<string, (int Value, double Weight)> { ["a"] = (6, 1) };
        var live = new LiveInputs(Pos: 40, Lights: false, Light: 0.8, Offsets: plusSix);
        static DateTimeOffset Date(string iso) => DateTimeOffset.Parse(iso, System.Globalization.CultureInfo.InvariantCulture);
        // At dusk: the first minute after noon the sun is 1° below the horizon, so the room lights count.
        var june = Date("2026-06-19T12:00:00Z");
        var dusk = Enumerable.Range(0, 12 * 60).Select(i => june.AddMinutes(i)).FirstOrDefault(t => Sun.Elevation(t, 51.48, 0) < -1, june);
        Func<FrameworkElement> Scene(DateTimeOffset now, double lat = 51.48, bool blind = true, LiveInputs? l = null) {
            var li = l ?? live;
            return () => new BrightnessChart(lat, 0, now, TimeZoneInfo.Utc, mons, blind, () => new Tuning(), () => li, (_, _) => { }) { Margin = new Thickness(16) };
        }
        yield return ("curve-today", Scene(Date("2026-06-19T15:00:00Z")));
        yield return ("curve-winter", Scene(Date("2026-12-21T12:00:00Z")));
        yield return ("curve-parked", Scene(Date("2026-12-21T12:00:00Z"), lat: 80));
        yield return ("curve-no-blind", Scene(Date("2026-06-19T15:00:00Z"), blind: false, l: new LiveInputs(Pos: null, Light: 0.8, Offsets: plusSix)));
        yield return ("curve-dusk", Scene(dusk, l: new LiveInputs(Pos: 0, Lights: true)));
        yield return ("curve-automatic-off", Scene(Date("2026-06-19T15:00:00Z"), l: new LiveInputs(Pos: 40, Light: 0.8, Applying: false, SetHelper: true)));
    }

    static Mon Fake(string label, int level, bool hdr = false, bool manual = false) =>
        new(new Display { Friendly = label, Gdi = @"\\.\DISPLAY" + label.Length, Hdr = hdr, DevicePath = "snapshot-" + label }, null) {
            Cur = level, Reads = ReadState.Readable, Manual = manual };

    static IEnumerable<(string name, string json, Func<List<Mon>> mons, bool sync, string subtitle)> Scenes() {
        const string sun = """{ "source": "sun", "location": { "latitude": 51.4769, "longitude": -0.0005 } }""";
        const string ha = """{ "source": "homeAssistant", "homeAssistant": { "url": "http://homeassistant.local:8123" } }""";
        List<Mon> Two() => new() { Fake("LG 27UP850", 72, hdr: true), Fake("Dell U2723QE", 48) };
        yield return ("panel-two", sun, Two, false, "Sun · 21.7° above the horizon");
        yield return ("panel-two-linked", sun, Two, true, "Sun · 21.7° above the horizon");
        yield return ("panel-three-linked", sun, () => [.. Two(), Fake("LG 27UK850", 60)], true, "Sun · 21.7° above the horizon");
        yield return ("panel-three-partial", sun, () => [.. Two(), Fake("LG 27UK850", 60)], true, "Sun · 21.7° above the horizon");
        yield return ("panel-one-manual", ha, () => new() { Fake("LG UltraFine 5K", 60, manual: true) }, false, "Home Assistant · sun 100% · blind 56%");
        yield return ("panel-one-suggestion", ha, () => new() { Fake("Monitor", 64) }, false, "Home Assistant · sun 100% · blind 35%");
        yield return ("panel-update", sun, Two, false, "Sun · 21.7° above the horizon");
        yield return ("panel-empty", "{}", () => new(), false, "");
    }

    /// The content on a fixed-width background, with the window's font and text colour.
    static FrameworkElement Frame(FrameworkElement content, double width, Brush background, double radius) {
        var b = new Border { Child = content, Width = width, Background = background, CornerRadius = new CornerRadius(radius),
                             BorderThickness = new Thickness(radius > 0 ? 1 : 0), BorderBrush = Palette.CardBorder };
        TextElement.SetFontFamily(b, Palette.Ui);
        TextElement.SetFontSize(b, 14);
        TextElement.SetForeground(b, Palette.Text);
        return b;
    }

    static void Save(FrameworkElement e, string file) {
        e.Measure(new Size(e.Width, double.PositiveInfinity));
        e.Arrange(new Rect(e.DesiredSize));
        e.UpdateLayout();
        var bmp = new RenderTargetBitmap((int)Math.Ceiling(e.ActualWidth * Scale), (int)Math.Ceiling(e.ActualHeight * Scale),
                                         96 * Scale, 96 * Scale, PixelFormats.Pbgra32);
        bmp.Render(e);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var f = File.Create(file);
        enc.Save(f);
        Console.Out.WriteLine(Path.GetFileName(file));
    }

    // MARK: compare

    /// A pixel counts as changed when any channel moves more than Channel; the image fails when more
    /// than Ratio of its pixels changed (anti-aliasing noise stays under both).
    const int Channel = 24;
    const double Ratio = 0.005;

    public static int Compare(string baseline, string current) {
        var names = Directory.Exists(current)
            ? Directory.GetFiles(current, "*.png").Select(Path.GetFileName).Where(n => !n!.StartsWith("diff-")).Order().ToList() : new();
        var base_ = Directory.Exists(baseline) ? Directory.GetFiles(baseline, "*.png").Select(Path.GetFileName).ToHashSet() : new();
        if (base_.Count == 0) { Console.Out.WriteLine($"No baselines in {baseline} yet: nothing to compare (record them, see CONTRIBUTING.md)."); return 0; }
        var failed = new List<string>();
        foreach (var n in names) {
            if (!base_.Contains(n)) { failed.Add($"{n}: new scene, no baseline"); continue; }
            var (aw, ah, a) = Pixels(Path.Combine(baseline, n!));
            var (bw, bh, b) = Pixels(Path.Combine(current, n!));
            if (aw != bw || ah != bh) { failed.Add($"{n}: size {aw}x{ah} → {bw}x{bh}"); continue; }
            var diff = new byte[b.Length];
            int changed = 0;
            for (int i = 0; i < a.Length; i += 4) {
                bool moved = false;
                for (int c = 0; c < 4; c++) if (Math.Abs(a[i + c] - b[i + c]) > Channel) { moved = true; break; }
                if (moved) { changed++; diff[i] = 0; diff[i + 1] = 0; diff[i + 2] = 255; diff[i + 3] = 255; }   // BGRA: red
                else { for (int c = 0; c < 3; c++) diff[i + c] = (byte)(b[i + c] / 4 + 191); diff[i + 3] = 255; }
            }
            double share = (double)changed / (aw * ah);
            if (share > Ratio) {
                failed.Add($"{n}: {share * 100:0.00}% of pixels changed");
                var img = BitmapSource.Create(bw, bh, 96, 96, PixelFormats.Bgra32, null, diff, bw * 4);
                var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(img));
                using var f = File.Create(Path.Combine(current, "diff-" + n));
                enc.Save(f);
            }
        }
        foreach (var n in base_.Except(names)) failed.Add($"{n}: baseline has no current render (scene removed?)");
        if (failed.Count == 0) { Console.Out.WriteLine($"Snapshots match the baselines ({names.Count} images)."); return 0; }
        Console.Out.WriteLine("UI snapshots differ from windows/tests/Snapshots:");
        foreach (var f in failed) Console.Out.WriteLine("  " + f);
        Console.Out.WriteLine("If the change is intended, re-record the baselines: Actions → build → Run workflow → record snapshots, then commit the downloaded images (CONTRIBUTING.md).");
        return 1;
    }

    static (int w, int h, byte[] px) Pixels(string file) {
        using var s = File.OpenRead(file);
        var frame = BitmapDecoder.Create(s, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        var conv = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
        var px = new byte[conv.PixelWidth * conv.PixelHeight * 4];
        conv.CopyPixels(px, conv.PixelWidth * 4, 0);
        return (conv.PixelWidth, conv.PixelHeight, px);
    }
}
