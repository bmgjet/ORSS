// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The first start: what the app is going to be used for - writing and simulating ROMs, or tuning a car - which sets the view it opens in. Settings > General changes it later, and can bring this back.
public sealed class WelcomeWindow : Window
{
    /// "simulator" or "tuner"; null when closed without picking.
    public string? Choice { get; private set; }

    public WelcomeWindow()
    {
        Title = "Welcome";
        Width = 940; Height = 640; MinWidth = 860; MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Welcome to " + BuildInfo.Product);

        var head = new StackPanel { Margin = new Thickness(28, 18, 28, 6), Spacing = 4 };
        head.Children.Add(new TextBlock { Text = "What will you use it for?", FontSize = 24, FontWeight = FontWeight.Bold });
        head.Children.Add(new TextBlock
        {
            Text = "This picks the view the app opens in. Both are always there: File > Tuner mode / Simulator mode switches between them, " +
                   "and Settings > General changes where it starts.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75, FontSize = 12.5,
        });

        var cards = new Grid { ColumnDefinitions = new ColumnDefinitions("*,20,*"), Margin = new Thickness(28, 12, 28, 12) };
        var sim = Card(new SimArt(), "ROM development and simulation", "simulator",
            [
                "Write and change the ROM in assembly: build it, patch it live",
                "Run it on a simulated MSM66207 against a simulated engine",
                "Step, break, trace and watch every register, port and RAM byte",
                "See what code reads each table and writes each RAM value",
            ], "Start in the simulator");
        var tune = Card(new TunerArt(), "Tuning and datalogging", "tuner",
            [
                "Open a .bin, find its maps, edit them as tables, lines or in 3D",
                "Datalog the car and watch the engine move across the map",
                "Upload changes to an Ostrich or Demon as you make them",
                "Gauges, graphs, trouble codes and service commands",
            ], "Start in the tuner");
        Grid.SetColumn(sim, 0); cards.Children.Add(sim);
        Grid.SetColumn(tune, 2); cards.Children.Add(tune);

        var later = new Button { Content = "Decide later", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(28, 0, 28, 18) };
        ToolTip.SetTip(later, "Open as it did last time. Settings > General > Welcome screen brings this back.");
        later.Click += (_, _) => Close();

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(head, 1); g.Children.Add(head);
        Grid.SetRow(cards, 2); g.Children.Add(cards);
        Grid.SetRow(later, 3); g.Children.Add(later);
        Content = g;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    Border Card(Control art, string title, string choice, string[] points, string button)
    {
        var p = new StackPanel { Spacing = 10 };
        art.Height = 190;
        p.Children.Add(new Border { Child = art, CornerRadius = new CornerRadius(8), ClipToBounds = true, Background = Dark.Back });
        p.Children.Add(new TextBlock { Text = title, FontSize = 18, FontWeight = FontWeight.Bold, Margin = new Thickness(4, 4, 4, 0) });
        var list = new StackPanel { Spacing = 5, Margin = new Thickness(4, 0) };
        foreach (var pt in points)
        {
            var row = new DockPanel();
            var dot = new TextBlock { Text = "●", FontSize = 8, Foreground = Panels.Accent, Margin = new Thickness(0, 5, 8, 0), VerticalAlignment = VerticalAlignment.Top };
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);
            row.Children.Add(new TextBlock { Text = pt, TextWrapping = TextWrapping.Wrap, FontSize = 12.5, Opacity = 0.9 });
            list.Children.Add(row);
        }
        p.Children.Add(list);
        var pick = new Button
        {
            Content = button, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(12, 8), FontSize = 13.5, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 6, 0, 0),
            Background = AppTheme.Brush(Color.FromArgb(60, DarkChrome.Accent.R, DarkChrome.Accent.G, DarkChrome.Accent.B)),
        };
        pick.Click += (_, _) => { Choice = choice; Close(); };
        var dock = new DockPanel();
        DockPanel.SetDock(pick, Dock.Bottom);
        dock.Children.Add(pick);
        dock.Children.Add(p);
        var card = new Border
        {
            Child = dock, Padding = new Thickness(14), CornerRadius = new CornerRadius(10), Background = Panels.CardBack,
            BorderBrush = Panels.CardLine, BorderThickness = new Thickness(1.5), Cursor = new Cursor(StandardCursorType.Hand),
        };
        card.PointerEntered += (_, _) => card.BorderBrush = Panels.Accent;
        card.PointerExited += (_, _) => card.BorderBrush = Panels.CardLine;
        card.PointerPressed += (_, e) => { if (e.Source is not Button) { Choice = choice; Close(); } };
        return card;
    }

    static FormattedText T(string s, double size, IBrush ink, bool bold = false, bool mono = true) =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(mono ? MainWindow.MonoFont : FontFamily.Default, FontStyle.Normal, bold ? FontWeight.Bold : FontWeight.Normal), size, ink);

    /// The chip, and the assembly that runs on it.
    sealed class SimArt : Control
    {
        public override void Render(DrawingContext ctx)
        {
            double w = Bounds.Width, h = Bounds.Height;
            ctx.FillRectangle(new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(AppTheme.Map(Color.FromRgb(0x17, 0x1d, 0x26)), 0), new GradientStop(AppTheme.Map(Color.FromRgb(0x1b, 0x24, 0x1d)), 1) },
            }, new Rect(0, 0, w, h));
            // board traces behind
            var trace = new Pen(AppTheme.Brush(Color.FromArgb(50, 0x3c, 0xc8, 0x5a)), 2);
            for (int i = 0; i < 7; i++)
            {
                double ty = 22 + (i * 24);
                ctx.DrawLine(trace, new Point(0, ty), new Point(w * 0.12, ty));
                ctx.DrawLine(trace, new Point(w * 0.12, ty), new Point(w * 0.16, ty + 10));
            }
            // the chip: a QFP, pins round all four sides
            double size = Math.Min(h - 50, w * 0.36), cx = 26 + (size / 2) + 14, cy = h / 2;
            var body = new Rect(cx - (size / 2), cy - (size / 2), size, size);
            var pin = AppTheme.Brush(Color.FromRgb(0xb8, 0xbe, 0xc8));
            int n = 12;
            double step = (size - 16) / n;
            for (int i = 0; i < n; i++)
            {
                double o = body.Left + 8 + (i * step) + (step / 2) - 2;
                ctx.FillRectangle(pin, new Rect(o, body.Top - 9, 4, 9));
                ctx.FillRectangle(pin, new Rect(o, body.Bottom, 4, 9));
                double oy = body.Top + 8 + (i * step) + (step / 2) - 2;
                ctx.FillRectangle(pin, new Rect(body.Left - 9, oy, 9, 4));
                ctx.FillRectangle(pin, new Rect(body.Right, oy, 9, 4));
            }
            ctx.FillRectangle(AppTheme.Brush(Color.FromRgb(0x24, 0x26, 0x2b)), body, 6);
            ctx.DrawRectangle(new Pen(AppTheme.Brush(Color.FromRgb(0x3a, 0x3d, 0x44)), 1.5), body, 6);
            ctx.DrawEllipse(AppTheme.Brush(Color.FromRgb(0x3a, 0x3d, 0x44)), null, new Point(body.Left + 12, body.Top + 12), 4, 4);
            var oki = T("OKI", 15, AppTheme.Brush(Color.FromRgb(0xd7, 0xda, 0xe0)), bold: true);
            ctx.DrawText(oki, new Point(cx - (oki.Width / 2), cy - 22));
            var part = T("MSM66207", 12, DataList.Address);
            ctx.DrawText(part, new Point(cx - (part.Width / 2), cy - 2));
            var mhz = T("10 MHz", 10, DataList.Dim);
            ctx.DrawText(mhz, new Point(cx - (mhz.Width / 2), cy + 16));
            // the code it runs, beside it
            (string Label, string Op, string Args)[] code =
            [
                ("fuel_calc:", "", ""), ("", "LB", "A, 0ACh"), ("", "CAL", "table_interp"), ("", "MUL", ""), ("", "JBS", "off(0217h).6, vtec_on"),
                ("", "ST", "A, er0"), ("vtec_on:", "", ""), ("", "LCB", "A, FuelHigh[X1]"), ("", "RT", ""),
            ];
            double x = body.Right + 40, y = 18;
            foreach (var (label, op, args) in code)
            {
                if (y > h - 16) break;
                if (label.Length > 0) ctx.DrawText(T(label, 12, DataList.Label, bold: true), new Point(x, y));
                else
                {
                    ctx.DrawText(T(op, 12, DataList.MnemonicInk(op) == DataList.Text ? DataList.Call : DataList.MnemonicInk(op)), new Point(x + 18, y));
                    ctx.DrawText(T(args, 12, DataList.Text), new Point(x + 64, y));
                }
                y += 18.5;
            }
            // the line it is on
            ctx.FillRectangle(AppTheme.Brush(Color.FromArgb(40, 0x00, 0xd0, 0xd0)), new Rect(x - 6, 18 + (2 * 18.5) - 2, w - x, 18));
            ctx.DrawText(T("▶", 10, DataList.Good), new Point(x + 4, 18 + (2 * 18.5)));
        }
    }

    /// A map as the tuner shows it, the engine's cell outlined, and a datalog under it.
    sealed class TunerArt : Control
    {
        public override void Render(DrawingContext ctx)
        {
            double w = Bounds.Width, h = Bounds.Height;
            ctx.FillRectangle(new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(AppTheme.Map(Color.FromRgb(0x1d, 0x1b, 0x26)), 0), new GradientStop(AppTheme.Map(Color.FromRgb(0x26, 0x1d, 0x1b)), 1) },
            }, new Rect(0, 0, w, h));
            // the table: green to red, rising with rpm and load
            int rows = 6, cols = 9;
            double gx = 18, gy = 14, cw = Math.Min(38, (w * 0.62) / cols), ch = 17;
            for (int r = 0; r < rows; r++)
                for (int c = 0; c < cols; c++)
                {
                    double t = Math.Clamp((0.55 * c / (cols - 1)) + (0.45 * r / (rows - 1)) + (0.06 * Math.Sin((r * 3) + c)), 0, 1);
                    var col = Heat(t);
                    var rc = new Rect(gx + (c * cw), gy + (r * ch), cw - 1.5, ch - 1.5);
                    ctx.FillRectangle(AppTheme.Brush(col), rc, 2);
                    var v = T((40 + (t * 90)).ToString("0", CultureInfo.InvariantCulture), 9.5, Brushes.Black);
                    ctx.DrawText(v, new Point(rc.Left + ((rc.Width - v.Width) / 2), rc.Top + ((rc.Height - v.Height) / 2)));
                }
            // where the engine is
            var live = new Rect(gx + (4 * cw) - 2, gy + (2 * ch) - 2, (2 * cw) + 2.5, (2 * ch) + 2.5);
            ctx.DrawRectangle(new Pen(AppTheme.White, 2.5), live, 3);
            ctx.DrawEllipse(Brushes.White, null, new Point(live.Center.X, live.Center.Y), 3.5, 3.5);
            // a gauge beside it
            double gcx = gx + (cols * cw) + ((w - (gx + (cols * cw))) / 2), gcy = gy + (rows * ch / 2) + 4, rad = Math.Min(44, (w - (gx + (cols * cw))) / 2 - 10);
            if (rad > 18)
            {
                var arcBg = new Pen(AppTheme.Brush(Color.FromArgb(60, 255, 255, 255)), 6, lineCap: PenLineCap.Round);
                var arc = new Pen(AppTheme.Brush(Color.FromRgb(0x3c, 0xc8, 0x5a)), 6, lineCap: PenLineCap.Round);
                DrawArc(ctx, arcBg, gcx, gcy, rad, 135, 405);
                DrawArc(ctx, arc, gcx, gcy, rad, 135, 330);
                var rpm = T("5400", 15, DataList.Text, bold: true);
                ctx.DrawText(rpm, new Point(gcx - (rpm.Width / 2), gcy - 10));
                var unit = T("rpm", 10, DataList.Dim);
                ctx.DrawText(unit, new Point(gcx - (unit.Width / 2), gcy + 8));
            }
            // the datalog: rpm and AFR against time
            double top = gy + (rows * ch) + 16, bottom = h - 14, left = 18, right = w - 18;
            var axis = new Pen(AppTheme.Brush(Color.FromArgb(70, 255, 255, 255)), 1);
            ctx.DrawLine(axis, new Point(left, bottom), new Point(right, bottom));
            ctx.DrawLine(axis, new Point(left, top), new Point(left, bottom));
            DrawLine(ctx, AppTheme.Brush(Color.FromRgb(0x46, 0x8c, 0xff)), left, right, top, bottom, x => 0.15 + (0.75 * Math.Pow(x, 1.4)) + (0.03 * Math.Sin(x * 40)));
            DrawLine(ctx, AppTheme.Brush(Color.FromRgb(0xff, 0x9d, 0x5c)), left, right, top, bottom, x => 0.55 - (0.25 * x) + (0.05 * Math.Sin(x * 23)));
            ctx.DrawText(T("rpm", 10, AppTheme.Brush(Color.FromRgb(0x46, 0x8c, 0xff))), new Point(left + 6, top));
            ctx.DrawText(T("AFR", 10, AppTheme.Brush(Color.FromRgb(0xff, 0x9d, 0x5c))), new Point(left + 40, top));
            // the replay's cursor
            double cur = left + ((right - left) * 0.62);
            ctx.DrawLine(new Pen(AppTheme.Brush(Color.FromArgb(160, 255, 255, 255)), 1.5), new Point(cur, top), new Point(cur, bottom));
        }

        static Color Heat(double t)
        {
            // the table's own colours: green, yellow, orange, red
            (double At, Color C)[] stops = [(0, Color.FromRgb(0x5c, 0xd6, 0x7a)), (0.4, Color.FromRgb(0xe8, 0xe0, 0x4a)), (0.7, Color.FromRgb(0xf5, 0x9a, 0x3c)), (1, Color.FromRgb(0xe8, 0x45, 0x3c))];
            for (int i = 1; i < stops.Length; i++)
                if (t <= stops[i].At)
                {
                    double k = (t - stops[i - 1].At) / (stops[i].At - stops[i - 1].At);
                    Color a = stops[i - 1].C, b = stops[i].C;
                    return Color.FromRgb((byte)(a.R + ((b.R - a.R) * k)), (byte)(a.G + ((b.G - a.G) * k)), (byte)(a.B + ((b.B - a.B) * k)));
                }
            return stops[^1].C;
        }

        static void DrawLine(DrawingContext ctx, IBrush ink, double left, double right, double top, double bottom, Func<double, double> f)
        {
            var g = new StreamGeometry();
            using (var s = g.Open())
            {
                for (int i = 0; i <= 80; i++)
                {
                    double x = i / 80.0, px = left + ((right - left) * x), py = bottom - ((bottom - top) * Math.Clamp(f(x), 0, 1));
                    if (i == 0) s.BeginFigure(new Point(px, py), false); else s.LineTo(new Point(px, py));
                }
                s.EndFigure(false);
            }
            ctx.DrawGeometry(null, new Pen(ink, 2), g);
        }

        static void DrawArc(DrawingContext ctx, Pen pen, double cx, double cy, double r, double fromDeg, double toDeg)
        {
            var g = new StreamGeometry();
            using (var s = g.Open())
            {
                for (int i = 0; i <= 40; i++)
                {
                    double a = (fromDeg + ((toDeg - fromDeg) * i / 40)) * Math.PI / 180;
                    var p = new Point(cx + (r * Math.Cos(a)), cy + (r * Math.Sin(a)));
                    if (i == 0) s.BeginFigure(p, false); else s.LineTo(p);
                }
                s.EndFigure(false);
            }
            ctx.DrawGeometry(null, pen, g);
        }
    }
}
