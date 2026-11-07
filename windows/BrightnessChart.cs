// Settings → Automatic: how bright a monitor gets through today. Time across, brightness up; one line
// with the blind open and one with it closed; two handles, each one sun height (Chart.cs), with both of
// its crossings draggable sideways; and "How Daylit decides, right now". Snapshots draw it from fixed
// state. Same as the Mac's BrightnessChart.
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;

namespace Daylit;

/// A monitor the chart can show: its key and the levels typed in the window.
sealed record ChartMonitor(string Id, string Label, double Day, double BlindDown, double Night);

sealed class BrightnessChart : StackPanel {
    public static readonly Color DayColor = Color.FromRgb(0xF7, 0x8C, 0x1E), NightColor = Color.FromRgb(0x6E, 0x5B, 0xD6);
    const string SunDayId = "brightness.sunDay", SunNightId = "brightness.sunNight";

    readonly double lat, lon;
    readonly DateTimeOffset now;
    readonly TimeZoneInfo tz;
    readonly IReadOnlyList<ChartMonitor> monitors;
    readonly bool hasBlind;
    readonly Func<Tuning> tuning;            // with the elevations being edited
    readonly Func<LiveInputs?> live;         // the last tick's blind, lights, clouds and hand-set distances; null: a preview
    readonly Action<string, double> set;     // tuning field, elevation
    readonly Action<string>? picked;
    readonly (DateTimeOffset Start, double Length) day;
    readonly List<(double t, double e)> samples;
    string? pick;
    string? dragging;

    readonly Plot plot;
    readonly List<(ToggleButton button, string id)> segments = new();
    readonly TextBlock decidesTitle = new() { FontSize = 12, FontWeight = FontWeights.SemiBold };
    readonly WrapPanel chips = new() { Margin = new Thickness(0, 6, 0, 0) };
    readonly TextBlock idle = new() { Text = "Automatic is off or this PC is idle: the screen stays where it is until it takes over again.",
                                      TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 6, 0, 0) };

    /// `pick`: the monitor to show first (the window keeps it across rebuilds); `picked` reports a new choice.
    public BrightnessChart(double lat, double lon, DateTimeOffset now, TimeZoneInfo tz, IReadOnlyList<ChartMonitor> monitors, bool hasBlind,
                           Func<Tuning> tuning, Func<LiveInputs?> live, Action<string, double> set, string? pick = null, Action<string>? picked = null) {
        (this.lat, this.lon, this.now, this.tz, this.monitors, this.hasBlind, this.tuning, this.live, this.set, this.pick, this.picked) =
            (lat, lon, now, tz, monitors, hasBlind, tuning, live, set, pick, picked);
        day = Chart.DayBounds(now, tz);
        samples = Samples(lat, lon, day);

        if (monitors.Count > 1) {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
            foreach (var m in monitors) {
                var b = new ToggleButton { Content = m.Label, Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(0, 0, 4, 0) };
                b.Click += (_, _) => { this.pick = m.Id; this.picked?.Invoke(m.Id); Update(); };
                System.Windows.Automation.AutomationProperties.SetName(b, m.Label);
                segments.Add((b, m.Id));
                row.Children.Add(b);
            }
            Children.Add(row);
        }
        plot = new Plot(this);
        Children.Add(plot);
        var text = new TextBlock { Text = "Each handle is one sun height, so its morning and evening times move together and shift through the year. A level you set by hand keeps its distance until dusk.",
                                   TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = Palette.Secondary, Margin = new Thickness(0, 6, 0, 0) };
        Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(10), Margin = new Thickness(0, 10, 0, 0),
                                  Background = Solid(Colors.Gray, 20), Child = new StackPanel { Children = { decidesTitle, chips, idle, text } } });
        Update();
    }

    /// Redraws from the current tuning, levels and live state.
    public void Update() {
        foreach (var (b, id) in segments) b.IsChecked = id == Mon?.Id;
        plot.InvalidateVisual();
        Decides();
    }

    /// Today's sun changes once a day, not on every rebuild (each slider step rebuilds the chart).
    static (double lat, double lon, DateTimeOffset start, double length, List<(double t, double e)> samples)? cache;
    static List<(double t, double e)> Samples(double lat, double lon, (DateTimeOffset Start, double Length) day) {
        if (cache is { } c && c.lat == lat && c.lon == lon && c.start == day.Start && c.length == day.Length) return c.samples;
        var s = Chart.DaySamples(lat, lon, day.Start, day.Length);
        cache = (lat, lon, day.Start, day.Length, s);
        return s;
    }

    ChartMonitor? Mon => monitors.FirstOrDefault(m => m.Id == pick) ?? monitors.FirstOrDefault();

    static Brush Solid(Color c, byte a = 255) { var b = new SolidColorBrush(Color.FromArgb(a, c.R, c.G, c.B)); b.Freeze(); return b; }
    static string Fmt(double v) => v.ToString("0.##", CultureInfo.InvariantCulture);

    /// The monitor's levels in effect: Home Assistant's helpers where it has them.
    double[] Levels(ChartMonitor m) =>
        Chart.EffectiveLevels([m.Day, m.BlindDown, m.Night], live()?.Levels is { } lv && lv.TryGetValue(m.Id, out var ha) ? ha : null);

    /// The line's level for an elevation: Rules.Target's rule without its rounding, so the slopes draw smooth.
    static double Level(double[] l, double elev, double pos, Tuning t) {
        double daytime = l[1] + (l[0] - l[1]) * pos / 100;
        return l[2] + (daytime - l[2]) * t.Fraction(elev);
    }

    string Clock(double t) =>
        TimeZoneInfo.ConvertTime(day.Start.AddMinutes(Math.Round(t * day.Length / 60, MidpointRounding.AwayFromZero)), tz).ToString("HH:mm", CultureInfo.InvariantCulture);

    double Fraction(int hour) {
        var d = TimeZoneInfo.ConvertTime(day.Start, tz).Date.AddHours(hour);
        return (new DateTimeOffset(d, tz.GetUtcOffset(d)) - day.Start).TotalSeconds / day.Length;
    }

    /// Where the monitor is right now: the level the rules give with today's blind, clouds and lights and
    /// any hand-set distance. Without a reading from the last tick it is a preview with the blind open.
    Decision Decide(ChartMonitor m) {
        var l = Levels(m);
        var li = live();
        (int Value, double Weight)? o = li?.Offsets is { } offs && offs.TryGetValue(m.Id, out var ov) ? ov : null;
        int? linked = li?.Linked is { } lk && lk.TryGetValue(m.Id, out var lv) ? lv : null;
        return Chart.Explain(l[0], l[1], l[2], li?.Elev ?? Sun.Elevation(now, lat, lon), hasBlind ? li?.Pos ?? 100 : (double?)null,
                             li?.Lights ?? false, tuning(), li?.Light ?? 1, o?.Value, o?.Weight ?? 1,
                             linked, li?.Leader ?? "", li?.Applying ?? true);
    }

    /// "Now 77%" while Daylit sets it; "Target 77%" when Automatic is off or this PC is idle.
    string DotTitle => live()?.Applying == false ? "Target" : "Now";

    void Decides() {
        chips.Children.Clear();
        decidesTitle.Text = live() == null ? "How Daylit decides (preview, blind open)" : "How Daylit decides, right now";
        idle.Foreground = Palette.Secondary;
        idle.Visibility = live()?.Applying == false ? Visibility.Visible : Visibility.Collapsed;
        if (Mon is not { } m) return;
        var d = Decide(m);
        for (int i = 0; i < d.Steps.Count; i++) {
            var st = d.Steps[i];
            if (i > 0) chips.Children.Add(new TextBlock { Text = "\uE72A", FontFamily = Palette.Icons, FontSize = 9, Foreground = Palette.Secondary, Opacity = 0.7,
                                                          VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(5, 0, 5, 4) });
            var value = new TextBlock { Text = st.Value, FontSize = 12, FontWeight = st.Final ? FontWeights.Bold : FontWeights.Medium, Foreground = Palette.Text };
            Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular);
            chips.Children.Add(new Border {
                CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 4, 6, 4), Margin = new Thickness(0, 0, 0, 4), Background = Palette.Solid,
                Child = new StackPanel { Children = { new TextBlock { Text = st.Title, FontSize = 11, Foreground = Palette.Secondary }, value } } });
        }
    }

    /// The handle labels: the times today, or why there are none.
    string Title(bool isDay, HandlePlace p, Tuning t) {
        double value = isDay ? t.SunDay : t.SunNight;
        string degrees = dragging == (isDay ? SunDayId : SunNightId) ? $" · sun {Fmt(value)}° up" : "";
        if (p.Parked) {
            string v = Fmt(value);
            return (isDay, p.SunAbove) switch {
                (true, false) => $"No full brightness today: the sun stays under {v}°",
                (true, true) => $"Full brightness all day: the sun stays above {v}°",
                (false, false) => $"Night level all day: the sun stays under {v}°",
                (false, true) => $"No night level today: the sun stays above {v}°",
            };
        }
        return isDay ? "Full brightness today " + Sun.SpanLabel(Sun.Spans(samples, value), Clock) + degrees
                     : "Night level today: " + Sun.SpanLabel(Sun.Spans(samples, value, below: true), Clock) + degrees;
    }

    /// The drawn part: axis labels, the chart with its handles, the hours under it and the legend.
    sealed class Plot : FrameworkElement {
        const double AxisW = 40, Gap = 6, ChartH = 190, HoursH = 18, LegendH = 26;
        readonly BrightnessChart c;
        readonly List<(bool isDay, HandlePlace place, Rect r)> grips = new();
        HandlePlace? held;   // where the dragged handle was when the drag started (a parked one stays put until it leaves)
        bool heldDay;

        public Plot(BrightnessChart c) {
            this.c = c;
            Height = ChartH + HoursH + LegendH;
            Cursor = Cursors.Arrow;
            System.Windows.Automation.AutomationProperties.SetName(this, "Brightness through today");
        }

        static double X0 => AxisW + Gap;

        protected override void OnRender(DrawingContext dc) {
            double w = ActualWidth > 0 ? ActualWidth : Width;
            if (double.IsNaN(w) || w <= X0 || c.Mon is not { } m) return;
            double cw = w - X0, h = ChartH;
            double X(double t) => X0 + t * cw;
            double Y(double v) => h - v / 100 * h;
            double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
            FormattedText Text(string t, double size, Brush b, FontWeight? weight = null) =>
                new(t, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                    new Typeface(Palette.Ui, FontStyles.Normal, weight ?? FontWeights.Normal, FontStretches.Normal), size, b, dpi);
            Pen Dashed(Color col, byte a, double width, double dash, double gap) =>
                new(Solid(col, a), width) { DashStyle = new DashStyle([dash / width, gap / width], 0) };   // WPF dashes are in pen widths
            StreamGeometry Line(IEnumerable<Point> pts) {
                var list = pts.ToList();
                var g = new StreamGeometry();
                using (var ctx = g.Open()) {
                    ctx.BeginFigure(list[0], false, false);
                    ctx.PolyLineTo(list.Skip(1).ToList(), true, true);
                }
                g.Freeze();
                return g;
            }

            var t = c.tuning();
            var l = c.Levels(m);
            var s = c.samples;

            // 100% / 50% / 0% on the left
            foreach (var (v, label) in new[] { (100.0, "100%"), (50.0, "50%"), (0.0, "0%") }) {
                var ft = Text(label, 10, Palette.Secondary);
                dc.DrawText(ft, new Point(AxisW - ft.Width, Math.Clamp(Y(v) - ft.Height / 2, 0, h - ft.Height)));
            }

            var frame = new Rect(X0, 0, cw, h);
            dc.PushClip(new RectangleGeometry(frame, 8, 8));
            dc.DrawRectangle(Solid(NightColor, 15), null, frame);
            // full daytime brightness today, shaded
            foreach (var sp in Sun.Spans(s, t.SunDay))
                dc.DrawRectangle(Solid(DayColor, 23), null, new Rect(X(sp.From), 0, Math.Max(0, X(sp.To) - X(sp.From)), h));
            var grid = new Pen(Solid(Colors.Gray, 45), 1);
            foreach (double v in new[] { 25.0, 50, 75 }) dc.DrawLine(grid, new Point(X0, Y(v)), new Point(w, Y(v)));
            // the night level: the floor both lines share
            dc.DrawLine(Dashed(NightColor, 115, 1.5, 3, 3), new Point(X0, Y(l[2])), new Point(w, Y(l[2])));
            if (c.hasBlind)
                dc.DrawGeometry(null, Dashed(DayColor, 204, 2, 5, 4), Line(s.Select(p => new Point(X(p.t), Y(Level(l, p.e, 0, t))))));
            dc.DrawGeometry(null, new Pen(Solid(DayColor), 2.5) { LineJoin = PenLineJoin.Round },
                            Line(s.Select(p => new Point(X(p.t), Y(Level(l, p.e, 100, t))))));

            // now
            double nowT = (c.now - c.day.Start).TotalSeconds / c.day.Length;
            var d = c.Decide(m);
            dc.DrawEllipse(Palette.Text, new Pen(Palette.Solid, 2), new Point(X(nowT), Y(d.Level)), 5, 5);
            var nowText = Text($"{c.DotTitle} {d.Level}%", 11, Palette.Text, FontWeights.SemiBold);
            var nowCentre = new Point(Math.Clamp(X(nowT), X0 + 34, Math.Max(X0 + 34, w - 34)), Math.Max(Y(d.Level) - 13, 9));
            var nowPill = new Rect(nowCentre.X - nowText.Width / 2 - 4, nowCentre.Y - nowText.Height / 2, nowText.Width + 8, nowText.Height);
            dc.PushOpacity(0.85);
            dc.DrawRoundedRectangle(Palette.Solid, null, nowPill, nowPill.Height / 2, nowPill.Height / 2);
            dc.Pop();
            dc.DrawText(nowText, new Point(nowPill.X + 4, nowPill.Y));

            // handles: a grip on each crossing of each line, and a label under it, kept apart from the other
            grips.Clear();
            var specs = new[] { (isDay: true, color: DayColor, line: t.SunDay, row: Y(l[0])), (isDay: false, color: NightColor, line: t.SunNight, row: Y(l[2])) };
            var places = specs.Select(sp => Chart.Place(s, sp.line)).ToArray();
            var labelY = Layout.SpreadLabels(specs.Select(sp => sp.row + 24).ToArray(), 22, h);
            for (int i = 0; i < specs.Length; i++) {
                var sp = specs[i]; var p = places[i];
                var fill = Solid(sp.color, p.Parked ? (byte)140 : (byte)255);
                foreach (double at in p.Partner is double other ? new[] { p.At, other } : new[] { p.At }) {
                    var r = new Rect(X(at) - 6, sp.row - 13, 12, 26);
                    dc.DrawRoundedRectangle(fill, new Pen(Solid(Colors.Black, 40), 0.5), r, 6, 6);
                    for (int k = -1; k <= 1; k++) dc.DrawRectangle(Brushes.White, null, new Rect(r.X + 3, sp.row + k * 3.7 - 0.6, 6, 1.2));
                    var hit = r; hit.Inflate(8, 8);
                    grips.Add((sp.isDay, p, hit));
                }
                var label = Text(c.Title(sp.isDay, p, t), 12, Palette.Text, FontWeights.Medium);
                double half = label.Width / 2 + 11;   // the pill stays inside the chart, whatever its text
                double lx = Math.Clamp(X(p.At), X0 + half, Math.Max(X0 + half, w - half));
                var pill = new Rect(lx - label.Width / 2 - 7, labelY[i] - label.Height / 2 - 3, label.Width + 14, label.Height + 6);
                dc.DrawRoundedRectangle(Palette.Solid, new Pen(Palette.CardBorder, 1), pill, 6, 6);
                dc.DrawText(label, new Point(pill.X + 7, pill.Y + 3));
            }
            dc.Pop();
            dc.DrawRoundedRectangle(null, new Pen(Solid(Colors.Gray, 50), 1), new Rect(X0 + 0.5, 0.5, cw - 1, h - 1), 8, 8);

            // hours under the chart
            foreach (int hr in new[] { 0, 6, 12, 18 }) {
                var ft = Text($"{hr:00}:00", 10, Palette.Secondary);
                double x = X0 + Math.Max(16, c.Fraction(hr) * cw);
                dc.DrawText(ft, new Point(x - ft.Width / 2, h + 4));
            }

            // legend
            double lx0 = X0, ly = h + HoursH + LegendH / 2;
            void Key(Pen swatch, string text) {
                dc.DrawLine(swatch, new Point(lx0, ly), new Point(lx0 + 16, ly));
                var ft = Text(text, 12, Palette.Secondary);
                dc.DrawText(ft, new Point(lx0 + 21, ly - ft.Height / 2));
                lx0 += 21 + ft.Width + 14;
            }
            string Pct(double v) => ((int)v).ToString(CultureInfo.InvariantCulture);
            Key(new Pen(Solid(DayColor), 2.5), c.hasBlind ? $"Blind open · day {Pct(l[0])}%" : $"Day {Pct(l[0])}%");
            if (c.hasBlind) Key(new Pen(Solid(DayColor, 204), 2), $"Blind closed · {Pct(l[1])}%");
            Key(new Pen(Solid(NightColor, 115), 2), $"Night · {Pct(l[2])}%");
        }

        // Dragging a grip sideways moves its line to the sun's height at that time of day.
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) {
            var p = e.GetPosition(this);
            var hit = grips.LastOrDefault(g => g.r.Contains(p));
            if (hit.r.IsEmpty || hit.r.Width == 0) return;
            held = hit.place; heldDay = hit.isDay;
            c.dragging = hit.isDay ? SunDayId : SunNightId;
            CaptureMouse(); e.Handled = true;
            Drag(p);
        }
        protected override void OnMouseMove(MouseEventArgs e) {
            var p = e.GetPosition(this);
            Cursor = c.dragging != null || grips.Any(g => g.r.Contains(p)) ? Cursors.SizeWE : Cursors.Arrow;
            if (c.dragging != null) Drag(p);
        }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) {
            if (c.dragging == null) return;
            c.dragging = null; held = null; ReleaseMouseCapture();
            c.Update();
        }
        protected override void OnLostMouseCapture(MouseEventArgs e) {
            base.OnLostMouseCapture(e);
            if (c.dragging == null) return;
            c.dragging = null; held = null;
            c.Update();
        }

        void Drag(Point p) {
            if (held is not { } place) return;
            var t = c.tuning();
            double cw = ActualWidth - X0;
            if (cw <= 0) return;
            double at = Math.Clamp((p.X - X0) / cw, 0, 1);
            double other = heldDay ? t.SunNight : t.SunDay;
            if (Chart.DraggedElevation(c.samples, at, heldDay, other, place.Parked ? place.At : null) is double v)
                c.set(heldDay ? SunDayId : SunNightId, v);
            c.Update();
        }

        protected override Size MeasureOverride(Size available) =>
            new(double.IsInfinity(available.Width) ? 600 : available.Width, Height);
    }
}
