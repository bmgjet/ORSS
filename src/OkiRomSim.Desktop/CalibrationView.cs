using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Calibration tab, a full editor for the ROM's settings and maps:
/// - maps drawn as tuners expect (RPM rows, load columns, coloured cells) with Line
/// and 3D views, multi-cell editing, copy/paste, interpolate/smooth, undo/redo;
/// - settings as number boxes, switches as checkboxes, all in a tree by category;
/// - live trace: the cells the simulated program is reading light up (aqua, lime trail) -
/// or, in Tuner mode, the cell the car is in according to the datalog;
/// - a logged channel (wideband AFR, knock...) averaged per cell over the map;
/// - Detect, definitions editing, Import/Export (JSON, TunerPro XDF), Save .bin, and the
/// ROM emulator (connect, upload, upload every change as it is made).
public sealed class CalibrationView : UserControl
{
    readonly SimHost _host;
    readonly Func<IEnumerable<(string Path, string Text)>> _sources;
    readonly Func<TopLevel?> _top;
    readonly TreeView _tree = new() { FontSize = 12 };
    readonly TextBox _filter = new() { Watermark = "filter", Margin = new Thickness(0, 0, 0, 4) };
    readonly ContentControl _detail = new();
    readonly TextBlock _status = new() { FontSize = 11, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(12, 0, 0, 0) };
    readonly CheckBox _live = new() { Content = "Live trace", IsChecked = true, FontSize = 11 };
    readonly CheckBox _follow = new() { Content = "Follow reads when stepping", IsChecked = true, FontSize = 11 };
    readonly CheckBox _autoUpload = new() { Content = "Upload on changes", FontSize = 11 };
    readonly Button _emuButton;
    readonly TextBlock _emuStatus = new() { FontSize = 11, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0), MaxWidth = 260, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly ComboBox _overlayPick = new() { Width = 110, FontSize = 11 };
    readonly HashSet<string> _openCategories = new() { "Fuel", "Ignition" };
    List<ItemDef> _items = new();
    bool _updating;
    ItemDef? _selected;

    // current table
    ItemDef? _item;
    TableModel? _model;
    readonly TableGrid _grid = new();
    readonly TableGraph _graph = new();
    readonly TableSurface _surface = new();
    readonly Canvas _overlay = new();
    readonly TabControl _views = new();
    readonly TextBox _adjust = new() { Width = 70, Text = "1", FontFamily = MainWindow.MonoFont };

    // definition form
    readonly TextBox _fName = new() { Width = 190 };
    readonly TextBox _fAddr = new() { Width = 110 };
    readonly ComboBox _fType = new() { Width = 90, ItemsSource = Enum.GetNames<CellType>() };
    readonly NumericUpDown _fRows = Num(0, 64), _fCols = Num(0, 64), _fStride = Num(0, 256);
    readonly ComboBox _fFormula = new() { Width = 160 };
    readonly TextBox _fCategory = new() { Width = 120 };
    readonly TextBox _fDesc = new() { Width = 380 };
    readonly TextBox _fRowAxis = new() { Width = 130, Watermark = "label/addr" };
    readonly ComboBox _fRowFormula = new() { Width = 150 };
    readonly TextBox _fColAxis = new() { Width = 130, Watermark = "label/addr" };
    readonly ComboBox _fColFormula = new() { Width = 150 };
    readonly TextBox _fScale = new() { Width = 110, Watermark = "none" };
    readonly CheckBox _fFlag = new() { Content = "on/off switch" };
    readonly TextBox _fOn = new() { Width = 60 };
    readonly Expander _defExpander = new() { HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 6, 0, 0) };

    public event Action<int>? GoToAddress;
    /// The Expand / Restore button: give the calibration editor the whole window.
    public event Action? ExpandRequested;
    /// Compare this ROM with another file.
    public event Action? CompareRequested;
    readonly Button _expand = new() { Content = "⤢ Expand", Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(7, 2) };
    double _trail = 1.0;
    /// Emulator serial port (from Settings).
    public string EmulatorPort { get; set; } = "";
    /// Datalog frames for the overlay (the engine's recorded frames, or a loaded log).
    public Func<IReadOnlyList<LogFrame>>? OverlayFrames { get; set; }
    bool _tuner;

    public void SetExpanded(bool expanded) => _expand.Content = expanded ? "⤡ Restore" : "⤢ Expand";

    public void SetOptions(bool liveTrace, bool follow, double trailSeconds)
    {
        _live.IsChecked = liveTrace; _follow.IsChecked = follow; _trail = Math.Max(0.1, trailSeconds);
    }

    /// Tuner mode: no simulator-only controls; the trace comes from the datalog.
    public void SetTunerMode(bool tuner)
    {
        _tuner = tuner;
        _expand.IsVisible = !tuner;
        _follow.IsVisible = !tuner;
        ToolTip.SetTip(_live, tuner ? "Mark the cell the car is in, from the datalog (rpm and load against the table's axes)."
                                    : "Colour the cells the simulated program is reading: aqua = just now, fading lime = recently.");
        if (_model != null) { _model.Heat = new(); _model.ExternalTrace = null; Redraw(); }
    }

    static NumericUpDown Num(double min, double max) => new() { Width = 100, Minimum = (decimal)min, Maximum = (decimal)max, Increment = 1, FormatString = "0" };

    public CalibrationView(SimHost host, Func<IEnumerable<(string Path, string Text)>> sources, Func<TopLevel?> top)
    {
        _host = host; _sources = sources; _top = top;
        _emuButton = Btn("Connect emulator", ToggleEmulator,
            "Connect to the Moates Ostrich 2.0 / Demon on the port set in Settings and upload the ROM (with every edit made here), so the car runs it. Press again to disconnect.");

        var bar = new WrapPanel { Margin = new Thickness(4) };
        _expand.Click += (_, _) => ExpandRequested?.Invoke();
        ToolTip.SetTip(_expand, "Give the calibration editor (and the other lower tabs) the whole window; press again to put the layout back.");
        bar.Children.Add(_expand);
        // the definition work lives in one drop-down so the bar stays readable in both modes
        bar.Children.Add(Toolbar.Menu("Tools", Toolbar.Detect,
            new Toolbar.Entry(Toolbar.Detect, "Detect",
                "Scan the assembly for calibration data: the maps set up for the 2D lookup (with their RPM and load axes, row stride and fuel multiplier row), " +
                "labelled DB/DW blocks, tables the code reads with LC/LCB, and on/off switches. New finds are added to the list.", Detect),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Add, "Add", "Add a new definition at the address in the Definition form (or the selected item's address).", AddNew),
            new Toolbar.Entry(Toolbar.Delete, "Delete", "Remove the selected definition from the list (the ROM bytes are not touched).", Delete),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Import, "Import…", "Load definitions from a JSON file exported earlier.", Import),
            new Toolbar.Entry(Toolbar.Export, "Export definitions (JSON)…", "Write every definition as OkiRomSim JSON.", Export),
            new Toolbar.Entry(Toolbar.Export, "Export TunerPro XDF…", "Write a TunerPro XDF to edit this ROM in TunerPro RT.", ExportXdf),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Bin, "Save .bin…", "Write the ROM image, with every value edited here, to a .bin file you choose.", SaveBin),
            new Toolbar.Entry(Toolbar.Compare, "Compare…", "Compare this ROM with another .bin or .asm: what changed in the code and in the tables.",
                () => CompareRequested?.Invoke())));
        bar.Children.Add(Toolbar.Menu("Emulator", Toolbar.Bin,
            new Toolbar.Entry(Toolbar.Bin, "Connect / disconnect",
                "Connect to the Moates Ostrich 2.0 / Demon on the port set in Settings and upload the ROM, so the car runs it. Again to disconnect.", ToggleEmulator),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Import, "Download", "Read what is in the emulator and make it the ROM here (one undo step).", EmulatorDownload),
            new Toolbar.Entry(Toolbar.Export, "Upload", "Send the whole ROM, with every edit made here, to the emulator.", EmulatorUpload),
            new Toolbar.Entry(Toolbar.Detect, "Validate", "Read the emulator back and check it byte for byte against the ROM here.", EmulatorValidate),
            Toolbar.Entry.Line,
            new Toolbar.Entry("✓", "Toggle upload on changes",
                "Send every change to the emulator the moment it is made (only the 256-byte blocks that changed).", ToggleAutoUpload)));
        bar.Children.Add(new Separator { Width = 8 });
        _back = Toolbar.Button("←", "Back", "Back to the table you came from (a header opens the axis it is read from).", GoBack);
        _back.IsVisible = false;
        bar.Children.Add(_back);
        bar.Children.Add(Toolbar.Button("↶", "Undo", "Undo the last value change (Ctrl+Z in a table).", UndoEdit));
        bar.Children.Add(Toolbar.Button("↷", "Redo", "Redo (Ctrl+Y in a table).", RedoEdit));
        _autoUpload.IsCheckedChanged += (_, _) => { _host.AutoUpload = _autoUpload.IsChecked == true; UpdateEmulator(); };
        ToolTip.SetTip(_autoUpload, "Send every change to the emulator the moment it is made (only the 256-byte blocks that changed), so the car runs it straight away.");
        bar.Children.Add(_autoUpload);
        bar.Children.Add(_emuStatus);
        ToolTip.SetTip(_follow, "When you Step / Over / Out and the instruction reads a defined table or setting, switch to it here and select the cell it read.");
        _live.Margin = _follow.Margin = new Thickness(8, 0, 0, 0);
        bar.Children.Add(_live);
        bar.Children.Add(_follow);
        var ovLabel = new TextBlock { Text = "Overlay", FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 4, 0) };
        bar.Children.Add(ovLabel);
        _overlayPick.ItemsSource = new[] { "none" };
        _overlayPick.SelectedIndex = 0;
        _overlayPick.SelectionChanged += (_, _) => UpdateOverlay();
        ToolTip.SetTip(_overlayPick, "Lay a datalogged channel over the map: its average in every cell the engine sat in (wideband AFR over the fuel map, knock over the ignition map...).");
        bar.Children.Add(_overlayPick);

        _tree.SelectionChanged += (_, _) => { if (!_updating && (_tree.SelectedItem as TreeViewItem)?.Tag is ItemDef it) { _selected = it; ShowSelected(); } };
        _tree.DoubleTapped += (_, _) => { if ((_tree.SelectedItem as TreeViewItem)?.Tag is ItemDef it) GoToAddress?.Invoke(it.Address); };
        ToolTip.SetTip(_tree, "Settings and maps by category. Select one to edit it; double-click to show it in the source.");
        _filter.TextChanged += (_, _) => Refresh();
        ToolTip.SetTip(_filter, "Show only items whose name, category or address contains this text.");

        var left = new DockPanel { Margin = new Thickness(4, 0, 0, 4) };
        DockPanel.SetDock(_filter, Dock.Top);
        left.Children.Add(_filter);
        left.Children.Add(new ScrollViewer { Content = _tree, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto });

        var split = new Grid { ColumnDefinitions = new ColumnDefinitions("240,4,*") };
        Grid.SetColumn(left, 0); split.Children.Add(left);
        var gs = new GridSplitter { Width = 4 }; Grid.SetColumn(gs, 1); split.Children.Add(gs);
        Grid.SetColumn(_detail, 2); split.Children.Add(_detail);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(split, 1); g.Children.Add(split);
        Content = g;

        // table views
        _grid.Message += m => _status.Text = m;
        _grid.SetCells += (cells, v, raw) => Write(cells, _ => v, raw, raw ? $"raw {v}" : $"= {v}");
        _grid.NudgeCells += (cells, d) => Write(cells, i => _model!.Raw[i] + d, true, d > 0 ? $"+{d} raw" : $"{d} raw");
        _grid.PasteCells += list =>
        {
            var dict = list.ToDictionary(x => x.Index, x => x.Value);
            Write(dict.Keys.ToList(), i => dict[i], false, "paste");
        };
        _grid.Undo += UndoEdit; _grid.Redo += RedoEdit;
        _grid.HeaderActivated += OpenAxis;
        _traceTimer.Tick += (_, _) => Tick();
        _traceTimer.Start();
        _graph.SetCell += (i, v) => Write(new[] { i }, _ => v, false, "drag");
        _graph.SelectCell += i => { if (_model != null) _grid.SelectCell(i / _model.Cols, i % _model.Cols); };
        _overlay.IsHitTestVisible = true;
        var gridHost = new Panel();
        gridHost.Children.Add(_grid);
        gridHost.Children.Add(_overlay);
        _grid.AttachEditorHost(_overlay);
        _grid.HorizontalAlignment = HorizontalAlignment.Left; _grid.VerticalAlignment = VerticalAlignment.Top;
        var gridScroll = new ScrollViewer { Content = gridHost, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
        var transpose = new CheckBox { Content = "one line per column", FontSize = 11 };
        transpose.IsCheckedChanged += (_, _) => _graph.Transpose = transpose.IsChecked == true;
        ToolTip.SetTip(transpose, "Off: x = columns (load), one line per row. On: x = rows (rpm), one line per column.");
        var graphPanel = new DockPanel();
        DockPanel.SetDock(transpose, Dock.Top);
        graphPanel.Children.Add(transpose);
        graphPanel.Children.Add(_graph);
        ToolTip.SetTip(_graph, "Drag a point up or down to change that cell; hover for its value. The aqua band and the thick line are where the engine is.");
        ToolTip.SetTip(_surface, "Drag to rotate, mouse wheel to zoom. The white dot is where the engine is.");
        _views.Items.Add(new TabItem { Header = "Table", Content = gridScroll });
        _views.Items.Add(new TabItem { Header = "Line", Content = graphPanel });
        _views.Items.Add(new TabItem { Header = "3D", Content = _surface });
        foreach (var t in _views.Items.OfType<TabItem>()) { t.FontSize = 12; t.MinHeight = 24; t.Padding = new Thickness(8, 1); }
        _views.SelectionChanged += (_, e) => { if (ReferenceEquals(e.Source, _views)) Redraw(); };
        // the tip goes on the three tab headers, not on the whole control: a 1 x 10 table leaves
        // most of the panel empty, and a tip on the panel followed the pointer around it
        foreach (var t in _views.Items.OfType<TabItem>())
            ToolTip.SetTip(t, (string?)t.Header switch
            {
                "Table" => "The cells, with their RPM and load axes.",
                "Line" => "Every row of the map as a line; drag a point to change it.",
                _ => "The whole map as a surface: drag to rotate, wheel to zoom.",
            });

        foreach (var (c, tip) in new (Control, string)[]
        {
            (_fName, "Name of the setting or table."),
            (_fAddr, "Address in hex (6A10, 6A10h) or a label from the source."),
            (_fType, "Element type: u8/s8 bytes, u16/s16 little-endian words, BE = big-endian words, Bit = one bit."),
            (_fRows, "Table rows (RPM); 0 for a single value."),
            (_fCols, "Table columns (load); 0 for a single value."),
            (_fStride, "Bytes from one row to the next; 0 = packed (columns × element size). Honda maps often store 24 bytes per row but use fewer columns."),
            (_fFormula, "How a stored number converts to a real value (rpm, degrees, kPa...)."),
            (_fCategory, "Group shown in the tree."),
            (_fDesc, "Free text description."),
            (_fRowAxis, "Row axis (RPM breakpoints): label or address of its bytes; empty = row numbers."),
            (_fRowFormula, "Formula for the row axis bytes."),
            (_fColAxis, "Column axis (load breakpoints): label or address; empty = column numbers."),
            (_fColFormula, "Formula for the column axis bytes."),
            (_fScale, "Address of a per-column multiplier row (Honda fuel maps: right after the last row); the value shown is formula(cell × multiplier)."),
            (_fFlag, "Show as a checkbox: checked when the byte is not 0."),
            (_fOn, "Raw value written when the switch is turned on (usually FF or 01)."),
        }) ToolTip.SetTip(c, tip);

        // an MCP agent (or undo from elsewhere) changed something: show it
        _host.CalibrationChanged += (what, item) => Dispatcher.UIThread.Post(() =>
        {
            try
            {
                _status.Text = what;
                if (item != null && _host.Defs().Find(item) is { } it) { _selected = it; Refresh(it.Name); }
                else if (_item != null) { Refresh(_item.Name); }
                else Refresh();
            }
            catch (Exception ex) { AppLog.Error("calibration", "refresh after a change failed", ex); }
        });
        UpdateEmulator();
    }

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(7, 2) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    public ItemDef? Selected => _selected;

    /// Another ROM was opened (or the project was cleared): drop everything from the last one.
    public void ResetForNewRom()
    {
        _selected = null; _item = null; _model = null;
        _grid.Model = null; _graph.Model = null; _surface.Model = null;
        _filter.Text = "";
        _overlayPick.SelectedIndex = 0;
        _openCategories.Clear(); _openCategories.Add("Fuel"); _openCategories.Add("Ignition");
        _status.Text = "";
        Refresh();
    }

    public void Refresh(string? select = null)
    {
        if (_updating) return;
        var defs = _host.Defs();
        select ??= _selected?.Name;
        _items = defs.Items.OrderBy(i => CategoryOrder(i.Category)).ThenBy(i => i.Category)
            .ThenBy(i => i.IsTable && i.Rows > 1 ? 0 : i.IsTable && i.Count > 1 ? 1 : 2).ThenBy(i => i.Address).ToList();
        var f = (_filter.Text ?? "").Trim();
        var shown = f.Length == 0 ? _items : _items.Where(i =>
            i.Name.Contains(f, StringComparison.OrdinalIgnoreCase) || i.Category.Contains(f, StringComparison.OrdinalIgnoreCase) ||
            i.Address.ToString("X4").Contains(f, StringComparison.OrdinalIgnoreCase)).ToList();
        var pick = select == null ? shown.FirstOrDefault() : shown.FirstOrDefault(i => i.Name == select) ?? shown.FirstOrDefault();
        _updating = true;
        try
        {
            // remember which categories are open
            foreach (var node in _tree.Items.OfType<TreeViewItem>())
                if (node.Header is string h) { if (node.IsExpanded) _openCategories.Add(h); else _openCategories.Remove(h); }
            var nodes = new List<TreeViewItem>();
            TreeViewItem? pickNode = null;
            if (shown.Count == 0)
                nodes.Add(new TreeViewItem { Header = _items.Count == 0 ? "(nothing defined - press Detect)" : "(nothing matches)" });
            foreach (var grp in shown.GroupBy(i => string.IsNullOrWhiteSpace(i.Category) ? "General" : i.Category))
            {
                var cat = new TreeViewItem { Header = grp.Key, FontWeight = FontWeight.SemiBold };
                var leaves = new List<TreeViewItem>();
                foreach (var i in grp)
                {
                    var leaf = new TreeViewItem
                    {
                        Header = $"{i.Name}{(i.IsTable && i.Count > 1 ? $"  {i.Rows}×{i.Cols}" : i.Flag ? "  ☐" : "")}", Tag = i,
                        FontWeight = FontWeight.Normal, Padding = new Thickness(2, 0), MinHeight = 0,
                    };
                    ToolTip.SetTip(leaf, $"{i.Address:X4}  {i.Type}  {i.Formula}{(i.Description.Length > 0 ? "\n" + i.Description : "")}");
                    if (i == pick) pickNode = leaf;
                    leaves.Add(leaf);
                }
                cat.ItemsSource = leaves;
                cat.IsExpanded = f.Length > 0 || _openCategories.Contains(grp.Key) || grp.Contains(pick!);
                nodes.Add(cat);
            }
            _tree.ItemsSource = nodes;
            _selected = pick;
            if (pickNode != null) _tree.SelectedItem = pickNode;
        }
        finally { _updating = false; }
        var formulas = defs.Formulas.Select(x => x.Name).OrderBy(n => n).ToList();
        _fFormula.ItemsSource = formulas;
        _fRowFormula.ItemsSource = formulas;
        _fColFormula.ItemsSource = formulas;
        ShowSelected();
    }

    static int CategoryOrder(string c) => c switch
    {
        "Fuel" => 0, "Ignition" => 1, "VE" => 2, "Maps" => 3, "VTEC" => 4, "Limits" => 5, "Idle" => 6, "Axes" => 8, "Switches" => 7, _ => 9,
    };

    // ------------------------------------------------------------------ live trace / follow / overlay

    /// The trace has its own, faster timer: the rest of the window refreshes every 150 ms, which is plenty for text but leaves the trail stepping visibly behind the engine.
    readonly DispatcherTimer _traceTimer = new() { Interval = TimeSpan.FromMilliseconds(45) };

    /// Called on the UI refresh tick: update the trace colouring of the table on screen.
    public void Tick()
    {
        if (_model == null || _item == null || !IsEffectivelyVisible) return;
        if (_tuner) return;       // the datalog drives the trace (SetEngineState)
        if (_live.IsChecked != true) { if (_model.Heat.Count > 0) { _model.Heat = new(); Redraw(); } return; }
        var heat = _host.TableHeat(_item, _trail);
        if (heat.Count == 0 && _model.Heat.Count == 0) return;
        if (Same(heat, _model.Heat)) return;        // nothing moved: do not redraw the map
        _model.Heat = heat;
        Redraw();
    }

    /// Cheap comparison of two heat maps - a plain loop rather than LINQ, because this runs twenty times a second while the simulator is going.
    static bool Same(Dictionary<int, double> a, Dictionary<int, double> b)
    {
        if (a.Count != b.Count) return false;
        foreach (var (k, v) in a)
            if (!b.TryGetValue(k, out var other) || Math.Abs(other - v) >= 0.02) return false;
        return true;
    }

    /// Follow the cam crossover: when the log says VTEC engaged (or dropped out) and the map on screen is the other side's copy, switch to the one the ECU is actually reading.
    public bool FollowVtec { get; set; } = true;
    bool? _lastVtec;

    /// Where the car is now (from a datalog frame): marks that cell of the table on screen.
    public void SetEngineState(LogFrame? f)
    {
        if (FollowVtec && f?.Vtec is bool vt && vt != _lastVtec)
        {
            _lastVtec = vt;
            if (_item != null && MapSide.Side(_item) is bool side && side != vt &&
                MapSide.Other(_host.Defs(), _item) is { } other)
            {
                _status.Text = $"VTEC {(vt ? "engaged" : "dropped out")}: following to {other.Name}";
                AppLog.Action("calibration", $"followed the cam crossover to {other.Name}");
                Refresh(other.Name);
                return;
            }
        }
        if (_model == null || _item == null || !_item.IsTable) return;
        (double, double)? pos = null;
        if (f != null && _live.IsChecked == true)
        {
            var defs = _host.Defs();
            var (_, rget) = LogOverlay.AxisInput(defs, _item.RowAxis, true);
            var (_, cget) = LogOverlay.AxisInput(defs, _item.ColAxis, false);
            if (rget(f) is double rv && (_model.Cols == 1 || cget(f) is double))
                pos = (_item.RowAxis == null ? 0 : LogOverlay.Position(_model.RowAxis, rv),
                       _model.Cols == 1 || _item.ColAxis == null ? 0 : LogOverlay.Position(_model.ColAxis, cget(f)!.Value));
        }
        if (pos == _model.ExternalTrace) return;
        _model.ExternalTrace = pos;
        Redraw();
    }

    /// What the engine should be running and what the wideband really means (Settings > Targets).
    public TargetMap? TargetLow { get; set; }
    public TargetMap? TargetHigh { get; set; }
    public LookupCurve? WidebandCorrection { get; set; }

    /// Channels available for the overlay (updated as frames come in).
    public void SetOverlayChannels(IEnumerable<string> channels, string preferred)
    {
        var list = new[] { "none" }.Concat(channels.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(c => c)).ToList();
        var cur = _overlayPick.SelectedItem as string ?? "none";
        if (_overlayPick.ItemsSource is IEnumerable<string> old && old.SequenceEqual(list)) return;
        _overlayPick.ItemsSource = list;
        _overlayPick.SelectedItem = list.Contains(cur) && cur != "none" ? cur : list.Contains(preferred) && cur == "none" ? "none" : cur;
    }

    DateTime _lastOverlay;
    /// Recompute the overlay from the frames (called now and then while logging).
    public void UpdateOverlay(bool throttle = false)
    {
        if (_model == null || _item == null || !_item.IsTable) return;
        if (throttle && (DateTime.UtcNow - _lastOverlay).TotalMilliseconds < 1000) return;
        _lastOverlay = DateTime.UtcNow;
        var ch = _overlayPick.SelectedItem as string;
        if (ch == null || ch == "none" || OverlayFrames == null) { if (_model.Overlay != null) { _model.Overlay = null; Redraw(); } return; }
        try
        {
            var frames = OverlayFrames();
            var ov = LogOverlay.Compute(_host.Defs(), _host.RomBytes(0, Bus.RomSize), _item, frames, ch);
            _model.Overlay = ov.Mean; _model.OverlayCount = ov.Count; _model.OverlayName = ch;
            Redraw();
        }
        catch (Exception ex) { AppLog.Error("calibration", "overlay failed", ex); }
    }

    void Redraw()
    {
        // only the view on screen: drawing all three every tick made the trail lag
        switch (_views.SelectedIndex)
        {
            case 1: _graph.InvalidateVisual(); break;
            case 2: _surface.InvalidateVisual(); break;
            default: _grid.InvalidateVisual(); break;
        }
    }

    /// After a step: if the instruction read a defined table/setting, show it. Returns true when the page switched to something (the caller brings the tab forward).
    public bool FollowReads(IReadOnlyList<int> reads)
    {
        if (_tuner || _follow.IsChecked != true || reads.Count == 0) return false;
        foreach (var a in reads.Reverse())
            if (ShowAddress(a, quiet: true)) { _status.Text = $"step read {a:X4}: {_item?.Name}"; return true; }
        return false;
    }

    /// Select the table or setting that covers `addr` and the cell it is. False if none does.
    public bool ShowAddress(int addr, bool quiet = false)
    {
        var defs = _host.Defs();
        var item = defs.Items.Where(i => i.Contains(addr)).OrderByDescending(i => i.IsTable).ThenBy(i => i.Span).FirstOrDefault();
        if (item == null) return false;
        if (_filter.Text?.Length > 0) _filter.Text = "";
        if (_selected != item) { _selected = item; Refresh(item.Name); }
        if (item.CellOf(addr) is { } cell && _model != null)
        {
            _grid.SelectCell(cell.Row, cell.Col);
            _model.Heat = _host.TableHeat(item);
            Redraw();
        }
        if (!quiet) _status.Text = $"{addr:X4} is in {item.Name}" + (item.CellOf(addr) is { } c ? $" [{c.Row},{c.Col}]" : "");
        return true;
    }

    // ------------------------------------------------------------------ writing values

    void Write(IReadOnlyList<int> cells, Func<int, double> value, bool raw, string what)
    {
        if (_item == null || cells.Count == 0) return;
        var item = _item;
        try
        {
            var list = cells.Select(i => (i, value(i))).ToList();
            if (item.ColumnScaleAddress != null)
            {
                // a fuel map: let a cell that runs off the top of its range push the column's
                // multiplier up instead of flat-topping (the rest of the column is restated so
                // those values do not move)
                var report = Rescale.WriteWithRollover(_host.Defs(), _host.RomCopy(), item, list, raw);
                if (report.Any)
                {
                    _host.ApplyPatches(report.Patches, $"{item.Name} {what}");
                    if (report.ColumnsRescaled > 0) _status.Text = report.Summary;
                    AppLog.Action("calibration", report.Summary);
                }
            }
            else
            {
                _host.WriteCells(item, list, raw, what);
                AppLog.Action("calibration", $"{item.Name}: {cells.Count} cell(s) {what}");
            }
        }
        catch (Exception ex) { _status.Text = ex.Message; AppLog.Error("calibration", "write failed", ex); }
        ReloadValues();
        _status.Text = cells.Count == 1
            ? $"{item.Name}[{cells[0] / Math.Max(1, item.Cols)},{cells[0] % Math.Max(1, item.Cols)}] = {_model?.Format(_model.Values[cells[0]])} - patched in the running ROM{(_host.AutoUpload && _host.Emulator.Connected ? " and the emulator" : "")}"
            : $"{item.Name}: {cells.Count} cells {what} - patched in the running ROM{(_host.AutoUpload && _host.Emulator.Connected ? " and the emulator" : "")}";
    }

    void UndoEdit()
    {
        var what = _host.Undo();
        _status.Text = what == null ? "nothing to undo" : "undid " + what;
        ReloadValues();
    }

    void RedoEdit()
    {
        var what = _host.Redo();
        _status.Text = what == null ? "nothing to redo" : "redid " + what;
        ReloadValues();
    }

    void ReloadValues()
    {
        if (_item == null || _model == null) { ShowSelected(); return; }
        var cells = _host.ReadItem(_item);
        _model.Values = cells.Select(c => c.Value).ToArray();
        _model.Raw = cells.Select(c => c.Raw).ToArray();
        Redraw();
    }

    // ------------------------------------------------------------------ emulator

    void ToggleEmulator()
    {
        if (_busyEmulator) return;
        if (_host.Emulator.Connected)
        {
            _busyEmulator = true;
            _emuButton.IsEnabled = false;
            Task.Run(() =>
            {
                try { _host.EmulatorDisconnect(); } catch (Exception ex) { AppLog.Error("emulator", "disconnect failed", ex); }
                Dispatcher.UIThread.Post(() => { _busyEmulator = false; _emuButton.IsEnabled = true; UpdateEmulator(); _status.Text = "emulator disconnected"; });
            });
            AppLog.Action("emulator", "disconnect");
            return;
        }
        var port = EmulatorPort.Length > 0 ? EmulatorPort : MoatesTrace.Ports().LastOrDefault() ?? "";
        if (port.Length == 0) { _status.Text = "no serial port for the emulator: set it in Settings > Hit trace & emulator"; return; }
        _busyEmulator = true;
        _emuButton.IsEnabled = false;
        _status.Text = $"connecting to the emulator on {port} and uploading the ROM…";
        // identifying the device and writing 32 KB takes a moment: not on the UI thread
        Task.Run(() =>
        {
            string message;
            try
            {
                _host.EmulatorConnect(port);
                message = _host.EmulatorUploadAll();
                AppLog.Action("emulator", "connected and uploaded the ROM on " + port);
            }
            catch (Exception ex)
            {
                message = "emulator: " + ex.Message;
                AppLog.Error("emulator", "connect/upload failed", ex);
                try { _host.EmulatorDisconnect(); } catch { }
            }
            Dispatcher.UIThread.Post(() => { _busyEmulator = false; _emuButton.IsEnabled = true; _status.Text = message; UpdateEmulator(); });
        });
    }
    bool _busyEmulator;

    /// Anything that talks to the emulator: off the UI thread, one at a time, with the result on the status line either way.
    void EmulatorTask(string what, Func<string> run)
    {
        if (_busyEmulator) { _status.Text = "the emulator is busy"; return; }
        if (!_host.Emulator.Connected) { _status.Text = "connect the emulator first"; return; }
        _busyEmulator = true;
        _status.Text = what + "…";
        AppLog.Action("emulator", what);
        Task.Run(() =>
        {
            string message;
            try { message = run(); }
            catch (Exception ex) { message = "emulator: " + ex.Message; AppLog.Error("emulator", what + " failed", ex); }
            Dispatcher.UIThread.Post(() =>
            {
                _busyEmulator = false;
                _status.Text = message;
                UpdateEmulator();
                Refresh(_selected?.Name);
            });
        });
    }

    void EmulatorUpload() => EmulatorTask("uploading the ROM to the emulator", _host.EmulatorUploadAll);
    void EmulatorValidate() => EmulatorTask("checking the emulator against this ROM", _host.EmulatorValidate);
    void EmulatorDownload() => EmulatorTask("reading the ROM out of the emulator", _host.EmulatorDownload);

    void ToggleAutoUpload()
    {
        _autoUpload.IsChecked = _autoUpload.IsChecked != true;
        _status.Text = _autoUpload.IsChecked == true
            ? "changes will go to the emulator as they are made"
            : "changes stay here until you upload them";
    }

    public void UpdateEmulator()
    {
        bool on = _host.Emulator.Connected;
        _emuButton.Content = on ? "Disconnect emulator" : "Connect emulator";
        _emuStatus.Text = on ? _host.EmulatorStatus : "emulator not connected";
        ToolTip.SetTip(_emuStatus, _host.EmulatorStatus);
        if (_autoUpload.IsChecked != _host.AutoUpload) _autoUpload.IsChecked = _host.AutoUpload;
    }

    // ------------------------------------------------------------------ selection-wide adjustments

    void Adjust(string op)
    {
        if (_model == null) return;
        if (!double.TryParse(_adjust.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var k) && op is "set" or "add" or "pct")
        { _status.Text = "type a number in the box first"; return; }
        var sel = _grid.Selection();
        var (r0, c0, r1, c1) = _grid.SelectionRect();
        var m = _model;
        switch (op)
        {
            case "set": Write(sel, _ => k, false, $"set to {k}"); break;
            case "add": Write(sel, i => m.Values[i] + k, false, $"{(k >= 0 ? "+" : "")}{k}"); break;
            case "pct": Write(sel, i => m.Values[i] * (1 + k / 100), false, $"{(k >= 0 ? "+" : "")}{k}%"); break;
            case "ih":
                if (c1 - c0 < 2) { _status.Text = "select at least three columns to interpolate across"; return; }
                Write(sel, i =>
                {
                    int r = i / m.Cols, c = i % m.Cols;
                    double a = m[r, c0], b = m[r, c1];
                    return a + (b - a) * (c - c0) / (c1 - c0);
                }, false, "interpolated across");
                break;
            case "iv":
                if (r1 - r0 < 2) { _status.Text = "select at least three rows to interpolate down"; return; }
                Write(sel, i =>
                {
                    int r = i / m.Cols, c = i % m.Cols;
                    double a = m[r0, c], b = m[r1, c];
                    return a + (b - a) * (r - r0) / (r1 - r0);
                }, false, "interpolated down");
                break;
            case "smooth":
                {
                    var copy = m.Values.ToArray();
                    Write(sel, i =>
                    {
                        int r = i / m.Cols, c = i % m.Cols;
                        double sum = 0; int n = 0;
                        for (int dr = -1; dr <= 1; dr++)
                            for (int dc = -1; dc <= 1; dc++)
                            {
                                int rr = r + dr, cc = c + dc;
                                if (rr < r0 || rr > r1 || cc < c0 || cc > c1) continue;
                                sum += copy[rr * m.Cols + cc]; n++;
                            }
                        return sum / n;
                    }, false, "smoothed");
                    break;
                }
            case "overlay":
                {
                    // AFR overlay: scale each selected fuel cell by measured / target
                    if (m.Overlay == null) { _status.Text = "pick an AFR or lambda overlay first"; return; }
                    double target = k > 0 ? k : 14.7;
                    var cnt = m.OverlayCount;
                    var pick = sel.Where(i => !double.IsNaN(m.Overlay[i]) && (cnt == null || cnt[i] >= 3)).ToList();
                    if (pick.Count == 0) { _status.Text = "no selected cell has 3+ logged samples"; return; }
                    Write(pick, i => m.Values[i] * m.Overlay[i] / target, false, $"corrected to {target} from the log");
                    break;
                }
        }
    }

    // ------------------------------------------------------------------ detail view

    void ShowSelected()
    {
        _item = _selected;
        _model = null;
        var root = new DockPanel { Margin = new Thickness(8, 0, 4, 4) };
        var item = _item;
        if (item == null)
        {
            root.Children.Add(new TextBlock
            {
                TextWrapping = TextWrapping.Wrap, Opacity = 0.8, Margin = new Thickness(0, 8),
                Text = "No settings or maps are defined yet. Detect finds the fuel and ignition maps (with their RPM and load axes) from the " +
                       "code that looks them up, labelled DB/DW data, tables read with LC/LCB and on/off switches. " +
                       "Or fill in the Definition form below and press Add.",
            });
            var defx = DefinitionForm(null);
            DockPanel.SetDock(defx, Dock.Bottom);
            root.Children.Insert(0, defx);
            _detail.Content = root;
            return;
        }
        var defs = _host.Defs();
        FormulaDef formula;
        try { formula = defs.Formula(item.Formula); } catch { formula = Builtin.Raw; }

        var head = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };
        head.Children.Add(new TextBlock
        {
            Text = $"{item.Name}   @ {item.Address:X4}   {(item.IsTable ? $"{item.Rows}×{item.Cols}  " : "")}{item.Type.ToString().ToLowerInvariant()}   [{formula.Name}{(formula.Unit.Length > 0 ? ", " + formula.Unit : "")}]",
            FontWeight = FontWeight.Bold, FontSize = 13,
        });
        if (item.Description.Length > 0 || item.Origin != null)
            head.Children.Add(new TextBlock { Text = item.Description + (item.Origin != null ? $"   ({item.Origin})" : ""), FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap });
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        var def = DefinitionForm(item);
        DockPanel.SetDock(def, Dock.Bottom);
        root.Children.Add(def);

        try
        {
            if (item.IsTable && item.Count > 1) root.Children.Add(TableEditor(item, formula));
            else root.Children.Add(SettingsForm(item));
        }
        catch (Exception ex) { root.Children.Add(new TextBlock { Text = "cannot read values: " + ex.Message }); }
        _detail.Content = root;
        UpdateOverlay();
    }

    Control TableEditor(ItemDef item, FormulaDef formula)
    {
        var defs = _host.Defs();
        var cells = _host.ReadItem(item);
        string AxisUnit(AxisDef? a, string fallback)
        {
            if (a == null) return fallback;
            if (a.Unit.Length > 0) return a.Unit;
            try { return defs.Formula(a.Formula).Unit is { Length: > 0 } u ? u : fallback; } catch { return fallback; }
        }
        _model = new TableModel
        {
            Item = item, Rows = item.Rows, Cols = item.Cols,
            Values = cells.Select(c => c.Value).ToArray(), Raw = cells.Select(c => c.Raw).ToArray(),
            RowAxis = item.RowAxis == null ? Enumerable.Range(0, item.Rows).Select(i => (double)i).ToArray() : _host.AxisValues(item.RowAxis, item.Rows),
            ColAxis = item.ColAxis == null ? Enumerable.Range(0, item.Cols).Select(i => (double)i).ToArray() : _host.AxisValues(item.ColAxis, item.Cols),
            RowUnit = AxisUnit(item.RowAxis, "row"), ColUnit = AxisUnit(item.ColAxis, "col"),
            Unit = formula.Unit, Decimals = Math.Min(formula.Decimals, 2),
            Heat = _live.IsChecked == true && !_tuner ? _host.TableHeat(item) : new(),
        };
        _grid.Model = _model; _graph.Model = _model; _surface.Model = _model;

        var tools = new WrapPanel { Margin = new Thickness(0, 2, 0, 4) };
        tools.Children.Add(new TextBlock { Text = "Selection:", VerticalAlignment = VerticalAlignment.Center, FontSize = 11, Margin = new Thickness(0, 0, 4, 0) });
        ToolTip.SetTip(_adjust, "Amount used by Set / Add / % (and the target AFR for 'AFR fix').");
        tools.Children.Add(UiStyles.Adopt(_adjust));
        tools.Children.Add(Btn("Set", () => Adjust("set"), "Set every selected cell to the amount."));
        tools.Children.Add(Btn("Add", () => Adjust("add"), "Add the amount to every selected cell (negative subtracts)."));
        tools.Children.Add(Btn("%", () => Adjust("pct"), "Change every selected cell by the amount in percent."));
        tools.Children.Add(Btn("Interp ↔", () => Adjust("ih"), "Straight line across each row between the first and last selected columns."));
        tools.Children.Add(Btn("Interp ↕", () => Adjust("iv"), "Straight line down each column between the first and last selected rows."));
        tools.Children.Add(Btn("Smooth", () => Adjust("smooth"), "Average each selected cell with its selected neighbours."));
        tools.Children.Add(Btn("Scale…", () => ScaleTools(item),
            "Scale whole sections at once: this table by a percentage, the fuel tables for different injectors, the load axis for a different MAP sensor, " +
            "or rescale a table that has run to the top of its scale so it has room to grow again."));
        tools.Children.Add(Btn("O2 / knock…", () => LogTableTools(item),
            "The O2 / lambda and knock tables from the datalog: what each cell measured, how far it is from target, and a button to apply the offsets."));
        tools.Children.Add(Btn("AFR fix", () => Adjust("overlay"),
            "With an AFR overlay: scale each selected cell by measured AFR / the amount in the box (the target AFR), for cells with 3+ logged samples."));
        tools.Children.Add(new TextBlock
        {
            Text = "  type a value + Enter · +/- or [ ] nudge one step · PgUp/PgDn ten · Ctrl+C/V · Ctrl+Z/Y",
            FontSize = 10.5, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center,
        });
        var panel = new DockPanel();
        DockPanel.SetDock(tools, Dock.Top);
        panel.Children.Add(tools);
        panel.Children.Add(UiStyles.Adopt(_views));
        if (_views.SelectedIndex < 0) _views.SelectedIndex = 0;
        return panel;
    }

    /// Settings (not tables): every single-value item in the same category as a form, switches as checkboxes and numbers as number boxes, with the selected one first.
    Control SettingsForm(ItemDef selected)
    {
        var all = _items.Where(i => i.Category == selected.Category && !(i.IsTable && i.Count > 1)).ToList();
        var groups = all.GroupBy(GroupKey).OrderBy(g => g.Any(i => i == selected) ? 0 : 1).ThenBy(g => g.Min(i => i.Address)).ToList();
        var own = groups.First(g => g.Any(i => i == selected));

        var page = new StackPanel();
        page.Children.Add(Group(own, selected, expanded: true));
        foreach (var g in groups.Skip(1).Take(60))
            page.Children.Add(Group(g, null, expanded: false));
        return new ScrollViewer { Content = page };
    }

    /// What belongs on one page: switches that live in the same ROM byte are one group (they are the bits of a single option byte), everything else groups by the block of addresses it sits in, so a page shows the options around the one selected instead of the whole category.
    static string GroupKey(ItemDef i) =>
        i.Type == CellType.Bit || i.Flag ? $"@{i.Address:X4}" : $"#{i.Address / 16:X3}";

    /// A titled block of settings; the group the selection is in is open, the rest are folded away but still reachable.
    Control Group(IGrouping<string, ItemDef> g, ItemDef? selected, bool expanded)
    {
        var members = g.OrderBy(i => i == selected ? 0 : 1).ThenBy(i => i.Address).ThenBy(i => i.Bit).ToList();
        string title = GroupTitle(members);
        var body = SettingsGrid(members, selected);
        if (expanded)
        {
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 12, Margin = new Thickness(0, 2, 0, 2) });
            sp.Children.Add(body);
            return sp;
        }
        return new Expander { Header = title, Content = body, IsExpanded = false, Margin = new Thickness(0, 2) };
    }

    /// The longest name all the members start with ("vtec_" -> "vtec"), or the address they share.
    static string GroupTitle(IReadOnlyList<ItemDef> members)
    {
        string prefix = members[0].Name;
        foreach (var m in members)
        {
            int n = 0;
            while (n < prefix.Length && n < m.Name.Length && char.ToLowerInvariant(prefix[n]) == char.ToLowerInvariant(m.Name[n])) n++;
            prefix = prefix[..n];
        }
        prefix = prefix.TrimEnd('_', ' ', '-', '.');
        string where = members.Count == 1 || members.All(m => m.Address == members[0].Address)
            ? $"0x{members[0].Address:X4}"
            : $"0x{members.Min(m => m.Address):X4}-0x{members.Max(m => m.Address):X4}";
        string what = prefix.Length >= 3 ? prefix : where;
        return members.Count == 1 ? $"{what}   ({where})" : $"{what}   ({where}, {members.Count} settings)";
    }

    Control SettingsGrid(IReadOnlyList<ItemDef> group, ItemDef? selected)
    {
        var defs = _host.Defs();
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,Auto,*"), Margin = new Thickness(0, 4) };
        int row = 0;
        foreach (var it in group)
        {
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            FormulaDef f;
            try { f = defs.Formula(it.Formula); } catch { f = Builtin.Raw; }
            CellValue c;
            try { c = _host.ReadItem(it)[0]; } catch { continue; }
            var name = new TextBlock
            {
                Text = it.Name, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 2, 12, 2),
                FontWeight = it == selected ? FontWeight.Bold : FontWeight.Normal, FontSize = 12,
            };
            ToolTip.SetTip(name, (it.Description.Length > 0 ? it.Description + "\n" : "") + $"{it.Address:X4}  {it.Type}  [{f.Name}]" + (f.Notes != null ? "\n" + f.Notes : ""));
            Control editor;
            var info = new TextBlock { FontSize = 11, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0), FontFamily = MainWindow.MonoFont };
            void Info(CellValue v) => info.Text = $"raw {(long)v.Raw} (0x{(long)v.Raw:X2}) @ {it.Address:X4}";
            Info(c);
            var item = it;
            if (it.Flag || it.Type == CellType.Bit)
            {
                var cb = new CheckBox { IsChecked = it.Type == CellType.Bit ? c.Raw != 0 : c.Raw != it.OffRaw, VerticalAlignment = VerticalAlignment.Center };
                ToolTip.SetTip(cb, $"On writes {(it.Type == CellType.Bit ? "1 to bit " + it.Bit : $"0x{(long)it.OnRaw:X2}")}, off writes {(it.Type == CellType.Bit ? "0" : $"0x{(long)it.OffRaw:X2}")}. Changes the running ROM at once.");
                cb.IsCheckedChanged += (_, _) =>
                {
                    double raw = it.Type == CellType.Bit ? (cb.IsChecked == true ? 1 : 0) : cb.IsChecked == true ? it.OnRaw : it.OffRaw;
                    WriteSetting(item, raw, true, Info);
                };
                editor = cb;
            }
            else
            {
                var (lo, hi) = RomData.RawRange(it.Type);
                double vlo = Math.Min(f.ToValue(lo), f.ToValue(hi)), vhi = Math.Max(f.ToValue(lo), f.ToValue(hi));
                double step = Math.Abs(f.ToValue(lo + 1) - f.ToValue(lo));
                if (step <= 0 || double.IsNaN(step) || double.IsInfinity(step)) step = 1;
                var nud = new NumericUpDown
                {
                    Width = 150, Minimum = (decimal)Math.Max(-1e9, vlo), Maximum = (decimal)Math.Min(1e9, vhi),
                    Increment = (decimal)Math.Round(step, 6), Value = (decimal)Math.Round(c.Value, 6),
                    FormatString = "0." + new string('#', Math.Clamp(f.Decimals, 0, 6)), FontFamily = MainWindow.MonoFont,
                };
                ToolTip.SetTip(nud, $"{it.Name} in {(f.Unit.Length > 0 ? f.Unit : "raw units")}. Arrows step one raw count; typing a value rounds to the nearest the ROM can store. Changes the running ROM at once.");
                bool busy = false;
                nud.ValueChanged += (_, e) =>
                {
                    if (busy || e.NewValue is not decimal d) return;
                    busy = true;
                    var w = WriteSetting(item, (double)d, false, Info);
                    if (w != null) nud.Value = (decimal)Math.Round(w.Value, 6);
                    busy = false;
                };
                editor = nud;
            }
            var unit = new TextBlock { Text = f.Unit, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0), FontSize = 11 };
            Grid.SetRow(name, row); Grid.SetColumn(name, 0); grid.Children.Add(name);
            Grid.SetRow(editor, row); Grid.SetColumn(editor, 1); grid.Children.Add(editor);
            Grid.SetRow(unit, row); Grid.SetColumn(unit, 2); grid.Children.Add(unit);
            Grid.SetRow(info, row); Grid.SetColumn(info, 3); grid.Children.Add(info);
            row++;
        }
        return grid;
    }

    CellValue? WriteSetting(ItemDef item, double v, bool raw, Action<CellValue> show)
    {
        try
        {
            _host.WriteCells(item, new[] { (0, v) }, raw, raw ? $"raw {v}" : $"= {v}");
            var w = _host.ReadItem(item)[0];
            show(w);
            _status.Text = $"{item.Name} = {w.Display} (raw {(long)w.Raw:X2}) - patched in the running ROM";
            AppLog.Action("calibration", $"{item.Name} = {w.Display}");
            return w;
        }
        catch (Exception ex) { _status.Text = ex.Message; return null; }
    }

    // ------------------------------------------------------------------ definition form

    Control DefinitionForm(ItemDef? item)
    {
        _fName.Text = item?.Name ?? "";
        _fAddr.Text = item == null ? _fAddr.Text : item.Address.ToString("X4");
        _fType.SelectedItem = (item?.Type ?? CellType.U8).ToString();
        _fRows.Value = item?.Rows ?? 0;
        _fCols.Value = item?.Cols ?? 0;
        _fStride.Value = item?.Stride ?? 0;
        _fFormula.SelectedItem = item?.Formula ?? "raw";
        _fCategory.Text = item?.Category ?? "User";
        _fDesc.Text = item?.Description ?? "";
        _fRowAxis.Text = item?.RowAxis?.Address is int ra ? (item.RowAxis.Name ?? ra.ToString("X4")) : "";
        _fRowFormula.SelectedItem = item?.RowAxis?.Formula ?? "raw";
        _fColAxis.Text = item?.ColAxis?.Address is int ca ? (item.ColAxis.Name ?? ca.ToString("X4")) : "";
        _fColFormula.SelectedItem = item?.ColAxis?.Formula ?? "raw";
        _fScale.Text = item?.ColumnScaleAddress is int sc ? sc.ToString("X4") : "";
        _fFlag.IsChecked = item?.Flag ?? false;
        _fOn.Text = ((long)(item?.OnRaw ?? 0xFF)).ToString("X2");

        var wrap = new WrapPanel();
        void Field(string label, Control c)
        {
            UiStyles.Adopt(c);
            var sp = new StackPanel { Margin = new Thickness(0, 0, 10, 4) };
            sp.Children.Add(new TextBlock { Text = label, FontSize = 10, Opacity = 0.7 });
            sp.Children.Add(c);
            wrap.Children.Add(sp);
        }
        Field("name", _fName); Field("address / label", _fAddr); Field("type", _fType); Field("formula", _fFormula);
        Field("rows", _fRows); Field("columns", _fCols); Field("row stride (bytes)", _fStride);
        Field("row axis", _fRowAxis); Field("row axis formula", _fRowFormula);
        Field("column axis", _fColAxis); Field("column axis formula", _fColFormula);
        Field("column multiplier row", _fScale);
        Field("switch", _fFlag); Field("on value (hex)", _fOn);
        Field("category", _fCategory); Field("description", _fDesc);
        if (item != null)
        {
            var apply = Btn("Apply", () => Apply(item), "Save the edited definition (name, address, type, size, axes, formula...).");
            apply.VerticalAlignment = VerticalAlignment.Bottom;
            wrap.Children.Add(apply);
        }
        // the page's messages live on the Definition bar, out of the toolbar's way
        UiStyles.Adopt(_status);
        var header = new DockPanel { LastChildFill = true };
        var title = new TextBlock { Text = "Definition", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(title, Dock.Left);
        header.Children.Add(title);
        header.Children.Add(_status);
        bool wasOpen = _defExpander.Content != null && _defExpander.IsExpanded;
        _defExpander.Header = header;
        _defExpander.Content = wrap;
        _defExpander.IsExpanded = wasOpen;      // collapsed until it is wanted
        return UiStyles.Adopt(_defExpander);
    }

    void Apply(ItemDef item)
    {
        if (!TryAddress(_fAddr.Text ?? "", out var addr)) { _status.Text = $"cannot resolve address '{_fAddr.Text}'"; return; }
        _host.EditDefinitions(_ =>
        {
            item.Name = string.IsNullOrWhiteSpace(_fName.Text) ? item.Name : _fName.Text!.Trim();
            item.Address = addr;
            if (_fType.SelectedItem is string t && Enum.TryParse<CellType>(t, out var ct)) item.Type = ct;
            item.Rows = (int)(_fRows.Value ?? 0);
            item.Cols = (int)(_fCols.Value ?? 0);
            if (item.Rows > 0 != item.Cols > 0) { item.Rows = Math.Max(item.Rows, 1); item.Cols = Math.Max(item.Cols, 1); }
            item.Stride = (int)(_fStride.Value ?? 0);
            item.Formula = _fFormula.SelectedItem as string ?? item.Formula;
            item.Category = string.IsNullOrWhiteSpace(_fCategory.Text) ? "General" : _fCategory.Text!.Trim();
            item.Description = _fDesc.Text ?? "";
            item.RowAxis = AxisFrom(_fRowAxis.Text, _fRowFormula.SelectedItem as string, item.Rows, item.RowAxis);
            item.ColAxis = AxisFrom(_fColAxis.Text, _fColFormula.SelectedItem as string, item.Cols, item.ColAxis);
            item.ColumnScaleAddress = TryAddress(_fScale.Text ?? "", out var sa) && (_fScale.Text ?? "").Trim().Length > 0 ? sa : null;
            item.Flag = _fFlag.IsChecked == true;
            if (int.TryParse((_fOn.Text ?? "").TrimEnd('h', 'H'), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var on)) item.OnRaw = on;
            return 0;
        });
        _selected = item;
        Refresh(item.Name);
        _status.Text = $"updated {item.Name}";
        AppLog.Action("calibration", $"definition {item.Name} updated");
    }

    AxisDef? AxisFrom(string? text, string? formula, int count, AxisDef? old)
    {
        text = (text ?? "").Trim();
        if (text.Length == 0 || !TryAddress(text, out var a)) return null;
        var unit = "";
        try { unit = _host.Defs().Formula(formula).Unit; } catch { }
        return new AxisDef { Name = Regex.IsMatch(text, @"^[0-9A-Fa-f]+h?$") ? old?.Name : text, Address = a, Count = count, Formula = formula ?? "raw", Unit = unit };
    }

    bool TryAddress(string text, out int addr)
    {
        text = text.Trim();
        if (text.Length == 0) { addr = 0; return false; }
        if (_host.Defs().TryResolve(text, out addr)) return true;
        var hex = text.EndsWith("h", StringComparison.OrdinalIgnoreCase) ? text[..^1] : text.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? text[2..] : text;
        return int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out addr);
    }

    void AddNew()
    {
        var defs = _host.Defs();
        if (!TryAddress(_fAddr.Text ?? "", out var addr)) addr = _selected?.Address ?? 0;
        string name = string.IsNullOrWhiteSpace(_fName.Text) || defs.Items.Any(i => i.Name == _fName.Text) ? $"item_{addr:X4}" : _fName.Text!.Trim();
        var item = new ItemDef { Name = name, Address = addr, Type = CellType.U8, Formula = "raw", Category = "User", Origin = "user" };
        _host.EditDefinitions(d => { d.Items.Add(item); return 0; });
        _selected = item;
        Refresh(item.Name);
        _status.Text = $"added {item.Name} at {addr:X4}; open Definition to set its type, size, axes and formula, then Apply";
        AppLog.Action("calibration", $"added definition {item.Name} at {addr:X4}");
    }

    void Delete()
    {
        if (_selected is not { } item) return;
        _host.EditDefinitions(d => d.Items.Remove(item));
        _selected = null;
        Refresh();
        _status.Text = $"removed {item.Name}";
        AppLog.Action("calibration", $"removed definition {item.Name}");
    }

    /// Double-clicking a header opens the axis it is read from, with that breakpoint selected, so it can be edited where it lives. The axis is added to the list if it was only known as part of the map. Going back to the map shows the new breakpoint.
    void OpenAxis(bool rowHeader, int index)
    {
        if (_item == null) return;
        var axis = rowHeader ? _item.RowAxis : _item.ColAxis;
        if (axis?.Address is not int addr)
        {
            _status.Text = $"the {(rowHeader ? "row" : "column")} header is not read from the ROM (its values are fixed in the definition)";
            return;
        }
        var defs = _host.Defs();
        int count = rowHeader ? _item.Rows : _item.Cols;
        var existing = defs.Items.FirstOrDefault(i => i.Address == addr && i.IsTable && i.Count >= count && i.Rows <= 1)
                       ?? defs.Items.FirstOrDefault(i => i.Address == addr);
        if (existing == null)
        {
            var name = $"{_item.Name}_{(rowHeader ? "rpm" : "load")}_axis";
            if (defs.Find(name) != null) name += "_" + addr.ToString("X4");
            existing = new ItemDef
            {
                Name = name, Address = addr, Rows = 1, Cols = count,
                Type = axis.Type, Formula = axis.Formula, Category = "Axes",
                Description = $"{(rowHeader ? "row" : "column")} axis of {_item.Name}",
            };
            var added = existing;
            _host.EditDefinitions(d => { d.Items.Add(added); return true; });
            AppLog.Action("calibration", $"added the axis {added.Name} at {addr:X4} from a header");
        }
        _cameFrom = _item.Name;
        if (_back != null) _back.IsVisible = true;
        Refresh(existing.Name);
        _grid.SelectCell(0, Math.Clamp(index, 0, Math.Max(0, existing.Cols - 1)));
        _status.Text = $"{existing.Name}: breakpoint {index} - edit it here, then pick {_cameFrom} again to see the map against it";
    }

    /// The map a header jumped away from: Back returns to it.
    string? _cameFrom;
    Button? _back;

    void GoBack()
    {
        if (_cameFrom == null) return;
        var to = _cameFrom;
        _cameFrom = null;
        if (_back != null) _back.IsVisible = false;
        Refresh(to);
        _status.Text = $"back to {to}";
    }

    /// Open the O2 / knock tables on the map on screen, fed by the logged frames.
    async void LogTableTools(ItemDef? item)
    {
        if (_top() is not Window owner) return;
        if (OverlayFrames == null) { _status.Text = "no datalog source"; return; }
        var w = new LogTableWindow(_host, () => OverlayFrames(), item)
        {
            TargetLow = TargetLow, TargetHigh = TargetHigh, Correction = WidebandCorrection,
        };
        await w.ShowDialog(owner);
        if (w.Applied) { Refresh(_selected?.Name); UpdateOverlay(); _status.Text = "the log's offsets were applied - Undo puts them back"; }
    }

    /// Open the scaling tools on the table on screen, and redraw if anything was applied.
    async void ScaleTools(ItemDef? item)
    {
        if (_top() is not Window owner) return;
        var w = new ScaleWindow(_host, item);
        await w.ShowDialog(owner);
        if (w.Applied) { Refresh(_selected?.Name); _status.Text = "scaled - Undo puts it all back in one step"; }
    }

    // ------------------------------------------------------------------ detect

    void Detect()
    {
        var asm = _host.Assembly;
        if (asm == null) { _status.Text = "build first: Detect needs the assembled symbols"; return; }
        try
        {
            var rom = _host.RomBytes(0, Bus.RomSize);
            // only the files this ROM was built from: another ROM may still be open in a tab
            var built = asm.SourceMap.Select(e => e.File).Distinct().ToHashSet(StringComparer.OrdinalIgnoreCase);
            var sources = _sources().Where(x => { try { return built.Contains(Path.GetFullPath(x.Path)); } catch { return false; } }).ToList();
            if (sources.Count == 0) sources = _sources().ToList();
            var r = _host.EditDefinitions(defs => CalibrationDetector.Detect(defs, asm, rom, sources));
            Refresh();
            _status.Text = "Detect: " + r.Summary + (r.Added + r.Replaced > 0 ? " - check types and formulas" : "");
            AppLog.Action("calibration", "Detect: " + r.Summary);
        }
        catch (Exception ex) { _status.Text = "Detect failed: " + ex.Message; AppLog.Error("calibration", "Detect failed", ex); }
    }

    // ------------------------------------------------------------------ files

    async void SaveBin() => await SaveRomAsync();

    /// Ask where to put the tuned image and write it. False means the dialog was cancelled or the write failed, so a caller about to replace the ROM should stay where it is.
    public async Task<bool> SaveRomAsync()
    {
        try
        {
            var top = _top();
            if (top == null) return false;
            var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Save the ROM image",
                SuggestedFileName = Path.GetFileNameWithoutExtension(_host.LoadedPath ?? "rom").Replace(".disasm", "") + "_tuned.bin",
                DefaultExtension = "bin",
                FileTypeChoices = new[] { new FilePickerFileType("ROM image") { Patterns = new[] { "*.bin" } } },
            });
            var p = file?.TryGetLocalPath();
            if (p == null) return false;
            _host.SaveRom(p);
            _status.Text = $"saved {p}" + (File.Exists(p + ".bak") ? " (previous copy kept as .bak)" : "");
            AppLog.Action("calibration", "saved the ROM to " + p);
            return true;
        }
        catch (Exception ex) { _status.Text = "save failed: " + ex.Message; AppLog.Error("calibration", "save failed", ex); return false; }
    }

    async void Export()
    {
        try
        {
            var top = _top();
            if (top == null) return;
            var defs = _host.Defs();
            var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Export calibration definitions",
                SuggestedFileName = Path.GetFileNameWithoutExtension(_host.LoadedPath ?? "rom") + ".calibration.json",
                DefaultExtension = "json",
                FileTypeChoices = new[] { new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } } },
            });
            var path = file?.TryGetLocalPath();
            if (path == null) return;
            var used = defs.Items.SelectMany(i => new[] { i.Formula, i.RowAxis?.Formula, i.ColAxis?.Formula }).Where(n => n != null).ToHashSet();
            var export = new DefinitionSet
            {
                Name = Path.GetFileName(_host.LoadedPath ?? ""),
                RomSize = defs.RomSize,
                Items = defs.Items.OrderBy(i => i.Address).ToList(),
                Formulas = defs.Formulas.Where(f => used.Contains(f.Name)).ToList(),
            };
            export.Save(path);
            _status.Text = $"exported {export.Items.Count} definitions to {path}";
        }
        catch (Exception ex) { _status.Text = "export failed: " + ex.Message; AppLog.Error("calibration", "export failed", ex); }
    }

    async void ExportXdf()
    {
        try
        {
            var top = _top();
            if (top == null) return;
            var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Export a TunerPro XDF",
                SuggestedFileName = Path.GetFileNameWithoutExtension(_host.LoadedPath ?? "rom").Replace(".disasm", "") + ".xdf",
                DefaultExtension = "xdf",
                FileTypeChoices = new[] { new FilePickerFileType("TunerPro XDF") { Patterns = new[] { "*.xdf" } } },
            });
            var path = file?.TryGetLocalPath();
            if (path == null) return;
            var defs = _host.Defs();
            var values = XdfExport.Values.Raw;
            if (top is Window valueOwner)
            {
                var pick = await Dialogs.Ask(valueOwner, "Which numbers should TunerPro show?",
                    "As stored: the bytes exactly as they sit in the ROM, the way the XDFs written for these ECUs by hand do it - " +
                    "the numbers line up with those files, and a fuel map's per-column multiplier (which XDF cannot apply) is left alone.\n\n" +
                    "Scaled: degrees, percent and volts where XDF's arithmetic can express the scaling. Fuel maps stay as stored either way.",
                    "As stored", "Scaled", "Cancel");
                if (pick == "Cancel" || pick == null) { _status.Text = "XDF export cancelled"; return; }
                if (pick == "Scaled") values = XdfExport.Values.Scaled;
            }
            // these maps keep more bytes per row than they use; how TunerPro should be told about
            // that is the one thing the known-good files do not settle, so ask
            var stride = XdfExport.Stride.PaddingAsColumns;
            if (defs.Items.Any(i => i.IsTable && i.Rows > 1 && i.RowStride != i.Cols * i.ElementSize) && top is Window owner)
            {
                var answer = await Dialogs.Ask(owner, "How should padded rows be written?",
                    "These maps keep more bytes per row than they use (24 bytes for 10 columns, say).\n\n" +
                    "Show the padding: the table goes out as wide as the stride, the spare columns marked 'pad'. Every cell lands where it really is - " +
                    "this is the one that cannot be misread, and the padding columns are simply ignored while tuning.\n\n" +
                    "Row stride / Padding only: the narrow table plus a stride attribute, written the two ways TunerPro is read in the wild. " +
                    "If a map comes out shuffled, it was the wrong one.",
                    "Show the padding", "Row stride", "Padding only", "Cancel");
                if (answer == "Cancel" || answer == null) { _status.Text = "XDF export cancelled"; return; }
                stride = answer == "Row stride" ? XdfExport.Stride.WholeRow
                       : answer == "Padding only" ? XdfExport.Stride.PaddingOnly
                       : XdfExport.Stride.PaddingAsColumns;
            }
            File.WriteAllText(path, XdfExport.Write(defs, _host.RomBytes(0, Bus.RomSize), Path.GetFileNameWithoutExtension(path), stride, values));
            _status.Text = $"wrote {path}: {defs.Items.Count} definitions for TunerPro (open it with the matching .bin)";
            AppLog.Action("calibration", "exported XDF " + path);
        }
        catch (Exception ex) { _status.Text = "XDF export failed: " + ex.Message; AppLog.Error("calibration", "XDF export failed", ex); }
    }

    async void Import()
    {
        try
        {
            var top = _top();
            if (top == null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "Import calibration definitions",
                FileTypeFilter = new[] { new FilePickerFileType("JSON") { Patterns = new[] { "*.json" } } },
            });
            var path = files.FirstOrDefault()?.TryGetLocalPath();
            if (path == null) return;
            var loaded = DefinitionSet.Load(path);
            int n = _host.EditDefinitions(defs =>
            {
                foreach (var f in loaded.Formulas.Where(f => defs.Formulas.All(g => g.Name != f.Name))) defs.Formulas.Add(f);
                int k = 0;
                foreach (var item in loaded.Items)
                {
                    defs.Items.RemoveAll(i => i.Name == item.Name);
                    defs.Items.Add(item); k++;
                }
                return k;
            });
            Refresh();
            _status.Text = $"imported {n} definitions from {Path.GetFileName(path)}";
        }
        catch (Exception ex) { _status.Text = "import failed: " + ex.Message; AppLog.Error("calibration", "import failed", ex); }
    }
}
