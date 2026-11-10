// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace AlphaEmuPlugin;

/// One point of a custom wideband curve: volts at the sensor and the AFR it means.
public sealed class AlphaWidebandPoint
{
    public double Voltage { get; set; }
    public double Afr { get; set; }
    public AlphaWidebandPoint() { }
    public AlphaWidebandPoint(double v, double a) { Voltage = v; Afr = a; }
    public override string ToString() => $"{Voltage.ToString("0.000", CultureInfo.InvariantCulture)} V = {Afr.ToString("0.00", CultureInfo.InvariantCulture)} AFR";
}

/// The wideband sensor model: a table of volts to lambda, straight lines between the points, then
/// AFR = lambda x stoich + offset. The same twelve factory profiles ALPHAlink ships with, plus a
/// custom curve the user types in (volts and AFR, converted to lambda by the stoich in force).
public sealed class AlphaWideband
{
    public const string DefaultProfile = "aem_new";

    /// Volts and lambda, in flat pairs: v0, l0, v1, l1... Exactly the tables the ALPHAlink web UI uses.
    public static readonly (string Key, string Label, double[] Points)[] Profiles =
    [
        ("custom", "Custom", [0, 0.68, 5, 1.36]),
        ("stock", "Stock", [0, 1.3, 0.3, 1, 0.7, 1, 1, 0.71]),
        ("aem", "AEM", [0.5, 0.75, 0.75, 0.785, 1, 0.819, 1.25, 0.852, 1.5, 0.887, 1.75, 0.921, 2, 0.955, 2.25, 0.99, 2.5, 1.024, 2.75, 1.057, 3, 1.092, 3.38, 1.143]),
        ("plx_m", "PLX M Series", [0, 0.68, 5, 1.36]),
        ("fjo", "FJO CW0002", [0.85, 0.68, 1.2, 0.75, 1.6, 0.82, 1.95, 0.88, 2.3, 0.95, 2.5, 1, 2.65, 1.09, 2.8, 1.16, 3.1, 1.36]),
        ("innovate", "Innovate LC-1/LM-1", [0, 0.509, 5, 1.523]),
        ("innovate_mtx_l", "Innovate MTX-L", [0, 0.5, 5, 1.5231292517006803]),
        ("techedge", "Techedge", [0, 0.61, 5, 1.29]),
        ("zeitronix", "Zeitronix", [0.15, 0.65, 0.5, 0.69, 1, 0.73, 1.25, 0.77, 1.5, 0.81, 1.7, 0.84, 2, 0.89, 2.25, 0.93, 2.5, 1.01, 2.7, 1.09, 3, 1.27, 3.47, 1.51]),
        ("motec_plm", "Motec PLM", [0, 0.5034013605442177, 0.5, 0.6149659863945578, 1, 0.726530612244898, 1.25, 0.7823129251700681, 1.5, 0.8380952380952381, 1.75, 0.8938775510204082, 2, 0.9496598639455783, 2.5, 1.0612244897959184, 3, 1.1727891156462584, 3.5, 1.2843537414965986, 4, 1.3959183673469389, 4.5, 1.504761904761905]),
        ("jaw", "JAW", [1.02, 0.69, 1.08, 0.73, 1.16, 0.79, 1.22, 0.83, 1.28, 0.87, 1.32, 0.9, 1.4, 0.95, 1.47, 1, 1.65, 1.12, 1.82, 1.26, 2.02, 1.37, 2.21, 1.5]),
        ("aem_new", "AEM NEW", [0.5, 0.58, 0.75, 0.62, 1, 0.66, 1.25, 0.7, 1.5, 0.74, 1.75, 0.78, 2, 0.82, 2.25, 0.86, 2.5, 0.9, 2.75, 0.94, 3, 0.99, 3.25, 1.03, 3.5, 1.07, 3.75, 1.11, 4, 1.15, 4.25, 1.19, 4.5, 1.23]),
    ];

    public static string LabelOf(string key) => Profiles.FirstOrDefault(p => p.Key == key).Label ?? "AEM NEW";

    string _profile = DefaultProfile;
    public string Profile { get => _profile; set => _profile = Profiles.Any(p => p.Key == value) ? value : DefaultProfile; }
    public double Stoich { get; set; } = 14.7;
    public double Offset { get; set; }
    public List<AlphaWidebandPoint> Custom { get; set; } = DefaultCustomRows();

    public static List<AlphaWidebandPoint> DefaultCustomRows() => [new(0, 10), new(5, 20)];
    public static double ClampVolts(double v) => double.IsFinite(v) ? Math.Clamp(v, 0, 5) : 0;
    public static double ClampAfr(double a) => double.IsFinite(a) ? Math.Clamp(a, 5, 30) : 14.7;

    /// The table in force: the chosen profile, with the custom rows turned into lambda on the way.
    public double[] Points()
    {
        if (Profile != "custom") return Profiles.First(p => p.Key == Profile).Points;
        List<AlphaWidebandPoint> rows = [.. Custom.OrderBy(r => r.Voltage)];
        var pts = new double[rows.Count * 2];
        for (int i = 0; i < rows.Count; i++)
        {
            pts[i * 2] = ClampVolts(rows[i].Voltage);
            pts[i * 2 + 1] = Math.Round(rows[i].Afr / Math.Max(1, Stoich), 6);
        }
        return pts.Length >= 4 ? pts : [0, 0.68, 5, 1.36];
    }

    /// Linear interpolation across the flat pairs, held flat outside the table (as ALPHAlink does).
    public static double Interpolate(double[] points, double x)
    {
        if (points.Length == 0) return 0;
        if (x < points[0]) return points[1];
        int last = points.Length - 2;
        if (x > points[last]) return points[last + 1];
        for (int i = 0; i < points.Length - 2; i += 2)
        {
            double x1 = points[i], y1 = points[i + 1], x2 = points[i + 2], y2 = points[i + 3];
            if (x >= x1 && x <= x2) return y1 + (x - x1) * (y2 - y1) / (x2 - x1);
        }
        return points[1];
    }

    public double Lambda(double volts) => Interpolate(Points(), ClampVolts(volts));

    /// AFR at the sensor: lambda x stoich + offset, two decimals, as the gauge and the log show it.
    public double Afr(double volts) => Math.Round((Lambda(volts) * Stoich + Offset) * 100) / 100;

    /// Volts that would give this AFR (for drawing the curve and for the guide lines).
    public double VoltsFor(double afr)
    {
        double target = (afr - Offset) / Math.Max(1, Stoich);
        var pts = Points();
        for (int i = 0; i < pts.Length - 2; i += 2)
            if (target >= pts[i + 1] && target <= pts[i + 3])
                return pts[i] + (target - pts[i + 1]) * (pts[i + 2] - pts[i]) / Math.Max(1e-9, pts[i + 3] - pts[i + 1]);
        return pts[^2];
    }

    /// The profile as a text line for tooltips and logs.
    public string Summary => $"{LabelOf(Profile)} · stoich {Stoich.ToString("0.0", CultureInfo.InvariantCulture)} · offset {Offset:+0.00;-0.00;0}";
}

/// The wideband curve drawn small: volts along the bottom, AFR up the side, the operating point lit.
public sealed class WidebandCurve : Control
{
    readonly AlphaWideband _wb;
    double _volts = double.NaN;
    public double Volts { get => _volts; set { if (value == _volts) return; _volts = value; InvalidateVisual(); } }

    public WidebandCurve(AlphaWideband wb) { _wb = wb; Width = 300; Height = 150; }
    protected override Size MeasureOverride(Size available) => new(double.IsNaN(available.Width) ? 300 : available.Width, Height);

    public override void Render(DrawingContext ctx)
    {
        double w = Bounds.Width, h = Bounds.Height;
        double afrLow = 9, afrHigh = 19;
        // where the curve actually goes, so the box fits it
        for (double v = 0; v <= 5.001; v += 0.05)
        {
            double a = _wb.Afr(v);
            afrLow = Math.Min(afrLow, a); afrHigh = Math.Max(afrHigh, a);
        }
        ctx.DrawRectangle(Alpha.Tint(Color.FromRgb(0x12, 0x14, 0x17), 255), new Pen(Alpha.Line, 1), new RoundedRect(new Rect(0.5, 0.5, w - 1, h - 1), 6));
        double X(double v) => 26 + (w - 34) * v / 5;
        double Y(double a) => h - 18 - (h - 30) * (a - afrLow) / Math.Max(1e-9, afrHigh - afrLow);

        var grid = new Pen(Alpha.Tint(Alpha.InkColour, 22), 1);
        for (int v = 0; v <= 5; v++) ctx.DrawLine(grid, new Point(X(v), 6), new Point(X(v), h - 18));
        for (int i = 0; i <= 4; i++)
        {
            double a = afrLow + (afrHigh - afrLow) * i / 4, y = Y(a);
            ctx.DrawLine(grid, new Point(26, y), new Point(w - 8, y));
            var lab = LedLamp.Text(a.ToString("0.#", CultureInfo.InvariantCulture), 8, Alpha.DimColour, mono: true);
            ctx.DrawText(lab, new Point(4, y - lab.Height / 2));
        }
        for (int v = 0; v <= 5; v++)
        {
            var lab = LedLamp.Text(v + "V", 8, Alpha.DimColour, mono: true);
            ctx.DrawText(lab, new Point(X(v) - lab.Width / 2, h - 14));
        }
        // stoich line: the one AFR that matters most
        double sy = Y(_wb.Stoich);
        ctx.DrawLine(new Pen(Alpha.Tint(Alpha.Green, 150), 1) { DashStyle = new DashStyle(new double[] { 4, 3 }, 0) }, new Point(26, sy), new Point(w - 8, sy));

        var pts = new List<Point>();
        for (double v = 0; v <= 5.0001; v += 0.02) pts.Add(new Point(X(v), Y(_wb.Afr(v))));
        var geo = new StreamGeometry();
        using (var g = geo.Open()) { g.BeginFigure(pts[0], false); foreach (var p in pts.Skip(1)) g.LineTo(p); }
        ctx.DrawGeometry(null, new Pen(Alpha.Tint(Alpha.Cyan, 45), 5) { LineJoin = PenLineJoin.Round }, geo);
        ctx.DrawGeometry(null, new Pen(Alpha.CyanBrush, 1.8) { LineJoin = PenLineJoin.Round }, geo);

        if (!double.IsNaN(_volts))
        {
            double a = _wb.Afr(_volts);
            var p = new Point(X(_volts), Y(a));
            ctx.DrawLine(new Pen(Alpha.Tint(Alpha.Amber, 120), 1), new Point(p.X, 6), new Point(p.X, h - 18));
            ctx.DrawEllipse(Alpha.Tint(Alpha.Amber, 70), null, p, 8, 8);
            ctx.DrawEllipse(new SolidColorBrush(Alpha.Amber), null, p, 3.4, 3.4);
            var txt = LedLamp.Text($"{a:0.00} AFR @ {_volts:0.00} V", 10, Alpha.Amber, FontWeight.Bold, mono: true);
            ctx.DrawText(txt, new Point(w - txt.Width - 10, 6));
        }
    }
}


