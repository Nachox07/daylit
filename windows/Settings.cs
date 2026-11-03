// The settings window: source, location, levels per monitor and Home Assistant, saved into
// config.json without touching anything else in it (ConfigPatch). Same fields as the Mac one.
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace Daylit;

sealed class SettingsWindow : Window {
    static SettingsWindow? open;

    /// Opens the window, or brings the open one forward.
    public static void Open(Controller app) {
        if (open != null) { open.Activate(); return; }
        open = new SettingsWindow(app);
        open.Closed += (_, _) => open = null;
        open.Show();
        open.Activate();
    }

    readonly Controller app;
    readonly ComboBox source = new() { MinWidth = 220 };
    readonly TextBlock sourceHint = Hint("");
    readonly TextBox lat = new(), lon = new();
    readonly TextBlock sunNow = Hint("");
    readonly Button locate = new() { Content = "Locate me" };
    readonly StackPanel haSection = new();
    readonly TextBox haUrl = new(), cover = new(), lights = new(), autoSwitch = new(), sun = new();
    readonly Button test = new() { Content = "Test connection" };
    readonly StackPanel monitors = new();
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    readonly List<(Mon mon, TextBox label, Slider day, Slider blind, Slider night, TextBlock caption, bool haLevels)> rows = new();
    string? opened;

    static readonly (string tag, string text, string hint)[] Sources = [
        ("off", "Nothing (sliders only)", "Sliders and keyboard shortcuts only."),
        ("sun", "The sun", "Brighter by day, dimmer at night, from your location."),
        ("homeAssistant", "Home Assistant", "The sun, a blind and the room lights from Home Assistant. With a location, the sun takes over when Home Assistant is down."),
    ];

    SettingsWindow(Controller app) {
        this.app = app;
        Title = "Daylit settings";
        Width = 520; Height = 700; MinWidth = 440; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Palette.Ui; FontSize = 14;

        foreach (var s in Sources) source.Items.Add(new ComboBoxItem { Content = s.text, Tag = s.tag });
        source.SelectionChanged += (_, _) => SourceChanged();
        lat.TextChanged += (_, _) => Refresh(); lon.TextChanged += (_, _) => Refresh();
        locate.Click += async (_, _) => await Locate();
        test.Click += async (_, _) => await Test();

        var body = new StackPanel { Margin = new Thickness(24, 20, 24, 8) };
        body.Children.Add(Card(null, Field("Brightness follows", source), sourceHint));
        body.Children.Add(Card("Location", Field("Latitude", lat, "36.72"), Field("Longitude", lon, "-4.42"),
            Row(locate, sunNow),
            Hint("City level is enough. Daylit saves two decimals (about 1 km) and computes the sun on this PC.")));
        var token = new Button { Content = "Token…", Margin = new Thickness(8, 0, 0, 0) };
        token.Click += (_, _) => AskToken();
        haSection.Children.Add(Card("Home Assistant", Field("URL", haUrl, "http://homeassistant.local:8123"), Row(test, token),
            Field("Blind (optional)", cover, "cover.office_blind"), Field("Lights (optional)", lights, "light.office"),
            Field("Automatic switch (optional)", autoSwitch, "input_boolean.daylit_auto"), Field("Sun (optional)", sun, "sun.sun"),
            Hint("Entity ids, as shown in Home Assistant → Settings → Entities. Per-monitor helpers stay in the config file.")));
        body.Children.Add(haSection);
        body.Children.Add(monitors);

        var openFile = new Button { Content = "Open config file" };
        openFile.Click += (_, _) => app.OpenConfig();
        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 90, Margin = new Thickness(8, 0, 0, 0), Style = AccentStyle() };
        save.Click += (_, _) => Save();
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Margin = new Thickness(8, 0, 0, 0) };
        cancel.Click += (_, _) => Close();
        var footer = new Grid { Margin = new Thickness(24, 12, 24, 16) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Children = { openFile, cancel, save } };
        Grid.SetColumn(buttons, 1);
        footer.Children.Add(status); footer.Children.Add(buttons);

        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = root;
        Load();
    }

    // MARK: layout helpers

    static TextBlock Hint(string t) => new() { Text = t, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75, Margin = new Thickness(0, 4, 0, 0) };

    static Style? AccentStyle() => Application.Current?.TryFindResource("AccentButtonStyle") as Style;

    static FrameworkElement Card(string? title, params UIElement[] children) {
        var stack = new StackPanel();
        foreach (var c in children) stack.Children.Add(c);
        var card = new Border { Child = stack, CornerRadius = new CornerRadius(8), Padding = new Thickness(16, 12, 16, 12),
                                BorderThickness = new Thickness(1), Background = Palette.Card, BorderBrush = Palette.CardBorder };
        var outer = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
        if (title != null) outer.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 0, 0, 8) });
        outer.Children.Add(card);
        return outer;
    }

    static FrameworkElement Field(string label, Control input, string? placeholder = null) {
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        if (input is TextBox t && placeholder != null) {
            t.ToolTip = "For example " + placeholder;
            System.Windows.Automation.AutomationProperties.SetHelpText(t, "For example " + placeholder);
        }
        System.Windows.Automation.AutomationProperties.SetName(input, label);
        input.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(input, 1);
        g.Children.Add(l); g.Children.Add(input);
        return g;
    }

    static FrameworkElement Row(UIElement left, UIElement right) {
        var g = new Grid { Margin = new Thickness(0, 6, 0, 2) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        if (right is FrameworkElement f) { f.VerticalAlignment = VerticalAlignment.Center; f.Margin = new Thickness(12, 0, 0, 0); }
        Grid.SetColumn(right, 1);
        g.Children.Add(left); g.Children.Add(right);
        return g;
    }

    FrameworkElement Level(string title, Slider s) {
        var pct = new TextBlock { MinWidth = 44, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.75 };
        Typography.SetNumeralAlignment(pct, FontNumeralAlignment.Tabular);
        s.Minimum = 0; s.Maximum = 100; s.SmallChange = 1; s.LargeChange = 10; s.IsSnapToTickEnabled = true; s.TickFrequency = 1;
        s.VerticalAlignment = VerticalAlignment.Center; s.Margin = new Thickness(0, 0, 8, 0);
        System.Windows.Automation.AutomationProperties.SetName(s, title);
        s.ValueChanged += (_, _) => { pct.Text = $"{(int)s.Value}%"; Refresh(); };
        pct.Text = $"{(int)s.Value}%";
        var g = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(s, 1); Grid.SetColumn(pct, 2);
        g.Children.Add(l); g.Children.Add(s); g.Children.Add(pct);
        return g;
    }

    // MARK: state

    string SourceTag => (source.SelectedItem as ComboBoxItem)?.Tag as string ?? "off";

    void Load() {
        try { opened = File.Exists(Config.PathName) ? File.ReadAllText(Config.PathName) : null; } catch { opened = null; }
        var (c, _) = Config.Load();
        string tag = c.Source?.Trim() is { Length: > 0 } s ? s
                   : c.Effective == Source.HomeAssistant ? "homeAssistant" : c.Effective == Source.Sun ? "sun" : "off";
        source.SelectedIndex = Math.Max(0, Array.FindIndex(Sources, x => string.Equals(x.tag, tag, StringComparison.OrdinalIgnoreCase)));
        lat.Text = c.Location?.Latitude.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        lon.Text = c.Location?.Longitude.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        var h = c.HomeAssistant;
        haUrl.Text = h?.Url ?? ""; cover.Text = h?.Cover ?? ""; lights.Text = h?.Lights ?? ""; autoSwitch.Text = h?.AutoSwitch ?? ""; sun.Text = h?.Sun ?? "";

        monitors.Children.Clear(); rows.Clear();
        var external = app.Mons.Where(m => !m.D.Internal).ToList();
        if (external.Count == 0) monitors.Children.Add(Card("Monitors", new TextBlock { Text = "No external monitor connected. Plug one in to set its levels.", TextWrapping = TextWrapping.Wrap, Opacity = 0.75 }));
        foreach (var m in external) {
            var spec = Mon.Match(m.D, c.Monitors);
            var label = new TextBox { Text = !string.IsNullOrWhiteSpace(spec?.Label) ? spec!.Label! : m.D.Friendly };
            var day = new Slider { Value = spec?.Day ?? Config.DefaultDay };
            var blind = new Slider { Value = spec?.BlindDown ?? Config.DefaultBlindDown };
            var night = new Slider { Value = spec?.Night ?? Config.DefaultNight };
            var caption = Hint("");
            bool haLevels = spec?.HomeAssistant is { } mh && (mh.Day != null || mh.BlindDown != null || mh.Night != null);
            rows.Add((m, label, day, blind, night, caption, haLevels));
            monitors.Children.Add(Card(m.D.Friendly, Field("Name", label), Level("Day", day), Level("Blind closed", blind), Level("Night", night), caption));
        }
        status.Text = "";
        SourceChanged();
    }

    void SourceChanged() {
        sourceHint.Text = Sources.FirstOrDefault(s => s.tag == SourceTag).hint ?? "";
        haSection.Visibility = SourceTag == "homeAssistant" ? Visibility.Visible : Visibility.Collapsed;
        Refresh();
    }

    static double? Num(string s) => double.TryParse(s.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    (double lat, double lon)? Coords =>
        Num(lat.Text) is double a && Num(lon.Text) is double b && a is >= -90 and <= 90 && b is >= -180 and <= 180 ? (a, b) : null;

    /// The level each monitor would have right now with the blind open and the lights off: a preview only.
    void Refresh() {
        double? elev = Coords is var (a, b) ? Daylit.Sun.Elevation(DateTimeOffset.UtcNow, a, b) : null;
        sunNow.Text = elev is double e ? $"Sun now {e:0.0}°" : "";
        foreach (var r in rows) {
            var parts = new List<string>();
            if (elev is double el)
                parts.Add($"Right now: {Rules.Target([r.day.Value, r.blind.Value, r.night.Value], 100, false, Daylit.Sun.Fraction(el))}% with the blind open.");
            if (r.haLevels) parts.Add("Home Assistant helpers set these levels; these apply only when it cannot be reached.");
            r.caption.Text = parts.Count > 0 ? string.Join(" ", parts) : "Day with the blind open, day with it closed, and night.";
        }
    }

    void Say(string text, bool problem) {
        status.Text = text;
        status.Foreground = problem ? Palette.Error : Palette.Secondary;
    }

    // MARK: actions

    void Save() {
        bool blank = lat.Text.Trim() == "" && lon.Text.Trim() == "";
        if (!blank && Coords == null) { Say("Latitude is −90 to 90 and longitude −180 to 180, like 36.72 and -4.42.", true); return; }
        if (SourceTag == "sun" && Coords == null) { Say("The sun needs a location: type it or use Locate me.", true); return; }
        if (SourceTag == "homeAssistant" && haUrl.Text.Trim() == "") { Say("Home Assistant needs its URL.", true); return; }
        var edit = new SettingsEdit(SourceTag, Coords?.lat, Coords?.lon,
            rows.Select(r => new SettingsEdit.Monitor(r.mon.D.Friendly, ConfigPatch.SuggestMatch(r.mon.D.Friendly), r.label.Text,
                                                      (int)r.day.Value, (int)r.blind.Value, (int)r.night.Value)).ToList(),
            haUrl.Text, autoSwitch.Text, sun.Text, cover.Text, lights.Text);
        try {
            string? now = File.Exists(Config.PathName) ? File.ReadAllText(Config.PathName) : null;
            if (now != opened) {
                Load();
                Say("config.json changed while this window was open. It now shows the new file; check it and save again.", true);
                return;
            }
            var text = ConfigPatch.Apply(edit, now);
            Directory.CreateDirectory(Config.Dir);
            string tmp = Config.PathName + ".tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, Config.PathName, overwrite: true);
            Log.Write($"settings: saved config.json (source={edit.Source})");
            app.Reload();
            Close();
        } catch (InvalidDataException e) {
            Say(e.Message, true);
        } catch (Exception e) {
            Say("config.json could not be read or saved: " + e.Message, true);
        }
    }

    /// One position request through the Windows location service (System.Device in Windows PowerShell),
    /// so the app needs no WinRT runtime. Nothing is tracked; the result is rounded to two decimals.
    async Task Locate() {
        locate.IsEnabled = false; Say("Looking for your location…", false);
        const string script = """
            Add-Type -AssemblyName System.Device
            $w = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::Default)
            if (-not $w.TryStart($false, [TimeSpan]::FromSeconds(10))) { 'off'; exit }
            $end = (Get-Date).AddSeconds(15)
            while ($w.Status -ne 'Ready' -and $w.Permission -ne 'Denied' -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 200 }
            if ($w.Permission -eq 'Denied') { 'denied'; exit }
            $c = $w.Position.Location
            if ($c.IsUnknown) { 'unknown' } else { [string]::Format([cultureinfo]::InvariantCulture, '{0:F2},{1:F2}', $c.Latitude, $c.Longitude) }
            """;
        string answer = await Task.Run(() => {
            try {
                var p = Process.Start(new ProcessStartInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script]) {
                    RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
                string o = p.StandardOutput.ReadToEnd();
                if (!p.WaitForExit(30_000)) { try { p.Kill(); } catch { } return "unknown"; }
                return o.Trim();
            } catch (Exception e) { Log.Write("locate: " + e.Message); return "unknown"; }
        });
        locate.IsEnabled = true;
        var parts = answer.Split(',');
        if (parts.Length == 2 && Num(parts[0]) is double a && Num(parts[1]) is double b) {
            lat.Text = a.ToString("0.00", CultureInfo.InvariantCulture); lon.Text = b.ToString("0.00", CultureInfo.InvariantCulture);
            Say("Location found.", false);
        } else if (answer is "denied" or "off") {
            Say("Location is off for desktop apps. Turn it on in Settings → Privacy & security → Location, or type the coordinates.", true);
        } else {
            Say("Could not find your location. Type the coordinates instead.", true);
        }
    }

    void AskToken() {
        var (c, _) = Config.Load();
        var t = TokenDialog.Ask(c.TokenName);
        if (t == null) return;
        if (Cred.Write(c.TokenName, "homeassistant", t)) { HAClient.Token = t; Say("Token saved.", false); }
        else Say("Windows could not save the token in Credential Manager.", true);
    }

    /// Checks the URL and the stored token, then that each entity typed here exists.
    async Task Test() {
        var ids = new[] { cover.Text, lights.Text, autoSwitch.Text, sun.Text }.Select(s => s.Trim()).Where(s => s != "").ToList();
        if (ids.FirstOrDefault(s => !Config.IsEntityId(s)) is { } bad) { Say($"\"{bad}\" is not an entity id like light.office.", true); return; }
        var (c, _) = Config.Load();
        var probe = new Config { HomeAssistant = new HaConfig { Url = haUrl.Text.Trim(), TokenName = c.HomeAssistant?.TokenName } };
        HAClient.Token ??= Cred.Read(probe.TokenName);
        string template = ids.Count == 0 ? "ok" : string.Join(" ", ids.Select(id => $"{{{{ '{id}' if states('{id}') in ['unknown', 'unavailable'] else '' }}}}"));
        test.IsEnabled = false; Say("Testing…", false);
        var answer = await HAClient.Call(probe, "/api/template", new { template });
        test.IsEnabled = true;
        if (answer == null) { Say((HAClient.LastError ?? "Cannot reach Home Assistant") + (HAClient.LastCause != null ? $" ({HAClient.LastCause})" : ""), true); return; }
        var missing = answer.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(s => s != "ok").ToList();
        if (missing.Count == 0) Say("Connected to Home Assistant.", false);
        else Say("Connected, but not found or unavailable: " + string.Join(", ", missing), true);
    }
}
