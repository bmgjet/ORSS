// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using OkiRomSim.Calibration;
using OkiRomSim.Core;
using Avalonia.Threading;

namespace OkiRomSim.Desktop;

/// Draws one gauge and keeps its recent history. Values arrive frame by frame; nothing is redrawn unless the reading actually moved, so a wall of gauges costs little.
public sealed class GaugeControl : Control
{
    public GaugeSpec Spec { get; }
    double _value = double.NaN;
    readonly List<(double T, double V)> _history = [];
    double _t;

    public GaugeControl(GaugeSpec spec)
    {
        Spec = spec;
        Width = spec.Width; Height = spec.Height;
        ToolTip.SetTip(this, $"{spec.Title}: the logged channel '{spec.Channel}', {spec.Min:0.##} to {spec.Max:0.##}. Drag to move it, drag the corner to resize.");
    }

    /// The gauge in the units picked in Settings > Units: a channel kept in °C, km/h or kPa, on a gauge set up in that unit, reads (and is scaled, and warns) in °F, mph or psi instead. The layout keeps what was set; only the drawing changes.
    string Native => _native ??= LogFrame.UnitOf(Spec.Channel);
    string? _native;
    bool Converts => Units.Of(Native) != null && Units.Shown(Native) != Native && (Spec.Unit.Length == 0 || Units.Label(Native).Equals(Spec.Unit.Trim(), StringComparison.OrdinalIgnoreCase));
    double Conv(double v) => Converts && !double.IsNaN(v) ? Units.Show(v, Native) : v;
    double Lo => Conv(Spec.Min);
    double Hi => Conv(Spec.Max);
    double? WarnAt => Spec.Warn is double w ? Conv(w) : null;
    string UnitText => Converts ? Units.Label(Units.Shown(Native)) : Spec.Unit;

    public void Show(LogFrame? f)
    {
        double v = Conv(f?.Get(Spec.Channel) ?? double.NaN);
        // both graph kinds keep a history: the bar graph draws the very same samples in slots, and leaving it out of this was why it never drew anything
        if (f != null) Add(f);
        if (double.IsNaN(v) && double.IsNaN(_value) && !Plots) return;
        // a graph redraws as time passes even when the reading is standing still
        if (!Plots && Math.Abs(v - _value) < (Hi - Lo) / 2000.0) return;
        _value = v;
        InvalidateVisual();
    }

    public void Clear() { _history.Clear(); _value = double.NaN; InvalidateVisual(); }

    /// One frame into the history without drawing (a replay catching up on the frames it went past). Time going backwards (the slider dragged back, a replay started again) or jumping further than the graph shows starts the history afresh, so old samples are never drawn against the new time.
    public void Add(LogFrame f)
    {
        _t = f.T;
        if (!Plots) return;
        if (_history.Count > 0)
        {
            double last = _history[^1].T;
            if (f.T < last - 1e-6 || f.T - last > Math.Max(1, Spec.Seconds)) _history.Clear();
            else if (f.T <= last) return;                  // the same frame again
        }
        double v = Conv(f.Get(Spec.Channel) ?? double.NaN);
        if (double.IsNaN(v)) return;
        _history.Add((f.T, v));
        double cut = f.T - Math.Max(1, Spec.Seconds);
        if (_history.Count > 8000 || _history[0].T < cut) _history.RemoveAll(p => p.T < cut);
    }

    /// True for the two kinds that draw a history rather than just the latest reading.
    bool Plots => Spec.Kind is GaugeKind.Graph or GaugeKind.BarGraph;

    /// The range a graph is drawn against: the gauge's own, unless the readings do not fit inside it (a channel left on the default 0-8000 would otherwise sit flat on the floor), in which case the samples decide.
    (double Lo, double Hi) PlotRange()
    {
        double lo = Lo, hi = Hi;
        if (_history.Count == 0) return hi > lo ? (lo, hi) : (0, 1);
        double dlo = double.MaxValue, dhi = double.MinValue;
        foreach (var (_, v) in _history) { if (v < dlo) dlo = v; if (v > dhi) dhi = v; }
        bool fits = hi > lo && dhi <= hi && dlo >= lo && (dhi - dlo) >= (hi - lo) / 50;
        if (fits) return (lo, hi);
        if (dhi - dlo < 1e-9) { dlo -= 1; dhi += 1; }
        double pad = (dhi - dlo) * 0.08;
        return (dlo - pad, dhi + pad);
    }

    static readonly IBrush Face = AppTheme.Brush(Color.FromRgb(0x1a, 0x1c, 0x20));
    static readonly IBrush Ink = AppTheme.Brush(Color.FromRgb(0xd7, 0xda, 0xe0));
    static readonly IBrush Dim = AppTheme.Brush(Color.FromRgb(0x7a, 0x80, 0x8c));
    static readonly IBrush Good = AppTheme.Brush(Color.FromRgb(0x4e, 0xc9, 0x7a));
    static readonly IBrush Warn = AppTheme.Brush(Color.FromRgb(0xff, 0xb3, 0x3a));
    static readonly IPen Edge = new Pen(AppTheme.Brush(Color.FromRgb(0x3a, 0x3d, 0x44)), 1);

    /// A colour the gauge was given, or the theme's own. Parsed once per colour and kept: this runs several times every time a gauge draws, and a colour that does not parse used to throw each time.
    static IBrush Pick(string hex, IBrush fallback)
    {
        if (string.IsNullOrWhiteSpace(hex)) return fallback;
        if (!Brushes_.TryGetValue(hex, out var b))
        {
            b = Color.TryParse(hex.Trim(), out var c) ? new ImmutableSolidColorBrush(c) : null;
            Brushes_[hex] = b;
        }
        return b ?? fallback;
    }

    static readonly Dictionary<string, IBrush?> Brushes_ = new(StringComparer.OrdinalIgnoreCase);

    // Text layout is the expensive part of drawing a gauge, and almost all of what a dial writes (its title, its scale numbers, its unit) is the same at every redraw: layouts and pens are kept and reused (the UI thread draws every gauge, so no lock). Cleared when it grows, for the readings, which take a new value each time.
    static readonly Dictionary<(string, double, IBrush, bool), FormattedText> Layouts = [];
    static readonly Dictionary<(IBrush, double), IPen> Pens = [];

    static FormattedText Layout(string text, double size, IBrush brush, bool bold = false)
    {
        var key = (text, size, brush, bold);
        if (Layouts.TryGetValue(key, out var ft)) return ft;
        if (Layouts.Count > 600) Layouts.Clear();
        return Layouts[key] = new FormattedText(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(MainWindow.MonoFont, FontStyle.Normal, bold ? FontWeight.Bold : FontWeight.Normal), size, brush);
    }

    static IPen PenOf(IBrush brush, double width)
    {
        var key = (brush, Math.Round(width, 2));
        if (Pens.TryGetValue(key, out var p)) return p;
        if (Pens.Count > 300) Pens.Clear();
        return Pens[key] = new Pen(brush, key.Item2);
    }

    /// Pictures, shared by every gauge that uses the same file and decoded 800 pixels wide: a 12-megapixel photo behind a 200-pixel gauge used to sit in memory at full size, once for every gauge showing it.
    static readonly Dictionary<string, Avalonia.Media.Imaging.Bitmap?> Pictures = new(StringComparer.OrdinalIgnoreCase);

    static Avalonia.Media.Imaging.Bitmap? Picture(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        if (Pictures.TryGetValue(path, out var bmp)) return bmp;
        try
        {
            if (File.Exists(path))
            {
                using var s = File.OpenRead(path);
                bmp = Avalonia.Media.Imaging.Bitmap.DecodeToWidth(s, 800, Avalonia.Media.Imaging.BitmapInterpolationMode.MediumQuality);
            }
        }
        catch (Exception ex) { AppLog.Error("gauges", "could not load " + path, ex); bmp = null; }
        Pictures[path] = bmp;
        return bmp;
    }

    IBrush FaceBrush => Pick(Spec.FaceColour, Face);
    IBrush InkBrush => Pick(Spec.TextColour, Ink);
    /// What the needle, the bar and the graph are drawn in (amber once past the warning).
    IBrush AccentBrush => Alarm ? Warn : Pick(Spec.AccentColour, Good);
    IBrush Accent(IBrush fallback) => Spec.AccentColour.Length > 0 ? Pick(Spec.AccentColour, fallback) : fallback;

    /// The picture behind the gauge.
    Avalonia.Media.Imaging.Bitmap? Image() => Picture(Spec.ImagePath);

    bool Alarm => WarnAt is double w && !double.IsNaN(_value) && (Spec.WarnBelow ? _value <= w : _value >= w);
    double Fraction => Hi <= Lo || double.IsNaN(_value) ? 0 : Math.Clamp((_value - Lo) / (Hi - Lo), 0, 1);
    string Text => double.IsNaN(_value) ? "--" : _value.ToString("F" + Math.Clamp(Spec.Decimals, 0, 3));

    /// The picture on the dial face.
    Avalonia.Media.Imaging.Bitmap? FaceImage() => Picture(Spec.FaceImagePath);

    bool _flashPending;

    double FaceAlpha => Math.Clamp(Spec.FaceOpacity, 0, 1);

    public override void Render(DrawingContext c)
    {
        var r = new Rect(0, 0, Bounds.Width, Bounds.Height);
        // the background picture first, then the face over it as solid as FaceOpacity says
        if (Image() is { } bmp)
            using (c.PushClip(new RoundedRect(r, 6)))
            using (c.PushOpacity(Math.Clamp(Spec.ImageOpacity, 0, 1)))
                c.DrawImage(bmp, new Rect(0, 0, bmp.Size.Width, bmp.Size.Height), r);
        using (c.PushOpacity(FaceAlpha))
            c.DrawRectangle(FaceBrush, null, r, 6, 6);
        c.DrawRectangle(null, Edge, r, 6, 6);
        // a face picture on the kinds without a dial covers the gauge's own area
        if (Spec.Kind != GaugeKind.Dial && Spec.Kind != GaugeKind.Arc && FaceImage() is { } face)
            using (c.PushClip(new RoundedRect(r.Deflate(2), 5)))
            using (c.PushOpacity(FaceAlpha))
                c.DrawImage(face, new Rect(0, 0, face.Size.Width, face.Size.Height), r.Deflate(2));
        switch (Spec.Kind)
        {
            case GaugeKind.Dial: DialFace(c, r); break;
            case GaugeKind.Bar: Bar(c, r); break;
            case GaugeKind.Light: Light(c, r); break;
            case GaugeKind.Graph: Graph(c, r, bars: false); break;
            case GaugeKind.BarGraph: Graph(c, r, bars: true); break;
            case GaugeKind.Arc: ArcSweep(c, r); break;
            case GaugeKind.ShiftLights: ShiftLights(c, r); break;
            case GaugeKind.Text: Caption(c, r, Spec.Title, Math.Clamp(r.Height * 0.5, 10, 40), InkBrush, (r.Height - Math.Clamp(r.Height * 0.5, 10, 40) * 1.3) / 2); break;
            default: Number(c, r); break;
        }
    }

    /// The dial's own face: the sunk disc, its picture, both as solid as FaceOpacity says.
    void DialDisc(DrawingContext c, Point centre, double radius)
    {
        using (c.PushOpacity(FaceAlpha))
        {
            c.DrawEllipse(Well, null, centre, radius, radius);
            if (FaceImage() is { } face)
            {
                var box = new Rect(centre.X - radius, centre.Y - radius, radius * 2, radius * 2);
                using (c.PushGeometryClip(new EllipseGeometry(box)))
                    c.DrawImage(face, new Rect(0, 0, face.Size.Width, face.Size.Height), box);
            }
        }
    }

    /// A digital-dash sweep: a thick track round the same 270 degrees a dial uses, filled up to the reading (red past the warning level), with the number big in the middle.
    void ArcSweep(DrawingContext c, Rect r)
    {
        var centre = new Point(r.Width / 2, (r.Height * 0.55) + 4);
        double radius = Math.Min(r.Width * 0.44, r.Height * 0.44);
        if (radius < 14) { Number(c, r); return; }
        double thick = Math.Max(4, radius * 0.16);
        DialDisc(c, centre, radius);
        c.DrawGeometry(null, new Pen(AppTheme.Brush(Color.FromRgb(0x22, 0x25, 0x2b)), thick, lineCap: PenLineCap.Flat), Arc(centre, radius - (thick / 2), 0, 1));
        if (Fraction > 0.001)
            c.DrawGeometry(null, new Pen(AccentBrush, thick, lineCap: PenLineCap.Flat), Arc(centre, radius - (thick / 2), 0, Fraction));
        double span = Hi - Lo;
        if (span > 0 && WarnAt is double warn)
        {
            double wf = Math.Clamp((warn - Lo) / span, 0, 1);
            var (a, b) = Spec.WarnBelow ? (0.0, wf) : (wf, 1.0);
            if (b - a > 0.002) c.DrawGeometry(null, new Pen(Red, Math.Max(2, thick * 0.25)), Arc(centre, radius + 1, a, b));
        }
        Caption(c, r, Spec.Title, Math.Clamp(radius * 0.16, 9, 13), Dim, 3);
        double big = Math.Clamp(radius * 0.42, 12, 64);
        var ft = Layout(Text, big, Alarm ? Warn : InkBrush, bold: true);
        c.DrawText(ft, new Point(centre.X - (ft.Width / 2), centre.Y - (ft.Height / 2)));
        if (UnitText.Length > 0) At(c, UnitText, new Point(centre.X, centre.Y + (ft.Height * 0.62)), Math.Clamp(radius * 0.14, 8, 13), Dim);
    }

    /// A row of shift lights across the gauge: they come on in turn from Min to the warning level (or Max) - green, amber, then red - and all flash once the reading is past the warning.
    void ShiftLights(DrawingContext c, Rect r)
    {
        int n = Math.Clamp(Spec.Ticks, 3, 20);
        double top = WarnAt ?? Hi, span = top - Lo;
        double lit = span <= 0 || double.IsNaN(_value) ? 0 : Math.Clamp((_value - Lo) / span, 0, 1) * n;
        bool flash = Alarm && (DateTime.UtcNow.Millisecond / 125) % 2 == 0;
        double gap = 4, w = (r.Width - 12 - (gap * (n - 1))) / n;
        double d = Math.Max(4, Math.Min(w, r.Height - 10));
        for (int i = 0; i < n; i++)
        {
            double f = (double)i / Math.Max(1, n - 1);
            var on = f < 0.55 ? Color.FromRgb(0x3c, 0xe0, 0x5a) : f < 0.85 ? Color.FromRgb(0xff, 0xc4, 0x2a) : Color.FromRgb(0xff, 0x3a, 0x3a);
            bool isOn = Alarm ? flash : i < lit;
            var brush = isOn ? AppTheme.Brush(on) : AppTheme.Brush(Color.FromArgb(0x55, on.R, on.G, on.B));
            var centre = new Point(6 + (i * (w + gap)) + (w / 2), r.Height / 2);
            c.DrawEllipse(brush, Edge, centre, d / 2, d / 2);
        }
        if (Alarm && !_flashPending)
        {
            _flashPending = true;
            DispatcherTimer.RunOnce(() => { _flashPending = false; InvalidateVisual(); }, TimeSpan.FromMilliseconds(120));
        }
    }

    void Caption(DrawingContext c, Rect r, string text, double size, IBrush brush, double y, bool centre = true)
    {
        var ft = Layout(text, size, brush);
        c.DrawText(ft, new Point(centre ? (r.Width - ft.Width) / 2 : 8, y));
    }

    /// Text centred on a point (the dial's scale numbers).
    void At(DrawingContext c, string text, Point p, double size, IBrush brush)
    {
        var ft = Layout(text, size, brush);
        c.DrawText(ft, new Point(p.X - (ft.Width / 2), p.Y - (ft.Height / 2)));
    }

    /// A scale number as short as it can still be read: 8000 rpm as "8000", 14.7 AFR as "14.7", 0.45 V as "0.45".
    static string Mark(double v, double span) =>
        span >= 200 || Math.Abs(v) >= 1000 ? v.ToString("0")
        : span >= 2 ? v.ToString("0.#")
        : v.ToString("0.##");

    static readonly IBrush Bezel = AppTheme.Brush(Color.FromRgb(0x24, 0x27, 0x2d));
    static readonly IBrush Well = AppTheme.Brush(Color.FromRgb(0x10, 0x11, 0x14));
    static readonly IBrush Hub = AppTheme.Brush(Color.FromRgb(0x33, 0x36, 0x3d));
    static readonly IBrush Red = AppTheme.Brush(Color.FromRgb(0xe0, 0x3a, 0x3a));

    /// An arc along the dial's own sweep, from one fraction of the scale to another.
    static Geometry Arc(Point centre, double radius, double from, double to)
    {
        var geo = new StreamGeometry();
        using var g = geo.Open();
        var (sx, sy) = Dial.Direction(from);
        g.BeginFigure(new Point(centre.X + (sx * radius), centre.Y + (sy * radius)), false);
        int steps = Math.Max(2, (int)(Math.Abs(to - from) * 60));
        for (int i = 1; i <= steps; i++)
        {
            var (dx, dy) = Dial.Direction(from + ((to - from) * i / steps));
            g.LineTo(new Point(centre.X + (dx * radius), centre.Y + (dy * radius)));
        }
        g.EndFigure(false);
        return geo;
    }

    /// A proper round dial: a sunk face inside a bezel, a graded scale with its numbers printed round it, a red zone past the warning level, a tapered needle on a hub, and the reading in a box underneath.
    void DialFace(DrawingContext c, Rect r)
    {
        double span = Hi - Lo;
        var centre = new Point(r.Width / 2, (r.Height * 0.58) + 5);
        double radius = Math.Min(r.Width * 0.46, r.Height * 0.45);
        if (radius < 14) { Number(c, r); return; }
        double labels = radius * 0.68;
        double tickOut = radius * 0.94, tickIn = radius * 0.82, minorIn = radius * 0.88;
        double text = Math.Clamp(radius * 0.18, 6.5, 12);

        DialDisc(c, centre, radius);
        c.DrawEllipse(null, new Pen(Bezel, Math.Max(2, radius * 0.06)), centre, radius, radius);
        c.DrawGeometry(null, new Pen(Accent(Dim), Math.Max(1, radius * 0.035)), Arc(centre, tickOut, 0, 1));
        // the red zone: everything past the warning level (or below it, for a low warning such as battery volts)
        if (span > 0 && WarnAt is double warn)
        {
            double wf = Math.Clamp((warn - Lo) / span, 0, 1);
            var (a, b) = Spec.WarnBelow ? (0.0, wf) : (wf, 1.0);
            if (b - a > 0.002) c.DrawGeometry(null, new Pen(Red, Math.Max(2, radius * 0.07)), Arc(centre, tickOut, a, b));
        }

        int majors = Math.Clamp(Spec.Ticks, 2, 12);
        int minors = majors <= 6 ? 5 : 2;
        for (int i = 0; i <= majors * minors; i++)
        {
            double f = (double)i / (majors * minors);
            var (dx, dy) = Dial.Direction(f);
            bool major = i % minors == 0;
            bool hot = span > 0 && WarnAt is double wv &&
                       (Spec.WarnBelow ? Lo + (span * f) <= wv : Lo + (span * f) >= wv);
            double from = major ? tickIn : minorIn;
            c.DrawLine(PenOf(hot ? Red : major ? InkBrush : Dim, major ? Math.Max(1.5, radius * 0.045) : 1),
                       new Point(centre.X + (dx * from), centre.Y + (dy * from)),
                       new Point(centre.X + (dx * tickOut), centre.Y + (dy * tickOut)));
            if (major && radius >= 32)
                At(c, Mark(Lo + (span * f), span), new Point(centre.X + (dx * labels), centre.Y + (dy * labels)),
                   text, hot ? Red : InkBrush);
        }

        // the needle: a triangle from the hub, with a short counterweight behind it
        var (ndx, ndy) = Dial.Direction(Fraction);
        var tip = new Point(centre.X + (ndx * radius * 0.78), centre.Y + (ndy * radius * 0.78));
        double w = Math.Max(1.6, radius * 0.055);
        var needle = new StreamGeometry();
        using (var g = needle.Open())
        {
            g.BeginFigure(tip, true);
            g.LineTo(new Point(centre.X - (ndy * w) - (ndx * radius * 0.12), centre.Y + (ndx * w) - (ndy * radius * 0.12)));
            g.LineTo(new Point(centre.X + (ndy * w) - (ndx * radius * 0.12), centre.Y - (ndx * w) - (ndy * radius * 0.12)));
            g.EndFigure(true);
        }
        c.DrawGeometry(AccentBrush, null, needle);
        double hub = Math.Max(3, radius * 0.11);
        c.DrawEllipse(Hub, new Pen(AccentBrush, 1.5), centre, hub, hub);

        Caption(c, r, Spec.Title, Math.Clamp(radius * 0.2, 9, 12), Dim, 3);
        // the reading, in a box under the needle where a digital dial puts it
        string reading = Text + (UnitText.Length > 0 ? " " + UnitText : "");
        double rs = Math.Clamp(radius * 0.26, 10, 18);
        var rft = Layout(reading, rs, Alarm ? Warn : InkBrush, bold: true);
        var box = new Rect(((r.Width - rft.Width) / 2) - 6, centre.Y + (radius * 0.32), rft.Width + 12, rft.Height + 4);
        if (box.Bottom > r.Height - 2) box = box.WithY(Math.Max(centre.Y, r.Height - 2 - box.Height));
        c.DrawRectangle(Well, new Pen(Bezel, 1), box, 3, 3);
        c.DrawText(rft, new Point(box.X + 6, box.Y + 2));
    }

    void Bar(DrawingContext c, Rect r)
    {
        Caption(c, r, Spec.Title, 11, Dim, 5, centre: false);
        double h = Math.Max(10, r.Height - 40);
        var track = new Rect(8, 24, Math.Max(4, r.Width - 16), h * 0.5);
        c.DrawRectangle(AppTheme.Brush(Color.FromRgb(0x2a, 0x2d, 0x33)), null, track, 3, 3);
        c.DrawRectangle(AccentBrush, null, track.WithWidth(track.Width * Fraction), 3, 3);
        Caption(c, r, Text + (UnitText.Length > 0 ? " " + UnitText : ""), 13, Alarm ? Warn : InkBrush, track.Bottom + 4);
    }

    void Number(DrawingContext c, Rect r)
    {
        Caption(c, r, Spec.Title, 11, Dim, 6);
        Caption(c, r, Text, Math.Clamp(r.Height * 0.38, 14, 48), Alarm ? Warn : InkBrush, r.Height * 0.32);
        if (UnitText.Length > 0) Caption(c, r, UnitText, 11, Dim, r.Height - 18);
    }

    /// A trigger light: on when the channel is past its threshold (VTEC engaged, a knock flag).
    void Light(DrawingContext c, Rect r)
    {
        bool on = Alarm || (WarnAt == null && _value >= 0.5);
        var centre = new Point(r.Width / 2, (r.Height / 2) + 6);
        double rad = Math.Min(r.Width, r.Height) * 0.22;
        c.DrawEllipse(on ? (Spec.AccentColour.Length > 0 ? Pick(Spec.AccentColour, Warn) : Warn) : AppTheme.Brush(Color.FromRgb(0x33, 0x36, 0x3c)),
                      Edge, centre, rad, rad);
        Caption(c, r, Spec.Title, 11, on ? InkBrush : Dim, 6);
    }

    /// A rolling graph of the last `Seconds` of the channel: a line, or bars. The vertical range is the gauge's own unless the readings do not fit inside it, and its ends are printed down the left so the trace can be read off.
    void Graph(DrawingContext c, Rect r, bool bars)
    {
        Caption(c, r, $"{Spec.Title}  {Text}{(UnitText.Length > 0 ? " " + UnitText : "")}", 11, Alarm ? Warn : Dim, 4, centre: false);
        var (lo, hi) = PlotRange();
        double gutter = r.Width > 120 ? 34 : 6;
        var plot = new Rect(gutter, 20, Math.Max(4, r.Width - gutter - 6), Math.Max(4, r.Height - 30));
        c.DrawRectangle(Well, Edge, plot);
        for (int i = 0; i <= 2; i++)
        {
            double y = plot.Y + (plot.Height * i / 2);
            c.DrawLine(new Pen(Bezel, 1), new Point(plot.X, y), new Point(plot.Right, y));
            if (gutter <= 6) continue;
            var ft = Layout(Mark(hi - ((hi - lo) * i / 2), hi - lo), 8.5, Dim);
            c.DrawText(ft, new Point(Math.Max(1, plot.X - ft.Width - 3), y - (ft.Height / 2)));
        }
        if (WarnAt is double warn && hi > lo && warn > lo && warn < hi)
        {
            double y = plot.Bottom - (plot.Height * (warn - lo) / (hi - lo));
            c.DrawLine(new Pen(Red, 1, DashStyle.Dash), new Point(plot.X, y), new Point(plot.Right, y));
        }
        if (_history.Count < 2)
        {
            Caption(c, r, _history.Count == 0 ? "waiting for " + Spec.Channel : "\u2026", 10, Dim, plot.Y + (plot.Height / 2));
            return;
        }
        double t1 = _history[^1].T, t0 = t1 - Math.Max(1, Spec.Seconds);
        double tspan = Math.Max(1e-6, t1 - t0), vspan = Math.Max(1e-9, hi - lo);
        double F(double v) => Math.Clamp((v - lo) / vspan, 0, 1);
        if (bars)
        {
            int slots = Math.Clamp((int)(plot.Width / 5), 8, 200);
            double w = plot.Width / slots;
            for (int i = 0; i < slots; i++)
            {
                double a0 = t0 + (tspan * i / slots), a1 = t0 + (tspan * (i + 1) / slots);
                double sum = 0; int n = 0;
                foreach (var (t, v) in _history) if (t >= a0 && t < a1) { sum += v; n++; }
                if (n == 0) continue;
                double mean = sum / n;
                double h = Math.Max(1, plot.Height * F(mean));
                bool hot = WarnAt is double wv && (Spec.WarnBelow ? mean <= wv : mean >= wv);
                c.DrawRectangle(hot ? Warn : AccentBrush, null,
                                new Rect(plot.X + (i * w) + 0.5, plot.Bottom - h, Math.Max(1, w - 1), h));
            }
            return;
        }
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            bool started = false;
            foreach (var (t, v) in _history)
            {
                if (t < t0) continue;
                var pt = new Point(plot.X + (plot.Width * Math.Clamp((t - t0) / tspan, 0, 1)), plot.Bottom - (plot.Height * F(v)));
                if (!started) { g.BeginFigure(pt, false); started = true; }
                else g.LineTo(pt);
            }
            if (started) g.EndFigure(false);
        }
        c.DrawGeometry(null, new Pen(AccentBrush, 1.6, lineJoin: PenLineJoin.Round), geo);
    }
}
