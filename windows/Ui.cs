// The tray flyout, the on-screen indicator, the token prompt and the global hotkeys.
// WPF with the Fluent theme (Application.ThemeMode) for the controls; the flyout gets the Mica Alt
// backdrop on Windows 11 22H2+ (with transparency effects on) and a solid colour elsewhere.
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.Win32;
using WF = System.Windows.Forms;
using WI = System.Windows.Input;

namespace Daylit;

/// Colours not covered by the Fluent control styles, following the system light/dark setting.
static class Palette {
    static SolidColorBrush B(uint argb) { var b = new SolidColorBrush(Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb)); b.Freeze(); return b; }
    public static bool Dark => Theme.Dark;
    public static Brush Text => Dark ? B(0xFFFFFFFF) : B(0xE4000000);
    public static Brush Secondary => Dark ? B(0xC5FFFFFF) : B(0x9E000000);
    public static Brush Card => Dark ? B(0x0DFFFFFF) : B(0xB3FFFFFF);
    public static Brush CardBorder => Dark ? B(0x19000000) : B(0x0F000000);
    public static Brush Solid => Dark ? B(0xFF2C2C2C) : B(0xFFF3F3F3);
    public static Brush Osd => Dark ? B(0xF02C2C2C) : B(0xF5F9F9F9);
    public static Brush Track => Dark ? B(0x8BFFFFFF) : B(0x72000000);
    public static Brush Error => Dark ? B(0xFFFF99A4) : B(0xFFC42B1C);
    /// The Windows accent colour (DWM stores it as ABGR).
    public static Brush Accent {
        get {
            if (Theme.Force == null && Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor", null) is int abgr) {
                uint v = unchecked((uint)abgr);
                var b = new SolidColorBrush(Color.FromRgb((byte)v, (byte)(v >> 8), (byte)(v >> 16))); b.Freeze(); return b;
            }
            return Dark ? B(0xFF4CC2FF) : B(0xFF005FB8);
        }
    }
    public static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    public static readonly FontFamily Ui = new("Segoe UI Variable Text, Segoe UI");
    public const string Monitor = "", SunLow = "", SunHigh = "", Gear = "";
}

sealed class Flyout : Window {
    readonly Controller app;
    readonly StackPanel rows = new();
    readonly TextBlock offHint, autoSub, error;
    readonly CheckBox auto;
    readonly Grid autoRow;
    readonly Border suggestCard;      // a change of levels Daylit noticed (Suggest.cs), shown only while one is pending
    readonly TextBlock suggestText;
    readonly List<Border> cards = new();
    readonly List<(Mon m, Slider s, TextBlock pct, TextBlock note, Border card, Button member)> rowViews = new();
    Button? link;
    IntPtr hwnd;
    bool syncing;

    public Flyout(Controller app) {
        this.app = app;
        Title = "Daylit";
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; Topmost = true;
        Width = 340; SizeToContent = SizeToContent.Height;
        Left = -32000; Top = -32000;   // first shown off-screen, then moved next to the tray in pixels
        FontFamily = Palette.Ui; FontSize = 14;
        // A frameless window that still gets the DWM shadow, rounded corners and backdrop.
        WindowChrome.SetWindowChrome(this, new WindowChrome {
            CaptionHeight = 0, GlassFrameThickness = new Thickness(-1), ResizeBorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false });

        // Daily controls only: the monitors and Automatic. Everything set once lives in the gear menu.
        var root = new StackPanel { Margin = new Thickness(16, 14, 16, 16) };

        var header = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        link = LinkButton();
        Grid.SetColumn(link, 1);
        header.Children.Add(link);
        header.Children.Add(new TextBlock { Text = "Daylit", FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var gear = new Button { Content = new TextBlock { Text = Palette.Gear, FontFamily = Palette.Icons, FontSize = 14 },
                                Padding = new Thickness(8, 6, 8, 6), ToolTip = "Settings" };
        System.Windows.Automation.AutomationProperties.SetName(gear, "Settings");
        gear.Click += (_, _) => GearMenu(gear);
        Grid.SetColumn(gear, 2);
        header.Children.Add(gear);
        root.Children.Add(header);

        root.Children.Add(rows);

        offHint = Small("Set a location or Home Assistant in the config file (gear menu) for automatic brightness.");
        offHint.Margin = new Thickness(2, 4, 2, 0);
        root.Children.Add(offHint);

        // "Automatic": a label, a one-line caption with what it is following, and a switch on the right.
        autoRow = new Grid { Margin = new Thickness(2, 4, 0, 0) };
        autoRow.ColumnDefinitions.Add(new ColumnDefinition());
        autoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        autoSub = Small("");
        autoSub.TextWrapping = TextWrapping.NoWrap; autoSub.TextTrimming = TextTrimming.CharacterEllipsis;
        var autoText = new StackPanel { VerticalAlignment = VerticalAlignment.Center,
                                        Children = { new TextBlock { Text = "Automatic", FontWeight = FontWeights.SemiBold }, autoSub } };
        auto = new CheckBox { Style = SwitchStyle.Value, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        System.Windows.Automation.AutomationProperties.SetName(auto, "Automatic brightness");
        // Checked/Unchecked, not Click: UI Automation (Narrator, Voice Access, agents) toggles without a click.
        OnToggle(auto, on => app.SetAuto(on));
        auto.Checked += (_, _) => PaintSwitch(auto); auto.Unchecked += (_, _) => PaintSwitch(auto);
        Grid.SetColumn(auto, 1);
        autoRow.Children.Add(autoText); autoRow.Children.Add(auto);
        root.Children.Add(autoRow);

        // A change of levels Daylit noticed from repeated hand changes (Suggest.cs). Nothing changes without Apply.
        suggestText = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        var apply = new Button { Content = "Apply", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 8, 0),
                                 ToolTip = "Set the new level. A level from Home Assistant changes there; otherwise in config.json." };
        apply.Click += (_, _) => app.ApplySuggestion();
        var notNow = new Button { Content = "Not now", Padding = new Thickness(12, 4, 12, 4), ToolTip = "No suggestion for this monitor for 7 days" };
        notNow.Click += (_, _) => app.DismissSuggestion();
        suggestCard = Card(new StackPanel { Children = { suggestText, new StackPanel { Orientation = Orientation.Horizontal, Children = { apply, notNow } } } });
        suggestCard.Margin = new Thickness(0, 12, 0, 0);
        suggestCard.Visibility = Visibility.Collapsed;
        root.Children.Add(suggestCard);

        error = Small(""); error.Margin = new Thickness(2, 10, 2, 0);
        root.Children.Add(error);

        Content = root;
        SourceInitialized += (_, _) => { hwnd = new WindowInteropHelper(this).Handle; ApplyTheme(); };
        Deactivated += (_, _) => Hide();
        SizeChanged += (_, _) => { if (IsVisible) PlaceAtTray(); };   // grows with the monitor list
        ApplyTheme();
        Rebuild();
    }

    /// A Windows 11-style switch for a CheckBox (WPF's Fluent theme has no ToggleSwitch). Its colours
    /// come from Background / BorderBrush / Foreground, set by PaintSwitch from our palette.
    static readonly Lazy<Style> SwitchStyle = new(() => (Style)System.Windows.Markup.XamlReader.Parse("""
        <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="CheckBox">
          <Setter Property="Cursor" Value="Hand"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="CheckBox">
                <Grid Background="Transparent">
                  <Border Width="40" Height="20" CornerRadius="10" BorderThickness="1"
                          BorderBrush="{TemplateBinding BorderBrush}" Background="{TemplateBinding Background}"/>
                  <Ellipse x:Name="Knob" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="12" Height="12" HorizontalAlignment="Left"
                           Margin="5,0,0,0" Fill="{TemplateBinding Foreground}"/>
                </Grid>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="Knob" Property="Margin" Value="23,0,0,0"/>
                  </Trigger>
                  <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Opacity" Value="0.5"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
        """));

    static void PaintSwitch(CheckBox c) {
        bool on = c.IsChecked == true;
        c.Background = on ? Palette.Accent : Brushes.Transparent;
        c.BorderBrush = on ? Palette.Accent : Palette.Secondary;
        c.Foreground = on ? Brushes.White : Palette.Secondary;
    }

    static TextBlock Small(string t) => new() { Text = t, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Palette.Secondary, Tag = "secondary" };

    Border Card(UIElement child) {
        var b = new Border { Child = child, CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 10, 12, 10),
                             BorderThickness = new Thickness(1), Background = Palette.Card, BorderBrush = Palette.CardBorder };
        cards.Add(b);
        return b;
    }

    void OnToggle(CheckBox c, Action<bool> set) {
        c.Checked += (_, _) => { if (!syncing) set(true); };
        c.Unchecked += (_, _) => { if (!syncing) set(false); };
    }

    void GearMenu(Button anchor) {
        var m = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        MenuItem Item(string text, Action a) { var i = new MenuItem { Header = text }; i.Click += (_, _) => a(); return i; }
        MenuItem Check(string text, bool on, Action<bool> set) {
            var i = new MenuItem { Header = text, IsCheckable = true, IsChecked = on };
            i.Click += (_, _) => set(i.IsChecked);
            return i;
        }
        m.Items.Add(Item("Settings…", app.ShowSettings));
        m.Items.Add(new Separator());
        m.Items.Add(Item(Theme.Dark ? "Switch to light mode" : "Switch to dark mode", app.ToggleDark));
        var look = Check("Light or dark mode from daylight", Settings.AutoLook, app.SetLook);
        look.IsEnabled = app.Source != Source.Off;
        m.Items.Add(look);
        if (Win.HasBattery) m.Items.Add(Check("Pause on battery", app.PauseOnBattery, app.SetPause));
        m.Items.Add(Check("Open at sign-in", Win.StartsWithWindows, on => Win.StartsWithWindows = on));
        m.Items.Add(new Separator());
        m.Items.Add(Item("Keyboard shortcuts…", app.EditShortcuts));
        if (app.Source == Source.HomeAssistant) m.Items.Add(Item("Home Assistant token…", app.AskToken));
        m.Items.Add(Item("Open config file", app.OpenConfig));
        m.Items.Add(Item("Reload config", app.Reload));
        m.Items.Add(new Separator());
        m.Items.Add(Item("Quit Daylit", app.Quit));
        m.IsOpen = true;
    }

    /// The round link button in the header next to the gear: one switch for every monitor, however many there are.
    Button LinkButton() {
        var b = new Button {
            Width = 26, Height = 26, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center,
            Content = new TextBlock { Text = "", FontFamily = Palette.Icons, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        b.Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
              <Border CornerRadius="13" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </ControlTemplate>
            """);
        b.Cursor = WI.Cursors.Hand;
        b.Click += (_, _) => app.SetSync(!Settings.SyncMonitors || !app.SyncAll);   // a partial group: link them all
        System.Windows.Automation.AutomationProperties.SetName(b, "Sync monitors");
        return b;
    }

    void StyleLink() {
        if (link == null) return;
        bool on = Settings.SyncMonitors, all = app.SyncAll, many = app.Mons.Count > 2;
        link.Visibility = app.Mons.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        // Filled: all linked. Accent outline: some taken out of the group. Plain: off.
        link.Background = on && all ? Palette.Accent : Brushes.Transparent;
        link.BorderBrush = on ? Palette.Accent : Brushes.Transparent;
        link.Foreground = on && all ? Brushes.White : on ? Palette.Accent : Palette.Secondary;
        link.ToolTip = !on ? "Link monitors: brightness changes apply to every monitor, keeping how much brighter each one is."
                     : all ? "Monitors linked. Click to unlink." + (many ? " The link on each monitor takes it out of the group." : "")
                     : "Some monitors linked. Click to link them all.";
        System.Windows.Automation.AutomationProperties.SetHelpText(link, !on ? "Off" : all ? "On" : "Some");
        foreach (var r in rowViews) {
            bool member = app.IsLinked(r.m);
            r.card.BorderBrush = member ? Palette.Accent : Palette.CardBorder;
            r.member.Visibility = on && many ? Visibility.Visible : Visibility.Collapsed;
            r.member.Foreground = member ? Palette.Accent : Palette.Secondary;
            r.member.Opacity = member ? 1 : 0.5;
            r.member.ToolTip = member ? "Linked. Click to move this monitor on its own." : "Not linked. Click to link it with the others.";
            System.Windows.Automation.AutomationProperties.SetHelpText(r.member, member ? "On" : "Off");
        }
    }

    string KeysHint {
        get {
            string keys = Shortcut.Pair(Settings.Up, Settings.Down);
            return app.HotkeysOk ? $"{keys}: the screen with the active window. Add Shift for fine steps."
                                 : $"{keys} are taken by another app. Change them in the gear menu.";
        }
    }

    /// One card per detected monitor; called when the monitor list or the config changes.
    public void Rebuild() {
        foreach (var r in rowViews) cards.Remove(r.card);
        rows.Children.Clear(); rowViews.Clear();
        if (app.Mons.Count == 0) {
            var none = Small("No external monitors. Plug one in and Daylit takes over; the built-in screen stays with Windows.");
            none.Margin = new Thickness(2, 0, 2, 4);
            rows.Children.Add(none);
        }
        for (int i = 0; i < app.Mons.Count; i++) {
            var m = app.Mons[i];
            var top = new Grid { Margin = new Thickness(0, 0, 0, 4) };
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition());
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new TextBlock { Text = Palette.Monitor, FontFamily = Palette.Icons, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
            var name = new TextBlock { Text = m.Label, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            var note = Small(""); note.VerticalAlignment = VerticalAlignment.Center; note.Margin = new Thickness(8, 0, 8, 0); note.TextWrapping = TextWrapping.NoWrap;
            // "manual ✕": a hand-set level follows the automatic one at its distance until sunset; a click goes back to automatic.
            note.MouseLeftButtonUp += (_, e) => { if (m.Manual) { app.Resume(m); e.Handled = true; } };
            var pct = new TextBlock { Text = "–", VerticalAlignment = VerticalAlignment.Center, MinWidth = 40, TextAlignment = TextAlignment.Right };
            Typography.SetNumeralAlignment(pct, FontNumeralAlignment.Tabular);
            // With three or more monitors linked: leave or rejoin the group, one monitor at a time.
            var member = new Button { Content = new TextBlock { Text = "\uE71B", FontFamily = Palette.Icons, FontSize = 12 },
                                      Padding = new Thickness(4), Margin = new Thickness(0, 0, 6, 0), Background = Brushes.Transparent,
                                      BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center, Cursor = WI.Cursors.Hand,
                                      Visibility = Visibility.Collapsed };
            System.Windows.Automation.AutomationProperties.SetName(member, $"Link {m.Label}");
            member.Click += (_, _) => app.ToggleMember(m);
            Grid.SetColumn(name, 1); Grid.SetColumn(note, 2); Grid.SetColumn(member, 3); Grid.SetColumn(pct, 4);
            top.Children.Add(icon); top.Children.Add(name); top.Children.Add(note); top.Children.Add(member); top.Children.Add(pct);

            var bottom = new Grid();
            bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bottom.ColumnDefinitions.Add(new ColumnDefinition());
            bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var low = new TextBlock { Text = Palette.SunLow, FontFamily = Palette.Icons, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Palette.Secondary, Tag = "secondary" };
            var high = new TextBlock { Text = Palette.SunHigh, FontFamily = Palette.Icons, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Foreground = Palette.Secondary, Tag = "secondary" };
            var s = new Slider { Minimum = 0, Maximum = 100, SmallChange = 1, LargeChange = 6, TickFrequency = 1, IsSnapToTickEnabled = true,
                                 IsMoveToPointEnabled = true, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
            System.Windows.Automation.AutomationProperties.SetName(s, $"{m.Label} brightness");   // screen readers and agents
            s.ToolTipOpening += (_, _) => s.ToolTip = KeysHint;
            s.ToolTip = KeysHint;
            s.GotMouseCapture += (_, _) => m.Dragging = true;
            s.LostMouseCapture += (_, _) => m.Dragging = false;
            s.ValueChanged += (_, e) => {
                if (syncing) return;
                int v = (int)Math.Round(e.NewValue);
                pct.Text = v + "%";
                app.UserSet(m, v);
            };
            Grid.SetColumn(s, 1); Grid.SetColumn(high, 2);
            bottom.Children.Add(low); bottom.Children.Add(s); bottom.Children.Add(high);

            var card = Card(new StackPanel { Children = { top, bottom } });
            rows.Children.Add(card);
            rowViews.Add((m, s, pct, note, card, member));
            if (i < app.Mons.Count - 1) {
                rows.Children.Add(new Border { Height = 10 });   // the gap between cards
            }
        }
        Sync();
    }

    /// Copies the controller's state into the controls. Never moves a slider the user is holding.
    public void Sync() {
        if (rowViews.Count != app.Mons.Count || rowViews.Where((r, i) => !ReferenceEquals(r.m, app.Mons[i])).Any()) { Rebuild(); return; }
        syncing = true;
        try {
            foreach (var (m, s, pct, note, card, _) in rowViews) {
                s.IsEnabled = m.Usable;
                card.Opacity = m.Usable ? 1 : 0.55;
                note.Cursor = m.Manual ? WI.Cursors.Hand : null;
                note.ToolTip = m.Manual ? "Set by hand: follows the automatic level this far from it until the sun sets. Click to go back to automatic." : null;
                note.Text = m.Untried ? "level not reported" : m.Reads == ReadState.Silent ? "refused (DDC/CI off?)"
                          : !m.On ? "no control: turn on HDR, or DDC/CI in its menu" : m.Manual ? "manual ✕" : m.D.Hdr ? "HDR"
                          : m.Reads == ReadState.WriteOnly ? "no readback" : "";
                if (m.Cur is int c) {
                    bool held = s.IsMouseCaptureWithin || (DateTime.UtcNow - m.UserTouched).TotalSeconds < 1.5;
                    if (!held) s.Value = Math.Clamp(c, 0, 100);
                    pct.Text = (held ? (int)Math.Round(s.Value) : c) + "%";
                } else { pct.Text = "–"; if (m.Untried && !s.IsMouseCaptureWithin) s.Value = 50; }
            }
            StyleLink();
            bool automatic = app.Source != Source.Off;
            offHint.Visibility = automatic ? Visibility.Collapsed : Visibility.Visible;
            autoRow.Visibility = automatic ? Visibility.Visible : Visibility.Collapsed;
            auto.IsChecked = app.AutoOn;
            PaintSwitch(auto);
            autoSub.Text = app.Subtitle;
            autoSub.ToolTip = app.Subtitle == "" ? null : app.Subtitle;
            autoSub.Visibility = app.Subtitle == "" ? Visibility.Collapsed : Visibility.Visible;
            var sg = app.Suggestion;
            var sgMon = sg is { } pending ? app.Mons.FirstOrDefault(x => x.Key == pending.Monitor) : null;
            suggestCard.Visibility = sg != null && sgMon != null ? Visibility.Visible : Visibility.Collapsed;
            suggestText.Text = sg != null && sgMon != null ? sg.Sentence(sgMon.Label) : "";
            string problem = string.Join("\n", new[] { app.Error, app.SuggestError }.Where(t => !string.IsNullOrEmpty(t)));   // an Apply that failed stays until the next suggestion action
            error.Text = problem;
            error.Visibility = problem == "" ? Visibility.Collapsed : Visibility.Visible;
        } finally { syncing = false; }
    }

    /// Re-reads light/dark: our colours, the window frame and the backdrop. The Fluent controls follow by themselves.
    public void ApplyTheme() {
        Foreground = Palette.Text;
        foreach (var c in cards) { c.Background = Palette.Card; c.BorderBrush = Palette.CardBorder; }
        StyleLink();
        PaintSwitch(auto);
        foreach (var t in FindSecondary(this)) t.Foreground = t == error ? Palette.Error : Palette.Secondary;
        error.Foreground = Palette.Error;
        if (hwnd == IntPtr.Zero) { Background = Win.HasBackdrop ? Brushes.Transparent : Palette.Solid; return; }
        Win.DarkFrame(hwnd, Theme.Dark);
        Win.RoundCorners(hwnd);
        if (Win.Backdrop(hwnd)) {
            Background = Brushes.Transparent;
            if (HwndSource.FromHwnd(hwnd)?.CompositionTarget is { } ct) ct.BackgroundColor = Colors.Transparent;
        } else Background = Palette.Solid;
    }

    static IEnumerable<TextBlock> FindSecondary(DependencyObject o) {
        foreach (var child in LogicalTreeHelper.GetChildren(o).OfType<DependencyObject>()) {
            if (child is TextBlock { Tag: "secondary" } t) yield return t;
            foreach (var x in FindSecondary(child)) yield return x;
        }
    }

    public void ShowAtTray() {
        Sync();
        if (!IsVisible) Show();
        ApplyTheme();
        PlaceAtTray();
        Activate();
    }

    /// Next to the tray: the corner of the working area beside the taskbar, on the screen under the cursor.
    void PlaceAtTray() {
        if (hwnd == IntPtr.Zero) return;
        var scr = WF.Screen.FromPoint(WF.Cursor.Position);
        var wa = scr.WorkingArea; var b = scr.Bounds;   // physical pixels (per-monitor DPI aware process)
        Win.Place(hwnd, (w, h) => {
            int gap = (int)Math.Round(12 * VisualTreeHelper.GetDpi(this).DpiScaleX);
            int x = wa.Left > b.Left ? wa.Left + gap : wa.Right - w - gap;
            int y = wa.Top > b.Top ? wa.Top + gap : wa.Bottom - h - gap;
            return (x, y);
        });
    }
}

/// The brightness indicator shown by the hotkeys, centred near the bottom of that monitor.
sealed class Osd : Window {
    readonly TextBlock label = new() { FontSize = 14, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock pct = new() { FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock icon = new() { Text = Palette.SunHigh, FontFamily = Palette.Icons, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
    readonly Border panel, track = new() { Height = 4, CornerRadius = new CornerRadius(2) }, fill = new() { Height = 4, CornerRadius = new CornerRadius(2) };
    readonly Grid bar = new() { Margin = new Thickness(0, 10, 0, 0) };
    readonly DispatcherTimer hideT = new() { Interval = TimeSpan.FromMilliseconds(1200) };
    IntPtr hwnd;

    public Osd() {
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; Topmost = true; ShowActivated = false; Focusable = false;
        Width = 260; SizeToContent = SizeToContent.Height; Left = -32000; Top = -32000;
        FontFamily = Palette.Ui;
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition());
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(label, 1); Grid.SetColumn(pct, 2);
        Typography.SetNumeralAlignment(pct, FontNumeralAlignment.Tabular);
        top.Children.Add(icon); top.Children.Add(label); top.Children.Add(pct);
        bar.ColumnDefinitions.Add(new ColumnDefinition());
        bar.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumnSpan(track, 2);
        bar.Children.Add(track); bar.Children.Add(fill);
        panel = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(16, 12, 16, 14), BorderThickness = new Thickness(1),
                             Child = new StackPanel { Children = { top, bar } } };
        Content = panel;
        SourceInitialized += (_, _) => { hwnd = new WindowInteropHelper(this).Handle; Win.MakeOverlay(hwnd); };
        hideT.Tick += (_, _) => {
            hideT.Stop();
            var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(300));
            fade.Completed += (_, _) => { if (!hideT.IsEnabled) Hide(); };
            BeginAnimation(OpacityProperty, fade);
        };
    }

    public void Flash(string name, int v, string gdi) {
        Fill(name, v);
        BeginAnimation(OpacityProperty, null); Opacity = 1;
        if (!IsVisible) Show();
        var b = (WF.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == gdi) ?? WF.Screen.PrimaryScreen!).Bounds;
        if (hwnd != IntPtr.Zero) Win.Place(hwnd, (w, h) => (b.Left + (b.Width - w) / 2, b.Bottom - (int)(b.Height * 0.12) - h));
        hideT.Stop(); hideT.Start();
    }

    /// The indicator's content alone, filled in and detached from the window (snapshots).
    public FrameworkElement Detach(string name, int v) { Fill(name, v); Content = null; panel.Width = Width; return panel; }

    void Fill(string name, int v) {
        panel.Background = Palette.Osd; panel.BorderBrush = Palette.CardBorder;
        Foreground = Palette.Text; track.Background = Palette.Track; fill.Background = Palette.Accent;
        label.Text = name; pct.Text = v + "%";
        bar.ColumnDefinitions[0].Width = new GridLength(Math.Max(v, 0.0001), GridUnitType.Star);
        bar.ColumnDefinitions[1].Width = new GridLength(Math.Max(100 - v, 0.0001), GridUnitType.Star);
        fill.Visibility = v > 0 ? Visibility.Visible : Visibility.Hidden;
    }
}

static class TokenDialog {
    public static string? Ask(string target) {
        var box = new PasswordBox { Margin = new Thickness(0, 12, 0, 16), MinWidth = 400 };
        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 90, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90 };
        var w = new Window {
            Title = "Daylit — Home Assistant token", SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Topmost = true, FontFamily = Palette.Ui, FontSize = 14,
            Content = new StackPanel {
                Margin = new Thickness(24), MaxWidth = 460,
                Children = {
                    new TextBlock { Text = "Paste a Home Assistant long-lived access token (your profile → Security).", TextWrapping = TextWrapping.Wrap },
                    new TextBlock { Text = $"It is stored in Windows Credential Manager as \"{target}\", never in config.json.", TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75, Margin = new Thickness(0, 6, 0, 0) },
                    box,
                    new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { save, cancel } },
                },
            },
        };
        save.Click += (_, _) => w.DialogResult = true;
        w.Loaded += (_, _) => box.Focus();
        return w.ShowDialog() == true && box.Password.Trim().Length > 0 ? box.Password.Trim() : null;
    }
}

/// Ctrl+Alt+PageUp/PageDown (+Shift for fine steps), registered on a message-only window.
/// The WPF dispatcher pumps its messages like any other window's.
sealed class HotkeyWindow : WF.NativeWindow, IDisposable {
    [DllImport("user32")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32")] static extern bool UnregisterHotKey(IntPtr h, int id);
    readonly Action<bool, bool> on;
    readonly Action onTheme;

    public HotkeyWindow(Action<bool, bool> on, Action onTheme) {
        this.on = on;
        this.onTheme = onTheme;
        CreateHandle(new WF.CreateParams { Parent = new IntPtr(-3) });   // HWND_MESSAGE
    }
    /// Registers up/down and their Shift variants (fine steps). False if any is taken.
    public bool Register(Shortcut up, Shortcut down) {
        Unregister();
        uint S = (uint)Shortcut.Shift;
        return RegisterHotKey(Handle, 1, (uint)up.Mods, (uint)up.Vk) & RegisterHotKey(Handle, 2, (uint)down.Mods, (uint)down.Vk)
             & RegisterHotKey(Handle, 3, (uint)up.Mods | S, (uint)up.Vk) & RegisterHotKey(Handle, 4, (uint)down.Mods | S, (uint)down.Vk);
    }
    /// Light/dark mode: id 5, no Shift variant. False if taken.
    public bool RegisterTheme(Shortcut t) {
        UnregisterHotKey(Handle, 5);
        return RegisterHotKey(Handle, 5, (uint)t.Mods, (uint)t.Vk);
    }
    public void Unregister() { for (int i = 1; i <= 5; i++) UnregisterHotKey(Handle, i); }
    protected override void WndProc(ref WF.Message m) {
        if (m.Msg == 0x0312 /* WM_HOTKEY */) { int id = (int)m.WParam; if (id == 5) onTheme(); else on(id is 1 or 3, id >= 3); }
        base.WndProc(ref m);
    }
    public void Dispose() { Unregister(); DestroyHandle(); }
}

/// A key plus modifiers, in RegisterHotKey terms (MOD_ALT 1, MOD_CONTROL 2, MOD_SHIFT 4, MOD_WIN 8).
readonly record struct Shortcut(int Mods, int Vk) {
    public const int Alt = 1, Ctrl = 2, Shift = 4, Win = 8;
    public static readonly Shortcut DefaultUp = new(Ctrl | Alt, 0x21), DefaultDown = new(Ctrl | Alt, 0x22);   // PgUp, PgDn
    public static readonly Shortcut DefaultTheme = new(Ctrl | Alt, 0x44);   // D

    public string ModsText {
        get {
            var p = new List<string>();
            if ((Mods & Win) != 0) p.Add("Win");
            if ((Mods & Ctrl) != 0) p.Add("Ctrl");
            if ((Mods & Alt) != 0) p.Add("Alt");
            if ((Mods & Shift) != 0) p.Add("Shift");
            return string.Join("+", p);
        }
    }
    public string KeyText => Vk switch {
        0x21 => "PgUp", 0x22 => "PgDn", 0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓",
        0xBB => "+", 0xBD => "-", 0x6B => "Num +", 0x6D => "Num -",
        >= 0x30 and <= 0x39 => ((char)Vk).ToString(), >= 0x41 and <= 0x5A => ((char)Vk).ToString(),
        _ => WI.KeyInterop.KeyFromVirtualKey(Vk).ToString(),
    };
    public override string ToString() => ModsText == "" ? KeyText : $"{ModsText}+{KeyText}";
    /// "Ctrl+Alt+PgUp / PgDn" when both share modifiers, else both in full.
    public static string Pair(Shortcut up, Shortcut down) => up.Mods == down.Mods ? $"{up} / {down.KeyText}" : $"{up} / {down}";
}

/// Pick the brightness hotkeys: click a box, press the combination.
static class ShortcutDialog {
    /// tryApply registers the shortcuts and returns null, or what another app owns ("brightness", "light/dark").
    public static void Edit(Shortcut up, Shortcut down, Shortcut theme, Func<Shortcut, Shortcut, Shortcut, string?> tryApply) {
        Shortcut newUp = up, newDown = down, newTheme = theme;
        var error = new TextBlock { Foreground = Palette.Error, TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 4, 0, 0), Visibility = Visibility.Collapsed };
        void Fail(string? msg) { error.Text = msg ?? ""; error.Visibility = msg == null ? Visibility.Collapsed : Visibility.Visible; }

        TextBox Capture(Func<Shortcut> get, Action<Shortcut> set) {
            var box = new TextBox { Text = get().ToString(), IsReadOnly = true, IsReadOnlyCaretVisible = false, MinWidth = 220, Cursor = WI.Cursors.Hand };
            box.PreviewKeyDown += (_, e) => {
                var k = e.Key == WI.Key.System ? e.SystemKey : e.Key;
                var km = WI.Keyboard.Modifiers;
                if (km == WI.ModifierKeys.None && k is WI.Key.Tab or WI.Key.Escape or WI.Key.Enter) return;   // keep dialog navigation
                e.Handled = true;
                if (k is WI.Key.LeftCtrl or WI.Key.RightCtrl or WI.Key.LeftAlt or WI.Key.RightAlt or WI.Key.LeftShift or WI.Key.RightShift or WI.Key.LWin or WI.Key.RWin) return;
                int mods = (km.HasFlag(WI.ModifierKeys.Control) ? Shortcut.Ctrl : 0) | (km.HasFlag(WI.ModifierKeys.Alt) ? Shortcut.Alt : 0) | (km.HasFlag(WI.ModifierKeys.Windows) ? Shortcut.Win : 0);
                if (km.HasFlag(WI.ModifierKeys.Shift)) { Fail("Leave Shift out: it is added automatically for steps of 1."); return; }
                if (mods == 0) { Fail("Use Ctrl, Alt or Win with the key, so it does not clash with typing."); return; }
                var sc = new Shortcut(mods, WI.KeyInterop.VirtualKeyFromKey(k));
                set(sc); box.Text = sc.ToString(); Fail(null);
            };
            box.GotKeyboardFocus += (_, _) => box.SelectAll();
            return box;
        }
        var upBox = Capture(() => newUp, v => newUp = v);
        var downBox = Capture(() => newDown, v => newDown = v);
        var themeBox = Capture(() => newTheme, v => newTheme = v);

        Grid Row(string label, TextBox box) {
            var g = new Grid { Margin = new Thickness(0, 6, 0, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            var t = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(box, 1);
            g.Children.Add(t); g.Children.Add(box);
            return g;
        }
        var reset = new Button { Content = "Reset to defaults", MinWidth = 90 };
        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 90, Margin = new Thickness(0, 0, 8, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90 };
        var buttons = new Grid { Margin = new Thickness(0, 18, 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { save, cancel } };
        Grid.SetColumn(right, 1);
        buttons.Children.Add(reset); buttons.Children.Add(right);

        var w = new Window {
            Title = "Daylit — keyboard shortcuts", SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Topmost = true, FontFamily = Palette.Ui, FontSize = 14,
            Content = new StackPanel {
                Margin = new Thickness(24), MaxWidth = 460,
                Children = {
                    new TextBlock { Text = "Click a box and press the new combination.", TextWrapping = TextWrapping.Wrap },
                    new TextBlock { Text = "They change the screen with the active window. Hold Shift as well for steps of 1.", TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75, Margin = new Thickness(0, 4, 0, 8) },
                    Row("Brighter", upBox), Row("Dimmer", downBox), Row("Light / dark mode", themeBox), error, buttons,
                },
            },
        };
        reset.Click += (_, _) => { newUp = Shortcut.DefaultUp; newDown = Shortcut.DefaultDown; newTheme = Shortcut.DefaultTheme; upBox.Text = newUp.ToString(); downBox.Text = newDown.ToString(); themeBox.Text = newTheme.ToString(); Fail(null); };
        save.Click += (_, _) => {
            var clash = ShortcutRule.Clash([(newUp.Mods, newUp.Vk), (newDown.Mods, newDown.Vk), (newTheme.Mods, newTheme.Vk)]);
            if (clash is { } c) {
                string[] names = ["Brighter", "Dimmer", "Light / dark mode"];
                Fail($"{names[c.Item1]} and {names[c.Item2]} need different combinations.");
                return;
            }
            var taken = tryApply(newUp, newDown, newTheme);
            if (taken != null) { Fail($"The {taken} shortcut is taken by another app or by Windows. Try another."); return; }
            w.DialogResult = true;
        };
        w.ShowDialog();
    }
}
