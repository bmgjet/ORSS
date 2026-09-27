// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// The bar across the top of a page: a few category drop-downs (File, Tools) holding the things done once in a while, and the everyday actions as icon buttons beside them. The icons are plain text glyphs, so there is nothing to ship and nothing to scale badly: the label still says what the button does, and the tooltip says it in full.
public static class Toolbar
{
    /// One line of a drop-down. `Sub` makes it a submenu instead of an action, and is asked for its items each time the menu is opened, so a list that changes while the program runs (the datalog channels offered for the map overlay) is always up to date. `Checked` puts a tick beside the line, for the settings a menu switches on and off.
    public sealed record Entry(string Icon, string Text, string Tip, Action Run, bool Separator = false,
                               Func<Entry[]>? Sub = null, Func<bool>? Checked = null)
    {
        public static Entry Line => new("", "", "", () => { }, true);
        public static Entry Submenu(string icon, string text, string tip, Func<Entry[]> items) => new(icon, text, tip, () => { }, false, items);
    }

    /// A category drop-down: "File ▾" with its items.
    public static Button Menu(string text, string icon, params Entry[] items)
    {
        var flyout = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedLeft };
        var b = new Button { Content = Label(icon, text + "  ▾"), Margin = new Thickness(2, 0), Flyout = flyout };
        // rebuilt every time it opens: ticks, and any submenu whose contents change as the program runs
        flyout.Opening += (_, _) =>
        {
            flyout.Items.Clear();
            foreach (var mi in Items(items)) flyout.Items.Add(mi);
        };
        foreach (var mi in Items(items)) flyout.Items.Add(mi);
        ToolTip.SetTip(b, string.Join(", ", items.Where(i => !i.Separator).Select(i => i.Text)));
        return b;
    }

    /// A drop-down whose lines are asked for each time it opens (the Datalogging menu, whose Connect reads Disconnect while logging).
    public static Button Menu(string text, string icon, Func<Entry[]> items)
    {
        var flyout = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedLeft };
        var b = new Button { Content = Label(icon, text + "  ▾"), Margin = new Thickness(2, 0), Flyout = flyout };
        flyout.Opening += (_, _) =>
        {
            flyout.Items.Clear();
            foreach (var mi in Items(items())) flyout.Items.Add(mi);
        };
        flyout.Items.Add(new MenuItem { Header = "…" });
        return b;
    }

    static List<Control> Items(IEnumerable<Entry> items)
    {
        var list = new List<Control>();
        foreach (var e in items)
        {
            if (e.Separator) { list.Add(new Separator()); continue; }
            bool ticked = e.Checked?.Invoke() == true;
            var mi = new MenuItem { Header = (ticked ? "✓  " : "") + e.Text, Icon = Glyph(e.Icon, 14) };
            if (e.Sub != null)
            {
                var sub = e.Sub;
                mi.ItemsSource = Items(sub());
                // the list may have grown since: ask again as the submenu opens
                mi.SubmenuOpened += (_, _) => mi.ItemsSource = Items(sub());
            }
            else
            {
                var run = e.Run;
                mi.Click += (_, _) => run();
            }
            if (e.Tip.Length > 0) ToolTip.SetTip(mi, e.Tip);
            list.Add(mi);
        }
        return list;
    }

    /// An everyday action: icon and label side by side.
    public static Button Button(string icon, string text, string tip, Action run)
    {
        var b = new Button { Content = Label(icon, text), Margin = new Thickness(2, 0) };
        b.Click += (_, _) => run();
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// An icon on its own: for the everyday actions whose tooltip says what they do (Back, Undo, Redo), so no screen goes on a label.
    public static Button IconButton(string icon, string tip, Action run)
    {
        var b = new Button { Content = Glyph(icon, 14), Margin = new Thickness(2, 0), Padding = new Thickness(8, 4), MinWidth = 32 };
        b.Click += (_, _) => run();
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// A menu's label with a coloured dot in front: the state of the link the menu drives.
    public static Control DotLabel(StatusDot dot, string icon, string text)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        sp.Children.Add(UiStyles.Adopt(dot));
        sp.Children.Add(Glyph(icon, 13));
        sp.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return sp;
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
