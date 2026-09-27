// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The O2 / lambda and knock tables: what the log measured in every cell of a map, how far that is from the target, and the change that closes the gap. The channel can be a wideband's AFR or lambda, the ECU's own O2 voltage, or any analog input scaled between two voltages, so whatever is wired in reads in the right units here. "Compare to target" fills the difference column; "Apply offset changes" writes the corrections to the map as one undo step (fuel by proportion, ignition by degrees pulled where it knocked).
public sealed class LogTableWindow : Window
{
    readonly SimHost _host;
    readonly Func<IReadOnlyList<LogFrame>> _frames;
    // searchable: type any part of a name ("fuel", "ign", "afr") and pick from what matches
    readonly AutoCompleteBox _table = Search(240, "type part of a table name");
    readonly AutoCompleteBox _channel = Search(170, "type part of a channel");

    static AutoCompleteBox Search(double width, string hint)
    {
        var box = new AutoCompleteBox
        {
            Width = width, MinimumPrefixLength = 0, FilterMode = AutoCompleteFilterMode.Contains, Watermark = hint,
            MaxDropDownHeight = 360, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center,
        };
        // the whole list on a click, before anything is typed
        box.GotFocus += (_, _) => { if (string.IsNullOrEmpty(box.Text) || box.SelectedItem != null) box.IsDropDownOpen = true; };
        return box;
    }
    readonly CheckBox _asVolts = new() { Content = "scale from volts", VerticalAlignment = VerticalAlignment.Center };
    readonly NumericUpDown _at0 = Num(10, 0, 100, 0.5), _at5 = Num(20, 0, 100, 0.5);
    readonly NumericUpDown _target = Num(14.7, 0.5, 30, 0.1);
    readonly NumericUpDown _minSamples = Num(3, 1, 500, 1);
    readonly NumericUpDown _limit = Num(15, 1, 100, 1);
    readonly NumericUpDown _authority = Num(100, 5, 100, 5);
    readonly NumericUpDown _knockPull = Num(2, 0.25, 10, 0.25);
    readonly ComboBox _mode = new() { Width = 150, ItemsSource = new[] { "O2 / lambda (fuel)", "Knock (ignition)" }, SelectedIndex = 0 };
    /// The measured table, drawn as the very same grid the fuel and ignition maps use: RPM down the left, load across the top, every cell coloured by its value, the samples and the distance from target under each one. Nothing in it is edited here - the numbers came from the log - so it shows only, and Apply writes the changes to the map itself.
    readonly GridBox _grid = new() { Editable = false };
    readonly ComboBox _show = new()
    {
        Width = 190, SelectedIndex = 0,
        ItemsSource = new[] { "measured", "difference from target", "what the map would become" },
    };
    readonly TextBlock _status = new() { FontSize = 11.5, Opacity = 0.9, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6) };
    LogTable? _measured;
    List<CellChange> _changes = [];
    public bool Applied { get; private set; }

    static NumericUpDown Num(double v, double min, double max, double step) => new()
    {
        Value = (decimal)v, Minimum = (decimal)min, Maximum = (decimal)max, Increment = (decimal)step,
        Width = 110, FormatString = "0.###", FontFamily = MainWindow.MonoFont,
    };

    /// The AFR you want, per cam, and what the wideband really means (Settings > Targets).
    public TargetMap? TargetLow { get; init; }
    public TargetMap? TargetHigh { get; init; }
    public LookupCurve? Correction { get; init; }

    public LogTableWindow(SimHost host, Func<IReadOnlyList<LogFrame>> frames, ItemDef? preferred)
    {
        _host = host; _frames = frames;
        Title = "O2 / knock tables";
        Width = 940; Height = 720; MinWidth = 640; MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "O2 / knock tables");

        var tables = _host.Defs().Items.Where(i => i.IsTable && i.Count > 1).OrderBy(i => i.Category).ThenBy(i => i.Name).ToList();
        _table.ItemsSource = tables.Select(i => i.Name).ToList();
        _table.SelectedItem = preferred?.Name ?? tables.FirstOrDefault(i => i.Category.Equals("Fuel", StringComparison.OrdinalIgnoreCase))?.Name ?? tables.FirstOrDefault()?.Name;
        ToolTip.SetTip(_table, "The map the log is laid over: its rows and columns are the cells measured (normally a fuel map for O2, an ignition map for knock).");

        var channels = LogFrame.AllChannels(_frames()).OrderBy(c => c, StringComparer.OrdinalIgnoreCase).ToList();
        if (channels.Count == 0) channels = ["afr", "lambda", "o2_v", "knock"];
        _channel.ItemsSource = channels;
        _channel.SelectedItem = channels.FirstOrDefault(c => c.Equals("afr", StringComparison.OrdinalIgnoreCase))
                                ?? channels.FirstOrDefault(c => c.Equals("lambda", StringComparison.OrdinalIgnoreCase)) ?? channels[0];
        ToolTip.SetTip(_channel, "Which logged channel to read: a wideband's AFR or lambda, the ECU's O2 voltage, or an aux input you set up on the Settings page.");
        ToolTip.SetTip(_asVolts, "The channel is a raw voltage: read it as a straight line between the two readings below (a wideband's 0-5 V output, a knock box).");
        ToolTip.SetTip(_at0, "What the channel reads at 0 V.");
        ToolTip.SetTip(_at5, "What the channel reads at 5 V.");
        ToolTip.SetTip(_target, "Target AFR for the whole map (or the knock threshold in knock mode).");
        ToolTip.SetTip(_minSamples, "Cells with fewer logged samples than this are left alone.");
        ToolTip.SetTip(_limit, "Never change a cell by more than this in one pass.");
        ToolTip.SetTip(_authority, "How much of the gap to close this pass: 100% goes straight to target, less creeps up on it.");
        ToolTip.SetTip(_knockPull, "Degrees to take out of a cell that knocked (twice that where it knocked hard).");
        ToolTip.SetTip(_mode, "O2 mode corrects fuel by proportion; knock mode takes timing out of the cells that knocked.");

        var top = new WrapPanel { Margin = new Thickness(12, 8, 12, 0) };
        void Add(string label, Control c)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 4, 14, 4) };
            sp.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5 });
            sp.Children.Add(c);
            top.Children.Add(sp);
        }
        Add("Mode", _mode);
        Add("Map", _table);
        Add("Channel", _channel);
        top.Children.Add(_asVolts);
        Add("at 0 V", _at0);
        Add("at 5 V", _at5);
        Add("Target", _target);
        Add("Min samples", _minSamples);
        Add("Max change %", _limit);
        Add("Authority %", _authority);
        Add("Knock pull °", _knockPull);

        Add("Cells show", _show);
        ToolTip.SetTip(_show, "What the big number in each cell is: what the log measured there, how far that is from target as the fuel it is short of, " +
                              "or the value the map would hold after Apply. The small number underneath is always the samples that cell had.");
        _show.SelectionChanged += (_, _) => Draw();

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 4) };
        buttons.Children.Add(Btn("Read the log", Measure, "Average the channel into every cell of the map."));
        buttons.Children.Add(Btn("Compare to target", Compare, "Show how far each cell is from the target, and what would change."));
        var apply = Btn("Apply offset changes", Apply, "Write the changes to the map as one undo step.");
        buttons.Children.Add(apply);
        buttons.Children.Add(Btn("Close", Close, "Close this window."));

        var body = new DockPanel { Margin = new Thickness(12, 0, 12, 4) };
        DockPanel.SetDock(_status, Dock.Bottom);
        body.Children.Add(_status);
        body.Children.Add(_grid);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(top, 1); g.Children.Add(top);
        Grid.SetRow(buttons, 2); g.Children.Add(buttons);
        Grid.SetRow(body, 3); g.Children.Add(body);
        Content = g;

        _mode.SelectionChanged += (_, _) =>
        {
            bool knock = _mode.SelectedIndex == 1;
            _target.Value = knock ? 1 : 14.7m;
            var defs = _host.Defs();
            var want = defs.Items.FirstOrDefault(i => i.IsTable && i.Count > 1 &&
                i.Category.Equals(knock ? "Ignition" : "Fuel", StringComparison.OrdinalIgnoreCase));
            if (want != null) _table.SelectedItem = want.Name;
            var ch = (_channel.ItemsSource as IEnumerable<string>)?.FirstOrDefault(c => c.Contains(knock ? "knock" : "afr", StringComparison.OrdinalIgnoreCase));
            if (ch != null) _channel.SelectedItem = ch;
        };
        Measure();
    }

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    ItemDef? Item() => _host.Defs().Items.FirstOrDefault(i => i.Name.Equals(_table.SelectedItem as string ?? _table.Text ?? "", StringComparison.OrdinalIgnoreCase));

    ChannelScale Scale() => new()
    {
        Channel = _channel.SelectedItem as string ?? (string.IsNullOrWhiteSpace(_channel.Text) ? "afr" : _channel.Text.Trim()),
        Volts = _asVolts.IsChecked == true,
        AtZeroVolts = (double)(_at0.Value ?? 0),
        AtFiveVolts = (double)(_at5.Value ?? 5),
        Correction = Correction,
    };

    /// The target table for the map on screen: the high-cam one for a Hi map, the low-cam one otherwise, sampled onto the map's own axes. Null when no table has been set up, in which case the single Target box is used.
    double[]? Targets(ItemDef item)
    {
        var map = MapSide.Side(item) == true ? (TargetHigh?.Any == true ? TargetHigh : TargetLow) : TargetLow;
        return map is not { Any: true } ? null : map.ForTable(_host.Defs(), _host.RomCopy(), item, (double)(_target.Value ?? 14.7m));
    }

    void Measure()
    {
        var item = Item();
        if (item == null) { _status.Text = "no table to lay the log over"; return; }
        var frames = _frames();
        if (frames.Count == 0) { _status.Text = "no logged frames yet: log a drive, or load one on the Datalog page"; _grid.Note = ""; return; }
        _measured = LogTables.Build(_host.Defs(), _host.RomCopy(), item, frames, Scale());
        _changes = [];
        _diff = null;
        Draw();
        int seen = _measured.Count.Count(c => c > 0);
        _status.Text = $"{_measured.Frames:N0} frames landed in {seen} of {_measured.Cells} cells. Compare to target to see what would change.";
    }

    void Compare()
    {
        Measure();
        if (_measured == null) return;
        var item = _measured.Item;
        double target = (double)(_target.Value ?? 14.7m);
        var targetTable = _mode.SelectedIndex == 1 ? null : Targets(item);
        _changes = _mode.SelectedIndex == 1
            ? LogTables.KnockPulls(_host.Defs(), _host.RomCopy(), _measured, target, (double)(_knockPull.Value ?? 2), (int)(_minSamples.Value ?? 2))
            : LogTables.FuelOffsets(_host.Defs(), _host.RomCopy(), _measured, target, targetTable, (int)(_minSamples.Value ?? 3),
                                    (double)(_limit.Value ?? 15), (double)(_authority.Value ?? 100) / 100);
        _diff = _mode.SelectedIndex == 1 ? null : LogTables.Difference(_measured, target, targetTable);
        if (_diff != null && _show.SelectedIndex == 0) _show.SelectedIndex = 1;
        Draw();
        string where = targetTable != null
            ? $"targets from Settings > Targets ({(MapSide.Side(item) == true ? "high" : "low")} cam). "
            : "";
        _status.Text = where + (_changes.Count == 0
            ? "Nothing far enough from target, with enough samples, to change."
            : $"{_changes.Count} cell(s) of {item.Name} would change. Apply offset changes writes them as one undo step.");
    }

    void Apply()
    {
        if (_measured == null || _changes.Count == 0) { Compare(); if (_changes.Count == 0) return; }
        var item = _measured!.Item;
        try
        {
            _host.WriteCells(item, _changes.Select(c => (c.Index, c.To)).ToList(), false,
                             _mode.SelectedIndex == 1 ? "knock: timing pulled from the log" : "corrected to target from the log");
            Applied = true;
            AppLog.Action("calibration", $"{item.Name}: {_changes.Count} cell(s) corrected from the log ({_channel.SelectedItem})");
            _status.Text = $"{_changes.Count} cell(s) written to {item.Name} - Undo puts them back.";
            Measure();
        }
        catch (Exception ex) { _status.Text = "could not apply: " + ex.Message; AppLog.Error("calibration", "log offsets failed", ex); }
    }

    double[]? _diff;

    /// Put the measured table (and whatever the "cells show" box asks for) into the grid.
    void Draw()
    {
        var t = _measured;
        if (t == null) return;
        var item = t.Item;
        int rows = Math.Max(1, item.Rows), cols = Math.Max(1, item.Cols);
        var rowAxis = t.RowAxis.Length >= rows ? t.RowAxis[..rows] : [.. Enumerable.Range(0, rows).Select(i => (double)i)];
        var colAxis = t.ColAxis.Length >= cols ? t.ColAxis[..cols] : [.. Enumerable.Range(0, cols).Select(i => (double)i)];

        var after = new double[t.Cells];
        var now = RomData.Read(_host.Defs(), _host.RomCopy(), item);
        for (int i = 0; i < after.Length; i++) after[i] = i < now.Length ? now[i].Value : double.NaN;
        foreach (var c in _changes) if (c.Index >= 0 && c.Index < after.Length) after[c.Index] = c.To;

        bool knock = _mode.SelectedIndex == 1;
        var (values, unit, decimals, what) = _show.SelectedIndex switch
        {
            1 when _diff != null => (_diff, "%", 1, "how far each cell is from target, as the fuel it is short of (+) or over on (-)"),
            1 => (Blank(t.Cells), "", 1, "press Compare to target first"),
            2 => (after, knock ? "\u00b0" : "", 2, "the value the map would hold after Apply"),
            _ => (t.Mean, "", 2, $"what the log measured for {t.Channel} in each cell"),
        };
        _grid.Set(rowAxis, colAxis, [.. values], AxisUnit(item.RowAxis, "rpm"), AxisUnit(item.ColAxis, "load"), unit, decimals);
        // under each cell: how many samples it had, which is what decides whether it is corrected
        _grid.SetOverlay([.. t.Count.Select(n => n == 0 ? double.NaN : (double)n)], t.Count, "samples");
        _grid.Note = what + (_changes.Count > 0 ? $"  \u00b7  {_changes.Count} cell(s) would change" : "");
    }

    static double[] Blank(int n) => [.. Enumerable.Repeat(double.NaN, n)];

    string AxisUnit(AxisDef? a, string fallback)
    {
        if (a == null) return fallback;
        if (a.Unit.Length > 0) return a.Unit;
        try { return _host.Defs().Formula(a.Formula).Unit is { Length: > 0 } u ? u : fallback; } catch { return fallback; }
    }
}
