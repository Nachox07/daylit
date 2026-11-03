// Today's sun as a picture: its height through the day at the user's location, with draggable lines
// for the elevations the rules use. Each line shows when the sun crosses it today, so nobody has to
// think in degrees. Below, how bright a monitor would be hour by hour. Same as the Mac's SunCurve.
using System.Globalization;
using System.Windows;
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
    readonly Func<double, int>? level;
    readonly string levelTitle;
    const double ChartH = 170, Gap = 26, StripH = 44;
    readonly List<(Marker m, Rect r)> handles = new();
    string? dragging;
    double top, bottom;

    public SunCurve(double lat, double lon, DateTimeOffset now, TimeZoneInfo tz, IReadOnlyList<Marker> markers,
                    Func<string, double> get, Action<string, double> set, Func<double, int>? level = null, string levelTitle = "") {
        (this.lat, this.lon, this.now, this.tz, this.markers, this.get, this.set, this.level, this.levelTitle) =
            (lat, lon, now, tz, markers, get, set, level, levelTitle);
        Height = ChartH + (level != null ? Gap + StripH : 0);
        Cursor = Cursors.Arrow;
        System.Windows.Automation.AutomationProperties.SetName(this, "Today's sun");
    }

    /// Today's elevations every 10 minutes, local midnight to midnight.
    List<(double t, double e)> Samples() {
        var local = TimeZoneInfo.ConvertTime(now, tz);
        var start = new DateTimeOffset(local.Date, local.Offset);
        return Enumerable.Range(0, 145).Select(i => (i / 144.0, Sun.Elevation(start.AddMinutes(i * 10), lat, lon))).ToList();
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
        var local = TimeZoneInfo.ConvertTime(now, tz);
        double nowT = local.TimeOfDay.TotalDays;
        dc.DrawEllipse(Solid(Colors.Gold), new Pen(Solid(Colors.DarkOrange), 1.5), new Point(nowT * w, Y(Sun.Elevation(now, lat, lon))), 6, 6);
        foreach (int hr in new[] { 6, 12, 18 }) {
            var ft = Text($"{hr:00}:00", 11, Palette.Secondary);
            dc.DrawText(ft, new Point(hr / 24.0 * w - ft.Width / 2, ChartH - ft.Height - 2));
        }
        handles.Clear();
        foreach (var m in markers) {
            double v = get(m.Id), y = Y(v);
            var pen = new Pen(Solid(m.Color), 1.5) { DashStyle = new DashStyle([4, 3], 0) };
            dc.DrawLine(pen, new Point(0, y), new Point(w, y));
            var label = Text($"{m.Title} · {Crossings(s, v, m.Below)}", 12, Palette.Text, bold: true);
            double hy = Math.Clamp(y, 12, ChartH - 12);
            var pill = new Rect(16, hy - 11, label.Width + 34, 22);
            dc.DrawRoundedRectangle(Palette.Solid, new Pen(Solid(m.Color, 160), 1), pill, 11, 11);
            dc.DrawEllipse(Solid(m.Color), null, new Point(pill.X + 11, hy), 7, 7);
            var grip = new FormattedText("\uE76F", CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                                     new Typeface(Palette.Icons, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), 9, Brushes.White, dpi);
            dc.DrawText(grip, new Point(pill.X + 11 - grip.Width / 2, hy - grip.Height / 2));
            dc.DrawText(label, new Point(pill.X + 24, hy - label.Height / 2));
            handles.Add((m, pill));
        }
        dc.Pop();
        dc.DrawRoundedRectangle(null, new Pen(Palette.CardBorder, 1), new Rect(0.5, 0.5, w - 1, ChartH - 1), 8, 8);

        if (level != null) {
            var title = Text(levelTitle, 12, Palette.Secondary);
            dc.DrawText(title, new Point(0, ChartH + (Gap - title.Height) / 2));
            double y0 = ChartH + Gap;
            var area = new StreamGeometry();
            using (var g = area.Open()) {
                g.BeginFigure(new Point(0, y0 + StripH), true, true);
                g.PolyLineTo(s.Select(p => new Point(p.t * w, y0 + StripH - level(p.e) / 100.0 * StripH))
                              .Append(new Point(w, y0 + StripH)).ToList(), true, true);
            }
            area.Freeze();
            var box = new Rect(0, y0, w, StripH);
            dc.PushClip(new RectangleGeometry(box, 6, 6));
            dc.DrawGeometry(Solid(((SolidColorBrush)Palette.Accent).Color, 90), null, area);
            dc.Pop();
            dc.DrawRoundedRectangle(null, new Pen(Palette.CardBorder, 1), box, 6, 6);
        }
    }

    /// Today's times for an elevation: "06:52 – 21:14" while the sun is above it, or for a state that
    /// applies below it, "until 06:52 · from 21:14".
    static string Crossings(List<(double t, double e)> s, double e, bool below) {
        string Time(int i) {
            var (a, b) = (s[i - 1], s[i]);
            double t = a.t + (b.t - a.t) * (e - a.e) / (b.e - a.e);
            int mins = (int)Math.Round(t * 1440);
            return $"{mins / 60 % 24:00}:{mins % 60:00}";
        }
        int? up = Enumerable.Range(1, s.Count - 1).Cast<int?>().FirstOrDefault(i => s[i!.Value - 1].e < e && s[i.Value].e >= e);
        int? down = Enumerable.Range(1, s.Count - 1).Cast<int?>().LastOrDefault(i => s[i!.Value - 1].e >= e && s[i.Value].e < e);
        bool allAbove = s[0].e >= e;
        if (below) return (up, down) switch {
            ({ } u, { } d) => $"until {Time(u)} · from {Time(d)}",
            (null, null) => allAbove ? "not today" : "all day",
            ({ } u, null) => $"until {Time(u)}",
            (null, { } d) => $"from {Time(d)}",
        };
        return (up, down) switch {
            ({ } u, { } d) => $"{Time(u)} – {Time(d)}",
            (null, null) => allAbove ? "all day" : "not today",
            ({ } u, null) => $"from {Time(u)}",
            (null, { } d) => $"until {Time(d)}",
        };
    }

    // Dragging a handle moves its line in half-degree steps.
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) {
        var p = e.GetPosition(this);
        var hit = handles.LastOrDefault(h => h.r.Contains(p));
        if (hit.m == null) return;
        dragging = hit.m.Id; CaptureMouse(); e.Handled = true;
    }
    protected override void OnMouseMove(MouseEventArgs e) {
        var p = e.GetPosition(this);
        Cursor = dragging != null || handles.Any(h => h.r.Contains(p)) ? Cursors.SizeNS : Cursors.Arrow;
        if (dragging == null) return;
        double v = top - Math.Clamp(p.Y, 0, ChartH) / ChartH * (top - bottom);
        set(dragging, Math.Round(Math.Clamp(v, -18, 60) * 2) / 2);
        InvalidateVisual();
    }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { dragging = null; ReleaseMouseCapture(); }

    protected override Size MeasureOverride(Size available) =>
        new(double.IsInfinity(available.Width) ? 400 : available.Width, Height);
}
