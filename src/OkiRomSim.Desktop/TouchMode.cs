// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;

namespace OkiRomSim.Desktop;

/// Touch screen mode (Settings > General): controls sized for a finger across the app, and a pad of big buttons beside the tables (TouchPad) for what the keys do on a keyboard.
public static class TouchMode
{
    static Styles? _styles;
    public static bool On { get; private set; }
    public static event Action? Changed;

    public static void Set(bool on)
    {
        if (on == On) return;
        On = on;
        if (Application.Current is { } app)
        {
            if (on) app.Styles.Add(_styles ??= Build());
            else if (_styles != null) app.Styles.Remove(_styles);
        }
        Changed?.Invoke();
    }

    /// Taller buttons, list rows, boxes and tabs: a finger needs about 9 mm, the mouse-sized controls are half that.
    static Styles Build()
    {
        Style S<T>(params (AvaloniaProperty P, object V)[] setters) where T : Control
        {
            var s = new Style(x => x.OfType<T>());
            foreach (var (p, v) in setters) s.Setters.Add(new Setter(p, v));
            return s;
        }
        return
        [
            S<Button>((Layoutable.MinHeightProperty, 40.0), (TemplatedControl.PaddingProperty, new Thickness(12, 6))),
            S<ToggleButton>((Layoutable.MinHeightProperty, 40.0), (TemplatedControl.PaddingProperty, new Thickness(12, 6))),
            S<CheckBox>((Layoutable.MinHeightProperty, 36.0)),
            S<RadioButton>((Layoutable.MinHeightProperty, 36.0)),
            S<ComboBox>((Layoutable.MinHeightProperty, 40.0)),
            S<TextBox>((Layoutable.MinHeightProperty, 38.0)),
            S<NumericUpDown>((Layoutable.MinHeightProperty, 40.0)),
            S<TabItem>((Layoutable.MinHeightProperty, 40.0), (TemplatedControl.PaddingProperty, new Thickness(14, 6))),
            S<TreeViewItem>((Layoutable.MinHeightProperty, 34.0)),
            S<ListBoxItem>((Layoutable.MinHeightProperty, 36.0)),
            S<MenuItem>((TemplatedControl.PaddingProperty, new Thickness(14, 10))),
            S<ScrollBar>((ScrollBar.AllowAutoHideProperty, false)),
        ];
    }
}

/// The table keys as buttons, for a touch screen: beside the table on the Calibration page in touch screen mode. Every button is one the table views already answer to (TableKeys) - so a tap does exactly what the key does - and none takes the focus, so the keys still work on a keyboard as well.
public sealed class TouchPad : Border
{
    readonly TableGrid _grid;
    readonly Action<string> _adjust;
    readonly Func<string?> _amount;
    readonly Action<string> _setAmount;
    readonly ToggleButton _extend = Toggle("Select\nmore", "On: the arrows grow the selection (as Shift+arrows do). Off: they move it.");

    static readonly IBrush Up = new SolidColorBrush(Color.FromRgb(0x2f, 0x7d, 0x46));
    static readonly IBrush Down = new SolidColorBrush(Color.FromRgb(0x9a, 0x3b, 0x2c));

    /// adjust: the page's actions on the selection ("set", "add", "pct" with the amount box, "ih", "iv", "smooth"); the amount box is read and written through amount / setAmount (the keypad fills it).
    public TouchPad(TableGrid grid, Action<string> adjust, Func<string?> amount, Action<string> setAmount, Action undo, Action redo)
    {
        _grid = grid; _adjust = adjust; _amount = amount; _setAmount = setAmount;
        Background = new SolidColorBrush(Color.FromRgb(0x1b, 0x1c, 0x20));
        CornerRadius = new CornerRadius(6);
        Padding = new Thickness(6);
        Margin = new Thickness(6, 0, 0, 0);
        var col = new StackPanel { Spacing = 6, Width = 152 };
        col.Children.Add(Head("CHANGE"));
        col.Children.Add(Pair(Key("▲▲", "Up ten steps", Up, "Up ten steps"), Key("▲", "Up one step", Up, "Up one step")));
        col.Children.Add(Pair(Key("▼▼", "Down ten steps", Down, "Down ten steps"), Key("▼", "Down one step", Down, "Down one step")));
        col.Children.Add(Pair(Key("+1 %", "Up 1 %", Up), Key("−1 %", "Down 1 %", Down)));
        col.Children.Add(Pair(Key("+5 %", "Up 5 %", Up), Key("−5 %", "Down 5 %", Down)));
        col.Children.Add(Wide(Btn("Value…", "Type a value on a keypad: set the selected cells to it, add it, or change them by it in percent.", OpenKeypad)));
        col.Children.Add(Head("SELECT"));
        col.Children.Add(Pair(new Border(), Move("▲", -1, 0)));
        col.Children.Add(Pair(Move("◀", 0, -1), Move("▶", 0, 1)));
        col.Children.Add(Pair(new Border(), Move("▼", 1, 0)));
        col.Children.Add(Pair(_extend, Btn("All", "Select every cell.", () => _grid.SelectAll())));
        col.Children.Add(Head("SHAPE"));
        col.Children.Add(Pair(Btn("Interp\n↔", "A straight line across each row between the first and last selected columns.", () => _adjust("ih")),
                              Btn("Interp\n↕", "A straight line down each column between the first and last selected rows.", () => _adjust("iv"))));
        col.Children.Add(Pair(Btn("Smooth", "Each selected cell averaged with its selected neighbours.", () => _adjust("smooth")),
                              Btn("Copy", "Copy the selected cells.", () => _grid.DoCopy())));
        col.Children.Add(Pair(Btn("↶ Undo", "Undo the last change.", undo), Btn("↷ Redo", "Put back what Undo took away.", redo)));
        Child = new ScrollViewer { Content = col, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    static TextBlock Head(string t) => new() { Text = t, FontSize = 10.5, FontWeight = FontWeight.Bold, Opacity = 0.6, Margin = new Thickness(2, 4, 0, 0) };

    static Grid Pair(Control a, Control b)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,6,*") };
        Grid.SetColumn(a, 0); g.Children.Add(a);
        Grid.SetColumn(b, 2); g.Children.Add(b);
        return g;
    }

    static Control Wide(Control c) { c.HorizontalAlignment = HorizontalAlignment.Stretch; return c; }

    static Button Btn(string text, string tip, Action a, IBrush? bg = null)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = text, TextAlignment = TextAlignment.Center, FontSize = 15, FontWeight = FontWeight.SemiBold },
            MinHeight = 52, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center, Focusable = false, Padding = new Thickness(4),
        };
        if (bg != null) b.Background = bg;
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => a();
        return b;
    }

    static ToggleButton Toggle(string text, string tip)
    {
        var b = new ToggleButton
        {
            Content = new TextBlock { Text = text, TextAlignment = TextAlignment.Center, FontSize = 12.5 },
            MinHeight = 52, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center, Focusable = false,
        };
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// A button for a table key (TableKeys id): it does what the key does.
    Button Key(string text, string id, IBrush bg, string? what = null) =>
        Btn(text, (TableKeys.All.FirstOrDefault(k => k.Id == id)?.What ?? id) + $"  ({TableKeys.Display(id)})", () => _grid.Run(id), bg);

    Button Move(string text, int dr, int dc) => Btn(text, "Move the selection (with Select more on: grow it).", () => _grid.Move(dr, dc, _extend.IsChecked == true));

    void OpenKeypad()
    {
        var shown = new TextBox { Text = _amount() ?? "", FontSize = 20, IsReadOnly = true, HorizontalContentAlignment = HorizontalAlignment.Right, MinHeight = 44 };
        var keys = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*,*"), RowDefinitions = new RowDefinitions("*,*,*,*,*") };
        var flyout = new Flyout { Placement = PlacementMode.LeftEdgeAlignedTop };
        void Put(int r, int c, string label, Action a)
        {
            var b = new Button
            {
                Content = label, FontSize = 18, MinHeight = 50, MinWidth = 60, Margin = new Thickness(2), Focusable = false,
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center,
            };
            b.Click += (_, _) => a();
            Grid.SetRow(b, r); Grid.SetColumn(b, c); keys.Children.Add(b);
        }
        for (int d = 1; d <= 9; d++) { int n = d; Put(2 - ((d - 1) / 3), (d - 1) % 3, n.ToString(), () => shown.Text += n); }
        Put(3, 0, "±", () => shown.Text = shown.Text is { Length: > 0 } t && t[0] == '-' ? t[1..] : "-" + shown.Text);
        Put(3, 1, "0", () => shown.Text += "0");
        Put(3, 2, ".", () => { if (!(shown.Text ?? "").Contains('.')) shown.Text += "."; });
        Put(4, 0, "⌫", () => { if (shown.Text is { Length: > 0 } t) shown.Text = t[..^1]; });
        Put(4, 1, "C", () => shown.Text = "");
        var actions = new StackPanel { Spacing = 4, Margin = new Thickness(6, 0, 0, 0) };
        foreach (var (label, op, tip) in new[] { ("Set", "set", "Set the selected cells to it."), ("Add", "add", "Add it to the selected cells."), ("%", "pct", "Change the selected cells by it, in percent.") })
        {
            var b = new Button { Content = label, FontSize = 16, MinHeight = 50, MinWidth = 80, Focusable = false, HorizontalContentAlignment = HorizontalAlignment.Center };
            ToolTip.SetTip(b, tip);
            b.Click += (_, _) =>
            {
                if (!double.TryParse(shown.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out _)) return;
                _setAmount(shown.Text!);
                _adjust(op);
                flyout.Hide();
            };
            actions.Children.Add(b);
        }
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetColumnSpan(shown, 2); body.Children.Add(shown);
        Grid.SetRow(keys, 1); body.Children.Add(keys);
        Grid.SetRow(actions, 1); Grid.SetColumn(actions, 1); body.Children.Add(actions);
        body.Width = 330;
        flyout.Content = body;
        flyout.ShowAt(this);
    }
}
