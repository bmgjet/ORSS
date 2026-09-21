using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Draws one gauge and keeps its recent history. Values arrive frame by frame; nothing is redrawn unless the reading actually moved, so a wall of gauges costs little.
public sealed class GaugeControl : Control
{
    public GaugeSpec Spec { get; }
    double _value = double.NaN;
    readonly List<(double T, double V)> _history = new();
    double _t;

    public GaugeControl(GaugeSpec spec)
    {
        Spec = spec;
        Width = spec.Width; Height = spec.Height;
        ToolTip.SetTip(this, $"{spec.Title}: the logged channel '{spec.Channel}', {spec.Min:0.##} to {spec.Max:0.##}. Drag to move it, drag the corner to resize.");
    }

    public void Show(LogFrame? f)
    {
        double v = f?.Get(Spec.Channel) ?? double.NaN;
        _t = f?.T ?? _t;
        if (Spec.Kind == GaugeKind.Graph && !double.IsNaN(v))
        {
            _history.Add((_t, v));
            double cut = _t - Math.Max(1, Spec.Seconds);
            if (_history.Count > 4000 || _history[0].T < cut) _history.RemoveAll(p => p.T < cut);
        }
        if (double.IsNaN(v) && double.IsNaN(_value)) return;
        if (Math.Abs(v - _value) < (Spec.Max - Spec.Min) / 2000.0 && Spec.Kind != GaugeKind.Graph) return;
        _value = v;
        InvalidateVisual();
    }

    public void Clear() { _history.Clear(); _value = double.NaN; InvalidateVisual(); }

    static readonly IBrush Face = new SolidColorBrush(Color.FromRgb(0x1a, 0x1c, 0x20));
    static readonly IBrush Ink = new SolidColorBrush(Color.FromRgb(0xd7, 0xda, 0xe0));
    static readonly IBrush Dim = new SolidColorBrush(Color.FromRgb(0x7a, 0x80, 0x8c));
    static readonly IBrush Good = new SolidColorBrush(Color.FromRgb(0x4e, 0xc9, 0x7a));
    static readonly IBrush Warn = new SolidColorBrush(Color.FromRgb(0xff, 0xb3, 0x3a));
    static readonly IPen Edge = new Pen(new SolidColorBrush(Color.FromRgb(0x3a, 0x3d, 0x44)), 1);

    /// A colour the gauge was given, or the theme's own.
    static IBrush Pick(string hex, IBrush fallback)
    {
        if (string.IsNullOrWhiteSpace(hex)) return fallback;
        try { return new SolidColorBrush(Color.Parse(hex)); } catch { return fallback; }
    }

    IBrush FaceBrush => Pick(Spec.FaceColour, Face);
    IBrush InkBrush => Pick(Spec.TextColour, Ink);
    /// What the needle, the bar and the graph are drawn in (amber once past the warning).
    IBrush AccentBrush => Alarm ? Warn : Pick(Spec.AccentColour, Good);
    IBrush Accent(IBrush fallback) => Spec.AccentColour.Length > 0 ? Pick(Spec.AccentColour, fallback) : fallback;

    /// The picture behind the gauge, loaded once and kept.
    Avalonia.Media.Imaging.Bitmap? _image;
    string _imageFrom = "";
    Avalonia.Media.Imaging.Bitmap? Image()
    {
        if (Spec.ImagePath == _imageFrom) return _image;
        _imageFrom = Spec.ImagePath;
        _image?.Dispose();
        _image = null;
        try { if (File.Exists(Spec.ImagePath)) _image = new Avalonia.Media.Imaging.Bitmap(Spec.ImagePath); }
        catch (Exception ex) { AppLog.Error("gauges", "could not load " + Spec.ImagePath, ex); }
        return _image;
    }

    bool Alarm => Spec.Warn is double w && !double.IsNaN(_value) && (Spec.WarnBelow ? _value <= w : _value >= w);
    double Fraction => Spec.Max <= Spec.Min || double.IsNaN(_value) ? 0 : Math.Clamp((_value - Spec.Min) / (Spec.Max - Spec.Min), 0, 1);
    string Text => double.IsNaN(_value) ? "--" : _value.ToString("F" + Math.Clamp(Spec.Decimals, 0, 3));

    public override void Render(DrawingContext c)
    {
        var r = new Rect(0, 0, Bounds.Width, Bounds.Height);
        c.DrawRectangle(FaceBrush, Edge, r, 6, 6);
        if (Image() is { } bmp)
            using (c.PushOpacity(Math.Clamp(Spec.ImageOpacity, 0, 1)))
                c.DrawImage(bmp, new Rect(0, 0, bmp.Size.Width, bmp.Size.Height), r);
        switch (Spec.Kind)
        {
            case GaugeKind.Dial: DialFace(c, r); break;
            case GaugeKind.Bar: Bar(c, r); break;
            case GaugeKind.Light: Light(c, r); break;
            case GaugeKind.Graph: Graph(c, r, bars: false); break;
            case GaugeKind.BarGraph: Graph(c, r, bars: true); break;
            default: Number(c, r); break;
        }
    }

    void Caption(DrawingContext c, Rect r, string text, double size, IBrush brush, double y, bool centre = true)
    {
        var ft = new FormattedText(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                                   new Typeface(MainWindow.MonoFont), size, brush);
        c.DrawText(ft, new Point(centre ? (r.Width - ft.Width) / 2 : 8, y));
    }

    /// A round dial with a needle, ticks every tenth of the range, and a red zone past the warning.
    void DialFace(DrawingContext c, Rect r)
    {
        var centre = new Point(r.Width / 2, r.Height * 0.68);
        double radius = Math.Min(r.Width / 2, r.Height * 0.62) - 12;
        int ticks = Math.Clamp(Spec.Ticks, 2, 40);
        for (int i = 0; i <= ticks; i++)
        {
            var (dx, dy) = Dial.Direction((double)i / ticks);
            var dir = new Point(dx, dy);
            bool hot = Spec.Warn is double wv && Spec.Min + (Spec.Max - Spec.Min) * i / ticks >= wv;
            c.DrawLine(new Pen(hot ? Warn : Accent(Dim), i % 5 == 0 ? 2 : 1),
                       new Point(centre.X + dir.X * (radius - 8), centre.Y + dir.Y * (radius - 8)),
                       new Point(centre.X + dir.X * radius, centre.Y + dir.Y * radius));
        }
        var (ndx, ndy) = Dial.Direction(Fraction);
        var nd = new Point(ndx, ndy);
        c.DrawLine(new Pen(AccentBrush, 2.5), centre, new Point(centre.X + nd.X * (radius - 10), centre.Y + nd.Y * (radius - 10)));
        c.DrawEllipse(AccentBrush, null, centre, 3.5, 3.5);
        Caption(c, r, Spec.Title, 11, Dim, 6);
        Caption(c, r, Text + (Spec.Unit.Length > 0 ? " " + Spec.Unit : ""), 15, Alarm ? Warn : InkBrush, r.Height - 24);
    }

    void Bar(DrawingContext c, Rect r)
    {
        Caption(c, r, Spec.Title, 11, Dim, 5, centre: false);
        double h = Math.Max(10, r.Height - 40);
        var track = new Rect(8, 24, Math.Max(4, r.Width - 16), h * 0.5);
        c.DrawRectangle(new SolidColorBrush(Color.FromRgb(0x2a, 0x2d, 0x33)), null, track, 3, 3);
        c.DrawRectangle(AccentBrush, null, track.WithWidth(track.Width * Fraction), 3, 3);
        Caption(c, r, Text + (Spec.Unit.Length > 0 ? " " + Spec.Unit : ""), 13, Alarm ? Warn : InkBrush, track.Bottom + 4);
    }

    void Number(DrawingContext c, Rect r)
    {
        Caption(c, r, Spec.Title, 11, Dim, 6);
        Caption(c, r, Text, Math.Clamp(r.Height * 0.38, 14, 48), Alarm ? Warn : InkBrush, r.Height * 0.32);
        if (Spec.Unit.Length > 0) Caption(c, r, Spec.Unit, 11, Dim, r.Height - 18);
    }

    /// A trigger light: on when the channel is past its threshold (VTEC engaged, a knock flag).
    void Light(DrawingContext c, Rect r)
    {
        bool on = Alarm || (Spec.Warn == null && _value >= 0.5);
        var centre = new Point(r.Width / 2, r.Height / 2 + 6);
        double rad = Math.Min(r.Width, r.Height) * 0.22;
        c.DrawEllipse(on ? (Spec.AccentColour.Length > 0 ? Pick(Spec.AccentColour, Warn) : Warn) : new SolidColorBrush(Color.FromRgb(0x33, 0x36, 0x3c)),
                      Edge, centre, rad, rad);
        Caption(c, r, Spec.Title, 11, on ? InkBrush : Dim, 6);
    }

    /// A rolling graph of the last `Seconds` of the channel: a line, or bars.
    void Graph(DrawingContext c, Rect r, bool bars)
    {
        Caption(c, r, $"{Spec.Title}  {Text}{(Spec.Unit.Length > 0 ? " " + Spec.Unit : "")}", 11, Alarm ? Warn : Dim, 4, centre: false);
        var plot = new Rect(6, 20, Math.Max(4, r.Width - 12), Math.Max(4, r.Height - 28));
        c.DrawRectangle(null, Edge, plot);
        if (_history.Count < 2) return;
        double t1 = _history[^1].T, t0 = t1 - Math.Max(1, Spec.Seconds);
        if (bars)
        {
            int slots = Math.Clamp((int)(plot.Width / 5), 8, 120);
            double w = plot.Width / slots;
            for (int i = 0; i < slots; i++)
            {
                double a0 = t0 + (t1 - t0) * i / slots, a1 = t0 + (t1 - t0) * (i + 1) / slots;
                double sum = 0; int n = 0;
                foreach (var (t, v) in _history) if (t >= a0 && t < a1) { sum += v; n++; }
                if (n == 0) continue;
                double f = Spec.Max <= Spec.Min ? 0 : Math.Clamp((sum / n - Spec.Min) / (Spec.Max - Spec.Min), 0, 1);
                c.DrawRectangle(AccentBrush, null, new Rect(plot.X + i * w + 0.5, plot.Bottom - plot.Height * f, Math.Max(1, w - 1), plot.Height * f));
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
                double x = plot.X + plot.Width * Math.Clamp((t - t0) / (t1 - t0), 0, 1);
                double f = Spec.Max <= Spec.Min ? 0 : Math.Clamp((v - Spec.Min) / (Spec.Max - Spec.Min), 0, 1);
                var pt = new Point(x, plot.Bottom - plot.Height * f);
                if (!started) { g.BeginFigure(pt, false); started = true; }
                else g.LineTo(pt);
            }
            if (started) g.EndFigure(false);
        }
        c.DrawGeometry(null, new Pen(AccentBrush, 1.5), geo);
    }
}
