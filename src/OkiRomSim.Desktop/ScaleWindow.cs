// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Scaling a whole section at once: this table by a percentage, every fuel table for a different injector size, the load axis for a different MAP sensor, and the rescale that gives a fuel map that has run to the top of its scale room to grow again (each column's multiplier is raised and its cells divided to match, so the ECU delivers exactly what it did before). Nothing is written until Apply: the preview line says what would change first, and the whole scaling lands as a single undo step.
public sealed class ScaleWindow : Window
{
    readonly SimHost _host;
    readonly ItemDef? _item;
    readonly TextBlock _preview = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.9, MinHeight = 46, Margin = new Thickness(0, 6) };
    public bool Applied { get; private set; }

    public ScaleWindow(SimHost host, ItemDef? item)
    {
        _host = host;
        _item = item;
        Title = "Scale";
        // a fixed size that holds the tallest page (sizing to the content cut the inputs off under the dark title bar, and a page picked later could be taller than the first one); anything that still does not fit scrolls
        Width = 620; Height = 470; MinWidth = 440; MinHeight = 380;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Scale");

        var tabs = new TabControl { Margin = new Thickness(8, 4) };
        // small tab headers: the theme's own large ones took a third of a small window
        TabItem Tab(string header, Control page) => new()
        {
            Header = new TextBlock { Text = header, FontSize = 13 }, Tag = header, MinHeight = 30, Padding = new Thickness(10, 3),
            Content = new ScrollViewer { Content = page, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled },
        };
        tabs.Items.Add(Tab("This table", TablePage()));
        tabs.Items.Add(Tab("Headroom", HeadroomPage()));
        tabs.Items.Add(Tab("Injectors", InjectorPage()));
        tabs.Items.Add(Tab("MAP sensor", MapPage()));
        tabs.SelectionChanged += (_, _) => Preview();
        _tabs = tabs;

        var apply = new Button { Content = "Apply", IsDefault = true, MinWidth = 96 };
        apply.Click += (_, _) => Apply();
        ToolTip.SetTip(apply, "Write these bytes to the ROM as one change (Undo puts them all back).");
        var close = new Button { Content = "Close", IsCancel = true, MinWidth = 96 };
        close.Click += (_, _) => Close();
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 6, Margin = new Thickness(12, 4, 12, 12) };
        bar.Children.Add(close); bar.Children.Add(apply);

        // the preview can list every axis it would move: it scrolls in a box of its own instead of pushing the inputs and the buttons off the window
        var body = new ScrollViewer { Content = _preview, Margin = new Thickness(12, 0), MaxHeight = 96, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(tabs, 1); g.Children.Add(tabs);
        Grid.SetRow(body, 2); g.Children.Add(body);
        Grid.SetRow(bar, 3); g.Children.Add(bar);
        Content = g;
        Preview();
    }

    // ------------------------------------------------------------------ pages

    static StackPanel Page() => new() { Margin = new Thickness(12, 10) };

    NumericUpDown Num(double value, double min, double max, double step, string tip)
    {
        var n = new NumericUpDown
        {
            Value = (decimal)value, Minimum = (decimal)min, Maximum = (decimal)max, Increment = (decimal)step,
            Width = 130, FormatString = "0.###", FontFamily = MainWindow.MonoFont,
        };
        n.ValueChanged += (_, _) => Preview();
        ToolTip.SetTip(n, tip);
        return n;
    }

    static Control Line(string label, Control editor, string? note = null)
    {
        // wraps rather than running off the side when the window is narrow
        var sp = new WrapPanel { Margin = new Thickness(0, 4) };
        sp.Children.Add(new TextBlock { Text = label, Width = 190, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 8, 0) });
        sp.Children.Add(editor);
        if (note != null) sp.Children.Add(new TextBlock { Text = note, VerticalAlignment = VerticalAlignment.Center, FontSize = 11, Opacity = 0.7, Margin = new Thickness(8, 0, 0, 0) });
        return sp;
    }

    Control TablePage()
    {
        var p = Page();
        if (_item == null || !_item.IsTable)
        {
            p.Children.Add(new TextBlock { Text = "Select a table on the Calibration page first.", TextWrapping = TextWrapping.Wrap });
            return p;
        }
        var pct = Num(0, -90, 500, 1, "How much to change every cell of this table by, in percent.");
        var keep = new CheckBox { Content = "rescale columns that would max out", IsChecked = true, Margin = new Thickness(0, 6) };
        keep.IsCheckedChanged += (_, _) => Preview();
        ToolTip.SetTip(keep, "When a column would run past the top of its range, raise that column's multiplier and divide its cells to match, instead of flat-topping at the end of the scale.");
        p.Children.Add(new TextBlock { Text = _item.Name + $"  ({_item.Rows} x {_item.Cols})", FontWeight = FontWeight.Bold });
        p.Children.Add(Line("Change every cell by", pct, "%"));
        p.Children.Add(keep);
        _pages["This table"] = rom => Rescale.ScaleTable(_host.Defs(), rom, _item, 1 + ((double)(pct.Value ?? 0) / 100), keep.IsChecked == true);
        return p;
    }

    Control HeadroomPage()
    {
        var p = Page();
        if (_item == null || _item.ColumnScaleAddress == null)
        {
            p.Children.Add(new TextBlock
            {
                Text = "Select a fuel table (one with a column multiplier row) to rescale it.",
                TextWrapping = TextWrapping.Wrap,
            });
            return p;
        }
        var peak = Num(200, 32, 250, 8, "Where the biggest cell of each column should sit, out of 255. Lower leaves more room to add fuel.");
        p.Children.Add(new TextBlock
        {
            Text = "Move the cells down the scale and raise each column's multiplier to match. The ECU delivers exactly " +
                   "what it did before - the table simply has room above it again.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.85, FontSize = 11.5, Margin = new Thickness(0, 0, 0, 6),
        });
        p.Children.Add(Line("Put the biggest cell at", peak, "of 255"));
        _pages["Headroom"] = rom => Rescale.Headroom(_host.Defs(), rom, _item, (int)(peak.Value ?? 200));
        return p;
    }

    Control InjectorPage()
    {
        var p = Page();
        var oldCc = Num(240, 1, 3000, 10, "The injectors the calibration was written for.");
        var newCc = Num(310, 1, 3000, 10, "The injectors fitted now. Bigger injectors get a shorter pulse.");
        p.Children.Add(new TextBlock
        {
            Text = "Every fuel table is scaled by old / new, so the same air gets the same fuel. Use the same unit for both (cc/min or lb/hr).",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.85, FontSize = 11.5, Margin = new Thickness(0, 0, 0, 6),
        });
        p.Children.Add(Line("Injectors in the calibration", oldCc, "cc/min"));
        p.Children.Add(Line("Injectors fitted", newCc, "cc/min"));
        _pages["Injectors"] = rom => Rescale.Injectors(_host.Defs(), rom, FuelTables(), (double)(oldCc.Value ?? 0), (double)(newCc.Value ?? 0));
        return p;
    }

    Control MapPage()
    {
        var p = Page();
        var oldKpa = Num(101.3, 10, 1000, 10, "Pressure the old sensor reads at the top of its range.");
        var newKpa = Num(200, 10, 1000, 10, "Pressure the new sensor reads at the top of its range (a 2 bar sensor reads about 200 kPa).");
        p.Children.Add(new TextBlock
        {
            Text = "A different MAP sensor reads a different pressure at the same voltage, so the load breakpoints move to stay at the same real pressure. " +
                   "The load axis of every map is scaled by old / new; an axis shared by several maps is changed once.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.85, FontSize = 11.5, Margin = new Thickness(0, 0, 0, 6),
        });
        p.Children.Add(Line("Sensor in the calibration", oldKpa, "kPa full scale"));
        p.Children.Add(Line("Sensor fitted", newKpa, "kPa full scale"));
        _pages["MAP sensor"] = rom => Rescale.MapSensor(_host.Defs(), rom, Maps(), (double)(oldKpa.Value ?? 0), (double)(newKpa.Value ?? 0));
        return p;
    }

    readonly Dictionary<string, Func<byte[], ScaleReport>> _pages = [];

    IEnumerable<ItemDef> FuelTables() =>
        _host.Defs().Items.Where(i => i.IsTable && i.Count > 1 &&
            (i.ColumnScaleAddress != null || i.Category.Equals("Fuel", StringComparison.OrdinalIgnoreCase)));

    IEnumerable<ItemDef> Maps() => _host.Defs().Items.Where(i => i.IsTable && i.Cols > 1 && i.ColAxis?.Address != null);

    // ------------------------------------------------------------------ preview / apply

    TabControl? _tabs;
    string Current => _tabs?.SelectedItem is TabItem t ? t.Tag as string ?? "" : "";

    ScaleReport? Build()
    {
        if (!_pages.TryGetValue(Current, out var f)) return null;
        try { return f(_host.RomCopy()); }
        catch (Exception ex) { return ScaleReport.Nothing("cannot work that out: " + ex.Message); }
    }

    void Preview()
    {
        var r = Build();
        _preview.Text = r == null ? "" : r.Any ? r.Summary + $"\n{r.Patches.Count} byte(s) would change." : r.Summary;
    }

    void Apply()
    {
        var r = Build();
        if (r == null || !r.Any) { _preview.Text = r?.Summary ?? "nothing to do"; return; }
        try
        {
            int n = _host.ApplyPatches(r.Patches, "scale: " + Current);
            Applied = true;
            AppLog.Action("calibration", $"scaled ({Current}): {r.Summary}");
            _preview.Text = r.Summary + $"\n{n} byte(s) written - Undo puts them back.";
            Preview();
        }
        catch (Exception ex) { _preview.Text = "could not apply: " + ex.Message; AppLog.Error("calibration", "scale failed", ex); }
    }
}
