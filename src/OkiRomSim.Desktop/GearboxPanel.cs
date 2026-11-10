// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The gearbox, the way the established tuning software sets it: pick the car's gearbox from the presets (its gear
/// boundaries are written), or learn them from a drive with the datalog running. At the top of the Transmission page.
public static class GearboxPanel
{
    static List<GearboxPreset>? _presets;

    public static List<GearboxPreset> Presets()
    {
        if (_presets != null) return _presets;
        try { _presets = AppPaths.Templates() is { } t ? PresetLibrary.Load(Path.Combine(t, "Presets")).Gearboxes : []; }
        catch (Exception ex) { AppLog.Error("gearbox", "presets could not be read", ex); _presets = []; }
        return _presets;
    }

    /// Write a set of boundaries as one undo step; what was done, for the status line.
    public static string Write(AppHost host, int[] bounds, int preset, string what)
    {
        var defs = host.Defs();
        var rom = host.RomCopy();
        var work = (byte[])rom.Clone();
        if (!Gearboxes.Apply(defs, work, bounds, preset)) return $"this ROM does not work out the gear (build in Gear detection: {AboutPage.ChangeFunctions})";
        var patches = MapImport.Diff(rom, work);
        if (patches.Count == 0) return $"gearbox: {what} - already set";
        host.ApplyPatches(patches, "gearbox: " + what);
        AppLog.Action("gearbox", $"{what}: {string.Join(", ", bounds)}");
        return $"gearbox: {what} ({string.Join(", ", bounds)}) - Undo puts it back";
    }

    /// The panel: the preset in use (or Custom), and Gear learning.
    public static Control? Build(AppHost host, DatalogEngine engine, Action<string> status, Func<Window?> owner)
    {
        var defs = host.Defs();
        if (!Gearboxes.Has(defs)) return null;
        var presets = Presets();
        var now = Gearboxes.Read(defs, host.RomCopy()) ?? [];
        int match = presets.FindIndex(p => p.Bounds.Take(4).SequenceEqual(now.Take(4)));
        var names = presets.Select(p => p.Name).Append("Custom (learned or typed in)").ToList();
        var box = new ComboBox { ItemsSource = names, Width = 260, SelectedIndex = match >= 0 ? match : names.Count - 1 };
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedIndex < 0 || box.SelectedIndex >= presets.Count) return;
            var p = presets[box.SelectedIndex];
            status(Write(host, [.. p.Bounds.Take(4)], box.SelectedIndex, p.Name));
        };
        ToolTip.SetTip(box, "The car's gearbox: its gear boundaries are written to the ROM (the custom ratios below). Custom: what Gear learning measured, or typed into the table.");
        var learn = new Button { Content = "Gear learning…", Padding = new Thickness(10, 3), VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(learn, "Drive in each gear with the datalog running: the ratio of rpm to road speed in each is measured, and the boundaries between them written.");
        learn.Click += (_, _) => { var w = new GearLearnWindow(host, engine, status); if (owner() is { } o) w.Show(o); else w.Show(); };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children =
        {
            new TextBlock { Text = "Gearbox:", Width = 240, VerticalAlignment = VerticalAlignment.Center },
            box, learn,
        } };
        var body = new StackPanel { Margin = new Thickness(10, 6, 8, 8), Spacing = 4, Children =
        {
            row,
            new TextBlock
            {
                Text = "now: " + (now.Length == 0 ? "-" : string.Join(", ", now)) + "  (raw ratio between gears 1-2, 2-3, 3-4, 4-5: 7324 x km/h / rpm)",
                FontSize = 11, Opacity = 0.7, Margin = new Thickness(248, 0, 0, 0),
            },
        } };
        return new Border
        {
            BorderBrush = AppTheme.Brush(Color.FromArgb(64, 255, 255, 255)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
            Margin = new Thickness(0, 0, 0, 10),
            Child = new StackPanel { Children = { new TextBlock { Text = "Gearbox", FontWeight = FontWeight.Bold, FontSize = 12, Margin = new Thickness(10, 6, 0, 0) }, body } },
        };
    }
}

/// Gear learning: with the datalog running, drive in each gear and press its button; the ratio of rpm to road speed is
/// averaged over the last couple of seconds there, and Apply writes the boundaries half way between the gears.
public sealed class GearLearnWindow : Window
{
    readonly AppHost _host;
    readonly DatalogEngine _engine;
    readonly Action<string> _status;
    readonly TextBlock _live = new() { FontFamily = UiFonts.Mono, FontSize = 16 };
    readonly TextBlock _note = new() { FontSize = 11.5, Opacity = 0.8, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock[] _got = new TextBlock[5];
    readonly double[] _learned = new double[5];
    readonly List<(double T, double Raw)> _recent = [];
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(200) };

    public GearLearnWindow(AppHost host, DatalogEngine engine, Action<string> status)
    {
        _host = host; _engine = engine; _status = status;
        Title = "Gear learning";
        Width = 520; SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, Title);
        var page = new StackPanel { Margin = new Thickness(14, 10), Spacing = 8 };
        page.Children.Add(new TextBlock
        {
            Text = "Drive steadily in each gear (above 10 km/h, clutch out) and press that gear's button. Do the gears you can; " +
                   "the ones left are worked out from the gaps between the others. Apply writes the boundaries.",
            TextWrapping = TextWrapping.Wrap, FontSize = 12,
        });
        page.Children.Add(_live);
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("120,*"), RowSpacing = 4 };
        for (int g = 0; g < 5; g++)
        {
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            int gear = g;
            var b = new Button { Content = $"Gear {g + 1}", Width = 110 };
            b.Click += (_, _) => Record(gear);
            _got[g] = new TextBlock { Text = "-", VerticalAlignment = VerticalAlignment.Center, FontFamily = UiFonts.Mono };
            Grid.SetRow(b, g); grid.Children.Add(b);
            Grid.SetRow(_got[g], g); Grid.SetColumn(_got[g], 1); grid.Children.Add(_got[g]);
        }
        page.Children.Add(grid);
        page.Children.Add(_note);
        var apply = new Button { Content = "Apply", Padding = new Thickness(14, 4) };
        apply.Click += (_, _) => Apply();
        var reset = new Button { Content = "Start again", Padding = new Thickness(14, 4) };
        reset.Click += (_, _) => { Array.Clear(_learned); for (int i = 0; i < 5; i++) _got[i].Text = "-"; _note.Text = ""; };
        var close = new Button { Content = "Close", Padding = new Thickness(14, 4) };
        close.Click += (_, _) => Close();
        page.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { reset, apply, close } });
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(page);
        Content = root;
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        Closed += (_, _) => _timer.Stop();
    }

    void Tick()
    {
        var f = _engine.Latest;
        if (!_engine.Running || f == null || !_engine.Fresh)
        {
            _live.Text = "waiting for the datalog (connect it from the Datalogging menu)";
            return;
        }
        double rpm = f.Rpm ?? 0, kmh = f.SpeedKmh ?? 0;
        double raw = Gearboxes.RawOf(rpm, kmh);
        _live.Text = $"{rpm,5:0} rpm  {kmh,4:0} km/h  ratio {raw,5:0.0}";
        if (rpm > 1000 && kmh > 10)
        {
            if (_recent.Count == 0 || f.T > _recent[^1].T) _recent.Add((f.T, raw));
            _recent.RemoveAll(x => x.T < f.T - 2);
        }
    }

    void Record(int gear)
    {
        if (_recent.Count < 3) { _note.Text = "no steady reading yet: drive in that gear above 10 km/h with the datalog running"; return; }
        var vals = _recent.Select(x => x.Raw).OrderBy(v => v).ToList();
        double median = vals[vals.Count / 2];
        double spread = vals[^1] - vals[0];
        _learned[gear] = median;
        _got[gear].Text = $"{median:0.0}" + (spread > median * 0.1 ? "   (unsteady - try again holding a steady speed)" : "");
        _note.Text = $"gear {gear + 1} recorded";
    }

    void Apply()
    {
        var per = _learned.Where(v => v > 0).ToList();
        if (per.Count < 2) { _note.Text = "record at least two gears first"; return; }
        if (per.Zip(per.Skip(1)).Any(p => p.Second <= p.First)) { _note.Text = "the gears must go up in ratio (gear 1 lowest): record them again"; return; }
        // every gear in its own place (0 for one not recorded), so a gear left out does not move the others down
        var bounds = Gearboxes.FromLearned(_learned);
        var msg = GearboxPanel.Write(_host, bounds, -1, "learned");
        _note.Text = msg;
        _status(msg);
    }
}
