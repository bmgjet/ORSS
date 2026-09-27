// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// The pieces the pages are dressed in, so they all look alike: a card (a titled, rounded panel), a bar of buttons along the top of a page, and a line of small print.
public static class Panels
{
    public static readonly IBrush CardBack = new SolidColorBrush(Color.FromRgb(0x23, 0x25, 0x2a));
    public static readonly IBrush CardLine = new SolidColorBrush(Color.FromRgb(0x33, 0x36, 0x3d));
    public static readonly IBrush BarBack = new SolidColorBrush(Color.FromRgb(0x25, 0x27, 0x2c));
    public static readonly IBrush Accent = new SolidColorBrush(DarkChrome.Accent);

    /// A titled panel: the title small and upper case on the left of its head, anything in `extras` on the right.
    public static Border Card(string title, Control body, params Control[] extras)
    {
        var head = new DockPanel { Margin = new Thickness(10, 6, 6, 4), LastChildFill = true };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        foreach (var e in extras) right.Children.Add(e);
        DockPanel.SetDock(right, Dock.Right);
        head.Children.Add(right);
        // the title gives way to the controls beside it: cut short rather than drawn under them
        var name = new DockPanel { VerticalAlignment = VerticalAlignment.Center };
        var bar = new Border { Width = 3, Height = 12, CornerRadius = new CornerRadius(1.5), Background = Accent, Margin = new Thickness(0, 0, 7, 0) };
        DockPanel.SetDock(bar, Dock.Left);
        name.Children.Add(bar);
        name.Children.Add(new TextBlock
        {
            Text = title.ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeight.SemiBold, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 0, 8, 0),
        });
        head.Children.Add(name);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(head, 0); g.Children.Add(head);
        Grid.SetRow(body, 1); g.Children.Add(body);
        return new Border
        {
            Child = g, Background = CardBack, BorderBrush = CardLine, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6), Margin = new Thickness(0, 0, 0, 8), ClipToBounds = true,
        };
    }

    /// A card's title changed (the panel in it now shows something else).
    public static void Retitle(Border card, string title)
    {
        if (card.Child is Grid { Children: [DockPanel head, ..] } && head.Children.OfType<DockPanel>().FirstOrDefault() is { Children: [_, TextBlock t] })
            t.Text = title.ToUpperInvariant();
    }

    /// The strip of buttons along the top of a page.
    public static Border Bar(params Control[] items)
    {
        var w = new WrapPanel { Margin = new Thickness(6, 4), VerticalAlignment = VerticalAlignment.Center };
        foreach (var i in items) w.Children.Add(i);
        return BarAround(w);
    }

    public static Border BarAround(Control content) => new()
    {
        Child = content, Background = BarBack, BorderBrush = CardLine, BorderThickness = new Thickness(0, 0, 0, 1),
    };

    /// A thin upright line between groups of buttons in a bar.
    public static Control Divider() => new Border { Width = 1, Height = 18, Background = CardLine, Margin = new Thickness(6, 0), VerticalAlignment = VerticalAlignment.Center };

    public static TextBlock Note(string text) => new()
    {
        Text = text, FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 2, 10, 6),
    };

    public static Button Button(string text, Action a, string tip, string? icon = null)
    {
        var b = new Button { Content = icon == null ? text : icon + "  " + text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(8, 3) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }
}

/// The CPU at a glance: the PC and the routine it is in, the registers in a grid (a value that changed with the last step shows in orange), the PSW flags as lamps, and the time simulated.
public sealed class CpuView : Control
{
    SimHost.Snapshot? _s;
    string _label = "", _hot = "";
    readonly Dictionary<string, string> _before = [], _now = [];
    readonly HashSet<string> _changed = [];
    static readonly Typeface Mono = new(MainWindow.MonoFont);
    static readonly Typeface MonoBold = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.Bold);
    static readonly Typeface Ui = new(FontFamily.Default);
    static readonly IBrush Lamp = new SolidColorBrush(Color.FromArgb(200, 0x3c, 0xc8, 0x5a));
    static readonly IBrush LampOff = new SolidColorBrush(Color.FromArgb(40, 255, 255, 255));
    static readonly IBrush Cell = new SolidColorBrush(Color.FromArgb(14, 255, 255, 255));
    const double CellW = 116, CellH = 22, Pad = 10;

    public void Update(SimHost.Snapshot s, string label, string hot)
    {
        (string, string)[] regs =
        [
            ("A", $"{s.A:X4}"), ("DP", $"{s.Dp:X4}"), ("X1", $"{s.X1:X4}"), ("X2", $"{s.X2:X4}"),
            ("USP", $"{s.Usp:X4}"), ("SSP", $"{s.Ssp:X4}"), ("LRB", $"{s.Lrb:X4}"), ("PSW", $"{s.Psw:X4}"),
            ("ER0", $"{s.Er[0]:X4}"), ("ER1", $"{s.Er[1]:X4}"), ("ER2", $"{s.Er[2]:X4}"), ("ER3", $"{s.Er[3]:X4}"),
        ];
        bool moved = _s == null || s.Instructions != _s.Instructions;
        if (moved)
        {
            _before.Clear();
            foreach (var kv in _now) _before[kv.Key] = kv.Value;
            _now.Clear();
            foreach (var (n, v) in regs) _now[n] = v;
            _changed.Clear();
            // running, everything changes all the time: the colour is for stepping
            if (!s.Running) foreach (var (n, v) in regs) if (_before.TryGetValue(n, out var was) && was != v) _changed.Add(n);
        }
        bool again = _s != null && _s.Pc == s.Pc && _s.Instructions == s.Instructions && _hot == hot && _s.Rate == s.Rate;
        _s = s; _label = label; _hot = hot;
        if (!again) InvalidateVisual();
    }

    int Cols(double w) => Math.Max(2, (int)((w - (2 * Pad)) / CellW));

    protected override Size MeasureOverride(Size availableSize)
    {
        double w = double.IsInfinity(availableSize.Width) ? 480 : availableSize.Width;
        int rows = (int)Math.Ceiling(12.0 / Cols(w));
        return new Size(w, 30 + (rows * (CellH + 4)) + 30 + 36);
    }

    FormattedText T(string s, double size, IBrush ink, Typeface? face = null) =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face ?? Mono, size, ink);

    public override void Render(DrawingContext ctx)
    {
        if (_s is not { } s) return;
        double w = Bounds.Width, y = 2;
        // PC and the routine
        var pcName = T("PC", 11, DataList.Dim, Ui);
        ctx.DrawText(pcName, new Point(Pad, y + 6));
        var pc = T($"{s.Pc:X4}", 16, DataList.Address, MonoBold);
        ctx.DrawText(pc, new Point(Pad + 26, y + 1));
        var lab = T(_label, 13, DataList.Label, MonoBold);
        lab.MaxTextWidth = Math.Max(20, w - Pad - 26 - pc.Width - 14 - Pad); lab.MaxLineCount = 1; lab.Trimming = TextTrimming.CharacterEllipsis;
        ctx.DrawText(lab, new Point(Pad + 26 + pc.Width + 12, y + 4));
        y += 30;
        // the registers
        int cols = Cols(w);
        double cw = (w - (2 * Pad)) / cols;
        int i = 0;
        foreach (var n in new[] { "A", "DP", "X1", "X2", "USP", "SSP", "LRB", "PSW", "ER0", "ER1", "ER2", "ER3" })
        {
            double x = Pad + (i % cols * cw), yy = y + (i / cols * (CellH + 4));
            ctx.FillRectangle(Cell, new Rect(x, yy, cw - 4, CellH), 4);
            ctx.DrawText(T(n, 10.5, DataList.Dim, Ui), new Point(x + 7, yy + 4));
            string v = _now.GetValueOrDefault(n, "");
            if (n == "LRB") v += $"→{s.Bank:X3}";
            var ft = T(v, 12.5, _changed.Contains(n) ? DataList.Jump : DataList.Text, _changed.Contains(n) ? MonoBold : Mono);
            ctx.DrawText(ft, new Point(x + 40, yy + ((CellH - ft.Height) / 2)));
            i++;
        }
        y += Math.Ceiling(12.0 / cols) * (CellH + 4) + 4;
        // the flags as lamps, then the interrupt masks
        double fx = Pad;
        foreach (var (n, on) in new[] { ("CY", s.Cy), ("Z", s.Z), ("HC", s.Hc), ("DD", s.Dd), ("MIE", s.Mie) })
        {
            var ft = T(n, 11, on ? Brushes.Black : DataList.Dim, on ? MonoBold : Mono);
            var r = new Rect(fx, y, ft.Width + 14, 20);
            ctx.FillRectangle(on ? Lamp : LampOff, r, 10);
            ctx.DrawText(ft, new Point(fx + 7, y + ((20 - ft.Height) / 2)));
            fx += r.Width + 5;
        }
        var masks = T($"SCB {s.Scb}   IRQ {s.Irq:X4}   IE {s.Ie:X4}", 11.5, DataList.Address);
        if (fx + 10 + masks.Width < w) ctx.DrawText(masks, new Point(fx + 10, y + ((20 - masks.Height) / 2)));
        y += 28;
        var foot = T($"{s.SimSeconds:F3} s simulated · {s.Instructions:N0} instructions" + (s.Running && s.Rate > 0 ? $" · {s.Rate:N0}/s" : ""), 11, DataList.Dim, Ui);
        foot.MaxTextWidth = Math.Max(20, w - (2 * Pad)); foot.MaxLineCount = 1; foot.Trimming = TextTrimming.CharacterEllipsis;
        ctx.DrawText(foot, new Point(Pad, y));
        if (_hot.Length > 0)
        {
            var hot = T(_hot, 11, DataList.Dim, Ui);
            hot.MaxTextWidth = Math.Max(20, w - (2 * Pad)); hot.MaxLineCount = 1; hot.Trimming = TextTrimming.CharacterEllipsis;
            ctx.DrawText(hot, new Point(Pad, y + 16));
        }
    }
}
