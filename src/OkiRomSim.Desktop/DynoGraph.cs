// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// The virtual dyno's graph: power (solid) and torque (dashed) of every run shown, against rpm, time or road speed, with the channels picked drawn in strips under it on the same axis. A run being replayed is drawn as far as its clock has got, so two runs played together race each other. Hovering reads every run off at the pointer; the wheel zooms in and out round it, dragging moves along, and a double-click picks the reading there (where it was in the maps). A right-click on a line is that run's own menu. Dark on screen, black on white for the printed sheet.
public sealed class DynoGraph : Control
{
    /// A run on the graph: its name, colour, the worked-out result, how far a replay has got, the run itself (for its menu) and its look.
    public sealed record Series(string Name, Color Colour, DynoResult Result, double? UpTo = null, DynoRun? Run = null, DynoStyle? Style = null);

    public List<Series> Runs { get; set; } = [];
    public DynoProfile Units { get; set; } = new();
    public string XAxis { get; set; } = "rpm";
    public bool Print { get; set; }

    /// A reading double-clicked: its run and the point.
    public event Action<Series, DynoPoint>? PointPicked;
    /// A right-click on a run's line (null: on the graph, off every line).
    public event Action<Series?, Point>? MenuWanted;

    public static readonly Color[] Palette =
    [
        Color.FromRgb(0xff, 0x5c, 0x5c), Color.FromRgb(0x4e, 0xa1, 0xff), Color.FromRgb(0x5c, 0xd6, 0x7a), Color.FromRgb(0xff, 0xc1, 0x4d),
        Color.FromRgb(0xc0, 0x8c, 0xff), Color.FromRgb(0x4d, 0xd9, 0xe0), Color.FromRgb(0xff, 0x8c, 0xd0), Color.FromRgb(0xe0, 0xe0, 0xe0),
    ];

    public DynoGraph()
    {
        ClipToBounds = true; MinHeight = 200; Focusable = true;
        Cursor = new Cursor(StandardCursorType.Cross);
    }

    IBrush Face => Print ? Brushes.White : AppTheme.Brush(Color.FromRgb(0x12, 0x13, 0x16));
    IBrush Ink => Print ? Brushes.Black : AppTheme.Brush(Color.FromRgb(0xb0, 0xb6, 0xc0));
    IPen GridPen => new Pen(AppTheme.Brush(Print ? Color.FromRgb(0xcc, 0xcc, 0xcc) : Color.FromRgb(0x2a, 0x2d, 0x33)), 1);

    double X(DynoPoint p, double t0) => XAxis switch { "time" => p.T - t0, "speed" => Calibration.Units.Show(p.Kmh, "km/h"), _ => p.Rpm };
    string XLabel => XAxis switch { "time" => "s", "speed" => Calibration.Units.Label(Calibration.Units.Shown("km/h")), _ => "rpm" };

    /// The points of a run to draw: its curve by rpm (time and speed axes take every point), as far as its replay has got.
    IEnumerable<DynoPoint> Shown(Series s)
    {
        var src = XAxis == "rpm" ? s.Result.Curve : s.Result.Points;
        if (s.Result.Points.Count == 0) return [];
        double t0 = s.Result.Points[0].T;
        return s.UpTo is double up ? src.Where(p => p.T - t0 <= up) : src;
    }

    static double Factor(Series s) => s.Style?.Factor is double f && f > 0 ? f : 1;
    double Power(Series s, DynoPoint p) => VirtualDyno.ToPower((Units.ShowCrank ? p.CrankW : p.WheelW) * Factor(s), Units.PowerUnit);
    double Torque(Series s, DynoPoint p) => VirtualDyno.ToTorque((Units.ShowCrank ? p.CrankTorqueNm : p.TorqueNm) * Factor(s), Units.TorqueUnit);
    static Color ColourOf(Series s) => s.Style?.Colour is { Length: > 0 } c && Color.TryParse(c, out var col) ? col : s.Colour;

    // ------------------------------------------------------------------ the view: zoom, pan, the pointer

    /// The x range shown when zoomed in (null: everything).
    (double Lo, double Hi)? _view;
    /// The whole x range, and the frame, of the last drawing: what the pointer is read against.
    double _x0, _x1, _pMax, _tMax;
    Rect _plot;
    List<(Series S, List<DynoPoint> P)> _drawn = [];
    Point? _pointer;
    Point? _dragFrom;
    (double Lo, double Hi) _dragView;

    public void ResetZoom() { _view = null; InvalidateVisual(); }
    public bool Zoomed => _view != null;

    double ToX(double px) => _x0 + ((px - _plot.X) / Math.Max(1, _plot.Width) * (_x1 - _x0));

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        if (_drawn.Count == 0 || _plot.Width < 10) return;
        var at = e.GetPosition(this);
        double x = ToX(at.X), lo = _x0, hi = _x1;
        double k = e.Delta.Y > 0 ? 0.8 : 1.25;
        var (fullLo, fullHi) = FullRange();
        double nlo = x - ((x - lo) * k), nhi = x + ((hi - x) * k);
        if (nhi - nlo >= (fullHi - fullLo) * 0.999) _view = null;
        else _view = (Math.Max(fullLo, nlo), Math.Min(fullHi, nhi));
        e.Handled = true;
        InvalidateVisual();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        var pt = e.GetCurrentPoint(this);
        var at = pt.Position;
        if (pt.Properties.IsRightButtonPressed)
        {
            MenuWanted?.Invoke(Nearest(at), at);
            e.Handled = true;
            return;
        }
        if (pt.Properties.IsMiddleButtonPressed) { ResetZoom(); e.Handled = true; return; }
        if (e.ClickCount == 2 && Pick(at) is { } hit) { PointPicked?.Invoke(hit.S, hit.P); e.Handled = true; return; }
        if (pt.Properties.IsLeftButtonPressed && _view != null) { _dragFrom = at; _dragView = _view.Value; e.Pointer.Capture(this); }
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var at = e.GetPosition(this);
        if (_dragFrom is { } from && _view != null)
        {
            double per = (_dragView.Hi - _dragView.Lo) / Math.Max(1, _plot.Width);
            double dx = (at.X - from.X) * per;
            var (fullLo, fullHi) = FullRange();
            double w = _dragView.Hi - _dragView.Lo, lo = Math.Clamp(_dragView.Lo - dx, fullLo, fullHi - w);
            _view = (lo, lo + w);
        }
        _pointer = at;
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        _dragFrom = null;
        e.Pointer.Capture(null);
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        _pointer = null;
        InvalidateVisual();
    }

    /// The point of each run nearest the pointer's x.
    IEnumerable<(Series S, DynoPoint P)> At(double px)
    {
        double x = ToX(px);
        foreach (var (s, pts) in _drawn)
        {
            if (pts.Count == 0) continue;
            double t0 = s.Result.Points[0].T;
            var near = pts.MinBy(p => Math.Abs(X(p, t0) - x))!;
            if (Math.Abs(X(near, t0) - x) <= Math.Max((_x1 - _x0) / 25, 1e-9)) yield return (s, near);
        }
    }

    /// The reading under a double-click: the nearest point of the run whose line is nearest.
    (Series S, DynoPoint P)? Pick(Point at)
    {
        if (!_plot.Contains(at)) return null;
        var near = At(at.X).ToList();
        if (near.Count == 0) return null;
        return near.MinBy(n => Math.Min(Math.Abs(PowerY(n.S, n.P) - at.Y), Math.Abs(TorqueY(n.S, n.P) - at.Y)));
    }

    /// The run whose power or torque line passes nearest the point (within 10 px), or null.
    Series? Nearest(Point at)
    {
        if (!_plot.Contains(at)) return null;
        Series? best = null; double bestD = 10;
        foreach (var (s, p) in At(at.X))
        {
            double d = Math.Min(s.Style?.ShowPower == false ? 1e9 : Math.Abs(PowerY(s, p) - at.Y), s.Style?.ShowTorque == false ? 1e9 : Math.Abs(TorqueY(s, p) - at.Y));
            if (d < bestD) { bestD = d; best = s; }
        }
        return best;
    }

    double PowerY(Series s, DynoPoint p) => _plot.Bottom - (_plot.Height * Power(s, p) / _pMax);
    double TorqueY(Series s, DynoPoint p) => _plot.Bottom - (_plot.Height * Torque(s, p) / _tMax);

    (double Lo, double Hi) FullRange()
    {
        var all = Runs.Where(s => s.Result.Points.Count > 0).ToList();
        if (all.Count == 0) return (0, 1);
        double lo = double.MaxValue, hi = double.MinValue;
        foreach (var s in all)
        {
            var src = XAxis == "rpm" ? s.Result.Curve : s.Result.Points;
            if (src.Count == 0) continue;
            double t0 = s.Result.Points[0].T;
            lo = Math.Min(lo, src.Min(p => X(p, t0))); hi = Math.Max(hi, src.Max(p => X(p, t0)));
        }
        if (lo > hi) return (0, 1);
        if (XAxis == "rpm") { lo = Math.Floor(lo / 500) * 500; hi = Math.Ceiling(hi / 500) * 500; }
        return hi - lo < 1 ? (lo, lo + 1) : (lo, hi);
    }

    // ------------------------------------------------------------------ drawing

    public override void Render(DrawingContext c)
    {
        var all = new Rect(0, 0, Bounds.Width, Bounds.Height);
        c.FillRectangle(Face, all);
        var overlays = Units.Overlays.Where(o => o.Length > 0).ToList();
        double stripH = overlays.Count == 0 ? 0 : Math.Min(110, (Bounds.Height - 60) * 0.18);
        const double L = 58, R = 58, T = 24, B = 26;
        double mainBottom = Bounds.Height - B - (stripH * overlays.Count);
        var plot = _plot = new Rect(L, T, Math.Max(10, Bounds.Width - L - R), Math.Max(10, mainBottom - T - 6));
        c.DrawRectangle(null, GridPen, plot);

        var series = Runs.Select(s => (S: s, P: Shown(s).ToList())).Where(x => x.P.Count > 0).ToList();
        _drawn = series;
        if (series.Count == 0)
        {
            Text(c, "No run yet: make a pull (the triggers or the Start button start and end it), or tick a saved run.", new Point(plot.X + 10, plot.Y + 10), 12, Ink);
            return;
        }
        // the axes: x from every run (or the zoom), power and torque each to their own peak
        var (x0, x1) = _view ?? FullRange();
        _x0 = x0; _x1 = x1;
        var fullSets = Runs.Where(s => s.Result.Curve.Count > 0).Select(s => (S: s, P: s.UpTo != null ? s.Result.Curve : Shown(s).ToList())).ToList();
        double pMax = _pMax = Nice(Math.Max(1, fullSets.Max(l => l.P.Count == 0 ? 0 : l.P.Max(p => Power(l.S, p)))) * 1.1);
        double tMax = _tMax = Nice(Math.Max(1, fullSets.Max(l => l.P.Count == 0 ? 0 : l.P.Max(p => Torque(l.S, p)))) * 1.1);
        double Px(double x) => plot.X + (plot.Width * (x - x0) / (x1 - x0));

        for (int i = 0; i <= 10; i++)
        {
            double x = plot.X + (plot.Width * i / 10);
            c.DrawLine(GridPen, new Point(x, plot.Y), new Point(x, Bounds.Height - B));
            double v = x0 + ((x1 - x0) * i / 10);
            Text(c, v.ToString(XAxis == "time" || x1 - x0 < 20 ? "0.0" : "0", CultureInfo.InvariantCulture), new Point(x - 14, Bounds.Height - B + 4), 10, Ink);
        }
        Text(c, XLabel + (_view != null ? "  (zoomed: middle-click or right-click > Reset zoom)" : ""), new Point(Bounds.Width - R + 6, Bounds.Height - B + 4), 10, Ink);
        for (int i = 0; i <= 5; i++)
        {
            double y = plot.Bottom - (plot.Height * i / 5);
            c.DrawLine(GridPen, new Point(plot.X, y), new Point(plot.Right, y));
            Text(c, (pMax * i / 5).ToString("0", CultureInfo.InvariantCulture), new Point(6, y - 7), 10, Ink);
            Text(c, (tMax * i / 5).ToString("0", CultureInfo.InvariantCulture), new Point(plot.Right + 6, y - 7), 10, Ink);
        }
        Text(c, (Units.ShowCrank ? "crank " : "wheel ") + Units.PowerUnit, new Point(6, 5), 10, Ink);
        Text(c, VirtualDyno.TorqueLabel(Units.TorqueUnit), new Point(plot.Right + 6, 5), 10, Ink);

        using (c.PushClip(plot))
            foreach (var (s, pts) in series)
            {
                double t0 = s.Result.Points[0].T;
                var brush = AppTheme.Brush(ColourOf(s));
                double w = s.Style?.Width is double sw && sw > 0 ? sw : 2.2;
                if (s.Style?.ShowPower != false)
                    Line(c, pts.Select(p => new Point(Px(X(p, t0)), plot.Bottom - (plot.Height * Power(s, p) / pMax))),
                         new Pen(brush, w, s.Style?.Dashed == true ? new DashStyle([6, 3], 0) : null, lineJoin: PenLineJoin.Round));
                if (s.Style?.ShowTorque != false)
                    Line(c, pts.Select(p => new Point(Px(X(p, t0)), plot.Bottom - (plot.Height * Torque(s, p) / tMax))), new Pen(brush, Math.Max(1, w * 0.72), new DashStyle([4, 3], 0), lineJoin: PenLineJoin.Round));
                if (s.UpTo != null && pts.Count > 0)
                {
                    var last = pts[^1];
                    c.DrawEllipse(brush, null, new Point(Px(X(last, t0)), plot.Bottom - (plot.Height * Power(s, last) / pMax)), 4.5, 4.5);
                }
            }

        // the legend: each run, its peaks (of what is drawn so far)
        double ly = plot.Y + 6;
        foreach (var (s, pts) in series)
        {
            var pk = pts.MaxBy(p => Power(s, p))!; var tq = pts.MaxBy(p => Torque(s, p))!;
            string line = $"{s.Name}   {Power(s, pk):0.0} {Units.PowerUnit} @ {pk.Rpm:0}   {Torque(s, tq):0.0} {VirtualDyno.TorqueLabel(Units.TorqueUnit)} @ {tq.Rpm:0}";
            var ft = Formatted(line, 11.5, AppTheme.Brush(ColourOf(s)));
            c.FillRectangle(Print ? Brushes.White : AppTheme.Brush(Color.FromArgb(0xc8, 0x12, 0x13, 0x16)), new Rect(plot.X + 6, ly - 1, ft.Width + 8, ft.Height + 2));
            c.DrawText(ft, new Point(plot.X + 10, ly));
            ly += ft.Height + 3;
        }

        // the strips under it: each channel picked, every run, the same x axis, in the units picked
        for (int k = 0; k < overlays.Count; k++)
        {
            var ch = overlays[k];
            var strip = new Rect(plot.X, mainBottom + (k * stripH), plot.Width, stripH - 4);
            c.DrawRectangle(null, GridPen, strip);
            string unit = ch.Equals("afr", StringComparison.OrdinalIgnoreCase) ? "AFR" : LogFrame.UnitOf(ch);
            double? V(DynoPoint p)
            {
                double? v = ch.Equals("afr", StringComparison.OrdinalIgnoreCase) ? p.Afr : p.Ch.TryGetValue(ch, out var x) ? x : null;
                return v is double d ? Calibration.Units.Show(d, unit) : null;
            }
            var vals = series.SelectMany(s => s.P.Select(V)).Where(v => v != null).Select(v => v!.Value).ToList();
            string shownUnit = Calibration.Units.Label(Calibration.Units.Shown(unit));
            Text(c, ch + (shownUnit.Length > 0 && !shownUnit.Equals(ch, StringComparison.OrdinalIgnoreCase) ? $" ({shownUnit})" : ""), new Point(6, strip.Y + 2), 10, Ink);
            if (vals.Count == 0) { Text(c, "not logged", new Point(strip.X + 6, strip.Y + 4), 10, Ink); continue; }
            double lo = vals.Min(), hi = vals.Max();
            if (hi - lo < 1e-6) { lo -= 1; hi += 1; }
            double pad = (hi - lo) * 0.1; lo -= pad; hi += pad;
            Text(c, hi.ToString("0.#", CultureInfo.InvariantCulture), new Point(plot.Right + 6, strip.Y), 9.5, Ink);
            Text(c, lo.ToString("0.#", CultureInfo.InvariantCulture), new Point(plot.Right + 6, strip.Bottom - 12), 9.5, Ink);
            using (c.PushClip(strip))
                foreach (var (s, pts) in series)
                {
                    double t0 = s.Result.Points[0].T;
                    Line(c, pts.Where(p => V(p) != null).Select(p => new Point(Px(X(p, t0)), strip.Bottom - (strip.Height * (V(p)!.Value - lo) / (hi - lo)))),
                         new Pen(AppTheme.Brush(ColourOf(s)), 1.4, lineJoin: PenLineJoin.Round));
                }
        }

        // the pointer: a line down the graph and every run read off at it
        if (!Print && _pointer is { } at && _dragFrom == null && plot.Contains(new Point(at.X, plot.Y + 1)))
        {
            c.DrawLine(new Pen(AppTheme.Brush(Color.FromArgb(0x90, 0xff, 0xff, 0xff)), 1, new DashStyle([2, 2], 0)), new Point(at.X, plot.Y), new Point(at.X, Bounds.Height - B));
            var lines = new List<(string Text, IBrush Brush)> { ($"{ToX(at.X).ToString(XAxis == "time" ? "0.00" : "0", CultureInfo.InvariantCulture)} {XLabel}", Ink) };
            foreach (var (s, p) in At(at.X))
            {
                var b = AppTheme.Brush(ColourOf(s));
                string more = (p.Afr is double afr ? $"  {Calibration.Units.Format(afr, "AFR", "0.0")}" : "")
                            + (p.Ch.TryGetValue("map_kpa", out var map) ? $"  {Calibration.Units.Format(map, "kPa", "0")}" : "")
                            + (p.Ch.TryGetValue("ign_deg", out var ign) ? $"  ign {ign:0.#}°" : "");
                lines.Add(($"{s.Name}: {p.Rpm:0} rpm  {Power(s, p):0.0} {Units.PowerUnit}  {Torque(s, p):0.0} {VirtualDyno.TorqueLabel(Units.TorqueUnit)}{more}", b));
                c.DrawEllipse(b, null, new Point(at.X, PowerY(s, p)), 3.5, 3.5);
            }
            var fts = lines.Select(l => Formatted(l.Text, 11, l.Brush)).ToList();
            double bw = fts.Max(f => f.Width) + 14, bh = fts.Sum(f => f.Height + 1) + 10;
            double bx = at.X + 14 + bw > plot.Right ? at.X - 14 - bw : at.X + 14;
            double by = Math.Clamp(at.Y - (bh / 2), plot.Y, Math.Max(plot.Y, plot.Bottom - bh));
            c.FillRectangle(AppTheme.Brush(Color.FromArgb(0xe8, 0x1c, 0x1e, 0x23)), new Rect(bx, by, bw, bh), 4);
            double y = by + 5;
            foreach (var f in fts) { c.DrawText(f, new Point(bx + 7, y)); y += f.Height + 1; }
            if (_drawn.Count > 0)
                Text(c, "double-click: where it was in the maps", new Point(bx + 7, by + bh + 2), 9.5, Ink);
        }
    }

    static void Line(DrawingContext c, IEnumerable<Point> pts, IPen pen)
    {
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            bool started = false;
            foreach (var p in pts)
            {
                if (double.IsNaN(p.Y) || double.IsInfinity(p.Y) || double.IsNaN(p.X)) continue;
                if (!started) { g.BeginFigure(p, false); started = true; } else g.LineTo(p);
            }
            if (started) g.EndFigure(false);
        }
        c.DrawGeometry(null, pen, geo);
    }

    static double Nice(double v)
    {
        double m = Math.Pow(10, Math.Floor(Math.Log10(v)));
        foreach (var f in new[] { 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) if (f * m >= v) return f * m;
        return 10 * m;
    }

    static FormattedText Formatted(string s, double size, IBrush brush) =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), size, brush);
    static void Text(DrawingContext c, string s, Point at, double size, IBrush brush) => c.DrawText(Formatted(s, size, brush), at);
}
