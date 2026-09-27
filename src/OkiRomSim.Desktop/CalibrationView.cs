// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.VisualTree;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Calibration tab, a full editor for the ROM's settings and maps: - maps drawn as tuners expect (RPM rows, load columns, coloured cells) with Line and 3D views, multi-cell editing, copy/paste, interpolate/smooth, undo/redo; - settings as number boxes, switches as checkboxes, all in a tree by category; - live trace: the cells the simulated program is reading light up (aqua, lime trail) - or, in Tuner mode, the cell the car is in according to the datalog; - a logged channel (wideband AFR, knock...) averaged per cell over the map; - Detect, definitions editing, Import/Export (JSON, TunerPro XDF), Save .bin, and the ROM emulator (connect, upload, upload every change as it is made).
public sealed class CalibrationView : UserControl
{
    readonly SimHost _host;
    readonly Func<IEnumerable<(string Path, string Text)>> _sources;
    readonly Func<TopLevel?> _top;
    readonly TreeView _tree = new() { FontSize = 12 };
    bool _clearingFilter;
    readonly TextBox _filter = new() { Watermark = "filter", Margin = new Thickness(0, 0, 0, 4) };
    readonly ContentControl _detail = new();
    readonly TextBlock _status = new() { FontSize = 11, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(12, 0, 0, 0) };
    readonly CheckBox _live = new() { Content = "Live trace", IsChecked = true, FontSize = 11 };
    readonly CheckBox _follow = new() { Content = "Follow reads when stepping", IsChecked = true, FontSize = 11 };
    /// Keep the table's selection on the cell the engine is in (the live trace), scrolled into view.
    readonly CheckBox _lock = new() { Content = "Lock to live cell", IsChecked = false, FontSize = 11 };
    (int R, int C) _locked = (-1, -1);

    /// The Datalogging menu's lines, from the datalog panel (set by the main window): (live trace on?, set it) -> entries.
    public Func<Func<bool>, Action<bool>, Toolbar.Entry[]>? DatalogMenu { get; set; }
    readonly CheckBox _autoUpload = new() { Content = "Upload on changes", FontSize = 11 };
    readonly Button _emuButton;
    readonly TextBlock _emuStatus = new() { FontSize = 11, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0), MaxWidth = 260, TextTrimming = TextTrimming.CharacterEllipsis };
    /// Which logged channel is laid over the map (Tools > Overlay); "none" for no overlay.
    string _overlayChannel = "none";
    List<string> _overlayChannels = ["none"];
    readonly HashSet<string> _openCategories = ["Fuel", "Ignition"];
    List<ItemDef> _items = [];
    bool _updating;

    // current table
    ItemDef? _item;
    TableModel? _model;
    readonly TableGrid _grid = new();
    readonly TableGraph _graph = new();
    readonly TableSurface _surface = new();
    readonly Canvas _overlay = new();
    readonly TabControl _views = new();
    readonly TextBox _adjust = new() { Width = 70, Text = "1", FontFamily = MainWindow.MonoFont };
    readonly Avalonia.Controls.Primitives.ToggleButton _stretchBtn = new() { Content = "⤢ Stretch", FontSize = 11, Padding = new Thickness(8, 1), MinHeight = 0 };

    /// The Table view stretched to fill its panel (remembered in the settings).
    public bool TableStretch
    {
        get;
        set { field = value; if ((_stretchBtn.IsChecked == true) != value) _stretchBtn.IsChecked = value; }
    }
    public event Action<bool>? StretchChanged;
    /// The touch screen mode's pad of big buttons beside the table (TouchMode).
    TouchPad? _touchPad;
    /// The list's rows: tight for a mouse, a finger's height in touch screen mode.
    static double TreeRow => TouchMode.On ? 34 : 0;

    // definition form
    readonly TextBox _fName = new() { Width = 190 };
    readonly TextBox _fAddr = new() { Width = 110 };
    readonly ComboBox _fType = new() { Width = 90, ItemsSource = Enum.GetNames<CellType>() };
    readonly NumericUpDown _fRows = Num(0, 64), _fCols = Num(0, 64), _fStride = Num(0, 256);
    readonly ComboBox _fFormula = new() { Width = 160 };
    readonly TextBox _fCategory = new() { Width = 120 };
    readonly TextBox _fDesc = new() { Width = 380 };
    readonly TextBox _fRowAxis = new() { Width = 130, Watermark = "label/addr" };
    readonly ComboBox _fRowFormula = new() { Width = 200 };
    readonly TextBox _fColAxis = new() { Width = 130, Watermark = "label/addr" };
    readonly ComboBox _fColFormula = new() { Width = 200 };
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
    double _trail = 2.0;
    /// Set when a write worked out to no byte change at all, so the page can say why.
    bool _nothingChanged;
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
        if (_model != null) { _model.Heat = []; _model.ExternalTrace = null; Redraw(); }
    }

    static NumericUpDown Num(double min, double max) => new() { Width = 130, Minimum = (decimal)min, Maximum = (decimal)max, Increment = 1, FormatString = "0" };

    public CalibrationView(SimHost host, Func<IEnumerable<(string Path, string Text)>> sources, Func<TopLevel?> top)
    {
        _host = host; _sources = sources; _top = top;
        _emuButton = Btn("Connect emulator", ToggleEmulator,
            "Connect to the emulator on the port set in Settings (the device and its baud rate are set there too) and upload the ROM, with every edit made here, so the car runs it. Press again to disconnect.");

        var bar = _bar = new WrapPanel { Margin = new Thickness(4) };
        _status.PropertyChanged += (_, e) =>
        {
            // every status line also goes to the Debug page's log, so a message that went by too fast can be read back
            if (e.Property == TextBlock.TextProperty && _status.Text is { Length: > 0 } t && t != _statusLogged) { _statusLogged = t; AppLog.Info("calibration", t); }
        };
        _emuWatch = new LinkSupervisor("emulator",
            () => _busyEmulator ? null : _host.Emulator.Connected && MoatesTrace.Ports().Contains(_emuPort, StringComparer.OrdinalIgnoreCase),
            () =>
            {
                if (!_emuWatch!.Wanted) return;
                ConnectAndCheck(_emuPort, "The emulator is connected again");
            });
        _emuWatch.Message += m => Dispatcher.UIThread.Post(() => { _status.Text = m; UpdateEmulator(); });
        _expand.Click += (_, _) => ExpandRequested?.Invoke();
        ToolTip.SetTip(_expand, "Give the calibration editor (and the other lower tabs) the whole window; press again to put the layout back.");
        bar.Children.Add(_expand);
        // the definition work lives in one drop-down so the bar stays readable in both modes
        bar.Children.Add(_toolsMenu = Toolbar.Menu("Tools", Toolbar.Detect,
            new Toolbar.Entry(Toolbar.Detect, "Detect",
                "Scan the assembly for calibration data: the maps set up for the 2D lookup (with their RPM and load axes, row stride and fuel multiplier row), " +
                "labelled DB/DW blocks, tables the code reads with LC/LCB, and on/off switches. New finds are added to the list.", Detect),
            Toolbar.Entry.Line,
            Toolbar.Entry.Submenu(Toolbar.Log, "Overlay",
                "Lay a datalogged channel over the map: its average in every cell the engine sat in (wideband AFR over the fuel map, knock over the ignition map...).",
                OverlayEntries),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Scale, "Injector size\u2026",
                "Stock and fitted injector size, the multiplier they come to, the injector offset and the fuel trims - and the fuel maps scaled to match.",
                () => OpenInjectors()),
            new Toolbar.Entry(Toolbar.Scale, "MAP sensor size\u2026",
                "Pick the MAP sensor fitted (or type what it reads at 0 V and 5 V) and move every load breakpoint to the count that means the same real pressure.",
                () => OpenMapSensor()),
            new Toolbar.Entry(Toolbar.Scale, "Scale\u2026",
                "Scale whole sections at once: this table by a percentage, or rescale a fuel map that has run to the top of its scale.",
                () => ScaleTools(Selected)),
            new Toolbar.Entry(Toolbar.Log, "O2 / knock tables\u2026",
                "What the log measured in every cell of the map, how far it is from target, and a button to apply the offsets.",
                () => LogTableTools(Selected)),
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
                () => CompareRequested?.Invoke()),
            new Toolbar.Entry(Toolbar.Import, "Import maps…",
                "Take maps and settings from another ROM (a .bin of any ROM the app knows, or a source): see what it has, pick what to bring " +
                "across - its fuel and ignition into a new ROM built from the skeleton, say - and they are resampled onto this ROM's " +
                "breakpoints where they differ. One undo step.", ImportMaps)));
        bar.Children.Add(_emuMenu = Toolbar.Menu("Emulator", Toolbar.Bin,
            new Toolbar.Entry(Toolbar.Bin, "Connect / disconnect",
                "Connect to the emulator on the port set in Settings and upload the ROM, so the car runs it. Again to disconnect.", ToggleEmulator),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Import, "Download",
                "Read the ROM out of the emulator, save it as a .bin (in Documents/OkiRomSim ROMs) and open it - the emulator and the datalog stay connected, since it is the ROM the car is running.",
                EmulatorDownload),
            new Toolbar.Entry(Toolbar.Export, "Upload", "Send the whole ROM, with every edit made here, to the emulator.", EmulatorUpload),
            new Toolbar.Entry(Toolbar.Detect, "Validate", "Read the emulator back and check it byte for byte against the ROM here.", EmulatorValidate),
            Toolbar.Entry.Line,
            new Toolbar.Entry("", "Upload on changes",
                "Send every change to the emulator the moment it is made (only the 256-byte blocks that changed), so the car runs it straight away.",
                ToggleAutoUpload, Checked: () => _host.AutoUpload)));
        bar.Children.Add(_logMenu = Toolbar.Menu("Datalogging", Toolbar.Log, () =>
        {
            var entries = DatalogMenu?.Invoke(() => _live.IsChecked == true, on => _live.IsChecked = on)
                          ?? [new Toolbar.Entry("", "Live trace", "Mark the cells the engine is reading on the map on screen.",
                                                () => _live.IsChecked = _live.IsChecked != true, Checked: () => _live.IsChecked == true)];
            return [.. entries, Toolbar.Entry.Line,
                new Toolbar.Entry("", "Lock to live cell", "Keep the table's selection on the cell the engine is in, scrolled into view, so Page Up / Down, + / - and typing change that cell - whatever has the keyboard.",
                    () => _lock.IsChecked = _lock.IsChecked != true, Checked: () => _lock.IsChecked == true),
                new Toolbar.Entry("", "Live cell: one cell", "Locked, the selection is the one cell nearest where the engine is.",
                    () => { _blendLive = false; _locked = (-1, -1); LockToTrace(); }, Checked: () => !_blendLive),
                new Toolbar.Entry("", "Live cell: the four round it, blended",
                    "Locked, the selection is the four cells round where the engine is, and a change is shared between them by how near the engine is to each (the nearest gets the full step) - the way the ECU blends them when it reads the map.",
                    () => { _blendLive = true; _locked = (-1, -1); LockToTrace(); }, Checked: () => _blendLive)];
        }));
        _emuMenu.Content = Toolbar.DotLabel(_emuDot, Toolbar.Bin, "Emulator  ▾");
        _logMenu.Content = Toolbar.DotLabel(_logDot, Toolbar.Log, "Datalogging  ▾");
        var gap = new Separator { Width = 8 };
        bar.Children.Add(gap);
        _back = Toolbar.IconButton("←", "Back: to where you came from - press again to keep going back, all the way to the first page.", GoBack);
        _back.IsEnabled = false;
        bar.Children.Add(_back);
        var undo = Toolbar.IconButton("↶", "Undo the last value change (Ctrl+Z in a table).", UndoEdit);
        var redo = Toolbar.IconButton("↷", "Redo what Undo took back (Ctrl+Y in a table).", RedoEdit);
        bar.Children.Add(undo);
        bar.Children.Add(redo);
        _barItems = [_toolsMenu, _emuMenu, _logMenu, gap, _back, undo, redo];
        // "Upload on changes" lives in the Emulator drop-down only: it was on the bar as well, which meant two controls for one setting
        _autoUpload.IsCheckedChanged += (_, _) => { _host.AutoUpload = _autoUpload.IsChecked == true; UpdateEmulator(); };
        ToolTip.SetTip(_follow, "When you Step / Over / Out and the instruction reads a defined table or setting, switch to it here and select the cell it read.");
        _lock.Margin = _follow.Margin = new Thickness(8, 0, 0, 0);
        ToolTip.SetTip(_lock, "Keep the table's selection on the cell the engine is in (the live trace), scrolled into view, so + / - and typing change that cell.");
        _lock.IsCheckedChanged += (_, _) => { _locked = (-1, -1); LockToTrace(); };
        AttachedToVisualTree += (_, _) => TopLevel.GetTopLevel(this)?.AddHandler(KeyDownEvent, OnTableKey, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        DetachedFromVisualTree += (_, e) => (e.Root as TopLevel)?.RemoveHandler(KeyDownEvent, OnTableKey);
        // Live trace and Lock to live cell are in the Datalogging menu only
        bar.Children.Add(_follow);

        _tree.SelectionChanged += (_, _) =>
        {
            if (_updating) return;
            switch ((_tree.SelectedItem as TreeViewItem)?.Tag)
            {
                case ItemDef it: Selected = it; _pageOpen = null; ShowSelected(); break;
                case CalPage page: ShowPage(page); break;
            }
        };
        _tree.DoubleTapped += (_, _) => { if ((_tree.SelectedItem as TreeViewItem)?.Tag is ItemDef it) GoToAddress?.Invoke(it.Address); };
        // right-click: the node under the pointer is selected first, then its menu opens
        _tree.ContextRequested += (_, e) =>
        {
            var node = (e.Source as Visual)?.FindAncestorOfType<TreeViewItem>(includeSelf: true);
            if (node != null && !ReferenceEquals(_tree.SelectedItem, node)) _tree.SelectedItem = node;
            TreeMenu(node?.Tag).Open(_tree);
            e.Handled = true;
        };
        // a tight indent: the theme's left a wide margin down the left of the list
        _tree.Resources["TreeViewItemIndent"] = 10.0;
        _tree.Resources["TreeViewItemExpandCollapseChevronMargin"] = new Thickness(2, 0, 2, 0);
        ToolTip.SetTip(_tree, "Feature pages at the top, then the ROM's settings and maps by category. Select one to edit it; double-click a setting to show it in the source.");
        _filter.TextChanged += (_, _) => { if (!_clearingFilter) Refresh(); };
        ToolTip.SetTip(_filter, "Show only items whose name, category or address contains this text.");

        var left = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        DockPanel.SetDock(_filter, Dock.Top);
        left.Children.Add(_filter);
        _validBox.IsCheckedChanged += (_, _) => { if (_validOnly != (_validBox.IsChecked == true)) { _validOnly = _validBox.IsChecked == true; Refresh(); } };
        ToolTip.SetTip(_validBox, "Hide the feature pages this ROM has nothing for (no row bound to one of its definitions), on a page the rows it has nothing for, and the tables with no known scaling for what they are looked up against (runs of raw bytes). Also on the list's right-click menu.");
        DockPanel.SetDock(_validBox, Dock.Top);
        left.Children.Add(_validBox);
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
        _grid.NudgeCells += (cells, d) =>
        {
            if (BlendWeights() is { } w && _model is { } bm)
            {
                // the four cells round the engine, each moved by its share: the nearest the full step, the others less
                var f = _host.Defs().Formula(_item!.Formula);
                Write([.. w.Keys], i => bm.Values[i] + (d * Math.Abs(f.ToValue(bm.Raw[i] + 1) - f.ToValue(bm.Raw[i])) * w[i]), false,
                      $"{(d > 0 ? "+" : "")}{d} step{(Math.Abs(d) == 1 ? "" : "s")}, blended");
                return;
            }
            Write(cells, i => _model!.Raw[i] + d, true, d > 0 ? $"+{d} raw" : $"{d} raw");
        };
        _grid.PasteCells += list =>
        {
            var dict = list.ToDictionary(x => x.Index, x => x.Value);
            Write([.. dict.Keys], i => dict[i], false, "paste");
        };
        _grid.Undo += UndoEdit; _grid.Redo += RedoEdit;
        _grid.HeaderActivated += OpenAxis;
        _traceTimer.Tick += (_, _) => Tick();
        // Low performance mode: the read trace looked at less often, the cells drawn without their shading
        Perf.Changed += () => { _traceTimer.Interval = TimeSpan.FromMilliseconds(Perf.TraceMs); Redraw(); };
        _traceTimer.Interval = TimeSpan.FromMilliseconds(Perf.TraceMs);
        _traceTimer.Start();
        void Dragged(IReadOnlyList<(int Index, double Value)> cells)
        {
            var to = cells.ToDictionary(x => x.Index, x => x.Value);
            Write([.. to.Keys], i => to[i], false, "drag");
        }
        _graph.SetCells += Dragged; _surface.SetCells += Dragged;
        _graph.SelectRange += _grid.SelectRange; _surface.SelectRange += _grid.SelectRange;
        _graph.Keys = _grid; _surface.Keys = _grid;
        _grid.Message += _ => { _graph.InvalidateVisual(); _surface.InvalidateVisual(); };
        _grid.Command += op =>
        {
            if (op.StartsWith("pct:") && _model != null && double.TryParse(op[4..], NumberStyles.Float, CultureInfo.InvariantCulture, out var pc))
            {
                var m = _model;
                if (BlendWeights() is { } w)
                    Write([.. w.Keys], i => m.Values[i] * (1 + (pc * w[i] / 100)), false, $"{(pc >= 0 ? "+" : "")}{pc}%, blended");
                else
                    Write(_grid.Selection(), i => m.Values[i] * (1 + (pc / 100)), false, $"{(pc >= 0 ? "+" : "")}{pc}%");
            }
            else Adjust(op);
        };
        // the menu opens on the table itself: a cell, the chart, the surface - not the empty space round it, and not at the
        // end of a right-drag that turned the 3D view
        foreach (var v in new Control[] { _grid, _graph, _surface })
            v.ContextRequested += (_, e) =>
            {
                e.Handled = true;
                if (e.TryGetPosition(v, out var p) && !(v == _surface ? _surface.MenuAllowed(p) : v == _graph ? _graph.MenuAllowed(p) : _grid.MenuAllowed(p))) return;
                TableMenu().Open(v);
            };
        _touchPad = new TouchPad(_grid, Adjust, () => _adjust.Text, t => _adjust.Text = t, UndoEdit, RedoEdit) { IsVisible = TouchMode.On };
        TouchMode.Changed += () => { _touchPad.IsVisible = TouchMode.On; _grid.InvalidateMeasure(); _grid.InvalidateVisual(); Refresh(); };
        _overlay.IsHitTestVisible = true;
        var gridHost = new Panel();
        gridHost.Children.Add(_grid);
        gridHost.Children.Add(_overlay);
        _grid.AttachEditorHost(_overlay);
        _grid.HorizontalAlignment = HorizontalAlignment.Left; _grid.VerticalAlignment = VerticalAlignment.Top;
        var gridScroll = new ScrollViewer { Content = gridHost, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
        // Stretch: the table fills the panel, its cells and numbers as big as the panel allows (no scrolling)
        _stretchBtn.IsCheckedChanged += (_, _) =>
        {
            bool on = _stretchBtn.IsChecked == true;
            var sv = on ? Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled : Avalonia.Controls.Primitives.ScrollBarVisibility.Auto;
            gridScroll.HorizontalScrollBarVisibility = sv; gridScroll.VerticalScrollBarVisibility = sv;
            _grid.HorizontalAlignment = on ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
            _grid.VerticalAlignment = on ? VerticalAlignment.Stretch : VerticalAlignment.Top;
            _grid.Stretch = on;
            if (on != TableStretch) { TableStretch = on; StretchChanged?.Invoke(on); }
        };
        ToolTip.SetTip(_stretchBtn, "Stretch the table to fill its panel: every cell bigger (or smaller) so the whole map is on screen, " +
                                    "the numbers - and the small logged ones in the corner of each cell - as big as the panel allows. Again for the normal size.");
        var gridPanel = new DockPanel();
        var gridBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(0, 0, 0, 2) };
        gridBar.Children.Add(_stretchBtn);
        DockPanel.SetDock(gridBar, Dock.Top);
        gridPanel.Children.Add(gridBar);
        gridPanel.Children.Add(gridScroll);
        var transpose = new CheckBox { Content = "one line per column", FontSize = 11 };
        transpose.IsCheckedChanged += (_, _) => _graph.Transpose = transpose.IsChecked == true;
        ToolTip.SetTip(transpose, "Off: x = columns (load), one line per row. On: x = rows (rpm), one line per column.");
        var graphPanel = new DockPanel();
        DockPanel.SetDock(transpose, Dock.Top);
        graphPanel.Children.Add(transpose);
        graphPanel.Children.Add(_graph);
        ToolTip.SetTip(_graph, "Drag a point up or down to change it (the selected points move together); drag a box round points to select them; Shift+click adds to the selection. Right-click for everything else. The aqua band and the thick line are where the engine is.");
        ToolTip.SetTip(_surface, "Left-drag a point to change it, left-drag round points to select them, right-drag to turn, middle-drag to move, wheel to zoom, double-click or Home to reset. The white dot is where the engine is.");
        _views.Items.Add(new TabItem { Header = "Table", Content = gridPanel });
        _views.Items.Add(new TabItem { Header = "Line", Content = graphPanel });
        var viewBar = new WrapPanel { Margin = new Thickness(0, 0, 0, 2) };
        foreach (var (text, view, tip) in new[]
        {
            ("Reset view", "reset", "Put the view back where it started (also Home, or double-click the background)."),
            ("Top", "top", "Straight down on the table: rows and columns as in the grid."),
            ("Front", "front", "Level with the table, the columns across."),
            ("Side", "side", "Level with the table, the rows across."),
            ("Under", "under", "From below."),
            ("⟲", "left", "Turn an eighth to the left."),
            ("⟳", "right", "Turn an eighth to the right."),
            ("▲", "up", "Tilt: look down more."),
            ("▼", "down", "Tilt: look down less."),
            ("＋", "zoomin", "Zoom in (also the mouse wheel, or pinch with two fingers)."),
            ("－", "zoomout", "Zoom out."),
        })
        {
            var b = new Button { Content = text, FontSize = 11, Padding = new Thickness(8, 1), MinHeight = 0, Margin = new Thickness(0, 0, 4, 0) };
            b.Click += (_, _) => { _surface.SetView(view); _surface.Focus(); };
            ToolTip.SetTip(b, tip);
            viewBar.Children.Add(b);
        }
        var surfacePanel = new DockPanel();
        DockPanel.SetDock(viewBar, Dock.Top);
        surfacePanel.Children.Add(viewBar);
        surfacePanel.Children.Add(_surface);
        _views.Items.Add(new TabItem { Header = "3D", Content = surfacePanel });
        foreach (var t in _views.Items.OfType<TabItem>()) { t.FontSize = 12; t.MinHeight = 24; t.Padding = new Thickness(8, 1); }
        _views.SelectionChanged += (_, e) =>
        {
            if (!ReferenceEquals(e.Source, _views)) return;
            Redraw();
            if (_tuner) Dispatcher.UIThread.Post(FocusView, DispatcherPriority.Background);
        };
        // the tip goes on the three tab headers, not on the whole control: a 1 x 10 table leaves most of the panel empty, and a tip on the panel followed the pointer around it
        foreach (var t in _views.Items.OfType<TabItem>())
            ToolTip.SetTip(t, (string?)t.Header switch
            {
                "Table" => "The cells, with their RPM and load axes.",
                "Line" => "Every row of the map as a line; drag a point to change it, or a box round points to select them.",
                _ => "The whole map as a surface (tables with more than one row and column): drag points to change them, right-drag to turn it.",
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

        // an MCP client (or undo from elsewhere) changed something: show it
        _host.CalibrationChanged += (what, item) => Dispatcher.UIThread.Post(() =>
        {
            try
            {
                _status.Text = what;
                if (item != null && _host.Defs().Find(item) is { } it) { Selected = it; Refresh(it.Name); }
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

    public ItemDef? Selected { get; private set; }

    /// What a project keeps of this page: the item open and the view (0 Table, 1 Line, 2 3D).
    public (string? Item, int View) ViewState => (Selected?.Name, _views.SelectedIndex);

    /// A project opened: the item and the view it was saved on.
    public void RestoreView(string? item, int view)
    {
        if (item != null && _host.Defs().Find(item) is { } it) { Selected = it; Refresh(it.Name); }
        if (view >= 0 && view < _views.ItemCount) _views.SelectedIndex = view;
    }

    /// Another ROM was opened (or the project was cleared): drop everything from the last one.
    public void ResetForNewRom()
    {
        Selected = null; _item = null; _model = null;
        _grid.Model = null; _graph.Model = null; _surface.Model = null;
        _filter.Text = "";
        _overlayChannel = "none";
        _openCategories.Clear(); _openCategories.Add("Fuel"); _openCategories.Add("Ignition");
        _pageOpen = null;
        _guessed.Clear();
        _layoutApplied = false;
        _history.Clear();
        _back?.IsEnabled = false;
        _status.Text = "";
        Refresh();
    }

    public void Refresh(string? select = null)
    {
        if (_updating) return;
        var defs = _host.Defs();
        bool jump = select != null;     // asked for by name (a jump), not just kept from before (typing in the filter)
        select ??= Selected?.Name;
        // the password block is where the watermark's password is kept: the Watermark row is its one control
        _items = [.. defs.Items.Where(i => i.Text != "password").OrderBy(i => CategoryOrder(i.Category)).ThenBy(i => i.Category)
            .ThenBy(i => i.IsTable && i.Rows > 1 ? 0 : i.IsTable && i.Count > 1 ? 1 : 2).ThenBy(i => i.Address)];
        var f = (_filter.Text ?? "").Trim();
        // Show only valid: a table with no scaling for what it is looked up against (a run of raw bytes) is left out
        List<ItemDef> listed = _validOnly ? [.. _items.Where(i => i.HasLookup)] : _items;
        // (a table asked for by name is listed whatever it is: going to it from a page or a header has to land on it)
        if (jump && _validOnly && listed.All(i => i.Name != select) && _items.FirstOrDefault(i => i.Name == select) is { } asked) listed = [.. listed, asked];
        var shown = f.Length == 0 ? listed : [.. listed.Where(i =>
            i.Name.Contains(f, StringComparison.OrdinalIgnoreCase) || i.Category.Contains(f, StringComparison.OrdinalIgnoreCase) ||
            i.Address.ToString("X4").Contains(f, StringComparison.OrdinalIgnoreCase))];
        // going to a table the filter hides (a header double-clicked, a button for another table): the filter is
        // cleared so the table can be shown, instead of landing on the first one the filter lets through
        if (jump && f.Length > 0 && !shown.Any(i => i.Name == select) && listed.Any(i => i.Name == select))
        {
            _clearingFilter = true;
            _filter.Text = "";
            _clearingFilter = false;
            shown = listed;
        }
        var pick = select == null ? shown.FirstOrDefault() : shown.FirstOrDefault(i => i.Name == select) ?? shown.FirstOrDefault();
        _updating = true;
        try
        {
            // remember which categories are open
            foreach (var node in _tree.Items.OfType<TreeViewItem>())
            {
                if (node.Header is "★ Favourites") { if (node.IsExpanded) _openCategories.Remove("!Favourites"); else _openCategories.Add("!Favourites"); continue; }
                if (node.Header is string h) { if (node.IsExpanded) _openCategories.Add(h); else _openCategories.Remove(h); }
                // the page categories are a level deeper, and are worth remembering too
                if ((node.Header as string) != "Pages") continue;
                foreach (var sub in node.ItemsSource?.OfType<TreeViewItem>() ?? [])
                    if (sub.Tag == null && sub.Header is string sh)
                    {
                        string key = "Pages/" + sh.Split("  (")[0];
                        if (sub.IsExpanded) _openCategories.Add(key); else _openCategories.Remove(key);
                    }
            }
            var nodes = new List<TreeViewItem>();
            TreeViewItem? pickNode = null;
            // favourites first: the tables and pages picked with a right-click, whatever their category
            var favs = Favourites();
            if (favs.Count > 0)
            {
                var romPagesF = CalPage.ForRom(defs);
                var favLeaves = new List<TreeViewItem>();
                foreach (var key in favs)
                {
                    TreeViewItem? leaf = null;
                    if (key.StartsWith("item:") && _items.FirstOrDefault(i => i.Name.Equals(key[5..], StringComparison.OrdinalIgnoreCase)) is { } fi
                        && (f.Length == 0 || fi.Name.Contains(f, StringComparison.OrdinalIgnoreCase)))
                    {
                        leaf = new TreeViewItem { Header = $"{fi.Name}{(fi.IsTable && fi.Count > 1 ? $"  {fi.Rows}×{fi.Cols}" : fi.Flag ? "  ☐" : "")}", Tag = fi };
                        ToolTip.SetTip(leaf, $"{fi.Address:X4}  {fi.Type}  {fi.Formula}{(fi.Description.Length > 0 ? "\n" + fi.Description : "")}");
                    }
                    else if (key.StartsWith("page:") && romPagesF.FirstOrDefault(p => p.Key == key[5..]) is { } fp
                             && (f.Length == 0 || fp.Name.Contains(f, StringComparison.OrdinalIgnoreCase)))
                    {
                        leaf = new TreeViewItem { Header = fp.Name, Tag = fp };
                        ToolTip.SetTip(leaf, fp.Blurb);
                    }
                    if (leaf == null) continue;
                    leaf.FontWeight = FontWeight.Normal; leaf.Padding = new Thickness(2, 0); leaf.MinHeight = TreeRow;
                    favLeaves.Add(leaf);
                }
                if (favLeaves.Count > 0)
                    nodes.Add(new TreeViewItem { Header = "★ Favourites", FontWeight = FontWeight.SemiBold, IsExpanded = !_openCategories.Contains("!Favourites"), ItemsSource = favLeaves });
            }
            // the feature pages first: the ECU's own features laid out as a tuner expects to find them, rather than as a list of addresses
            if (f.Length == 0 || "pages".Contains(f, StringComparison.OrdinalIgnoreCase))
            {
                var pageNode = new TreeViewItem { Header = "Pages", FontWeight = FontWeight.SemiBold, IsExpanded = _openCategories.Contains("Pages") };
                // there are a lot of them, so they sit under their own categories the way the established tuning software groups its tabs
                TreeViewItem PageLeaf(CalPage page)
                {
                    var leaf = new TreeViewItem
                    {
                        Header = page.Name,
                        Tag = page, FontWeight = FontWeight.Normal, Padding = new Thickness(2, 0), MinHeight = TreeRow,
                    };
                    ToolTip.SetTip(leaf, page.Blurb);
                    return leaf;
                }
                var romPages = CalPage.ForRom(defs);
                // the page on screen, as this ROM's list now has it (a binding may have added settings to it)
                if (_pageOpen is { } was && romPages.FirstOrDefault(p => p.Key == was.Key) is { } now) _pageOpen = now;
                // a ROM built from a skeleton: a page that belongs to modules it was built without is not valid, whatever a guess
                // (or a binding kept from an earlier build) has put on it - unless the skeleton's own stock code fills a row of it
                if (!ReferenceEquals(_leftOutFor, _host.Assembly)) { _leftOutFor = _host.Assembly; _leftOut = _host.Assembly is { } asmNow ? Skeleton.PagesLeftOut(asmNow) : null; }
                var leftOut = _leftOut;
                var skeletonFile = _host.Assembly?.Files.FirstOrDefault(x => x.EndsWith("-skeleton.asm", StringComparison.OrdinalIgnoreCase)) is { } sf ? Path.GetFileName(sf) : null;
                bool Valid(CalPage page)
                {
                    var bound = page.Slots().Select(x => CalPage.Bound(defs, x)).OfType<ItemDef>().Where(i => i.HasLookup).ToList();
                    if (bound.Count == 0) return false;
                    if (leftOut == null || !leftOut(page.Key)) return true;
                    return skeletonFile != null && bound.Any(i => i.Origin?.StartsWith(skeletonFile + ":", StringComparison.OrdinalIgnoreCase) == true);
                }
                pageNode.ItemsSource = romPages
                    .Where(page => !_validOnly || Valid(page))
                    .GroupBy(page => page.Category)
                    .OrderBy(g => PageCategoryOrder(g.Key)).ThenBy(g => g.Key)
                    .Select(g =>
                    {
                        string key = "Pages/" + g.Key;
                        var cat = new TreeViewItem
                        {
                            Header = g.Key, FontWeight = FontWeight.Normal, Padding = new Thickness(2, 0), MinHeight = TreeRow,
                            IsExpanded = _openCategories.Contains(key),
                            ItemsSource = g.Select(PageLeaf).ToList(),
                        };
                        return cat;
                    }).ToList();
                nodes.Add(pageNode);
            }
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
                        FontWeight = FontWeight.Normal, Padding = new Thickness(2, 0), MinHeight = TreeRow,
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
            Selected = pick;
            if (_pageOpen == null && pickNode != null) _tree.SelectedItem = pickNode;
        }
        finally { _updating = false; }
        var formulas = defs.Formulas.Select(x => x.Name).OrderBy(n => n).ToList();
        _fFormula.ItemsSource = formulas;
        _fRowFormula.ItemsSource = formulas;
        _fColFormula.ItemsSource = formulas;
        if (_pageOpen is { } open) ShowPage(open);
        else ShowSelected();
    }

    /// The order the feature-page categories read in: fuelling and spark first, the way a tuner works through them.
    static int PageCategoryOrder(string c) => c switch
    {
        "Fuel" => 0, "Ignition" => 1, "Limits" => 2, "Boost" => 3, "Protection" => 4,
        "Idle" => 5, "Outputs" => 6, "GPO" => 7, "Sensors" => 8, "Options" => 9, _ => 10,
    };

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
        UpdateDots();
        if (_model == null || _item == null || !IsEffectivelyVisible) return;
        // Tuner mode: the datalog drives the trace (SetEngineState); here the trail fades between frames
        if (_tuner)
        {
            // a new frame redraws at once (SetEngineState); the fading between frames is kept to its own pace
            if ((_extTrail.Count > 0 || _model.Heat.Count > 0) && (DateTime.UtcNow - _lastFade).TotalMilliseconds >= Perf.TrailMs)
            {
                _lastFade = DateTime.UtcNow;
                if (ExternalHeat()) Redraw();
            }
            return;
        }
        if (_live.IsChecked != true) { _idleTraced = default; if (_model.Heat.Count > 0) { _model.Heat = []; Redraw(); } return; }
        // with the simulator stopped the trace cannot move until a step: look once, not twenty times a second
        var idleKey = (_host.IsRunning, _host.StepSerial, _item);
        if (!idleKey.IsRunning && idleKey == _idleTraced) return;
        // the simulated ROM switches cams as the car does: the map on screen goes with it
        if (FollowCam(_host.VtecActive)) return;
        _idleTraced = idleKey;
        var heat = _host.TableHeat(_item, _trail);
        if (heat.Count == 0 && _model.Heat.Count == 0) return;
        if (Same(heat, _model.Heat)) return;        // nothing moved: do not redraw the map
        _model.Heat = heat;
        Redraw();
        LockToTrace();
    }

    (bool IsRunning, int StepSerial, ItemDef? Item) _idleTraced;

    /// Lock to live cell: move the selection to where the engine is, when that has changed.
    void LockToTrace()
    {
        if (_lock.IsChecked != true || _model == null || _model.TraceCentre() is not { } at) return;
        if (_blendLive)
        {
            var (r0, c0, r1, c1) = Quad(at);
            if ((r0 * 1000) + c0 == (_locked.R * 1000) + _locked.C && _grid.SelectionRect() == (r0, c0, r1, c1)) return;
            _locked = (r0, c0);
            _grid.FocusCell(r0, c0);
            _grid.SelectRange(r0, c0, r1, c1);
            return;
        }
        var cell = ((int)Math.Round(at.Row), (int)Math.Round(at.Col));
        cell = (Math.Clamp(cell.Item1, 0, Math.Max(0, _model.Rows - 1)), Math.Clamp(cell.Item2, 0, Math.Max(0, _model.Cols - 1)));
        if (cell == _locked) return;
        _locked = cell;
        _grid.FocusCell(cell.Item1, cell.Item2);
    }

    /// Live cell edits shared between the four cells round the engine (Datalogging menu).
    bool _blendLive;

    /// The block of cells round a fractional (row, col): two by two, or less at an edge.
    (int R0, int C0, int R1, int C1) Quad((double Row, double Col) at)
    {
        var m = _model!;
        int r0 = (int)Math.Floor(Math.Clamp(at.Row, 0, Math.Max(0, m.Rows - 1))), c0 = (int)Math.Floor(Math.Clamp(at.Col, 0, Math.Max(0, m.Cols - 1)));
        return (r0, c0, Math.Min(r0 + 1, m.Rows - 1), Math.Min(c0 + 1, m.Cols - 1));
    }

    /// Locked and blended: each of the four cells round the engine and its share of a change (the nearest 1, the others by how near the engine is to them, as the ECU weighs them reading the map). Null when not blending.
    Dictionary<int, double>? BlendWeights()
    {
        if (!_blendLive || _lock.IsChecked != true || _model is not { } m || m.TraceCentre() is not { } at) return null;
        var (r0, c0, r1, c1) = Quad(at);
        double fr = Math.Clamp(at.Row - r0, 0, 1), fc = Math.Clamp(at.Col - c0, 0, 1);
        var w = new Dictionary<int, double>();
        void Add(int r, int c, double k) { int i = (r * m.Cols) + c; w[i] = w.GetValueOrDefault(i) + k; }
        Add(r0, c0, (1 - fr) * (1 - fc)); Add(r0, c1, (1 - fr) * fc); Add(r1, c0, fr * (1 - fc)); Add(r1, c1, fr * fc);
        double max = w.Values.Max();
        return max <= 0 ? null : w.Where(kv => kv.Value > 0.001).ToDictionary(kv => kv.Key, kv => kv.Value / max);
    }

    /// In Tuner mode (or locked to the live cell) with a map open, the table keys always go to the map - Table, Line or 3D - whatever was clicked last (the datalog's playback slider, a menu button, the list), so one hand can keep on Page Up / Down while the other drives the dyno. Only a box being typed in keeps its keys. The key also puts the keyboard back on the map, so the next one (a digit to type a value) lands there too.
    void OnTableKey(object? sender, KeyEventArgs e)
    {
        if (e.Handled || !(_tuner || _lock.IsChecked == true) || _model == null || _item == null || !_views.IsEffectivelyVisible) return;
        var focused = TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement();
        if (focused is TextBox or TableGrid or TableGraph or TableSurface) return;
        if (focused is ComboBox { IsDropDownOpen: true }) return;
        bool arrow = e.Key is Key.Up or Key.Down or Key.Left or Key.Right && (e.KeyModifiers & ~KeyModifiers.Shift) == 0;
        // Space or Enter on a button left with the keyboard would press it again (Connect, Upload...): not while tuning
        bool press = e.Key is Key.Space && focused is Button;
        if (!arrow && !press && TableKeys.Match(e) == null) return;
        if (press) { e.Handled = true; FocusView(); return; }
        if (_views.SelectedIndex == 2 && TableKeys.Match(e) is { } id && _surface.Run(id)) e.Handled = true;
        else _grid.HandleKey(e);
        FocusView();
    }

    /// The keyboard to the view of the map on screen (Table, Line or 3D).
    void FocusView()
    {
        Control view = _views.SelectedIndex switch { 1 => _graph, 2 => _surface, _ => _grid };
        if (view.IsEffectivelyVisible) view.Focus();
    }

    /// Cheap comparison of two heat maps - a plain loop rather than LINQ, because this runs twenty times a second while the simulator is going.
    static bool Same(Dictionary<int, double> a, Dictionary<int, double> b)
    {
        if (a.Count != b.Count) return false;
        foreach (var (k, v) in a)
            if (!b.TryGetValue(k, out var other) || Math.Abs(other - v) >= 0.02) return false;
        return true;
    }

    /// The map on screen follows the cam: VTEC on shows the high-cam copy, off the low one (FollowVtec). True when it switched to the other map.
    bool FollowCam(bool vt)
    {
        if (!FollowVtec || vt == _lastVtec) return false;
        _lastVtec = vt;
        if (_item != null && MapSide.Side(_item) is bool side && side != vt && MapSide.Other(_host.Defs(), _item) is { } other)
        {
            _status.Text = $"VTEC {(vt ? "engaged" : "dropped out")}: following to {other.Name}";
            AppLog.Action("calibration", $"followed the cam crossover to {other.Name}");
            Refresh(other.Name);
            return true;
        }
        return false;
    }

    /// Follow the cam crossover: when the log says VTEC engaged (or dropped out) and the map on screen is the other side's copy, switch to the one the ECU is actually reading.
    public bool FollowVtec { get; set; } = true;
    bool? _lastVtec;

    /// Where the car is now (from a datalog frame): marks that cell of the table on screen.
    public void SetEngineState(LogFrame? f)
    {
        if (f?.Vtec is bool vt && FollowCam(vt)) return;
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
        // the trail: where the engine has been, over the trail time (a jump back in the log, or a long way forward - the
        // slider moved, another log - starts it again)
        if (pos is { } p && _tuner)
        {
            double t = f?.T ?? double.NaN;
            if (double.IsNaN(t) || double.IsNaN(_extLastT) || t < _extLastT || t - _extLastT > 3) _extTrail.Clear();
            _extLastT = t;
            _extTrail.Add((DateTime.UtcNow, p.Item1, p.Item2));
        }
        _model.ExternalTrace = pos;
        if (_tuner) ExternalHeat();
        Redraw();
        LockToTrace();
    }

    readonly List<(DateTime At, double Row, double Col)> _extTrail = [];
    DateTime _lastFade;
    double _extLastT = double.NaN;

    /// Tuner mode: the cells the engine is reading lit, as the simulator lights the ones the ROM reads - the four round it (the ECU interpolates between them) when Live cell is the four, else the nearest one - and the cells it passed through fading behind it over the trail time. True when the map needs drawing again.
    bool ExternalHeat()
    {
        if (_model is not { } m) return false;
        var now = DateTime.UtcNow;
        _extTrail.RemoveAll(t => (now - t.At).TotalSeconds > _trail);
        var heat = new Dictionary<int, double>();
        void Put(int r, int c, double h)
        {
            r = Math.Clamp(r, 0, Math.Max(0, m.Rows - 1)); c = Math.Clamp(c, 0, Math.Max(0, m.Cols - 1));
            int i = (r * m.Cols) + c;
            if (!heat.TryGetValue(i, out var o) || o < h) heat[i] = h;
        }
        foreach (var t in _extTrail)
            Put((int)Math.Round(t.Row), (int)Math.Round(t.Col), 0.7 * (1 - Math.Clamp((now - t.At).TotalSeconds / _trail, 0, 1)));
        if (m.ExternalTrace is { } at && _live.IsChecked == true)
        {
            if (_blendLive)
            {
                var (r0, c0, r1, c1) = Quad(at);
                Put(r0, c0, 1); Put(r0, c1, 1); Put(r1, c0, 1); Put(r1, c1, 1);
            }
            else Put((int)Math.Round(at.Row), (int)Math.Round(at.Col), 1);
        }
        m.TrailPath = [.. _extTrail.Select(t => (t.Row, t.Col, Math.Clamp((now - t.At).TotalSeconds / _trail, 0, 1)))];
        if (Same(heat, m.Heat) && heat.Count > 0) return m.TrailPath.Count > 1;
        m.Heat = heat;
        return true;
    }

    /// What the engine should be running and what the wideband really means (Settings > Targets).
    public TargetMap? TargetLow { get; set; }
    public TargetMap? TargetHigh { get; set; }
    public LookupCurve? WidebandCorrection { get; set; }

    /// Channels available for the overlay (updated as frames come in).
    public void SetOverlayChannels(IEnumerable<string> channels, string preferred)
    {
        _overlayChannels = [.. new[] { "none" }.Concat(channels.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(c => c))];
        _preferredOverlay = preferred;
        // a channel that has gone away (a new log without it) stops being the overlay
        if (_overlayChannel != "none" && !_overlayChannels.Contains(_overlayChannel, StringComparer.OrdinalIgnoreCase)) SetOverlayChannel("none");
    }
    string _preferredOverlay = "afr";

    /// The Tools > Overlay submenu: "none" and every channel the log has, with a tick on the one in use.
    Toolbar.Entry[] OverlayEntries()
    {
        var list = _overlayChannels.Count > 1 ? _overlayChannels : ["none", _preferredOverlay];
        return
        [
            .. list.Distinct(StringComparer.OrdinalIgnoreCase).Select(ch => new Toolbar.Entry(
                ch == "none" ? "" : Toolbar.Log,
                ch == "none" ? "No overlay" : ch,
                ch == "none" ? "Show the map's own values only."
                             : $"Show the average of '{ch}' in every cell the engine sat in, under each cell's value.",
                () => SetOverlayChannel(ch),
                Checked: () => _overlayChannel.Equals(ch, StringComparison.OrdinalIgnoreCase))),
        ];
    }

    void SetOverlayChannel(string channel)
    {
        _overlayChannel = channel;
        _status.Text = channel == "none" ? "overlay off" : $"overlay: {channel}";
        UpdateOverlay();
    }

    DateTime _lastOverlay;
    /// Recompute the overlay from the frames (called now and then while logging).
    public void UpdateOverlay(bool throttle = false)
    {
        if (_model == null || _item == null || !_item.IsTable) return;
        if (throttle && (DateTime.UtcNow - _lastOverlay).TotalMilliseconds < Perf.OverlayMs) return;
        _lastOverlay = DateTime.UtcNow;
        var ch = _overlayChannel;
        if (ch == "none" || OverlayFrames == null) { if (_model.Overlay != null) { _model.Overlay = null; Redraw(); } return; }
        // averaging a channel over every frame of a long log: on another core, the map keeps drawing meanwhile
        if (_overlayBusy) return;
        _overlayBusy = true;
        var (item, model, frames, defs, rom) = (_item, _model, OverlayFrames(), _host.Defs(), _host.RomBytes(0, Bus.RomSize));
        Task.Run(() =>
        {
            try
            {
                var ov = LogOverlay.Compute(defs, rom, item, frames, ch);
                Dispatcher.UIThread.Post(() =>
                {
                    _overlayBusy = false;
                    // still the same map and channel: show it
                    if (!ReferenceEquals(model, _model) || ch != _overlayChannel) return;
                    _model.Overlay = ov.Mean; _model.OverlayCount = ov.Count; _model.OverlayName = ch;
                    Redraw();
                });
            }
            catch (Exception ex) { Dispatcher.UIThread.Post(() => _overlayBusy = false); AppLog.Error("calibration", "overlay failed", ex); }
        });
    }
    bool _overlayBusy;

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
        if (Selected != item) { Selected = item; Refresh(item.Name); }
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
                // a fuel map: let a cell that runs off the top of its range push the column's multiplier up instead of flat-topping (the rest of the column is restated so those values do not move)
                var report = Rescale.WriteWithRollover(_host.Defs(), _host.RomCopy(), item, list, raw);
                if (report.Any)
                {
                    _host.ApplyPatches(report.Patches, $"{item.Name} {what}");
                    if (report.ColumnsRescaled > 0) _status.Text = report.Summary;
                    AppLog.Action("calibration", report.Summary);
                }
                else _nothingChanged = true;
            }
            else
            {
                _host.WriteCells(item, list, raw, what);
                AppLog.Action("calibration", $"{item.Name}: {cells.Count} cell(s) {what}");
            }
        }
        catch (Exception ex) { _status.Text = ex.Message; AppLog.Error("calibration", "write failed", ex); }
        ReloadValues();
        if (_nothingChanged)
        {
            _nothingChanged = false;
            _status.Text = $"{item.Name}: nothing changed - {what} is smaller than one step of this table " +
                           "(a fuel cell steps by its column multiplier; Scale\u2026 > Headroom gives it a finer scale)";
            return;
        }
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
        _model.Values = [.. cells.Select(c => c.Value)];
        _model.Raw = [.. cells.Select(c => c.Raw)];
        Redraw();
    }

    // ------------------------------------------------------------------ emulator

    /// The emulator was disconnected from its menu (a Demon's datalog goes with it).
    public event Action? EmulatorClosed;

    /// Another ROM is being opened: the emulator holds this one, so the link is closed (and not tried again).
    public void DisconnectEmulator()
    {
        _emuWatch.Wanted = false;
        if (!_host.Emulator.Connected) return;
        Task.Run(() =>
        {
            try { CloseEmulator(); } catch (Exception ex) { AppLog.Error("emulator", "disconnect failed", ex); }
            Dispatcher.UIThread.Post(UpdateEmulator);
        });
        AppLog.Action("emulator", "disconnected: another ROM opened");
    }

    void ToggleEmulator()
    {
        if (_busyEmulator) return;
        if (_host.Emulator.Connected)
        {
            _busyEmulator = true;
            _emuButton.IsEnabled = false;
            _emuWatch.Wanted = false;
            Task.Run(() =>
            {
                try { CloseEmulator(); } catch (Exception ex) { AppLog.Error("emulator", "disconnect failed", ex); }
                Dispatcher.UIThread.Post(() => { _busyEmulator = false; _emuButton.IsEnabled = true; UpdateEmulator(); _status.Text = "emulator disconnected: " + _emuPort + " is free"; EmulatorClosed?.Invoke(); });
            });
            AppLog.Action("emulator", "disconnect");
            return;
        }
        // no port set: the last one, but never the one the datalog has open
        var port = EmulatorPort.Length > 0 ? EmulatorPort
                 : MoatesTrace.Ports().LastOrDefault(p => !p.Equals(DatalogPortInUse?.Invoke(), StringComparison.OrdinalIgnoreCase)) ?? "";
        if (port.Length == 0) { _status.Text = "no serial port for the emulator: set it in Settings > Emulator & datalog"; return; }
        _busyEmulator = true;
        _emuButton.IsEnabled = false;
        _status.Text = $"connecting to the emulator on {port} and uploading the ROM…";
        _emuPort = port;
        // identifying the device and writing 32 KB takes a moment: not on the UI thread
        Task.Run(() =>
        {
            string message;
            try
            {
                message = ConnectAndCheck(port, "The emulator is connected");
                AppLog.Action("emulator", "connected and uploaded the ROM on " + port);
                _emuWatch.Wanted = true;
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
    string _emuPort = "";
    readonly LinkSupervisor _emuWatch;
    readonly StatusDot _emuDot = new(), _logDot = new();
    readonly Button _toolsMenu, _emuMenu, _logMenu;
    readonly WrapPanel _bar;
    readonly Control[] _barItems;
    string _statusLogged = "";

    /// The state of the datalog link, for the dot on the Datalogging menu.
    public Func<(LinkState State, string Tip)>? DatalogState { get; set; }

    /// Tuner mode puts Tools, Emulator, Datalogging, Back, Undo and Redo on the main bar beside File (null puts them back here).
    public void MoveBarItems(Panel? into)
    {
        foreach (var c in _barItems) UiStyles.Adopt(c);
        if (into != null) foreach (var c in _barItems) into.Children.Add(c);
        else for (int k = 0; k < _barItems.Length; k++) _bar.Children.Insert(Math.Min(_bar.Children.Count, 1 + k), _barItems[k]);
        _bar.IsVisible = into == null;
    }

    /// A line on the status text beside the Definition bar (the main window's messages, in Tuner mode).
    public void ShowStatus(string text) => _status.Text = text;

    /// The dots on the Emulator and Datalogging menus, kept up to date.
    void UpdateDots()
    {
        _emuDot.State = _emuWatch.State;
        if (DatalogState?.Invoke() is { } d)
        {
            _logDot.State = d.State;
            ToolTip.SetTip(_logMenu, d.Tip);
        }
    }

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
                Refresh(Selected?.Name);
            });
        });
    }

    void EmulatorUpload()
    {
        if (_host.LoadedPath == null) { _status.Text = "nothing is open to upload: open or build a ROM first (Download reads what the emulator has)"; return; }
        EmulatorTask("uploading the ROM to the emulator", _host.EmulatorUploadAll);
    }

    /// Close the emulator's port, after any reconnect the watch has under way (which would otherwise open it again).
    void CloseEmulator() => _emuWatch.Exclusive(() => { _host.EmulatorDisconnect(); return true; });

    /// The serial port the datalog has open, if it has one of its own (so the emulator does not guess it).
    public Func<string?>? DatalogPortInUse { get; set; }
    void EmulatorValidate() => EmulatorTask("checking the emulator against this ROM", () =>
    {
        var message = _host.EmulatorValidate();
        int diff = _host.LastDifferences;
        if (diff > 0 && _host.CanUpload(out _)) Dispatcher.UIThread.Post(() => _ = OfferUpload(diff, "Validate"));
        return message;
    });

    /// Connect, and never overwrite by surprise: with a ROM open, the emulator is read back first; if it already holds that ROM nothing is sent, and if it holds another the user is asked (uploads of edits wait for the answer). With nothing open the emulator keeps what it has. Runs off the UI thread; the question is asked on it.
    string ConnectAndCheck(string port, string context)
    {
        _host.UploadsHeld = true;
        try
        {
            _host.EmulatorConnect(port);
            if (!_host.CanUpload(out _))
            {
                _host.DiscardPendingUploads();
                _host.UploadsHeld = false;
                return $"{_host.EmulatorStatus}: nothing is open here, so the emulator's ROM was left as it is (Download reads it)";
            }
            if (_host.ChecksSumWhileRunning)
                AppLog.Warn("emulator", $"this ROM checks its own checksum while it runs (byte {_host.ChecksumAddress:X4} keeps it right, and goes to the emulator with every change): " +
                                        "a change sent while the engine runs can still land part-way through a pass of the sum, and the ECU resets once (BRK 48h). " +
                                        "For live tuning use a ROM with the check off (the skeleton's ROM checksum check switch, HTS and the tuning ROMs).");
            string sumNote = _host.ChecksSumWhileRunning ? " - note: this ROM checks its own checksum while it runs, so a live change can reset it once (see the Debug page)" : "";
            var (diff, _) = _host.EmulatorCompare();
            if (diff == 0)
            {
                _host.UploadsHeld = false;
                return $"{_host.EmulatorStatus}: the emulator already holds the ROM open here - nothing to upload" + sumNote;
            }
            Dispatcher.UIThread.Post(() => _ = OfferUpload(diff, context));
            return $"{_host.EmulatorStatus}: it holds a different ROM ({diff} bytes differ) - asking whether to upload";
        }
        catch
        {
            _host.UploadsHeld = false;
            throw;
        }
    }

    bool _offering;

    /// The emulator holds a different ROM from the one open here: upload the full ROM over it, keep it, or read it in.
    async Task OfferUpload(int diff, string context)
    {
        if (_offering || !_host.Emulator.Connected) { _host.UploadsHeld = false; return; }
        _offering = true;
        try
        {
            string? answer = TopLevel.GetTopLevel(this) is Window owner
                ? await Dialogs.Ask(owner, "Upload the full ROM?",
                    $"{context}. It holds a different ROM from the one open here ({diff:N0} bytes differ).\n\n" +
                    "Upload the full ROM open here? It replaces everything the emulator holds.\n\n" +
                    "Keep the emulator's leaves it as it is (changes made here are not sent into it); Download it opens the emulator's ROM here instead.",
                    "Upload", "Keep the emulator's", "Download it")
                : null;
            switch (answer)
            {
                case "Upload":
                    _host.UploadsHeld = false;
                    await Task.Run(() => { try { return _host.EmulatorUploadAll(); } catch (Exception ex) { return "emulator: " + ex.Message; } })
                              .ContinueWith(t => Dispatcher.UIThread.Post(() => { _status.Text = t.Result; UpdateEmulator(); }));
                    AppLog.Action("emulator", "asked: upload the full ROM - yes");
                    break;
                case "Download it":
                    _host.DiscardPendingUploads();
                    _host.UploadsHeld = false;
                    AppLog.Action("emulator", "asked: upload the full ROM - no, download the emulator's");
                    EmulatorDownload();
                    break;
                default:
                    _host.DiscardPendingUploads();
                    _host.UploadsHeld = false;
                    _status.Text = "the emulator keeps its own ROM; changes made here are not sent into it (Upload sends the full ROM when you want)";
                    AppLog.Action("emulator", "asked: upload the full ROM - no, keep the emulator's");
                    break;
            }
        }
        finally { _offering = false; }
    }
    void EmulatorDownload() => EmulatorTask("reading the ROM out of the emulator", () =>
    {
        var message = _host.EmulatorDownload(out var path);
        Dispatcher.UIThread.Post(() => OpenDownloaded?.Invoke(path));
        return message;
    });

    /// Download read the emulator's ROM into this .bin: open it (the main window asks about unsaved work first).
    public event Action<string>? OpenDownloaded;

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
        _emuDot.State = _emuWatch.State;
        ToolTip.SetTip(_emuMenu, _emuWatch.State switch
        {
            LinkState.Connected => "Emulator: connected. " + _host.EmulatorStatus,
            LinkState.Reconnecting => $"Emulator: connecting - try {_emuWatch.Attempt} of {LinkSupervisor.Attempts}",
            _ => "Emulator: not connected. Connect it from this menu (the port is set in Settings > Emulator & datalog).",
        });
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
            case "pct": Write(sel, i => m.Values[i] * (1 + (k / 100)), false, $"{(k >= 0 ? "+" : "")}{k}%"); break;
            case "ih":
                if (c1 - c0 < 2) { _status.Text = "select at least three columns to interpolate across"; return; }
                Write(sel, i =>
                {
                    int r = i / m.Cols, c = i % m.Cols;
                    double a = m[r, c0], b = m[r, c1];
                    return a + ((b - a) * (c - c0) / (c1 - c0));
                }, false, "interpolated across");
                break;
            case "iv":
                if (r1 - r0 < 2) { _status.Text = "select at least three rows to interpolate down"; return; }
                Write(sel, i =>
                {
                    int r = i / m.Cols, c = i % m.Cols;
                    double a = m[r0, c], b = m[r1, c];
                    return a + ((b - a) * (r - r0) / (r1 - r0));
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
                                sum += copy[(rr * m.Cols) + cc]; n++;
                            }
                        return sum / n;
                    }, false, "smoothed");
                    break;
                }
        }
    }

    /// The table's right-click menu: everything that can be done to the selected cells, each with its key (as set in Settings > Hot keys).
    ContextMenu TableMenu()
    {
        var menu = new ContextMenu();
        MenuItem Mi(string id, string? text = null, string tip = "")
        {
            var mi = new MenuItem { Header = text ?? id, InputGesture = TableKeys.First(id), IsEnabled = _model != null };
            mi.Click += (_, _) => { if (!_grid.Run(id)) _surface.Run(id); };
            ToolTip.SetTip(mi, tip.Length > 0 ? tip : TableKeys.All.FirstOrDefault(k => k.Id == id)?.What);
            return mi;
        }
        string amount = (_adjust.Text ?? "").Trim();
        string shown = amount.Length > 0 ? $" ({amount})" : "";
        menu.Items.Add(Mi("Edit value", "Edit value…", "Type the new value for the selected cells (r120 raw, +2 / -2 change by, *1.05 multiply)."));
        menu.Items.Add(new Separator());
        foreach (var id in new[] { "Up one step", "Down one step", "Up ten steps", "Down ten steps", "Up 1 %", "Down 1 %", "Up 5 %", "Down 5 %" })
            menu.Items.Add(Mi(id));
        menu.Items.Add(new Separator());
        menu.Items.Add(Mi("Set to the amount", "Set to the amount" + shown, "The amount is the box beside Set above the table."));
        menu.Items.Add(Mi("Add the amount", "Add the amount" + shown));
        menu.Items.Add(Mi("Change by the amount in %", "Change by the amount in %" + shown));
        menu.Items.Add(Mi("Interpolate across"));
        menu.Items.Add(Mi("Interpolate down"));
        menu.Items.Add(Mi("Smooth"));
        menu.Items.Add(new Separator());
        menu.Items.Add(Mi("Copy cells"));
        menu.Items.Add(Mi("Paste cells"));
        menu.Items.Add(Mi("Copy table", "Copy table (with axes)", "The whole table and its axes, to paste into another table or a spreadsheet."));
        menu.Items.Add(Mi("Paste table"));
        menu.Items.Add(Mi("Select all"));
        menu.Items.Add(new Separator());
        menu.Items.Add(Mi("Undo"));
        menu.Items.Add(Mi("Redo"));
        if (_views.SelectedIndex == 2) menu.Items.Add(Mi("Reset the 3D view"));
        menu.Items.Add(new Separator());
        var change = new MenuItem { Header = "Change keys…" };
        change.Click += (_, _) => OpenSettingsPage?.Invoke("Hot keys");
        ToolTip.SetTip(change, "Settings > Hot keys: every table key can be changed there.");
        menu.Items.Add(change);
        return menu;
    }

    /// Open a page of the Settings window (the menu's Change keys…).
    public event Action<string>? OpenSettingsPage;

    /// The feature page on screen, or null when a definition is being edited.
    CalPage? _pageOpen;

    /// Show a feature page (GPO 1, ...) instead of a single definition. The first time a page is opened on a ROM its rows are guessed from the definition names; after that the bindings are the user's, and travel with the definitions.
    void ShowPage(CalPage page)
    {
        _pageOpen = page;
        _item = null; _model = null;
        _grid.Model = null; _graph.Model = null; _surface.Model = null;
        // an HTS 1.15 / HTS120 ROM is bound from the HTS address layout the first time a page is opened (only when a row is still empty, so a ROM whose definitions already carry the bindings is left as it is)
        if (!_layoutApplied)
        {
            _layoutApplied = true;
            try
            {
                var rom = _host.RomCopy();
                var defs = _host.Defs();
                if (HtsLayout.Identify(rom).Layout != HtsLayout.Family.None && CalPage.All().SelectMany(pg => pg.Slots()).Any(sl => CalPage.Bound(defs, sl) == null))
                {
                    int n = _host.EditDefinitions(d => HtsLayout.Apply(d, rom));
                    if (n > 0) _status.Text = $"{HtsLayout.Identify(rom).Name} layout: {n} page row(s) bound";
                }
            }
            catch (Exception ex) { AppLog.Error("calibration", "HTS layout failed", ex); }
        }
        // guessed once per page per ROM: a guess the user then cleared must not come straight back
        if (_guessed.Add(page.Key))
            try
            {
                int n = _host.EditDefinitions(d => CalPage.GuessBindings(d, page));
                if (n > 0) _status.Text = $"{page.Name}: {n} row(s) bound by name - worth checking, they are only guesses";
            }
            catch (Exception ex) { AppLog.Error("calibration", "binding guess failed", ex); }
        var view = new FeaturePageView(_host, page, m => _status.Text = m, item =>
        {
            Remember();
            _pageOpen = null;
            Selected = item;
            Refresh(item.Name);
        }, _validOnly);
        var root = new DockPanel { Margin = new Thickness(8, 0, 4, 4) };
        var def = DefinitionForm(null);
        DockPanel.SetDock(def, Dock.Bottom);
        root.Children.Add(def);
        root.Children.Add(view);
        _detail.Content = root;
    }

    // the pages of modules a skeleton ROM was built without, worked out once per build
    object? _leftOutFor;
    Func<string, bool>? _leftOut;

    /// Show only the pages this ROM has something for (at least one row bound).
    bool _validOnly = true;
    readonly CheckBox _validBox = new() { Content = "Show only valid pages", IsChecked = true, FontSize = 11, Margin = new Thickness(2, 2, 0, 2) };

    /// The favourites of the ROM open now ("item:Name" / "page:key"), kept in the app settings by ROM file name.
    public Func<IReadOnlyList<string>>? GetFavourites;
    public Action<List<string>>? SaveFavourites;
    List<string> Favourites() => [.. GetFavourites?.Invoke() ?? []];

    void SetFavourite(string key, bool on)
    {
        var list = Favourites();
        list.RemoveAll(k => k.Equals(key, StringComparison.OrdinalIgnoreCase));
        if (on) list.Add(key);
        SaveFavourites?.Invoke(list);
        _status.Text = (on ? "added to" : "taken off") + " the favourites: " + key[5..];
        Refresh();
    }

    /// The tree's right-click menu: add, remove, edit and rename definitions, favourites, and the valid-pages filter.
    ContextMenu TreeMenu(object? tag)
    {
        var item = tag as ItemDef;
        var page = tag as CalPage;
        var menu = new ContextMenu();
        MenuItem Mi(string text, string tip, Action run, bool enabled = true)
        {
            var mi = new MenuItem { Header = text, IsEnabled = enabled };
            mi.Click += (_, _) => run();
            ToolTip.SetTip(mi, tip);
            return mi;
        }
        menu.Items.Add(Mi("Add", "Add a new definition at the address in the Definition form (or the selected item's address).", AddNew));
        menu.Items.Add(Mi("Remove", item == null ? "Pick a definition to remove (pages cannot be removed)." : $"Remove {item.Name} from the list (the ROM bytes are not touched).",
                          Delete, item != null));
        menu.Items.Add(Mi("Edit", page != null ? $"Open the {page.Name} page." : item != null ? $"Edit {item.Name} in the Definition form." : "Pick something to edit.",
                          () => EditNode(tag), item != null || page != null));
        menu.Items.Add(Mi("Rename…", item == null ? "Pick a definition to rename." : $"Give {item.Name} another name.", () => Rename(item), item != null));
        var favKey = item != null ? "item:" + item.Name : page != null ? "page:" + page.Key : null;
        if (favKey != null)
        {
            bool isFav = Favourites().Contains(favKey, StringComparer.OrdinalIgnoreCase);
            menu.Items.Add(new Separator());
            menu.Items.Add(Mi(isFav ? "Remove from favourites" : "Add to favourites",
                isFav ? "Take it off the favourites at the top of the list." : "Keep it at the top of the list, in Favourites, whatever its category.",
                () => SetFavourite(favKey, !isFav)));
        }
        menu.Items.Add(new Separator());
        var valid = new MenuItem { Header = (_validOnly ? "✓  " : "") + "Show only valid pages" };
        ToolTip.SetTip(valid, "Hide the feature pages this ROM has nothing for (no row bound to one of its definitions).");
        valid.Click += (_, _) => { _validOnly = !_validOnly; _validBox.IsChecked = _validOnly; };
        menu.Items.Add(valid);
        return menu;
    }

    void EditNode(object? tag)
    {
        switch (tag)
        {
            case CalPage page: ShowPage(page); break;
            case ItemDef it:
                _pageOpen = null; Selected = it; Refresh(it.Name);
                _fName.Focus();
                _status.Text = $"editing {it.Name}: change it in the Definition form below, then Update";
                break;
        }
    }

    async void Rename(ItemDef? item)
    {
        if (item == null || _top() is not Window owner) return;
        var box = new TextBox { Text = item.Name, Width = 260 };
        if (!await Dialogs.Prompt(owner, "Rename", $"A new name for {item.Name} (@{item.Address:X4}).", box)) return;
        var name = (box.Text ?? "").Trim();
        if (name.Length == 0 || name == item.Name) return;
        if (_host.Defs().Items.Any(i => i != item && i.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
        {
            _status.Text = $"there is already a definition called {name}";
            return;
        }
        var old = item.Name;
        _host.EditDefinitions(d => { item.Name = name; return true; });
        Refresh(name);
        _status.Text = $"renamed {old} to {name}";
        AppLog.Action("calibration", $"renamed {old} to {name}");
    }

    /// Pages whose bindings have already been guessed once, so a wrong guess is not put back every time the page is opened.
    readonly HashSet<string> _guessed = [];
    /// The HTS layout has been tried on this ROM.
    bool _layoutApplied;

    // ------------------------------------------------------------------ detail view

    void ShowSelected()
    {
        // another table: the trail was on the last one's axes
        if (_item?.Name != Selected?.Name) { _extTrail.Clear(); _extLastT = double.NaN; }
        _item = Selected;
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
        {
            // two lines at most (all of it on hover), so a long description does not eat the room the map needs on a laptop screen
            var about = item.Description + (item.Origin != null ? $"   ({item.Origin})" : "");
            var aboutText = new TextBlock { Text = about, FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis };
            ToolTip.SetTip(aboutText, about);
            head.Children.Add(aboutText);
        }
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);

        var def = DefinitionForm(item);
        DockPanel.SetDock(def, Dock.Bottom);
        root.Children.Add(def);

        try
        {
            if (item.IsTable && item.Count > 1 && item.Text == null) root.Children.Add(TableEditor(item, formula));
            else root.Children.Add(SettingsForm(item));
        }
        catch (Exception ex) { root.Children.Add(new TextBlock { Text = "cannot read values: " + ex.Message }); }
        _detail.Content = root;
        UpdateOverlay();
        // tuning: a map picked from the list takes the keyboard straight away (not while a box is being typed in - the filter)
        if (_tuner && _model != null && TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement() is not TextBox)
            Dispatcher.UIThread.Post(FocusView, DispatcherPriority.Background);
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
            Values = [.. cells.Select(c => c.Value)], Raw = [.. cells.Select(c => c.Raw)],
            RowAxis = item.RowAxis == null ? [.. Enumerable.Range(0, item.Rows).Select(i => (double)i)] : _host.AxisValues(item.RowAxis, item.Rows),
            ColAxis = item.ColAxis == null ? [.. Enumerable.Range(0, item.Cols).Select(i => (double)i)] : _host.AxisValues(item.ColAxis, item.Cols),
            RowUnit = AxisUnit(item.RowAxis, "row"), ColUnit = AxisUnit(item.ColAxis, "col"),
            Unit = formula.Unit, Decimals = Math.Min(formula.Decimals, 2),
            Heat = _live.IsChecked == true && !_tuner ? _host.TableHeat(item) : [],
        };
        _grid.Model = _model; _graph.Model = _model; _surface.Model = _model;
        // a single row or column is a line, not a surface: no 3D view for it
        bool flat = item.Rows < 2 || item.Cols < 2;
        if (_views.Items[2] is TabItem tab3d)
        {
            tab3d.IsVisible = !flat;
            if (flat && _views.SelectedIndex == 2) _views.SelectedIndex = 1;
        }

        var tools = new WrapPanel { Margin = new Thickness(0, 2, 0, 4) };
        tools.Children.Add(new TextBlock { Text = "Selection:", VerticalAlignment = VerticalAlignment.Center, FontSize = 11, Margin = new Thickness(0, 0, 4, 0) });
        ToolTip.SetTip(_adjust, "Amount used by Set, Add and %.");
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
        tools.Children.Add(Btn("AFR fix\u2026", () => AfrFix(item),
            "The correction the log asks for over the cells selected: how far they ran from target on average, the percentage that closes it (with a gain, " +
            "and a smallest and largest change), and how many of the cells have enough samples to count. Nothing moves until Apply."));
        // the keys are on hover over the Selection label rather than taking a line of their own
        string keys = string.Join("\n", TableGrid.KeyHelp.Select(k => $"{k.Keys}: {k.What}")) + "\nRight-click the table for all of these.";
        ToolTip.SetTip(tools.Children[0], keys);
        // clipped, so on a short screen the tools never draw over the Definition bar below
        var panel = new DockPanel { ClipToBounds = true };
        DockPanel.SetDock(tools, Dock.Top);
        panel.Children.Add(tools);
        // touch screen mode: the keys as big buttons, beside the table
        if (_touchPad != null)
        {
            DockPanel.SetDock(UiStyles.Adopt(_touchPad), Dock.Right);
            _touchPad.IsVisible = TouchMode.On;
            panel.Children.Add(_touchPad);
        }
        panel.Children.Add(UiStyles.Adopt(_views));
        if (_views.SelectedIndex < 0) _views.SelectedIndex = 0;
        return panel;
    }

    /// A single-value setting, on its own. One setting to a page: the one picked in the tree, with its own name, what it is for, the unit it is in and the byte it lives at - and nothing else competing with it. Settings that really are one setting (the bits of a single option byte) stay together, because changing one of those means reading the others. Everything else is where it belongs - in the tree on the left. This used to gather every setting whose address fell in the same sixteen bytes onto one page, which put unrelated things - a vacuum fuel-cut throttle position, a tip-out trim, a lean-protection threshold, an alpha-N crossover - side by side as though they belonged together, and there was no telling which one had been picked.
    Control SettingsForm(ItemDef selected)
    {
        var singles = _items.Where(i => !(i.IsTable && i.Count > 1) || i.Text != null).ToList();
        // the bits of one option byte are one setting seen from several sides: keep them as a set
        var together = singles.Where(i => i != selected && SameByte(i, selected)).OrderBy(i => i.Bit).ToList();
        var page = new StackPanel();

        page.Children.Add(new TextBlock
        {
            Text = together.Count == 0 ? "Setting" : $"Setting  ({together.Count + 1} bits of the byte at 0x{selected.Address:X4})",
            FontWeight = FontWeight.Bold, FontSize = 12, Margin = new Thickness(0, 2, 0, 2),
        });
        page.Children.Add(SettingsGrid([selected, .. together], selected));

        if (selected.Description.Length > 0 || Notes(selected) is { Length: > 0 })
            page.Children.Add(new TextBlock
            {
                Text = string.Join("\n", new[] { selected.Description, Notes(selected) }.Where(x => x.Length > 0)),
                FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 8),
            });

        return new ScrollViewer { Content = page };
    }

    /// Two settings are really one when they are bits of the same ROM byte.
    static bool SameByte(ItemDef a, ItemDef b) =>
        a.Address == b.Address && a.Type == CellType.Bit && b.Type == CellType.Bit;

    string Notes(ItemDef item)
    {
        try { return _host.Defs().Formula(item.Formula).Notes ?? ""; } catch { return ""; }
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
            if (it.Text != null)
            {
                AddTextRow(grid, row++, it, it == selected);
                continue;
            }
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
            // a setting a page offers as a choice (an input, an output, a mode) is the same drop-down here
            var choice = it.Slot == null ? null : CalPage.ForRom(defs).SelectMany(p => p.Groups).SelectMany(g => g.Rows)
                .FirstOrDefault(r => r.Kind == RowKind.Choice && r.Options is { Length: > 0 } && it.HasSlot(r.Slot));
            if (choice != null)
            {
                var options = choice.Options!;
                int RawOf(int i) => choice.Values is { } v && i < v.Length ? v[i] : i;
                int at = choice.Values is { } vals ? Array.IndexOf(vals, (int)c.Raw) : (int)c.Raw;
                var shownOpts = options.ToList();
                if (at < 0 || at >= options.Length) { shownOpts.Add($"(raw {c.Raw:0} - not one of these)"); at = shownOpts.Count - 1; }
                var box = new ComboBox { ItemsSource = shownOpts, SelectedIndex = at, MinWidth = 220, VerticalAlignment = VerticalAlignment.Center };
                box.SelectionChanged += (_, _) =>
                {
                    if (box.SelectedIndex >= 0 && box.SelectedIndex < options.Length) WriteSetting(item, RawOf(box.SelectedIndex), true, Info);
                };
                ToolTip.SetTip(box, $"{choice.Label}: pick one. The stored byte is {(long)c.Raw} (0x{(long)c.Raw:X2}). Changes the running ROM at once.");
                editor = box;
            }
            else if (it.Flag || it.Type == CellType.Bit)
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

    /// A text setting (the watermark): a box for the characters and whether the stored ones are intact.
    void AddTextRow(Grid grid, int row, ItemDef it, bool bold)
    {
        grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
        if (it.Text is "password" or "watermark")
        {
            var label = new TextBlock { Text = it.Name, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 2, 12, 2), FontWeight = bold ? FontWeight.Bold : FontWeight.Normal, FontSize = 12 };
            var editor = it.Text == "password" ? RomPasswordUi.Editor(_host, it, () => _top() as Window, m => _status.Text = m)
                                               : RomPasswordUi.WatermarkEditor(_host, it, () => _top() as Window, m => _status.Text = m);
            Grid.SetRow(label, row); Grid.SetColumn(label, 0); grid.Children.Add(label);
            Grid.SetRow(editor, row); Grid.SetColumn(editor, 1); Grid.SetColumnSpan(editor, 3); grid.Children.Add(editor);
            return;
        }
        bool wm = it.Text == "watermark";
        int len = wm ? WatermarkCodec.Length : it.Count;
        var name = new TextBlock { Text = it.Name, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 2, 12, 2), FontWeight = bold ? FontWeight.Bold : FontWeight.Normal, FontSize = 12 };
        ToolTip.SetTip(name, (it.Description.Length > 0 ? it.Description + "\n" : "") + $"{it.Address:X4}, {it.Count} bytes");
        var box = new TextBox { Width = 190, MaxLength = len, FontFamily = MainWindow.MonoFont };
        var state = new TextBlock { FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
        void Show()
        {
            var bytes = _host.RomBytes(it.Address, it.Count);
            if (wm)
            {
                var (text, intact) = WatermarkCodec.Decode(bytes);
                box.Text = text;
                state.Text = intact ? "intact" : "modified - the check word does not match the text";
                state.Foreground = intact ? null : Brushes.OrangeRed;
            }
            else box.Text = new string([.. bytes.Select(b => b is >= 0x20 and <= 0x7E ? (char)b : ' ')]).TrimEnd();
        }
        void Save()
        {
            var text = box.Text ?? "";
            byte[] bytes = wm ? WatermarkCodec.Encode(text) : [.. text.PadRight(len).Take(len).Select(ch => ch is >= ' ' and <= '~' ? (byte)ch : (byte)'?')];
            var old = _host.RomBytes(it.Address, bytes.Length);
            if (old.AsSpan().SequenceEqual(bytes)) { Show(); return; }
            try
            {
                _host.WriteCells(it, [.. bytes.Select((b, i) => (i, (double)b))], true, $"\"{text}\"");
                _status.Text = $"{it.Name} = \"{text}\" - patched in the running ROM";
                AppLog.Action("calibration", $"{it.Name} = \"{text}\"");
            }
            catch (Exception ex) { _status.Text = ex.Message; }
            Show();
        }
        box.LostFocus += (_, _) => Save();
        box.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) Save(); };
        ToolTip.SetTip(box, wm ? $"Up to {len} characters (printable ASCII). Stored scrambled, with a check word the app keeps right; Enter or leaving the box writes it."
                               : $"Up to {len} characters.");
        Show();
        Grid.SetRow(name, row); Grid.SetColumn(name, 0); grid.Children.Add(name);
        Grid.SetRow(box, row); Grid.SetColumn(box, 1); grid.Children.Add(box);
        Grid.SetRow(state, row); Grid.SetColumn(state, 2); Grid.SetColumnSpan(state, 2); grid.Children.Add(state);
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

        // the form in four titled groups, side by side where there is room
        static Control Pair(Control a, Control b)
        {
            UiStyles.Adopt(a); UiStyles.Adopt(b);
            return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { a, b } };
        }
        static Control Group(string title, params (string Label, Control Editor)[] rows)
        {
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Margin = new Thickness(12, 0, 12, 10) };
            foreach (var (label, editor) in rows)
            {
                UiStyles.Adopt(editor);
                int r = g.RowDefinitions.Count;
                g.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
                var l = new TextBlock { Text = label, FontSize = 11.5, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 3, 12, 3) };
                Grid.SetRow(l, r); g.Children.Add(l);
                editor.Margin = new Thickness(0, 3);
                editor.HorizontalAlignment = HorizontalAlignment.Left;
                Grid.SetRow(editor, r); Grid.SetColumn(editor, 1); g.Children.Add(editor);
            }
            var card = Panels.Card(title, g);
            card.Margin = new Thickness(0, 0, 8, 8);
            card.VerticalAlignment = VerticalAlignment.Top;
            return card;
        }
        var groups = new WrapPanel { Orientation = Orientation.Horizontal };
        groups.Children.Add(Group("What it is", ("Name", _fName), ("Category", _fCategory), ("Description", _fDesc)));
        groups.Children.Add(Group("Where and how it reads", ("Address / label", _fAddr), ("Cell type", _fType), ("Formula", _fFormula),
                                  ("Switch", Pair(_fFlag, _fOn))));
        groups.Children.Add(Group("Shape", ("Rows", _fRows), ("Columns", _fCols), ("Row stride (bytes)", _fStride), ("Column multiplier row", _fScale)));
        groups.Children.Add(Group("Axes", ("Row axis (rpm)", Pair(_fRowAxis, _fRowFormula)), ("Column axis (load)", Pair(_fColAxis, _fColFormula))));
        ToolTip.SetTip(_fOn, "Raw value written when the switch is turned on (usually FF or 01).");

        var form = new StackPanel { Margin = new Thickness(4, 8, 4, 4) };
        form.Children.Add(new TextBlock
        {
            Text = item == null ? "Nothing picked: fill this in and press Add (Tools menu) for a new definition at the address given."
                 : $"{item.Name}  ·  {item.Address:X4}  ·  {(item.IsTable ? $"{item.Rows}×{item.Cols} " : "")}{item.Type}  ·  {item.Formula ?? "raw"}",
            FontSize = 12.5, FontWeight = FontWeight.SemiBold, Margin = new Thickness(2, 0, 0, 8), Foreground = DataList.Label,
        });
        form.Children.Add(groups);
        if (item != null)
        {
            var apply = Btn("✔  Apply", () => Apply(item), "Save the edited definition (name, address, type, size, axes, formula...).");
            apply.Padding = new Thickness(18, 5); apply.FontWeight = FontWeight.SemiBold;
            apply.Background = new SolidColorBrush(Color.FromArgb(70, DarkChrome.Accent.R, DarkChrome.Accent.G, DarkChrome.Accent.B));
            var revert = Btn("Revert", () => Refresh(item.Name), "Put the form back to the definition as it is saved.");
            revert.Padding = new Thickness(12, 5);
            form.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 2, 0, 4), Children = { apply, revert } });
        }
        // the page's messages live on the Definition bar, out of the toolbar's way
        UiStyles.Adopt(_status);
        var header = new DockPanel { LastChildFill = true };
        var title = new TextBlock { Text = "⚙  Definition", FontSize = 12.5, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0) };
        DockPanel.SetDock(title, Dock.Left);
        header.Children.Add(title);
        header.Children.Add(_status);
        bool wasOpen = _defExpander.Content != null && _defExpander.IsExpanded;
        _defExpander.Header = header;
        _defExpander.Content = new ScrollViewer { Content = form, MaxHeight = 420, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
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
        Selected = item;
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
        if (!TryAddress(_fAddr.Text ?? "", out var addr)) addr = Selected?.Address ?? 0;
        string name = string.IsNullOrWhiteSpace(_fName.Text) || defs.Items.Any(i => i.Name == _fName.Text) ? $"item_{addr:X4}" : _fName.Text!.Trim();
        var item = new ItemDef { Name = name, Address = addr, Type = CellType.U8, Formula = "raw", Category = "User", Origin = "user" };
        _host.EditDefinitions(d => { d.Items.Add(item); return 0; });
        Selected = item;
        Refresh(item.Name);
        _status.Text = $"added {item.Name} at {addr:X4}; open Definition to set its type, size, axes and formula, then Apply";
        AppLog.Action("calibration", $"added definition {item.Name} at {addr:X4}");
    }

    void Delete()
    {
        if (Selected is not { } item) return;
        _host.EditDefinitions(d => d.Items.Remove(item));
        Selected = null;
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
        var from = _item.Name;
        Remember();
        Refresh(existing.Name);
        _grid.SelectCell(0, Math.Clamp(index, 0, Math.Max(0, existing.Cols - 1)));
        _status.Text = $"{existing.Name}: breakpoint {index} - edit it here, then Back to {from} to see the map against it";
    }

    /// Where a button took the editor from (a page, or a definition), newest last: Back walks it back one step at a time, all the way to where it started.
    readonly Stack<(CalPage? Page, string? Item)> _history = new();
    readonly Button? _back;

    /// Note the place on screen before a button moves away from it.
    void Remember()
    {
        if (_pageOpen != null) _history.Push((_pageOpen, null));
        else if (_item != null) _history.Push((null, _item.Name));
        else return;
        _back?.IsEnabled = true;
    }

    void GoBack()
    {
        if (_history.Count == 0) { _back?.IsEnabled = false; return; }
        var (page, name) = _history.Pop();
        _back?.IsEnabled = _history.Count > 0;
        if (page != null)
        {
            ShowPage(page);
            _status.Text = $"back to {page.Name}";
        }
        else if (name != null)
        {
            _pageOpen = null;
            Refresh(name);
            _status.Text = $"back to {name}";
        }
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
        await Dialogs.ShowModal(w, owner);
        if (w.Applied) { Refresh(Selected?.Name); UpdateOverlay(); _status.Text = "the log's offsets were applied - Undo puts them back"; }
    }

    /// The injector calibration: stock and fitted size, the multiplier that follows, the injector offset and the fuel trims.
    async void OpenInjectors()
    {
        if (_top() is not Window owner) return;
        var w = new InjectorWindow(_host);
        await Dialogs.ShowModal(w, owner);
        if (w.Applied) { Refresh(Selected?.Name); _status.Text = "injector calibration applied - Undo puts it all back in one step"; }
    }

    /// The code patches in the feature file, against the loaded ROM.
    async void OpenFeatures()
    {
        if (_top() is not Window owner) return;
        var w = new FeaturePatchWindow(_host);
        await Dialogs.ShowModal(w, owner);
        if (w.Changed) { Refresh(Selected?.Name); _status.Text = "feature patches changed - Undo takes each one back"; }
    }

    /// The MAP sensor: which one is fitted, and the load breakpoints moved to suit it.
    async void OpenMapSensor()
    {
        if (_top() is not Window owner) return;
        var w = new MapSensorWindow(_host);
        await Dialogs.ShowModal(w, owner);
        if (w.Applied) { Refresh(Selected?.Name); _status.Text = "MAP sensor applied - Undo puts it all back in one step"; }
    }

    /// The AFR correction over the selected cells, worked out from the log the way the established tuning software does it.
    async void AfrFix(ItemDef? item)
    {
        if (_top() is not Window owner || item == null || _model == null) return;
        var sel = _grid.Selection();
        if (sel.Count == 0) { _status.Text = "select the cells to correct first"; return; }
        if (_model.Overlay == null)
        {
            _status.Text = "pick an AFR or lambda overlay first (Tools > Overlay), so there is something to correct against";
            return;
        }
        var w = new AfrFixWindow(item.Name, _model.OverlayName, sel,
                                 [.. sel.Select(i => _model.Overlay[i])],
                                 [.. sel.Select(i => _model.OverlayCount is { } c && i < c.Length ? c[i] : 0)],
                                 TargetLow, TargetHigh, _host.Defs(), _host.RomCopy(), item, MapSide.Side(item) == true);
        await Dialogs.ShowModal(w, owner);
        if (w.Result is not { } fix) { _status.Text = "AFR fix cancelled"; return; }
        var cells = fix.Cells;
        if (cells.Count == 0) { _status.Text = "no selected cell has enough samples to correct"; return; }
        Write(cells, i => _model.Values[i] * (1 + (fix.Percent(i) / 100)), false, fix.What);
        _status.Text = $"{cells.Count} cell(s) corrected: {fix.What}";
    }

    /// Open the scaling tools on the table on screen, and redraw if anything was applied.
    async void ScaleTools(ItemDef? item)
    {
        if (_top() is not Window owner) return;
        var w = new ScaleWindow(_host, item);
        await Dialogs.ShowModal(w, owner);
        if (w.Applied) { Refresh(Selected?.Name); _status.Text = "scaled - Undo puts it all back in one step"; }
    }

    // ------------------------------------------------------------------ detect

    async void Detect() => await DetectAsync();

    /// Run Detect on the ROM loaded now (after a build): finds its tables and settings and adds them to the definitions.
    public async Task DetectAsync()
    {
        var asm = _host.Assembly;
        if (asm == null) { _status.Text = "build first: Detect needs the assembled symbols"; return; }
        try
        {
            // the known ROMs of the same family (loaded once, a few seconds the first time): their tables are found in this one first
            _status.Text = "Detect: lining the code up with the known ROMs…";
            var loaded = _host.LoadedPath;
            var refs = await Task.Run(() => RomReference.ShippedFor(loaded));
            var rom = _host.RomBytes(0, Bus.RomSize);
            // only the files this ROM was built from: another ROM may still be open in a tab
            var built = asm.SourceMap.Select(e => e.File).Distinct().ToHashSet(StringComparer.OrdinalIgnoreCase);
            var sources = _sources().Where(x => { try { return built.Contains(Path.GetFullPath(x.Path)); } catch { return false; } }).ToList();
            if (sources.Count == 0) sources = [.. _sources()];
            var r = await Task.Run(() => _host.EditDefinitions(defs => CalibrationDetector.Detect(defs, asm, rom, sources, refs)));
            Refresh();
            _status.Text = "Detect: " + r.Summary + (r.Added + r.Replaced > 0 ? " - check types and formulas" : "");
            AppLog.Action("calibration", "Detect: " + r.Summary);
        }
        catch (Exception ex) { _status.Text = "Detect failed: " + ex.Message; AppLog.Error("calibration", "Detect failed", ex); }
    }

    // ------------------------------------------------------------------ files

    async void ImportMaps()
    {
        if (_host.LoadedPath == null) { _status.Text = "open (or build) the ROM to import into first"; return; }
        var w = new ImportMapsWindow(_host, DetectAsync);
        w.Imported += () => Dispatcher.UIThread.Post(() => Refresh(Selected?.Name));
        AppLog.Action("calibration", "import maps");
        if (TopLevel.GetTopLevel(this) is Window owner) await w.ShowDialog(owner); else w.Show();
    }

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
                Items = [.. defs.Items.OrderBy(i => i.Address)],
                Formulas = [.. defs.Formulas.Where(f => used.Contains(f.Name))],
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
            var layout = XdfExport.Layout.Reference;
            if (top is Window layoutOwner)
            {
                var pick = await Dialogs.Ask(layoutOwner, "How much should the XDF carry?",
                    "Just the maps: the same handful of elements as the XDFs written for these ECUs that are known to work - a title, " +
                    "the two axes and the data, and nothing else. If TunerPro has been reading a file from here oddly, this is the one " +
                    "to use; there is nothing in it for a TunerPro build to disagree about.\n\n" +
                    "With notes: the same, plus categories down the side, a description on every item saying where it came from and how " +
                    "the ROM really scales it, and each fuel map's per-column multiplier row as a table of its own. Easier to read, but " +
                    "more elements that a given TunerPro build has to agree with.",
                    "Just the maps", "With notes", "Cancel");
                if (pick == "Cancel" || pick == null) { _status.Text = "XDF export cancelled"; return; }
                if (pick == "With notes") layout = XdfExport.Layout.Annotated;
            }
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
            // these maps keep more bytes per row than they use; how TunerPro should be told about that is the one thing the known-good files do not settle, so ask
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
            File.WriteAllText(path, XdfExport.Write(defs, _host.RomBytes(0, Bus.RomSize), Path.GetFileNameWithoutExtension(path), stride, values, layout));
            _status.Text = $"wrote {path}: {defs.Items.Count} definitions for TunerPro " +
                           $"({(layout == XdfExport.Layout.Reference ? "maps only" : "with notes and categories")}; open it with the matching .bin)";
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
