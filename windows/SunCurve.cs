// Today's sun as a picture: its height through the day at the user's location, with draggable lines
// for the elevations the rules use. Each line shows when the sun crosses it today, so nobody has to
// think in degrees. Same as the Mac's SunCurve. The keyboard moves the lines too: Left / Right (or Tab) pick a handle,
// Up / Down move it by half a degree (Page Up / Page Down by five), and Narrator reads it as a slider.
using System.Globalization;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Media;

namespace Daylit;

sealed class SunCurve : FrameworkElement {
    public sealed record Marker(string Id, string Title, Color Color, bool Below);

    readonly double lat, lon;
    readonly DateTimeOffset now;
    readonly TimeZoneInfo tz;
    readonly IReadOnlyList<Marker> markers;
    readonly Func<string, double> get;
    readonly Action<string, double> set;
    const double ChartH = 170;
    readonly List<(Marker m, Rect r)> handles = new();
    string? dragging;
    int active;   // the handle the keyboard and Narrator act on
    double top, bottom;

    public SunCurve(double lat, double lon, DateTimeOffset now, TimeZoneInfo tz, IReadOnlyList<Marker> markers,
                    Func<string, double> get, Action<string, double> set) {
        (this.lat, this.lon, this.now, this.tz, this.markers, this.get, this.set) = (lat, lon, now, tz, markers, get, set);
        Height = ChartH;
        Cursor = Cursors.Arrow;
        Focusable = true;
        FocusVisualStyle = null;   // the active handle gets its own ring in OnRender
        System.Windows.Automation.AutomationProperties.SetName(this, "Today's sun");
        GotKeyboardFocus += (_, _) => InvalidateVisual();
        LostKeyboardFocus += (_, _) => InvalidateVisual();
    }

    Marker? Active => markers.Count == 0 ? null : markers[Math.Clamp(active, 0, markers.Count - 1)];

    // MARK: keyboard and Narrator

    /// What Narrator calls the active handle, and its value with today's times.
    internal string ActiveName => Active is { } m ? m.Title + ", today's sun" : "Today's sun";
    internal string ActiveStatus => Active is { } m ? $"{get(m.Id).ToString("0.#", CultureInfo.InvariantCulture)} degrees, {Crossings(Samples(), get(m.Id), m.Below, Day(), tz)}" : "";
    internal double ActiveValue => Active is { } m ? get(m.Id) : 0;
    internal const double Lowest = -18, Highest = 60;   // the ranges tuning accepts

    /// Sets the active handle's line (half-degree steps) and tells Narrator.
    internal void SetActive(double value) {
        if (Active is not { } m) return;
        double before = get(m.Id);
        set(m.Id, Math.Round(Math.Clamp(value, Lowest, Highest) * 2, MidpointRounding.AwayFromZero) / 2);
        InvalidateVisual();
        (UIElementAutomationPeer.FromElement(this) as SunCurvePeer)?.ValueChanged(before, get(m.Id));
    }

    void Select(int index) {
        string before = ActiveName;
        active = Math.Clamp(index, 0, Math.Max(markers.Count - 1, 0));
        InvalidateVisual();
        (UIElementAutomationPeer.FromElement(this) as SunCurvePeer)?.SelectionChanged(before, ActiveName);
    }

    // Tab walks the handles first, then leaves the curve.
    protected override void OnPreviewKeyDown(KeyEventArgs e) {
        if (e.Key == Key.Tab && (Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) == 0 && markers.Count > 1) {
            int next = active + ((Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? -1 : 1);
            if (next >= 0 && next < markers.Count) { Select(next); e.Handled = true; return; }
        }
        base.OnPreviewKeyDown(e);
    }

    protected override void OnKeyDown(KeyEventArgs e) {
        if (Active == null) { base.OnKeyDown(e); return; }
        switch (e.Key) {
            case Key.Up: SetActive(ActiveValue + 0.5); break;
            case Key.Down: SetActive(ActiveValue - 0.5); break;
            case Key.PageUp: SetActive(ActiveValue + 5); break;
            case Key.PageDown: SetActive(ActiveValue - 5); break;
            case Key.Left: Select(active - 1); break;
            case Key.Right: Select(active + 1); break;
            default: base.OnKeyDown(e); return;
        }
        e.Handled = true;
    }

    protected override void OnMouseDown(MouseButtonEventArgs e) { Focus(); base.OnMouseDown(e); }

    protected override AutomationPeer OnCreateAutomationPeer() => new SunCurvePeer(this);

    /// Today from local midnight to the next one: 23 or 25 hours on the days the clocks change.
    (DateTimeOffset start, double hours) Day() {
        var date = TimeZoneInfo.ConvertTime(now, tz).Date;
        DateTimeOffset At(DateTime d) => new(d, tz.GetUtcOffset(d));
        var start = At(date);
        return (start, (At(date.AddDays(1)) - start).TotalHours);
    }

    /// Today's elevations at 145 even steps (every 10 minutes on a normal day).
    List<(double t, double e)> Samples() {
        var (start, hours) = Day();
        return Enumerable.Range(0, 145).Select(i => (i / 144.0, Sun.Elevation(start.AddHours(i / 144.0 * hours), lat, lon))).ToList();
    }

    /// Where a local time of today sits on the chart (0…1).
    double Fraction(DateTimeOffset at) { var (start, hours) = Day(); return (at - start).TotalHours / hours; }
    double Fraction(int hour) {
        var d = TimeZoneInfo.ConvertTime(now, tz).Date.AddHours(hour);
        return Fraction(new DateTimeOffset(d, tz.GetUtcOffset(d)));
    }

    double Y(double e) => (top - e) / (top - bottom) * ChartH;

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth > 0 ? ActualWidth : Width;
        if (double.IsNaN(w) || w <= 0) return;
        var s = Samples();
        var marks = markers.Select(m => get(m.Id)).ToList();
        top = new[] { 15, s.Max(p => p.e) + 5, marks.DefaultIfEmpty(0).Max() + 4 }.Max();
        bottom = new[] { -12, s.Min(p => p.e), marks.DefaultIfEmpty(0).Min() - 4 }.Min();
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        Brush Solid(Color c, byte a = 255) { var b = new SolidColorBrush(Color.FromArgb(a, c.R, c.G, c.B)); b.Freeze(); return b; }
        FormattedText Text(string t, double size, Brush b, bool bold = false) =>
            new(t, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface(Palette.Ui, FontStyles.Normal, bold ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal), size, b, dpi);

        var frame = new RectangleGeometry(new Rect(0, 0, w, ChartH), 8, 8);
        dc.PushClip(frame);
        dc.DrawRectangle(Solid(Colors.Orange, 16), null, new Rect(0, 0, w, Y(0)));
        dc.DrawRectangle(Solid(Color.FromRgb(0x5B, 0x4B, 0xC4), 36), null, new Rect(0, Y(0), w, ChartH - Y(0)));
        dc.DrawLine(new Pen(Solid(Colors.Gray, 110), 1), new Point(0, Y(0)), new Point(w, Y(0)));
        var curve = new StreamGeometry();
        using (var g = curve.Open()) {
            g.BeginFigure(new Point(0, Y(s[0].e)), false, false);
            g.PolyLineTo(s.Skip(1).Select(p => new Point(p.t * w, Y(p.e))).ToList(), true, true);
        }
        curve.Freeze();
        dc.DrawGeometry(null, new Pen(Solid(Color.FromRgb(0xF5, 0xB0, 0x1A)), 2.5), curve);
        double nowT = Fraction(now);
        dc.DrawEllipse(Solid(Colors.Gold), new Pen(Solid(Colors.DarkOrange), 1.5), new Point(nowT * w, Y(Sun.Elevation(now, lat, lon))), 6, 6);
        foreach (int hr in new[] { 6, 12, 18 }) {
            var ft = Text($"{hr:00}:00", 11, Palette.Secondary);
            dc.DrawText(ft, new Point(Fraction(hr) * w - ft.Width / 2, ChartH - ft.Height - 2));
        }
        handles.Clear();
        var labelYs = Layout.SpreadLabels(markers.Select(m => Y(get(m.Id))).ToArray(), 24, ChartH - 18);   // clear of the hour labels
        foreach (var (m, idx) in markers.Select((m, i) => (m, i))) {
            double v = get(m.Id), y = Y(v);
            var pen = new Pen(Solid(m.Color), 1.5) { DashStyle = new DashStyle([4, 3], 0) };
            dc.DrawLine(pen, new Point(0, y), new Point(w, y));
            var label = Text($"{m.Title} · {Crossings(s, v, m.Below, Day(), tz)}", 12, Palette.Text, bold: true);
            double hy = labelYs[idx];
            var pill = new Rect(16, hy - 11, label.Width + 34, 22);
            dc.DrawRoundedRectangle(Palette.Solid, new Pen(Solid(m.Color, 160), 1), pill, 11, 11);
            dc.DrawEllipse(Solid(m.Color), null, new Point(pill.X + 11, hy), 7, 7);
            var grip = new FormattedText("\uE76F", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                                     new Typeface(Palette.Icons, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), 9, Brushes.White, dpi);
            dc.DrawText(grip, new Point(pill.X + 11 - grip.Width / 2, hy - grip.Height / 2));
            dc.DrawText(label, new Point(pill.X + 24, hy - label.Height / 2));
            handles.Add((m, pill));
            if (IsKeyboardFocused && idx == active) dc.DrawRoundedRectangle(null, new Pen(Palette.Text, 2), new Rect(pill.X - 2, pill.Y - 2, pill.Width + 4, pill.Height + 4), 13, 13);
        }
        dc.Pop();
        dc.DrawRoundedRectangle(null, new Pen(Palette.CardBorder, 1), new Rect(0.5, 0.5, w - 1, ChartH - 1), 8, 8);
    }

    /// Today's times for an elevation: "06:52 – 21:14" while the sun is above it, or for a state that
    /// applies below it, "until 06:52 · from 21:14" (Sun.Spans, in the order they happen).
    static string Crossings(List<(double t, double e)> s, double e, bool below, (DateTimeOffset start, double hours) day, TimeZoneInfo tz) =>
        Sun.SpanLabel(Sun.Spans(s, e, below), t =>
            TimeZoneInfo.ConvertTime(day.start.AddMinutes(Math.Round(t * day.hours * 60, MidpointRounding.AwayFromZero)), tz).ToString("HH:mm", CultureInfo.InvariantCulture));

    // Dragging a handle moves its line in half-degree steps.
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) {
        var p = e.GetPosition(this);
        var hit = handles.LastOrDefault(h => h.r.Contains(p));
        if (hit.m == null) return;
        active = Math.Max(markers.ToList().FindIndex(x => x.Id == hit.m.Id), 0);
        Focus();
        dragging = hit.m.Id; CaptureMouse(); e.Handled = true;
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        var p = e.GetPosition(this);
        Cursor = dragging != null || handles.Any(h => h.r.Contains(p)) ? Cursors.SizeNS : Cursors.Arrow;
        if (dragging == null) return;
        double v = top - Math.Clamp(p.Y, 0, ChartH) / ChartH * (top - bottom);
        set(dragging, Math.Round(Math.Clamp(v, Lowest, Highest) * 2, MidpointRounding.AwayFromZero) / 2);
        InvalidateVisual();
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { dragging = null; ReleaseMouseCapture(); }

    protected override Size MeasureOverride(Size available) =>
        new(double.IsInfinity(available.Width) ? 400 : available.Width, Height);
}

/// Narrator reads the curve as a slider on the active handle: its name, value in degrees and today's times.
sealed class SunCurvePeer : FrameworkElementAutomationPeer, System.Windows.Automation.Provider.IRangeValueProvider {
    readonly SunCurve curve;
    public SunCurvePeer(SunCurve curve) : base(curve) { this.curve = curve; }

    protected override System.Windows.Automation.Peers.AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
    protected override string GetClassNameCore() => "SunCurve";
    protected override string GetNameCore() => curve.ActiveName;
    protected override string GetItemStatusCore() => curve.ActiveStatus;
    public override object? GetPattern(PatternInterface pattern) =>
        pattern == PatternInterface.RangeValue ? this : base.GetPattern(pattern);

    public double Value => curve.ActiveValue;
    public bool IsReadOnly => false;
    public double Maximum => SunCurve.Highest;
    public double Minimum => SunCurve.Lowest;
    public double LargeChange => 5;
    public double SmallChange => 0.5;
    public void SetValue(double value) => curve.SetActive(value);

    internal void ValueChanged(double before, double after) {
        if (before != after)
            RaisePropertyChangedEvent(System.Windows.Automation.RangeValuePatternIdentifiers.ValueProperty, before, after);
    }
    internal void SelectionChanged(string before, string after) {
        RaisePropertyChangedEvent(System.Windows.Automation.AutomationElementIdentifiers.NameProperty, before, after);
        RaisePropertyChangedEvent(System.Windows.Automation.RangeValuePatternIdentifiers.ValueProperty, 0.0, curve.ActiveValue);
    }
}
