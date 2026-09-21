using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// The bar across the top of a page: a few category drop-downs (File, Tools) holding the things done once in a while, and the everyday actions as icon buttons beside them.
/// The icons are plain text glyphs, so there is nothing to ship and nothing to scale badly: the label still says what the button does, and the tooltip says it in full.
public static class Toolbar
{
    public sealed record Entry(string Icon, string Text, string Tip, Action Run, bool Separator = false)
    {
        public static Entry Line => new("", "", "", () => { }, true);
    }

    /// A category drop-down: "File ▾" with its items.
    public static Button Menu(string text, string icon, params Entry[] items)
    {
        var flyout = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedLeft };
        foreach (var e in items)
        {
            if (e.Separator) { flyout.Items.Add(new Separator()); continue; }
            var mi = new MenuItem { Header = e.Text, Icon = Glyph(e.Icon, 14) };
            var run = e.Run;
            mi.Click += (_, _) => run();
            if (e.Tip.Length > 0) ToolTip.SetTip(mi, e.Tip);
            flyout.Items.Add(mi);
        }
        var b = new Button { Content = Label(icon, text + "  ▾"), Margin = new Thickness(2, 0), Flyout = flyout };
        ToolTip.SetTip(b, string.Join(", ", items.Where(i => !i.Separator).Select(i => i.Text)));
        return b;
    }

    /// An everyday action: icon and label side by side.
    public static Button Button(string icon, string text, string tip, Action run)
    {
        var b = new Button { Content = Label(icon, text), Margin = new Thickness(2, 0) };
        b.Click += (_, _) => run();
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// Put an icon on a button that is already built (its label is kept).
    public static Button WithIcon(this Button b, string icon)
    {
        if (b.Content is string text) b.Content = Label(icon, text);
        return b;
    }

    public static Control Label(string icon, string text)
    {
        if (icon.Length == 0) return new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center };
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        sp.Children.Add(Glyph(icon, 13));
        sp.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return sp;
    }

    static Control Glyph(string icon, double size) => new TextBlock
    {
        Text = icon, FontSize = size, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.95,
        // the glyphs are symbols, not letters: keep them from being italicised or bolded by a theme
        FontStyle = FontStyle.Normal, FontWeight = FontWeight.Normal, MinWidth = 14, TextAlignment = TextAlignment.Center,
    };

    // the glyphs used across the app, in one place so they stay consistent
    public const string Open = "📂", Save = "💾", SaveAs = "🖫", Project = "🗄", Restore = "⏱", Clear = "🧹",
                        Compare = "⇄", Build = "🔨", Run = "▶", Pause = "❚❚", Step = "⤼", Over = "⤻", Into = "⤶",
                        Out = "⤴", Reset = "↻", Tuner = "🎚", Settings = "⚙", Detect = "🔍", Add = "＋", Delete = "🗑",
                        Import = "⭳", Export = "⭱", Bin = "🖭", Scale = "⇕", Log = "📈", Gauge = "🕹";
}
