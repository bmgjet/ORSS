// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace AlphaEmuPlugin;

/// A lamp on the ALPHA dash: a glowing dot with a label, the way the ECU's own tell-tales look.
public sealed class LedLamp : Control
{
    public static readonly StyledProperty<bool> OnProperty = AvaloniaProperty.Register<LedLamp, bool>(nameof(On));
    public bool On { get => GetValue(OnProperty); set => SetValue(OnProperty, value); }
    public static readonly StyledProperty<Color> ColourProperty = AvaloniaProperty.Register<LedLamp, Color>(nameof(Colour), Alpha.Cyan);
    public Color Colour { get => GetValue(ColourProperty); set => SetValue(ColourProperty, value); }
    public string Label { get => _label; set { _label = value; InvalidateMeasure(); InvalidateVisual(); } } string _label = "";
    public double Dot { get => _dot; set { _dot = value; InvalidateMeasure(); } } double _dot = 9;


    static LedLamp() => AffectsRender<LedLamp>(OnProperty, ColourProperty);

    public LedLamp() { Height = 18; }

    protected override Size MeasureOverride(Size available)
    {
        var ft = Label.Length > 0 ? Text(Label, 10, Alpha.DimColour, FontWeight.SemiBold) : null;
        return new Size(Dot + 6 + (ft?.Width ?? 0), Math.Max(Alpha.Fin(Height, Dot), Dot));
    }

    public override void Render(DrawingContext ctx)
    {
        double cy = Bounds.Height / 2, r = Dot / 2, x = r;
        if (On)
        {
            ctx.DrawEllipse(Alpha.Tint(Colour, 40), null, new Point(x, cy), r * 2.1, r * 2.1);
            ctx.DrawEllipse(new SolidColorBrush(Colour), null, new Point(x, cy), r, r);
            ctx.DrawEllipse(Alpha.Tint(Colors.White, 200), null, new Point(x - r * 0.25, cy - r * 0.25), r * 0.35, r * 0.35);
        }
        else
        {
            ctx.DrawEllipse(Alpha.Tint(Colour, 30), new Pen(Alpha.Tint(Colour, 90), 1), new Point(x, cy), r, r);
        }
        if (Label.Length > 0)
        {
            var ft = Text(Label, 10, On ? Alpha.InkColour : Alpha.DimColour, FontWeight.SemiBold);
            ctx.DrawText(ft, new Point(Dot + 6, cy - ft.Height / 2));
        }
    }

    internal static FormattedText Text(string s, double size, Color colour, FontWeight? weight = null, bool mono = false,
                                       TextAlignment align = TextAlignment.Left)
        => new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
               new Typeface(mono ? Alpha.Mono : Alpha.Face, FontStyle.Normal, weight ?? FontWeight.Normal),
               size, new SolidColorBrush(colour)) { TextAlignment = align };

    /// Draw text with its centre at (x, y).
    internal static void DrawCentre(DrawingContext ctx, FormattedText ft, double x, double y)
        => ctx.DrawText(ft, new Point(x - ft.Width / 2, y - ft.Height / 2));
}

/// The ALPHA switch: a pill that slides, used for the master enable and every feature flag.
public sealed class ToggleSwitch : Control
{
    bool _on;
    public bool On { get => _on; set { if (_on == value) return; _on = value; InvalidateVisual(); Changed?.Invoke(value); } }
    public string LabelText { get => _label; set { _label = value; InvalidateMeasure(); InvalidateVisual(); } } string _label = "";
    public Color Colour { get; set; } = Alpha.Green;
    public event Action<bool>? Changed;

    public ToggleSwitch()
    {
        Height = 22; Focusable = true; Cursor = new Cursor(StandardCursorType.Hand);
        PointerPressed += (_, _) => { On = !On; };
        KeyDown += (_, e) => { if (e.Key == Key.Space || e.Key == Key.Enter) { On = !On; e.Handled = true; } };
    }

    protected override Size MeasureOverride(Size available)
        => new(46 + (LabelText.Length > 0 ? LabelText.Length * 6.6 : 0), Alpha.Fin(Height, 24));

    public override void Render(DrawingContext ctx)
    {
        const double w = 40, h = 18;
        double y = Bounds.Height / 2 - h / 2;
        var pill = new Rect(0, y, w, h);
        ctx.DrawRectangle(On ? Alpha.Tint(Colour, 90) : Alpha.Tint(Color.FromRgb(0x2c, 0x30, 0x37), 220),
                          new Pen(On ? Alpha.Tint(Colour, 220) : Alpha.Line, 1), new RoundedRect(pill, h / 2));
        double k = On ? w - h / 2 : h / 2;
        if (On) ctx.DrawEllipse(Alpha.Tint(Colour, 60), null, new Point(k, y + h / 2), h * 0.62, h * 0.62);
        ctx.DrawEllipse(On ? new SolidColorBrush(Colour) : Alpha.Dim, null, new Point(k, y + h / 2), h / 2 - 3, h / 2 - 3);
        if (LabelText.Length > 0)
        {
            var ft = LedLamp.Text(LabelText, 11.5, Alpha.InkColour);
            ctx.DrawText(ft, new Point(w + 8, Bounds.Height / 2 - ft.Height / 2));
        }
    }
}

/// A round ALPHA dial: colour-ramp sweep, ticks, redline, needle and a digital centre readout.
public sealed class DialGauge : Control
{
    public string Label { get; set; } = "";
    public string Unit { get; set; } = "";
    public double Min { get; set; }
    public double Max { get; set; } = 8000;
    public double? Redline { get; set; }
    public int Decimals { get; set; }
    public double Value { get => _value; set { double v = double.IsNaN(value) ? double.NaN : Math.Round(value, 3); if (Math.Abs(v - _value) < 1e-9) return; _value = v; InvalidateVisual(); } }
    double _value = double.NaN;
    string? _lastText;
    FormattedText? _cached;

    const double Start = Math.PI * 0.75, Sweep = Math.PI * 1.5;

    public DialGauge() { Width = 148; Height = 130; }

    protected override Size MeasureOverride(Size available) => new(Alpha.Fin(Width, 180), Alpha.Fin(Height, 160));

    public override void Render(DrawingContext ctx)
    {
        double w = Bounds.Width, h = Bounds.Height;
        double cx = w / 2, cy = h * 0.52, r = Math.Min(w, h * 0.94) / 2 - 12;
        if (r < 10) return;
        var thick = new Pen(Alpha.Tint(Color.FromRgb(0x2b, 0x2f, 0x36), 255), 9) { LineCap = PenLineCap.Round };

        ctx.DrawGeometry(null, thick, Arc(cx, cy, r, Start, Start + Sweep));

        // the redline, and the value sweep in the ramp colour
        double frac = double.IsNaN(Value) ? 0 : Math.Clamp((Value - Min) / (Max - Min), 0, 1);
        if (Redline is double hi && hi > Min && hi < Max)
        {
            double a = Start + Sweep * Math.Clamp((hi - Min) / (Max - Min), 0, 1);
            ctx.DrawGeometry(null, new Pen(Alpha.Tint(Alpha.Red, 190), 9) { LineCap = PenLineCap.Round }, Arc(cx, cy, r, a, Start + Sweep));
        }
        if (!double.IsNaN(Value) && frac > 0.001)
        {
            var colour = Alpha.Ramp(frac);
            ctx.DrawGeometry(null, new Pen(Alpha.Tint(colour, 55), 15) { LineCap = PenLineCap.Round }, Arc(cx, cy, r, Start, Start + Sweep * frac));
            ctx.DrawGeometry(null, new Pen(new SolidColorBrush(colour), 6) { LineCap = PenLineCap.Round }, Arc(cx, cy, r, Start, Start + Sweep * frac));
        }

        // ticks: 9, the even ones numbered just inside the ring (clear of the readout, which sits in the open bottom of the dial)
        for (int i = 0; i <= 8; i++)
        {
            double a = Start + Sweep * i / 8, t = frac >= i / 8.0 ? 1 : 0.35;
            ctx.DrawLine(new Pen(Alpha.Tint(Alpha.InkColour, (byte)(60 + 150 * t)), i % 2 == 0 ? 2 : 1),
                         Pt(cx, cy, r - 8, a), Pt(cx, cy, r - 15, a));
            if (i % 2 != 0) continue;
            double v = Min + (Max - Min) * i / 8;
            var ft = LedLamp.Text(v >= 1000 ? (v / 1000).ToString("0.#", CultureInfo.InvariantCulture) : v.ToString("0.#", CultureInfo.InvariantCulture),
                                  9, Alpha.Mix(Alpha.DimColour, Alpha.InkColour, (byte)(t * 200) / 255.0), mono: true);
            var tp = Pt(cx, cy, r - 23, a); ctx.DrawText(ft, new Point(tp.X - ft.Width / 2, tp.Y - ft.Height / 2));
        }

        // needle
        if (!double.IsNaN(Value))
        {
            double a = Start + Sweep * frac;
            var tip = Pt(cx, cy, r - 18, a);
            ctx.DrawLine(new Pen(Alpha.Tint(Alpha.Ramp(frac), 70), 7) { LineCap = PenLineCap.Round }, new Point(cx, cy), tip);
            ctx.DrawLine(new Pen(Brushes.White, 2) { LineCap = PenLineCap.Round }, new Point(cx, cy), tip);
            ctx.DrawEllipse(Alpha.Panel2, new Pen(Alpha.Ramp(frac) == default ? Alpha.Line : new SolidColorBrush(Alpha.Ramp(frac)), 1.5), new Point(cx, cy), 4.5, 4.5);
        }

        // digital centre
        string text = double.IsNaN(Value) ? "--" : Value.ToString("N" + Decimals, CultureInfo.InvariantCulture);
        if (text != _lastText) { _lastText = text; _cached = LedLamp.Text(text, 15, Alpha.InkColour, FontWeight.Bold, mono: true); }
        if (_cached != null) LedLamp.DrawCentre(ctx, _cached, cx, cy + r * 0.62);
        var unit = LedLamp.Text(Unit.ToUpperInvariant(), 7.5, Alpha.DimColour, FontWeight.SemiBold);
        LedLamp.DrawCentre(ctx, unit, cx, cy + r * 0.62 + 13);
        var head = LedLamp.Text(Label.ToUpperInvariant(), 9.5, Alpha.Mix(Alpha.DimColour, Alpha.Cyan, 0.35), FontWeight.SemiBold);
        LedLamp.DrawCentre(ctx, head, cx, h - 9);
    }

    static Point Pt(double cx, double cy, double r, double a) => new(cx + Math.Cos(a) * r, cy + Math.Sin(a) * r);

    internal static StreamGeometry Arc(double cx, double cy, double r, double a0, double a1)
    {
        var g = new StreamGeometry();
        using var c = g.Open();
        int steps = Math.Max(6, (int)(Math.Abs(a1 - a0) * 26));
        c.BeginFigure(Pt(cx, cy, r, a0), false);
        for (int i = 1; i <= steps; i++) c.LineTo(Pt(cx, cy, r, a0 + (a1 - a0) * i / steps));
        return g;
    }
}

/// A vertical ALPHA "liquid" bar (TPS, temperatures, duty) that fills from the bottom.
public sealed class BarGauge : Control
{
    public string Label { get; set; } = "";
    public string Unit { get; set; } = "";
    public double Min { get; set; }
    public double Max { get; set; } = 100;
    public double? Warn { get; set; }
    public Color Colour { get; set; } = Alpha.Cyan;
    public double Value { get => _value; set { double v = Math.Round(value, 3); if (v == _value) return; _value = v; InvalidateVisual(); } }
    double _value = double.NaN;
    int _decimals;
    public int Decimals { get => _decimals; set { _decimals = value; InvalidateVisual(); } }

    public BarGauge() { Width = 74; Height = 128; }
    protected override Size MeasureOverride(Size available) => new(Alpha.Fin(Width, 90), Alpha.Fin(Height, 160));

    public override void Render(DrawingContext ctx)
    {
        double w = Bounds.Width, h = Bounds.Height;
        double barW = 22, x = 8, top = 6, barH = h - 34;
        var track = new Rect(x, top, barW, barH);
        ctx.DrawRectangle(Alpha.Tint(Color.FromRgb(0x14, 0x16, 0x19), 255), new Pen(Alpha.Line, 1), new RoundedRect(track, 5));

        double frac = double.IsNaN(Value) ? 0 : Math.Clamp((Value - Min) / (Max - Min), 0, 1);
        bool hot = Warn is double wl && !double.IsNaN(Value) && Value >= wl;
        var colour = hot ? Alpha.Red : Colour;
        if (frac > 0.001)
        {
            double fh = Math.Max(3, barH * frac);
            var fill = new Rect(x, top + barH - fh, barW, fh);
            var brush = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(x, top + barH, RelativeUnit.Absolute),
                EndPoint = new RelativePoint(x, top, RelativeUnit.Absolute),
                GradientStops = { new GradientStop(Alpha.Fade(colour, 235), 0), new GradientStop(Alpha.Fade(colour, 110), 1) },
            };
            ctx.DrawRectangle(brush, null, new RoundedRect(fill, 4));
            ctx.DrawRectangle(Alpha.Tint(Colors.White, 140), null, new Rect(x + 1, top + barH - fh, barW - 2, 1.6));
        }
        // ticks down the right
        for (int i = 0; i <= 4; i++)
        {
            double y = top + barH * i / 4;
            ctx.DrawLine(new Pen(Alpha.Tint(Alpha.InkColour, 60), 1), new Point(x + barW, y), new Point(x + barW + 4, y));
            double v = Max - (Max - Min) * i / 4;
            var ft = LedLamp.Text(v.ToString("0.#", CultureInfo.InvariantCulture), 8, Alpha.DimColour, mono: true);
            ctx.DrawText(ft, new Point(x + barW + 6, y - ft.Height / 2));
        }
        string text = double.IsNaN(Value) ? "--" : Value.ToString("N" + Decimals, CultureInfo.InvariantCulture);
        var val = LedLamp.Text(text, 12.5, double.IsNaN(Value) ? Alpha.DimColour : colour, FontWeight.Bold, mono: true);
        LedLamp.DrawCentre(ctx, val, x + barW / 2 + 8, h - 16);
        var head = LedLamp.Text(Label.ToUpperInvariant(), 8.5, Alpha.DimColour, FontWeight.SemiBold);
        LedLamp.DrawCentre(ctx, head, x + barW / 2 + 8, h - 5);
    }
}

/// A horizontal meter with a scale and a warning zone: injector duty, load, closed-loop trim.
public sealed class MeterBar : Control
{
    public string Label { get; set; } = "";
    public double Min { get; set; }
    public double Max { get; set; } = 100;
    public double? Warn { get; set; }
    public Color Colour { get; set; } = Alpha.Cyan;
    public int Decimals { get; set; } = 1;
    public string Suffix { get; set; } = "";
    public double Value { get => _value; set { double v = Math.Round(value, 3); if (v == _value) return; _value = v; InvalidateVisual(); } }
    double _value = double.NaN;

    public MeterBar() { Height = 34; }
    protected override Size MeasureOverride(Size available) => new(Alpha.Fin(available.Width, 170), Alpha.Fin(Height, 30));

    public override void Render(DrawingContext ctx)
    {
        double w = Bounds.Width, track = w - 4, h = 8, y = 17, x = 2;
        ctx.DrawRectangle(Alpha.Tint(Color.FromRgb(0x14, 0x16, 0x19), 255), new Pen(Alpha.Line, 1), new RoundedRect(new Rect(x, y, track, h), 4));
        double frac = double.IsNaN(Value) ? 0 : Math.Clamp((Value - Min) / (Max - Min), 0, 1);
        bool hot = Warn is double wl && !double.IsNaN(Value) && Value >= wl;
        if (Warn is double wv)
        {
            double zx = x + track * Math.Clamp((wv - Min) / (Max - Min), 0, 1);
            ctx.DrawRectangle(Alpha.Tint(Alpha.Red, 40), null, new Rect(zx, y, x + track - zx, h));
        }
        var colour = hot ? Alpha.Red : Colour;
        if (frac > 0.002) ctx.DrawRectangle(Alpha.Tint(colour, 220), null, new RoundedRect(new Rect(x, y, Math.Max(2, track * frac), h), 4));
        var head = LedLamp.Text(Label.ToUpperInvariant(), 9, Alpha.DimColour, FontWeight.SemiBold);
        ctx.DrawText(head, new Point(x, 1));
        string text = double.IsNaN(Value) ? "--" : Value.ToString("N" + Decimals, CultureInfo.InvariantCulture) + Suffix;
        var val = LedLamp.Text(text, 11, double.IsNaN(Value) ? Alpha.DimColour : colour, FontWeight.Bold, mono: true);
        ctx.DrawText(val, new Point(x + track - val.Width, 1));
    }
}

/// One trace on the scope: a channel of the datalog, its colour and the span it is squashed into.
public sealed record ScopeTrace(string Name, string Channel, Color Colour, double Min, double Max, bool DefaultOn = true);

/// The ALPHA oscilloscope: a rolling multi-channel trace of the datalog frames, each channel
/// squashed into its own span so a 0-5 V sensor and a 9000 rpm axis share the same grid.
public sealed class TraceScope : Control
{
    public IReadOnlyList<ScopeTrace> Traces => _traces;
    readonly List<ScopeTrace> _traces;
    readonly List<LogFrame> _frames = [];
    readonly object _gate = new();
    int _capacity = 1400;
    double _seconds = 20;

    public double Seconds { get => _seconds; set { _seconds = Math.Max(1, value); InvalidateVisual(); } }
    public bool ShowGrid { get; set; } = true;
    /// Where the playback cursor is, as a fraction of the window (NaN = no cursor).
    public double Marker { get; set; } = double.NaN;

    public TraceScope(IReadOnlyList<ScopeTrace>? traces = null)
    {
        _traces = traces == null ? [] : [.. traces];
        Height = 180; ClipToBounds = true;
        PointerWheelChanged += (_, e) => { Seconds = _seconds * (e.Delta.Y > 0 ? 0.8 : 1.25); e.Handled = true; };
    }

    public void SetEnabled(ScopeTrace trace, bool on)
    {
        int i = _traces.IndexOf(trace);
        if (i < 0) return;
        _traces[i] = trace with { DefaultOn = on };
        InvalidateVisual();
    }

    public ScopeTrace Trace(string channel) => _traces.First(t => t.Channel == channel);

    /// A frame in. Frames whose time went backwards (a log loaded, a replay restarted) clear the trace.
    public void Add(LogFrame f)
    {
        lock (_gate)
        {
            if (_frames.Count > 0 && f.T < _frames[^1].T - 1e-6) _frames.Clear();
            _frames.Add(f);
            if (_frames.Count > _capacity) _frames.RemoveRange(0, _frames.Count - _capacity);
        }
        InvalidateVisual();
    }

    public void ClearTrace() { lock (_gate) _frames.Clear(); InvalidateVisual(); }

    public LogFrame? Latest { get { lock (_gate) return _frames.Count > 0 ? _frames[^1] : null; } }

    protected override Size MeasureOverride(Size available)
        => new(Alpha.Fin(available.Width, 600), Alpha.Fin(Height, 120));

    public override void Render(DrawingContext ctx)
    {
        double w = Bounds.Width, h = Bounds.Height;
        var bg = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(Color.FromRgb(0x11, 0x13, 0x16), 0), new GradientStop(Color.FromRgb(0x16, 0x19, 0x1d), 1) },
        };
        ctx.DrawRectangle(bg, new Pen(Alpha.Line, 1), new RoundedRect(new Rect(0.5, 0.5, w - 1, h - 1), 6));
        LogFrame[] frames;
        lock (_gate) frames = [.. _frames];

        const double pad = 6;
        double plotW = w - pad * 2, plotH = h - pad * 2;
        if (ShowGrid)
        {
            var grid = new Pen(Alpha.Tint(Alpha.InkColour, 18), 1);
            for (int i = 1; i < 8; i++) ctx.DrawLine(grid, new Point(pad + plotW * i / 8, pad), new Point(pad + plotW * i / 8, h - pad));
            for (int i = 1; i < 5; i++) ctx.DrawLine(grid, new Point(pad, pad + plotH * i / 5), new Point(w - pad, pad + plotH * i / 5));
        }
        if (frames.Length < 2)
        {
            var wait = LedLamp.Text("no frames - the trace starts when ALPHAemu is logging", 11, Alpha.DimColour);
            LedLamp.DrawCentre(ctx, wait, w / 2, h / 2);
            return;
        }
        double t1 = frames[^1].T, t0 = Math.Max(frames[0].T, t1 - _seconds);
        double X(LogFrame f) => pad + plotW * Math.Clamp((f.T - t0) / Math.Max(1e-6, t1 - t0), 0, 1);

        foreach (var tr in _traces)
        {
            if (!tr.DefaultOn) continue;
            var pts = new List<Point>(frames.Length);
            foreach (var f in frames)
            {
                double? v = f.Get(tr.Channel);
                if (v is not double d) continue;
                double y = pad + plotH * (1 - Math.Clamp((d - tr.Min) / Math.Max(1e-9, tr.Max - tr.Min), 0, 1));
                pts.Add(new Point(X(f), y));
            }
            if (pts.Count < 2) continue;
            var brush = new SolidColorBrush(tr.Colour);
            ctx.DrawGeometry(null, new Pen(Alpha.Tint(tr.Colour, 45), 5) { LineJoin = PenLineJoin.Round }, Poly(pts));
            ctx.DrawGeometry(null, new Pen(brush, 1.6) { LineJoin = PenLineJoin.Round }, Poly(pts));
            var tip = pts[^1];
            ctx.DrawEllipse(brush, null, tip, 2.4, 2.4);
        }
        if (!double.IsNaN(Marker))
        {
            double x = pad + plotW * Math.Clamp(Marker, 0, 1);
            ctx.DrawLine(new Pen(Alpha.Tint(Alpha.Amber, 220), 1) { DashStyle = new DashStyle(new double[] { 3, 3 }, 0) },
                         new Point(x, pad), new Point(x, h - pad));
        }
        // the last reading of each trace, along the right edge
        double ly = pad + 4;
        foreach (var tr in _traces)
        {
            if (!tr.DefaultOn) continue;
            double? v = frames[^1].Get(tr.Channel);
            if (v == null) continue;
            var ft = LedLamp.Text($"{tr.Name} {v.Value:0.##}", 9, tr.Colour, FontWeight.SemiBold, mono: true);
            ctx.DrawRectangle(Alpha.Tint(Color.FromRgb(0x11, 0x13, 0x16), 190), null, new Rect(w - ft.Width - pad - 3, ly - 1, ft.Width + 4, ft.Height + 2));
            ctx.DrawText(ft, new Point(w - ft.Width - pad, ly));
            ly += ft.Height + 2;
        }
    }

    static StreamGeometry Poly(List<Point> pts)
    {
        var g = new StreamGeometry();
        using var c = g.Open();
        c.BeginFigure(pts[0], false);
        for (int i = 1; i < pts.Count; i++) c.LineTo(pts[i]);
        return g;
    }
}


