// The tray flyout, the on-screen indicator, the token prompt and the global hotkeys.
// WPF with the Fluent theme (Application.ThemeMode) for the controls; the windows themselves get a
// system acrylic backdrop on Windows 11 22H2+ and a solid colour elsewhere.
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
            if (Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\DWM", "AccentColor", null) is int abgr) {
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
    readonly TextBlock offHint, autoSub, hint, error;
    readonly CheckBox auto, look, login;
    readonly Button modeBtn;
    readonly Border autoCard;
    readonly List<Border> cards = new();
    readonly List<(Mon m, Slider s, TextBlock pct, TextBlock note, Border card)> rowViews = new();
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

        var root = new StackPanel { Margin = new Thickness(16, 14, 16, 14) };

        var header = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = "Daylit", FontSize = 15, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var gear = new Button { Content = new TextBlock { Text = Palette.Gear, FontFamily = Palette.Icons, FontSize = 14 },
                                Padding = new Thickness(8, 6, 8, 6), ToolTip = "Settings" };
        gear.Click += (_, _) => GearMenu(gear);
        Grid.SetColumn(gear, 1);
        header.Children.Add(gear);
        root.Children.Add(header);

        root.Children.Add(rows);

        offHint = Small("Set a location or Home Assistant in the config file for automatic brightness.");
        offHint.Margin = new Thickness(2, 0, 2, 10);
        root.Children.Add(offHint);

        auto = new CheckBox { Content = "Automatic brightness" };
        auto.Click += (_, _) => { if (!syncing) app.SetAuto(auto.IsChecked == true); };
        autoSub = Small("");
        autoSub.Margin = new Thickness(28, 0, 0, 6);
        look = new CheckBox { Content = "Light or dark mode from daylight" };
        look.Click += (_, _) => { if (!syncing) app.SetLook(look.IsChecked == true); };
        modeBtn = new Button { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(12, 5, 12, 6) };
        modeBtn.Click += (_, _) => app.ToggleDark();
        autoCard = Card(new StackPanel { Children = { auto, autoSub, look, modeBtn } });
        autoCard.Margin = new Thickness(0, 0, 0, 10);
        root.Children.Add(autoCard);

        hint = Small(""); hint.Margin = new Thickness(2, 0, 2, 6);
        error = Small(""); error.Margin = new Thickness(2, 0, 2, 6);
        root.Children.Add(hint);
        root.Children.Add(error);

        var footer = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition());
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        login = new CheckBox { Content = "Open at sign-in", VerticalAlignment = VerticalAlignment.Center };
        login.Click += (_, _) => { if (!syncing) Win.StartsWithWindows = login.IsChecked == true; };
        var quit = new Button { Content = "Quit", Padding = new Thickness(14, 5, 14, 6) };
        quit.Click += (_, _) => app.Quit();
        Grid.SetColumn(quit, 1);
        footer.Children.Add(login); footer.Children.Add(quit);
        root.Children.Add(footer);

        Content = root;
        SourceInitialized += (_, _) => { hwnd = new WindowInteropHelper(this).Handle; ApplyTheme(); };
        Deactivated += (_, _) => Hide();
        SizeChanged += (_, _) => { if (IsVisible) PlaceAtTray(); };   // grows with the monitor list
        ApplyTheme();
        Rebuild();
    }

    static TextBlock Small(string t) => new() { Text = t, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = Palette.Secondary, Tag = "secondary" };

    Border Card(UIElement child) {
        var b = new Border { Child = child, CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 10, 12, 10),
                             BorderThickness = new Thickness(1), Background = Palette.Card, BorderBrush = Palette.CardBorder };
        cards.Add(b);
        return b;
    }

    void GearMenu(Button anchor) {
        var m = new ContextMenu { PlacementTarget = anchor, Placement = PlacementMode.Bottom };
        MenuItem Item(string text, Action a) { var i = new MenuItem { Header = text }; i.Click += (_, _) => a(); return i; }
        m.Items.Add(Item("Open config file", app.OpenConfig));
        m.Items.Add(Item("Reload config", app.Reload));
        if (app.Source == Source.HomeAssistant) m.Items.Add(Item("Home Assistant token…", app.AskToken));
        m.IsOpen = true;
    }

    /// One card per detected monitor; called when the monitor list or the config changes.
    public void Rebuild() {
        foreach (var r in rowViews) cards.Remove(r.card);
        rows.Children.Clear(); rowViews.Clear();
        if (app.Mons.Count == 0) {
            var none = Small("No external monitor found.");
            none.Margin = new Thickness(2, 0, 2, 10);
            rows.Children.Add(none);
        }
        foreach (var m in app.Mons) {
            var top = new Grid { Margin = new Thickness(0, 0, 0, 4) };
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition());
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new TextBlock { Text = Palette.Monitor, FontFamily = Palette.Icons, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
            var name = new TextBlock { Text = m.Label, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            var note = Small(""); note.VerticalAlignment = VerticalAlignment.Center; note.Margin = new Thickness(8, 0, 8, 0); note.TextWrapping = TextWrapping.NoWrap;
            var pct = new TextBlock { Text = "–", VerticalAlignment = VerticalAlignment.Center, MinWidth = 40, TextAlignment = TextAlignment.Right };
            Typography.SetNumeralAlignment(pct, FontNumeralAlignment.Tabular);
            Grid.SetColumn(name, 1); Grid.SetColumn(note, 2); Grid.SetColumn(pct, 3);
            top.Children.Add(icon); top.Children.Add(name); top.Children.Add(note); top.Children.Add(pct);

            var bottom = new Grid();
            bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bottom.ColumnDefinitions.Add(new ColumnDefinition());
            bottom.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var low = new TextBlock { Text = Palette.SunLow, FontFamily = Palette.Icons, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Palette.Secondary, Tag = "secondary" };
            var high = new TextBlock { Text = Palette.SunHigh, FontFamily = Palette.Icons, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Foreground = Palette.Secondary, Tag = "secondary" };
            var s = new Slider { Minimum = 0, Maximum = 100, SmallChange = 1, LargeChange = 6, TickFrequency = 1, IsSnapToTickEnabled = true,
                                 IsMoveToPointEnabled = true, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 8, 0) };
            s.ValueChanged += (_, e) => {
                if (syncing) return;
                int v = (int)Math.Round(e.NewValue);
                pct.Text = v + "%";
                app.UserSet(m, v);
            };
            Grid.SetColumn(s, 1); Grid.SetColumn(high, 2);
            bottom.Children.Add(low); bottom.Children.Add(s); bottom.Children.Add(high);

            var card = Card(new StackPanel { Children = { top, bottom } });
            card.Margin = new Thickness(0, 0, 0, 8);
            rows.Children.Add(card);
            rowViews.Add((m, s, pct, note, card));
        }
        Sync();
    }

    /// Copies the controller's state into the controls. Never moves a slider the user is holding.
    public void Sync() {
        if (rowViews.Count != app.Mons.Count || rowViews.Where((r, i) => !ReferenceEquals(r.m, app.Mons[i])).Any()) { Rebuild(); return; }
        syncing = true;
        try {
            foreach (var (m, s, pct, note, card) in rowViews) {
                s.IsEnabled = m.On;
                card.Opacity = m.On ? 1 : 0.55;
                note.Text = !m.On ? "no brightness control" : m.Manual ? "manual" : m.D.Hdr ? "HDR" : "";
                if (m.Cur is int c) {
                    bool held = s.IsMouseCaptureWithin || (DateTime.UtcNow - m.UserTouched).TotalSeconds < 1.5;
                    if (!held) s.Value = Math.Clamp(c, 0, 100);
                    pct.Text = (held ? (int)Math.Round(s.Value) : c) + "%";
                } else pct.Text = "–";
            }
            bool automatic = app.Source != Source.Off;
            offHint.Visibility = automatic ? Visibility.Collapsed : Visibility.Visible;
            autoCard.Visibility = automatic ? Visibility.Visible : Visibility.Collapsed;
            auto.IsChecked = app.AutoOn;
            autoSub.Text = app.Subtitle;
            autoSub.Visibility = app.Subtitle == "" ? Visibility.Collapsed : Visibility.Visible;
            look.IsChecked = Settings.AutoLook;
            modeBtn.Content = Theme.Dark ? "Switch to light mode" : "Switch to dark mode";
            bool any = app.Mons.Any(m => m.On);
            hint.Text = !any ? "Ctrl+Alt+PgUp / PgDn change brightness once a monitor with brightness control is connected."
                      : app.HotkeysOk ? "Ctrl+Alt+PgUp / PgDn: the screen with the active window. Add Shift for fine steps."
                      : "Ctrl+Alt+PgUp / PgDn are taken by another app.";
            error.Text = app.Error ?? "";
            error.Visibility = app.Error == null ? Visibility.Collapsed : Visibility.Visible;
            login.IsChecked = Win.StartsWithWindows;
        } finally { syncing = false; }
    }

    /// Re-reads light/dark: our colours, the window frame and the backdrop. The Fluent controls follow by themselves.
    public void ApplyTheme() {
        Foreground = Palette.Text;
        foreach (var c in cards) { c.Background = Palette.Card; c.BorderBrush = Palette.CardBorder; }
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
        panel.Background = Palette.Osd; panel.BorderBrush = Palette.CardBorder;
        Foreground = Palette.Text; track.Background = Palette.Track; fill.Background = Palette.Accent;
        label.Text = name; pct.Text = v + "%";
        bar.ColumnDefinitions[0].Width = new GridLength(Math.Max(v, 0.0001), GridUnitType.Star);
        bar.ColumnDefinitions[1].Width = new GridLength(Math.Max(100 - v, 0.0001), GridUnitType.Star);
        fill.Visibility = v > 0 ? Visibility.Visible : Visibility.Hidden;
        BeginAnimation(OpacityProperty, null); Opacity = 1;
        if (!IsVisible) Show();
        var b = (WF.Screen.AllScreens.FirstOrDefault(s => s.DeviceName == gdi) ?? WF.Screen.PrimaryScreen!).Bounds;
        if (hwnd != IntPtr.Zero) Win.Place(hwnd, (w, h) => (b.Left + (b.Width - w) / 2, b.Bottom - (int)(b.Height * 0.12) - h));
        hideT.Stop(); hideT.Start();
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
    const uint ALT = 1, CTRL = 2, SHIFT = 4, PGUP = 0x21, PGDN = 0x22;
    readonly Action<bool, bool> on;
    public readonly bool Ok;

    public HotkeyWindow(Action<bool, bool> on) {
        this.on = on;
        CreateHandle(new WF.CreateParams { Parent = new IntPtr(-3) });   // HWND_MESSAGE
        Ok = RegisterHotKey(Handle, 1, CTRL | ALT, PGUP) & RegisterHotKey(Handle, 2, CTRL | ALT, PGDN)
           & RegisterHotKey(Handle, 3, CTRL | ALT | SHIFT, PGUP) & RegisterHotKey(Handle, 4, CTRL | ALT | SHIFT, PGDN);
    }
    protected override void WndProc(ref WF.Message m) {
        if (m.Msg == 0x0312 /* WM_HOTKEY */) { int id = (int)m.WParam; on(id is 1 or 3, id >= 3); }
        base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i <= 4; i++) UnregisterHotKey(Handle, i); DestroyHandle(); }
}
