// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace AlphaEmuPlugin;

/// The ALPHA look: a dark console shell with neon accents, drawn to match the app rather than fight it.
/// Everything the plugin shows is built from here, so the one place to change the styling is this file.
static class Alpha
{
    /// A size a control can hand back from MeasureOverride: Width / Height not set (NaN) or no limit given (infinity)
    /// is not one, and Avalonia throws on it ("Invalid size returned for Measure").
    public static double Fin(double v, double fallback) => double.IsFinite(v) ? v : fallback;

    // ---- the palette ---------------------------------------------------------------------------
    public static readonly Color BackColour = Color.FromRgb(0x15, 0x17, 0x1a);
    public static readonly Color PanelColour = Color.FromRgb(0x1c, 0x1f, 0x23);
    public static readonly Color PanelColour2 = Color.FromRgb(0x23, 0x26, 0x2c);
    public static readonly Color LineColour = Color.FromRgb(0x34, 0x39, 0x42);
    public static readonly Color InkColour = Color.FromRgb(0xd8, 0xdc, 0xe3);
    public static readonly Color DimColour = Color.FromRgb(0x8f, 0x97, 0xa3);

    public static readonly Color Cyan = Color.FromRgb(0x00, 0xe5, 0xff);
    public static readonly Color Blue = Color.FromRgb(0x6e, 0xa8, 0xff);
    public static readonly Color Green = Color.FromRgb(0x4a, 0xde, 0x80);
    public static readonly Color Lime = Color.FromRgb(0xa3, 0xe6, 0x1a);
    public static readonly Color Amber = Color.FromRgb(0xff, 0xb0, 0x00);
    public static readonly Color Red = Color.FromRgb(0xff, 0x3b, 0x5c);
    public static readonly Color Purple = Color.FromRgb(0xa8, 0x55, 0xf7);
    public static readonly Color Teal = Color.FromRgb(0x14, 0xb8, 0xa6);
    public static readonly Color Sky = Color.FromRgb(0x7d, 0xd3, 0xfc);
    public static readonly Color Orange = Color.FromRgb(0xf9, 0x73, 0x16);

    public static readonly IBrush Back = new SolidColorBrush(BackColour);
    public static readonly IBrush Panel = new SolidColorBrush(PanelColour);
    public static readonly IBrush Panel2 = new SolidColorBrush(PanelColour2);
    public static readonly IBrush Line = new SolidColorBrush(LineColour);
    public static readonly IBrush Ink = new SolidColorBrush(InkColour);
    public static readonly IBrush Dim = new SolidColorBrush(DimColour);
    public static readonly IBrush CyanBrush = new SolidColorBrush(Cyan);
    public static readonly IBrush GreenBrush = new SolidColorBrush(Green);
    public static readonly IBrush AmberBrush = new SolidColorBrush(Amber);
    public static readonly IBrush RedBrush = new SolidColorBrush(Red);
    public static readonly IBrush BlueBrush = new SolidColorBrush(Blue);

    public static readonly FontFamily Mono = new("Cascadia Mono,Consolas,DejaVu Sans Mono,Menlo,monospace");
    public static readonly FontFamily Face = new("Inter,Segoe UI,Helvetica,Arial,sans-serif");

    /// A colour blended between two stops (0 = a, 1 = b).
    public static Color Mix(Color a, Color b, double f)
    {
        f = Math.Clamp(f, 0, 1);
        return Color.FromRgb((byte)(a.R + (b.R - a.R) * f), (byte)(a.G + (b.G - a.G) * f), (byte)(a.B + (b.B - a.B) * f));
    }

    /// The gauge ramp: cyan low, green, amber, red high.
    public static Color Ramp(double fraction)
    {
        fraction = Math.Clamp(fraction, 0, 1);
        return fraction < 0.45 ? Mix(Cyan, Green, fraction / 0.45)
             : fraction < 0.75 ? Mix(Green, Amber, (fraction - 0.45) / 0.30)
                               : Mix(Amber, Red, (fraction - 0.75) / 0.25);
    }

    /// Tooltips the short way (Avalonia's are attached properties).
static void Tip(Control c, string? tip) { if (!string.IsNullOrEmpty(tip)) ToolTip.SetTip(c, tip); }

    public static SolidColorBrush Tint(Color c, byte alpha = 255) => new(Color.FromArgb(alpha, c.R, c.G, c.B));

    /// The same colour with its alpha changed, still a colour (for gradient stops).
    public static Color Fade(Color c, byte alpha) => Color.FromArgb(alpha, c.R, c.G, c.B);

    // Colour.FromRgb takes bytes, which makes a literal awkward in a drawing call.
    public static Color Rgb(int r, int g, int b) => Color.FromRgb((byte)r, (byte)g, (byte)b);

    // ---- small builders ------------------------------------------------------------------------

    public static TextBlock Head(string text, string? tip = null)
    {
        var t = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeight.SemiBold, LetterSpacing = 0.9, Foreground = Tint(Cyan, 210), Margin = new Thickness(0, 0, 0, 2) };
        Tip(t, tip);
        return t;
    }

    public static TextBlock Kicker(string text) => new()
    {
        Text = text.ToUpperInvariant(), FontSize = 9.5, LetterSpacing = 1.4, Foreground = Dim,
    };

    public static TextBlock Body(string text, double size = 12, bool wrap = true) => new()
    {
        Text = text, FontSize = size, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, Foreground = Ink,
    };

    public static TextBlock Note(string text, double size = 10.5) => new()
    {
        Text = text, FontSize = size, Foreground = Dim, TextWrapping = TextWrapping.Wrap,
    };

    public static TextBlock MonoText(string text, double size = 13, Color? colour = null, FontWeight? weight = null) => new()
    {
        Text = text, FontFamily = Mono, FontSize = size, Foreground = new SolidColorBrush(colour ?? InkColour),
        FontWeight = weight ?? FontWeight.Medium,
    };

    /// A labelled number that the code keeps up to date: the big ALPHA readout.
    public static (Border Card, TextBlock Value, TextBlock Unit) Readout(string label, string unit, Color colour, string tip = "")
    {
        var value = MonoText("--", 21, colour, FontWeight.Bold);
        var unitText = new TextBlock { Text = unit, FontSize = 9.5, Foreground = Dim, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(2, 0, 0, 3) };
        var number = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        number.Children.Add(value);
        number.Children.Add(unitText);
        var body = new StackPanel { Spacing = 1, HorizontalAlignment = HorizontalAlignment.Center };
        body.Children.Add(new TextBlock { Text = label.ToUpperInvariant(), FontSize = 9, LetterSpacing = 1.2, Foreground = Dim, HorizontalAlignment = HorizontalAlignment.Center });
        body.Children.Add(number);
        var card = new Border
        {
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.FromRgb(0x20, 0x23, 0x28), 0), new GradientStop(Color.FromRgb(0x18, 0x1a, 0x1e), 1) },
            },
            BorderBrush = Tint(colour, 70), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(7),
            Padding = new Thickness(8, 6), MinWidth = 96, MinHeight = 54, Child = body,
        };
        Tip(card, tip.Length > 0 ? tip : label);
        return (card, value, unitText);
    }

    public static Border Divider(bool vertical = false) => new()
    {
        Background = Line, Width = vertical ? 1 : double.NaN, Height = vertical ? double.NaN : 1,
        Margin = vertical ? new Thickness(6, 2) : new Thickness(2, 6),
    };

    /// A small coloured pill: LIVE, TARGET, STAGED, AEMAP, ERROR...
    public static Border Badge(string text, Color colour, string tip = "")
    {
        var b = new Border
        {
            Background = Tint(colour, 38), BorderBrush = Tint(colour, 150), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 1), Margin = new Thickness(0, 0, 4, 0),
            Child = new TextBlock { Text = text, FontSize = 9, FontWeight = FontWeight.Bold, LetterSpacing = 1, Foreground = new SolidColorBrush(colour) },
                    };
        Tip(b, tip);
        return b;
    }

    public static Button Ghost(string text, Action run, string tip = "", string? icon = null)
    {
        var content = icon == null ? text : icon + "  " + text;
        var b = new Button
        {
            Content = content, FontSize = 12, Padding = new Thickness(10, 4),
            Background = Tint(Color.FromRgb(0x2a, 0x2e, 0x35), 200), Foreground = Ink,
            BorderBrush = Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6),
                    };
        b.Click += (_, _) => run();
        Tip(b, tip);
        return b;
    }

    /// A button that stands out (the one action on a panel).
    public static Button Primary(string text, Action run, string tip = "", string? icon = null)
    {
        var b = Ghost(text, run, tip, icon);
        b.Background = Tint(Cyan, 40); b.BorderBrush = Tint(Cyan, 170);
        b.Foreground = new SolidColorBrush(Color.FromRgb(0xd7, 0xf4, 0xff));
        b.FontWeight = FontWeight.SemiBold;
        return b;
    }

    public static Button Danger(string text, Action run, string tip = "")
    {
        var b = Ghost(text, run, tip);
        b.Background = Tint(Red, 40); b.BorderBrush = Tint(Red, 160); b.Foreground = new SolidColorBrush(Color.FromRgb(0xff, 0xd8, 0xde));
        return b;
    }

    /// label : editor, lined up the way the app's own settings rows are.
    public static Control Row(string label, Control editor, double labelWidth = 116, string tip = "")
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var name = new TextBlock { Text = label, Width = labelWidth, VerticalAlignment = VerticalAlignment.Center, FontSize = 12, Foreground = Ink };
        Tip(name, tip);
        sp.Children.Add(name);
        sp.Children.Add(editor);
        return sp;
    }

    public static TextBox Box(string? text, string watermark = "", double width = double.NaN, bool mono = false) => new()
    {
        Text = text ?? "", Watermark = watermark, Width = width, FontSize = 12,
        FontFamily = mono ? Mono : Face, CaretIndex = 0,
    };

    public static ComboBox Combo(IEnumerable<string> items, int index, Action<int> pick, double width = double.NaN, string tip = "")
    {
        var c = new ComboBox { ItemsSource = items.ToList(), SelectedIndex = index, Width = width, FontSize = 12 };
        Tip(c, tip);
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0) pick(c.SelectedIndex); };
        return c;
    }

    public static CheckBox Check(string text, bool on, Action<bool> set, string tip = "")
    {
        var c = new CheckBox { Content = text, IsChecked = on, FontSize = 12 };
        Tip(c, tip);
        c.IsCheckedChanged += (_, _) => set(c.IsChecked == true);
        return c;
    }

    /// A titled panel with a rule under the title and room for buttons at the right of the title.
    public static Border Card(string title, Control body, params Control[] extras)
    {
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var e in extras) right.Children.Add(e);
        DockPanel.SetDock(right, Dock.Right);
        head.Children.Add(right);
        var left = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new Border { Width = 3, Height = 14, Background = Tint(Cyan, 200), CornerRadius = new CornerRadius(2) });
        left.Children.Add(new TextBlock { Text = title, FontSize = 12.5, FontWeight = FontWeight.SemiBold, Foreground = Ink, VerticalAlignment = VerticalAlignment.Center });
        head.Children.Add(left);
        var stack = new StackPanel();
        stack.Children.Add(head);
        stack.Children.Add(body);
        return new Border
        {
            Background = Panel, BorderBrush = Line, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 8, 10, 10), Child = stack,
        };
    }

    /// A one-line health check row: dot, title, value, and a button that does something about it.
    public static (Border Row, LedLamp Dot, TextBlock Value) CheckRow(string title, string tip = "")
    {
        var dot = new LedLamp { Label = "", Colour = DimColour, On = false };
        var text = new TextBlock { Text = title, FontSize = 12, Width = 150, Foreground = Ink };
        var value = new TextBlock { FontSize = 11.5, Foreground = Dim, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto"), Margin = new Thickness(0, 2) };
        Grid.SetColumn(dot, 0); g.Children.Add(dot);
        Grid.SetColumn(text, 1); g.Children.Add(text);
        Grid.SetColumn(value, 2); g.Children.Add(value);
        var row = new Border
        {
            Background = Tint(Color.FromRgb(0x20, 0x23, 0x28), 160), CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 4), Child = g,
        };
        Tip(text, tip);
        return (row, dot, value);
    }
}






