using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The O2 / lambda and knock tables: what the log measured in every cell of a map, how far that is from the target, and the change that closes the gap.
/// The channel can be a wideband's AFR or lambda, the ECU's own O2 voltage, or any analog input scaled between two voltages, so whatever is wired in reads in the right units here. "Compare to target" fills the difference column; "Apply offset changes" writes the corrections to the map as one undo step (fuel by proportion, ignition by degrees pulled where it knocked).
public sealed class LogTableWindow : Window
{
    readonly SimHost _host;
    readonly Func<IReadOnlyList<LogFrame>> _frames;
    readonly ComboBox _table = new() { Width = 220 };
    readonly ComboBox _channel = new() { Width = 150 };
    readonly CheckBox _asVolts = new() { Content = "scale from volts", VerticalAlignment = VerticalAlignment.Center };
    readonly NumericUpDown _at0 = Num(10, 0, 100, 0.5), _at5 = Num(20, 0, 100, 0.5);
    readonly NumericUpDown _target = Num(14.7, 0.5, 30, 0.1);
    readonly NumericUpDown _minSamples = Num(3, 1, 500, 1);
    readonly NumericUpDown _limit = Num(15, 1, 100, 1);
    readonly NumericUpDown _authority = Num(100, 5, 100, 5);
    readonly NumericUpDown _knockPull = Num(2, 0.25, 10, 0.25);
    readonly ComboBox _mode = new() { Width = 150, ItemsSource = new[] { "O2 / lambda (fuel)", "Knock (ignition)" }, SelectedIndex = 0 };
    readonly TextBox _grid = new()
    {
        IsReadOnly = true, AcceptsReturn = true, FontFamily = MainWindow.MonoFont, FontSize = 11.5,
        Height = 320, TextWrapping = TextWrapping.NoWrap,
    };
    readonly TextBlock _status = new() { FontSize = 11.5, Opacity = 0.9, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6) };
    LogTable? _measured;
    List<CellChange> _changes = new();
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

        var channels = _frames().SelectMany(f => f.Channels()).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(c => c).ToList();
        if (channels.Count == 0) channels = new List<string> { "afr", "lambda", "o2_v", "knock" };
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

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 4) };
        buttons.Children.Add(Btn("Read the log", Measure, "Average the channel into every cell of the map."));
        buttons.Children.Add(Btn("Compare to target", Compare, "Show how far each cell is from the target, and what would change."));
        var apply = Btn("Apply offset changes", Apply, "Write the changes to the map as one undo step.");
        buttons.Children.Add(apply);
        buttons.Children.Add(Btn("Close", Close, "Close this window."));

        var body = new StackPanel { Margin = new Thickness(12, 0) };
        body.Children.Add(_grid);
        body.Children.Add(_status);

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

    ItemDef? Item() => _host.Defs().Items.FirstOrDefault(i => i.Name == (_table.SelectedItem as string ?? ""));

    ChannelScale Scale() => new()
    {
        Channel = _channel.SelectedItem as string ?? "afr",
        Volts = _asVolts.IsChecked == true,
        AtZeroVolts = (double)(_at0.Value ?? 0),
        AtFiveVolts = (double)(_at5.Value ?? 5),
        Correction = Correction,
    };

    /// The target table for the map on screen: the high-cam one for a Hi map, the low-cam one otherwise, sampled onto the map's own axes. Null when no table has been set up, in which case the single Target box is used.
    double[]? Targets(ItemDef item)
    {
        var map = MapSide.Side(item) == true ? (TargetHigh?.Any == true ? TargetHigh : TargetLow) : TargetLow;
        if (map is not { Any: true }) return null;
        return map.ForTable(_host.Defs(), _host.RomCopy(), item, (double)(_target.Value ?? 14.7m));
    }

    void Measure()
    {
        var item = Item();
        if (item == null) { _status.Text = "no table to lay the log over"; return; }
        var frames = _frames();
        if (frames.Count == 0) { _status.Text = "no logged frames yet: log a drive, or load one on the Datalog page"; _grid.Text = ""; return; }
        _measured = LogTables.Build(_host.Defs(), _host.RomCopy(), item, frames, Scale());
        _changes = new();
        _grid.Text = Render(_measured, null);
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
        var diff = _mode.SelectedIndex == 1 ? null : LogTables.Difference(_measured, target, targetTable);
        _grid.Text = Render(_measured, diff) + "\n" + LogTables.Describe(_measured, _changes, _mode.SelectedIndex == 1 ? "°" : "");
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

    /// The measured table, and the difference column when there is one.
    string Render(LogTable t, double[]? diff)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append("          ");
        for (int c = 0; c < t.Item.Cols; c++) sb.Append($"{(c < t.ColAxis.Length ? t.ColAxis[c] : c),10:0.#}");
        sb.AppendLine();
        for (int r = 0; r < t.Item.Rows; r++)
        {
            sb.Append($"{(r < t.RowAxis.Length ? t.RowAxis[r] : r),8:0.#}  ");
            for (int c = 0; c < t.Item.Cols; c++)
            {
                int i = r * t.Item.Cols + c;
                if (t.Count[i] == 0) { sb.Append("         ."); continue; }
                sb.Append(diff == null || double.IsNaN(diff[i])
                    ? $"{t.Mean[i],7:0.##}({Math.Min(t.Count[i], 99),2})"
                    : $"{diff[i],8:+0.#;-0.#}% ");
            }
            sb.AppendLine();
        }
        sb.AppendLine(diff == null
            ? $"measured {t.Channel} per cell (samples in brackets)"
            : $"how far {t.Channel} is from target, as the fuel each cell is short (+) or over (-)");
        return sb.ToString();
    }
}
