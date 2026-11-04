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
    readonly TextBox haUrl = new(), cover = new(), lights = new(), autoSwitch = new(), sun = new();
    readonly Button test = new() { Content = "Test connection" };
    CheckBox? lookBox;
    readonly StackPanel monitors = new();
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    readonly List<(Mon mon, TextBox label, Slider day, Slider blind, Slider night, TextBlock now, TextBlock caption, bool haLevels)> rows = new();
    string? opened;

    static readonly (string tag, string text, string hint)[] Sources = [
        ("off", "Nothing (sliders only)", "Sliders and keyboard shortcuts only."),
        ("sun", "The sun", "Brighter by day, dimmer at night, from your location."),
        ("homeAssistant", "Home Assistant", "The sun, a blind and the room lights from Home Assistant. With a location, the sun takes over when Home Assistant is down."),
    ];

    readonly string path;
    /// Snapshots: a fixed time, so "Sun now" and the previews do not change between runs.
    public static DateTimeOffset? FixedNow;

    /// `path` is the config file to edit; snapshots pass a made-up one.
    public SettingsWindow(Controller app, string? path = null, string? pane = null) {
        this.app = app;
        this.path = path ?? Config.PathName;
        Title = "Daylit settings";
        Width = 860; Height = 620; MinWidth = 700; MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Palette.Ui; FontSize = 14;

        foreach (var s in Sources) source.Items.Add(new ComboBoxItem { Content = s.text, Tag = s.tag });
        source.SelectionChanged += (_, _) => SourceChanged();
        lat.TextChanged += (_, _) => Refresh(); lon.TextChanged += (_, _) => Refresh();
        locate.Click += async (_, _) => await Locate();
        test.Click += async (_, _) => await Test();

        // Panes, one per sidebar entry, the same as on the Mac: Displays, Automatic, Home Assistant, App.
        var displaysPane = Pane(monitors);
        var automaticPane = Pane(Card(null, Field("Brightness follows", source), sourceHint),
            Card("Location", Field("Latitude", lat, "51.48"), Field("Longitude", lon, "0.00"), Row(locate, sunNow),
                 Hint("City level is enough. Daylit saves two decimals (about 1 km) and computes the sun on this PC.")),
            brightnessCard = Card("When the screens brighten", dayCurve,
                 Hint("Drag a line: full daytime brightness above the orange one, night brightness below the purple one, a blend in between."),
                 new Expander { Header = "Exact values", Margin = new Thickness(0, 8, 0, 0),
                                Content = TuningRows(TuningField.Tuning.Where(f => f.Group == "brightness")) }));
        var token = new Button { Content = "Token…", Margin = new Thickness(8, 0, 0, 0) };
        token.Click += (_, _) => AskToken();
        var haPane = Pane(Card("Connection", Field("URL", haUrl, "http://homeassistant.local:8123"), Row(test, token)),
            Card("Room", Field("Blind", cover, "cover.office_blind"), Field("Lights", lights, "light.office"),
                 Field("Automatic switch", autoSwitch, "input_boolean.daylit_auto"), Field("Sun", sun, "sun.sun"),
                 Hint("All optional. Entity ids as shown in Home Assistant → Settings → Entities. Per-monitor helpers stay in the config file.")));
        var look = new CheckBox { Content = "Light or dark mode from daylight", IsChecked = Settings.AutoLook, Margin = new Thickness(0, 2, 0, 2) };
        look.Click += (_, _) => app.SetLook(look.IsChecked == true);
        var pause = new CheckBox { Content = "Pause on battery", IsChecked = app.PauseOnBattery, Margin = new Thickness(0, 2, 0, 2),
                                   Visibility = Win.HasBattery ? Visibility.Visible : Visibility.Collapsed };
        pause.Click += (_, _) => app.SetPause(pause.IsChecked == true);
        var login = new CheckBox { Content = "Open at sign-in", IsChecked = Win.StartsWithWindows, Margin = new Thickness(0, 2, 0, 2) };
        login.Click += (_, _) => Win.StartsWithWindows = login.IsChecked == true;
        lookBox = look;
        var openFile = new Button { Content = "Open config file" };
        openFile.Click += (_, _) => app.OpenConfig();
        roomBox.Click += (_, _) => RefreshTuningRows();
        var appearancePane = Pane(Card(null, look, roomBox,
                Hint("Windows has no automatic light/dark mode of its own; this follows the sun, and with Home Assistant your blind and lights.")),
            Card("Today's sun", themeCurve, Hint("Drag a line: light mode once the sun is above the orange one, dark below the purple one. Times are for today.")),
            Card(null, new Expander { Header = "Exact values", Content = TuningRows(TuningField.Appearance) }));
        var appPane = Pane(Card(null, pause, login, Hint("These apply right away.")),
            Card("Advanced", Row(openFile, Hint(Config.DisplayPath)), Hint("Everything in this window is saved there; other keys are kept. How often Daylit checks, when it counts as idle and how long hand-set levels survive a restart are under \"tuning\" → \"timing\" in the file.")));

        panes.Add(("displays", "Displays", "\uE7F4", Color.FromRgb(0x2B, 0x88, 0xD8), displaysPane));
        panes.Add(("automatic", "Automatic", "\uE706", Color.FromRgb(0xF7, 0x8C, 0x1E), automaticPane));
        panes.Add(("homeAssistant", "Home Assistant", "ha", Color.FromRgb(0x18, 0xBC, 0xF2), haPane));
        panes.Add(("appearance", "Appearance", "\uE771", Color.FromRgb(0x6E, 0x5B, 0xD6), appearancePane));
        panes.Add(("app", "App", "\uE713", Color.FromRgb(0x8A, 0x8A, 0x8A), appPane));
        foreach (var p in panes) {
            var item = new ListBoxItem { Tag = p.key, Padding = new Thickness(10, 8, 10, 8), Content = new StackPanel {
                Orientation = Orientation.Horizontal, Children = {
                    p.glyph == "ha"
                        ? new Viewbox { Width = 17, Height = 17, Margin = new Thickness(0, 0, 11, 0), VerticalAlignment = VerticalAlignment.Center,
                                        Child = new System.Windows.Shapes.Path { Data = HaLogo, Fill = new SolidColorBrush(p.color) } }
                        : new TextBlock { Text = p.glyph, FontFamily = Palette.Icons, FontSize = 16, Foreground = new SolidColorBrush(p.color),
                                          VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) },
                    new TextBlock { Text = p.title, VerticalAlignment = VerticalAlignment.Center } } } };
            System.Windows.Automation.AutomationProperties.SetName(item, p.title);
            nav.Items.Add(item);
        }
        nav.ItemContainerStyle = NavItemStyle();
        nav.SelectionChanged += (_, _) => ShowPane();

        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 90, Margin = new Thickness(8, 0, 0, 0), Style = AccentStyle() };
        save.Click += (_, _) => Save();
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Margin = new Thickness(8, 0, 0, 0) };
        cancel.Click += (_, _) => Close();
        var footer = new Grid { Margin = new Thickness(32, 12, 32, 16) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Children = { cancel, save } };
        Grid.SetColumn(buttons, 1);
        footer.Children.Add(status); footer.Children.Add(buttons);

        var right = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom); DockPanel.SetDock(paneTitle, Dock.Top);
        right.Children.Add(footer); right.Children.Add(paneTitle); right.Children.Add(paneHost);
        var sidebar = new Border { Child = nav, Padding = new Thickness(8, 16, 8, 8), Width = 220 };
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(right, 1);
        root.Children.Add(sidebar); root.Children.Add(right);
        Content = root;
        Load();
        nav.SelectedIndex = Math.Max(0, panes.FindIndex(p => p.key == (pane ?? "displays")));
    }

    readonly ListBox nav = new() { BorderThickness = new Thickness(0), Background = Brushes.Transparent };
    readonly ContentControl paneHost = new();
    readonly TextBlock paneTitle = new() { FontSize = 24, FontWeight = FontWeights.SemiBold, Margin = new Thickness(32, 20, 32, 8) };
    readonly List<(string key, string title, string glyph, Color color, FrameworkElement content)> panes = new();

    /// Windows 11 Settings style: a soft highlight and a short accent bar on the selected item, no solid block.
    static Style NavItemStyle() {
        var accent = Palette.Accent is SolidColorBrush a ? a.Color : Colors.DodgerBlue;
        string hover = Palette.Dark ? "#0FFFFFFF" : "#0A000000", selected = Palette.Dark ? "#15FFFFFF" : "#0F000000";
        return (Style)System.Windows.Markup.XamlReader.Parse($$"""
            <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ListBoxItem">
              <Setter Property="Margin" Value="0,1"/>
              <Setter Property="Template">
                <Setter.Value>
                  <ControlTemplate TargetType="ListBoxItem">
                    <Grid>
                      <Border x:Name="bg" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" CornerRadius="4" Background="Transparent" Padding="{TemplateBinding Padding}">
                        <ContentPresenter VerticalAlignment="Center"/>
                      </Border>
                      <Border x:Name="pill" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="3" Height="16" CornerRadius="1.5" HorizontalAlignment="Left"
                              Background="#{{accent.R:X2}}{{accent.G:X2}}{{accent.B:X2}}" Visibility="Collapsed"/>
                    </Grid>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="{{hover}}"/></Trigger>
                      <Trigger Property="IsSelected" Value="True">
                        <Setter TargetName="bg" Property="Background" Value="{{selected}}"/>
                        <Setter TargetName="pill" Property="Visibility" Value="Visible"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Setter.Value>
              </Setter>
            </Style>
            """);
    }

    /// The Home Assistant logo, from Material Design Icons (mdi:home-assistant, Apache-2.0). The name and logo
    /// are trademarks of the Open Home Foundation; Daylit uses them only to name what it connects to.
    static readonly Geometry HaLogo = Geometry.Parse("M21.8,13H20V21H13V17.67L15.79,14.88L16.5,15C17.66,15 18.6,14.06 18.6,12.9C18.6,11.74 17.66,10.8 16.5,10.8A2.1,2.1 0 0,0 14.4,12.9L14.5,13.61L13,15.13V9.65C13.66,9.29 14.1,8.6 14.1,7.8A2.1,2.1 0 0,0 12,5.7A2.1,2.1 0 0,0 9.9,7.8C9.9,8.6 10.34,9.29 11,9.65V15.13L9.5,13.61L9.6,12.9A2.1,2.1 0 0,0 7.5,10.8A2.1,2.1 0 0,0 5.4,12.9A2.1,2.1 0 0,0 7.5,15L8.21,14.88L11,17.67V21H4V13H2.25C1.83,13 1.42,13 1.42,12.79C1.43,12.57 1.85,12.15 2.28,11.72L11,3C11.33,2.67 11.67,2.33 12,2.33C12.33,2.33 12.67,2.67 13,3L17,7V6H19V9L21.78,11.78C22.18,12.18 22.59,12.59 22.6,12.8C22.6,13 22.2,13 21.8,13M7.5,12A0.9,0.9 0 0,1 8.4,12.9A0.9,0.9 0 0,1 7.5,13.8A0.9,0.9 0 0,1 6.6,12.9A0.9,0.9 0 0,1 7.5,12M16.5,12C17,12 17.4,12.4 17.4,12.9C17.4,13.4 17,13.8 16.5,13.8A0.9,0.9 0 0,1 15.6,12.9A0.9,0.9 0 0,1 16.5,12M12,6.9C12.5,6.9 12.9,7.3 12.9,7.8C12.9,8.3 12.5,8.7 12,8.7C11.5,8.7 11.1,8.3 11.1,7.8C11.1,7.3 11.5,6.9 12,6.9Z");

    static FrameworkElement Pane(params UIElement[] children) {
        var stack = new StackPanel { Margin = new Thickness(32, 4, 32, 8) };
        foreach (var c in children) stack.Children.Add(c);
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    void ShowPane() {
        if (nav.SelectedItem is not ListBoxItem { Tag: string key }) return;
        var p = panes.First(x => x.key == key);
        paneTitle.Text = p.title;
        paneHost.Content = p.content;
    }

    readonly ContentControl themeCurve = new(), dayCurve = new();

    /// The value a tuning field has in the window: what is typed, or its default.
    double TuneValue(string id) =>
        tuneRows.TryGetValue(id, out var r) && Num(r.box.Text) is double v ? v : TuningField.All.First(f => f.Id == id).Default;

    /// A dragged line stops half a degree short of its partner: full day stays above night, light above dark.
    double KeepOrder(string id, double v0) {
        double v = Math.Clamp(v0, -18, id == "brightness.sunNight" ? 30 : 60);   // the ranges tuning accepts
        return id switch {
            "brightness.sunDay" => Math.Max(v, TuneValue("brightness.sunNight") + 0.5),
            "brightness.sunNight" => Math.Min(v, TuneValue("brightness.sunDay") - 0.5),
            "theme.lightSunAbove" => Math.Max(v, TuneValue("theme.darkSunBelow")),
            "theme.darkSunBelow" => Math.Min(v, TuneValue("theme.lightSunAbove")),
            _ => v,
        };
    }

    /// Today's sun pictures; a hint instead without a location.
    void RebuildCurves() {
        if (Coords is not var (la, lo)) {
            themeCurve.Content = Hint("Set a location (Automatic) to see today's sun.");
            dayCurve.Content = Hint("Set a location (Automatic) to see today's sun.");
            return;
        }
        var tz = FixedNow != null ? TimeZoneInfo.Utc : TimeZoneInfo.Local;
        var when = FixedNow ?? DateTimeOffset.Now;
        void Set(string id, double v) { if (tuneRows.TryGetValue(id, out var r)) r.box.Text = Fmt(KeepOrder(id, v)); }
        Color orange = Color.FromRgb(0xF7, 0x8C, 0x1E), purple = Color.FromRgb(0x6E, 0x5B, 0xD6);
        themeCurve.Content = new SunCurve(la, lo, when, tz,
            [new("theme.lightSunAbove", "Light", orange, false), new("theme.darkSunBelow", "Dark", purple, true)], TuneValue, Set);
        var first = rows.FirstOrDefault();
        dayCurve.Content = new SunCurve(la, lo, when, tz,
            [new("brightness.sunDay", "Full day", orange, false), new("brightness.sunNight", "Night", purple, true)], TuneValue, Set,
            first.mon == null ? null : e => {
                double night = TuneValue("brightness.sunNight"), day = TuneValue("brightness.sunDay");
                double sun = Math.Clamp((e - night) / (day - night), 0, 1);
                return Rules.Target([first.day.Value, first.blind.Value, first.night.Value], 100, false, sun, app.Cfg.Tuned, false);
            },
            first.mon == null ? "" : $"{first.label.Text} through the day, blind open");
    }

    readonly CheckBox roomBox = new() { Content = "Count the blind and the room lights", Margin = new Thickness(0, 2, 0, 2) };
    readonly Dictionary<string, (FrameworkElement row, TextBox box)> tuneRows = new();
    Dictionary<string, double> loadedTune = new();
    FrameworkElement? brightnessCard;

    /// One row per number: label, a box that shows the default in grey while empty, the unit.
    /// Empty means the default; Reset clears them all.
    FrameworkElement TuningRows(IEnumerable<TuningField> fields) {
        var list = fields.ToList();
        var stack = new StackPanel();
        foreach (var f in list) {
            var box = new TextBox { TextAlignment = TextAlignment.Right };
            var hint = new TextBlock { Text = Fmt(f.Default), Opacity = 0.45, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Right,
                                       VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
            box.TextChanged += (_, _) => {
                hint.Visibility = box.Text == "" ? Visibility.Visible : Visibility.Collapsed;
                (themeCurve.Content as UIElement)?.InvalidateVisual(); (dayCurve.Content as UIElement)?.InvalidateVisual();
            };
            System.Windows.Automation.AutomationProperties.SetName(box, f.Label);
            System.Windows.Automation.AutomationProperties.SetHelpText(box, $"Default {Fmt(f.Default)}{f.Unit}");
            var cell = new Grid { Width = 90, Children = { box, hint } };
            var g = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56) });
            var label = new TextBlock { Text = f.Label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 12, 0) };
            var unit = new TextBlock { Text = f.Unit, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.75, Margin = new Thickness(8, 0, 0, 0) };
            Grid.SetColumn(cell, 1); Grid.SetColumn(unit, 2);
            g.Children.Add(label); g.Children.Add(cell); g.Children.Add(unit);
            tuneRows[f.Id] = (g, box);
            stack.Children.Add(g);
        }
        var reset = new Button { Content = "Reset to defaults", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        reset.Click += (_, _) => {
            foreach (var f in list) tuneRows[f.Id].box.Text = "";
            if (list.Any(f => f.Group == "theme")) { roomBox.IsChecked = true; RefreshTuningRows(); }
        };
        stack.Children.Add(Hint("Empty boxes use the default, shown in grey. Saved in config.json under \"tuning\"."));
        stack.Children.Add(reset);
        return stack;
    }

    static string Fmt(double v) => v.ToString("0.##", CultureInfo.InvariantCulture);

    /// The blind and lights thresholds matter only with Home Assistant and "count the blind and lights" on.
    void RefreshTuningRows() {
        bool ha = SourceTag == "homeAssistant", room = ha && roomBox.IsChecked == true;
        roomBox.Visibility = ha ? Visibility.Visible : Visibility.Collapsed;
        if (brightnessCard != null) brightnessCard.Visibility = SourceTag == "off" ? Visibility.Collapsed : Visibility.Visible;
        foreach (var f in TuningField.Appearance)
            if (tuneRows.TryGetValue(f.Id, out var r))
                r.row.Visibility = room || f.Key is "lightSunAbove" or "darkSunBelow" ? Visibility.Visible : Visibility.Collapsed;
    }

    /// Snapshots: the window's content, to render offscreen.
    public FrameworkElement Detach() { var c = (FrameworkElement)Content; Content = null; return c; }

    // MARK: layout helpers

    static TextBlock Hint(string t) => new() { Text = t, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75, Margin = new Thickness(0, 4, 0, 0) };

    static Style? AccentStyle() => Application.Current?.TryFindResource("AccentButtonStyle") as Style;

    static FrameworkElement Card(string? title, params UIElement[] children) {
        var stack = new StackPanel();
        foreach (var c in children) stack.Children.Add(c);
        var card = new Border { Child = stack, CornerRadius = new CornerRadius(8), Padding = new Thickness(16, 12, 16, 12),
                                BorderThickness = new Thickness(1), Background = Palette.Card, BorderBrush = Palette.CardBorder };
        var outer = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
        if (title != null) {
            var head = new TextBlock { FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 0, 0, 8) };
            if (title.Length > 2 && title[0] >= '\uE000' && title[0] <= '\uF8FF') {   // a Segoe Fluent glyph, then the text
                head.Inlines.Add(new Run(title[0].ToString()) { FontFamily = Palette.Icons, FontWeight = FontWeights.Normal });
                head.Inlines.Add(new Run(title[1..]));
            } else head.Text = title;
            outer.Children.Add(head);
        }
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
        try { opened = File.Exists(path) ? File.ReadAllText(path) : null; } catch { opened = null; }
        var (c, _) = Config.Load(path);
        string tag = c.Source?.Trim() is { Length: > 0 } s ? s
                   : c.Effective == Source.HomeAssistant ? "homeAssistant" : c.Effective == Source.Sun ? "sun" : "off";
        source.SelectedIndex = Math.Max(0, Array.FindIndex(Sources, x => string.Equals(x.tag, tag, StringComparison.OrdinalIgnoreCase)));
        lat.Text = c.Location?.Latitude.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        lon.Text = c.Location?.Longitude.ToString("0.00", CultureInfo.InvariantCulture) ?? "";
        var h = c.HomeAssistant;
        haUrl.Text = h?.Url ?? ""; cover.Text = h?.Cover ?? ""; lights.Text = h?.Lights ?? ""; autoSwitch.Text = h?.AutoSwitch ?? ""; sun.Text = h?.Sun ?? "";
        var set = TuningField.SetValues(c.Tuning);
        loadedTune = set;
        foreach (var (id, r) in tuneRows) r.box.Text = set.TryGetValue(id, out var v) ? Fmt(v) : "";
        roomBox.IsChecked = c.Tuning?.Theme?.Room ?? true;

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
            var now = new TextBlock { FontSize = 20, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
            Typography.SetNumeralAlignment(now, FontNumeralAlignment.Tabular);
            var nowRow = new Grid { Margin = new Thickness(0, 6, 0, 0) };
            nowRow.ColumnDefinitions.Add(new ColumnDefinition());
            nowRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(now, 1);
            nowRow.Children.Add(new TextBlock { Text = "Right now", VerticalAlignment = VerticalAlignment.Center }); nowRow.Children.Add(now);
            rows.Add((m, label, day, blind, night, now, caption, haLevels));
            monitors.Children.Add(Card("\uE7F4  " + m.D.Friendly, Field("Name", label), Level("Day", day), Level("Blind closed", blind), Level("Night", night), nowRow, caption));
        }
        status.Text = opened != null && ConfigPatch.HasComments(opened) ? "Saving removes the comments in config.json." : "";
        status.Foreground = Palette.Secondary;
        SourceChanged();
    }

    void SourceChanged() {
        sourceHint.Text = Sources.FirstOrDefault(s => s.tag == SourceTag).hint ?? "";
        // The Home Assistant pane is listed only for that source.
        foreach (ListBoxItem item in nav.Items)
            if (item.Tag as string == "homeAssistant") item.Visibility = SourceTag == "homeAssistant" ? Visibility.Visible : Visibility.Collapsed;
        if (SourceTag != "homeAssistant" && (nav.SelectedItem as ListBoxItem)?.Tag as string == "homeAssistant") nav.SelectedIndex = 1;
        if (lookBox != null) lookBox.IsEnabled = SourceTag != "off";
        RefreshTuningRows();
        Refresh();
    }

    static double? Num(string s) => double.TryParse(s.Trim().Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;

    (double lat, double lon)? Coords =>
        Num(lat.Text) is double a && Num(lon.Text) is double b && a is >= -90 and <= 90 && b is >= -180 and <= 180 ? (a, b) : null;

    /// The level each monitor would have right now with the blind open and the lights off: a preview only.
    void Refresh() {
        RebuildCurves();
        double? elev = Coords is var (a, b) ? Daylit.Sun.Elevation(FixedNow ?? DateTimeOffset.UtcNow, a, b) : null;
        sunNow.Text = elev is double e ? $"Sun now {e:0.0}°" : "";
        foreach (var r in rows) {
            r.now.Text = elev is double el ? $"{Rules.Target([r.day.Value, r.blind.Value, r.night.Value], 100, false, app.Cfg.Tuned.Fraction(el), app.Cfg.Tuned)}%" : "–";
            var text = elev == null ? "Set a location to see the level right now." : "Right now is a preview with the blind open; nothing changes until you save.";
            if (r.haLevels) text += " Home Assistant helpers set these levels; these apply only when it cannot be reached.";
            r.caption.Text = text;
        }
    }

    void Say(string text, bool problem) {
        status.Text = text;
        status.Foreground = problem ? Palette.Error : Palette.Secondary;
    }

    // MARK: actions

    void Save() {
        bool blank = lat.Text.Trim() == "" && lon.Text.Trim() == "";
        if (!blank && Coords == null) { Say("Latitude is −90 to 90 and longitude −180 to 180, like 51.48 and 0.00.", true); return; }
        if (SourceTag == "sun" && Coords == null) { Say("The sun needs a location: type it or use Locate me.", true); return; }
        if (SourceTag == "homeAssistant" && haUrl.Text.Trim() == "") { Say("Home Assistant needs its URL.", true); return; }
        var values = new Dictionary<string, double>();
        foreach (var f in TuningField.All) {
            if (!tuneRows.TryGetValue(f.Id, out var r)) {   // not in the window (timing): keep what the file has
                if (loadedTune.TryGetValue(f.Id, out var kept)) values[f.Id] = kept;
                continue;
            }
            string text = r.box.Text.Trim();
            if (text == "") continue;
            if (Num(text) is not double v) { Say($"{f.Label} {f.Unit}: \"{text}\" is not a number.", true); return; }
            values[f.Id] = v;
        }
        var edit = new SettingsEdit(SourceTag, Coords?.lat, Coords?.lon,
            rows.Select(r => new SettingsEdit.Monitor(r.mon.D.Friendly, ConfigPatch.SuggestMatch(r.mon.D.Friendly), r.label.Text,
                                                      (int)r.day.Value, (int)r.blind.Value, (int)r.night.Value)).ToList(),
            haUrl.Text, autoSwitch.Text, sun.Text, cover.Text, lights.Text, values, roomBox.IsChecked == true);
        try {
            string? now = File.Exists(path) ? File.ReadAllText(path) : null;
            if (now != opened) {
                Load();
                Say("config.json changed while this window was open. It now shows the new file; check it and save again.", true);
                return;
            }
            var text = ConfigPatch.Apply(edit, now);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, text);
            File.Move(tmp, path, overwrite: true);
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
        string answer;
        try {
            using var p = Process.Start(new ProcessStartInfo("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script]) {
                RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(30));   // one limit for the whole request
            try {
                var output = p.StandardOutput.ReadToEndAsync(limit.Token);
                await p.WaitForExitAsync(limit.Token);
                answer = (await output).Trim();
            } catch (OperationCanceledException) {
                try { p.Kill(entireProcessTree: true); } catch { }
                answer = "unknown";
            }
        } catch (Exception e) { Log.Write("locate: " + e.Message); answer = "unknown"; }
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
        var (c, _) = Config.Load(path);
        var t = TokenDialog.Ask(c.TokenName);
        if (t == null) return;
        if (Cred.Write(c.TokenName, "homeassistant", t)) { HAClient.Token = t; Say("Token saved.", false); }
        else Say("Windows could not save the token in Credential Manager.", true);
    }

    /// Checks the URL and the stored token, then that each entity typed here exists.
    async Task Test() {
        var ids = new[] { cover.Text, lights.Text, autoSwitch.Text, sun.Text }.Select(s => s.Trim()).Where(s => s != "").ToList();
        if (ids.FirstOrDefault(s => !Config.IsEntityId(s)) is { } bad) { Say($"\"{bad}\" is not an entity id like light.office.", true); return; }
        var (c, _) = Config.Load(path);
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
