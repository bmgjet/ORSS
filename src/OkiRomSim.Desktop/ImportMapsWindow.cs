// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;
using OkiRomSim.Mcp;

namespace OkiRomSim.Desktop;

/// Tools > Import maps: open another ROM (a .bin of any family the app knows, or a source), see what maps and settings it has, and bring the ones picked into the ROM that is open - a tune's fuel and ignition into a new ROM built from the skeleton, say. Each of the other ROM's tables is paired with this ROM's table that does the same job (the same page row, the same name, or a fuel / ignition / VE map for the same cam); values move in real units, and a table of another size or with other breakpoints goes in the way picked for it: by breakpoints, stretched end to end, or cell for cell. The preview draws the three tables - the other ROM's, this ROM's now and after - in the same Table, Line and 3D views the Calibration page has. Everything imported is one undo step.
public sealed class ImportMapsWindow : Window
{
    readonly SimHost _host;
    readonly Func<Task>? _detectHere;
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly StackPanel _list = new() { Spacing = 1 };
    readonly CheckBox _mapsOnly = new() { Content = "Maps only", IsChecked = true };
    readonly CheckBox _axes = new() { Content = "Bring the axes across too", IsChecked = false };
    readonly TextBox _filter = new() { Watermark = "filter", Width = 160 };
    readonly Button _import = new() { Content = "Import ticked…", IsEnabled = false, MinWidth = 120 };
    readonly Button _detectBtn = new() { Content = "Detect this ROM's maps first", IsVisible = false };

    // the preview
    readonly TextBlock _selTitle = new() { FontWeight = FontWeight.SemiBold, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _note = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.85, Margin = new Thickness(0, 2, 0, 4) };
    readonly ToggleButton[] _viewBtns = [new() { Content = "Table" }, new() { Content = "Line" }, new() { Content = "3D" }];
    readonly ToggleButton _stretch = new() { Content = "⤢ Stretch", IsChecked = true };
    readonly ComboBox _scale = new() { MinWidth = 180, FontSize = 11.5 };
    readonly StackPanel _scaleRow = new() { Orientation = Orientation.Horizontal, Spacing = 6, IsVisible = false };
    readonly Pane _paneFrom = new("FROM"), _paneNow = new("THIS ROM NOW"), _paneAfter = new("AFTER THE IMPORT");
    readonly ToggleButton[] _showBtns = [new() { Content = "From" }, new() { Content = "Now" }, new() { Content = "After" }];
    readonly Grid _panes = new() { RowDefinitions = new RowDefinitions("*,*,*") };
    int _view;
    bool _settingScale;

    Source? _src;
    readonly List<Row> _rows = [];
    Row? _selected;

    sealed record Source(string Path, byte[] Rom, DefinitionSet Defs, string Kind);

    sealed class Row
    {
        public required MapImport.Pairing Pair;
        public ItemDef? To;
        public required CheckBox Tick;
        public required ComboBox Target;
        public required Control View;
        /// How it goes in when the two tables differ in size or breakpoints; null until picked (or worked out).
        public MapImport.Scaling? Scale;
    }

    static readonly string Leave = "(leave it)";
    static readonly (MapImport.Scaling Mode, string Text, string Tip)[] Scalings =
    [
        (MapImport.Scaling.Breakpoints, "Match the breakpoints",
            "Each cell here takes the other table's value at this cell's rpm and load (straight lines between its points, the ends held): the engine sees the same numbers at the same rpm and load. Needs both tables' axes, in the same units."),
        (MapImport.Scaling.Stretch, "Stretch end to end",
            "The other table stretched (or squeezed) over this one, first row and column to first, last to last, whatever the breakpoints say."),
        (MapImport.Scaling.Direct, "Direct: cell for cell",
            "Cell for cell from the top left corner, whatever the breakpoints say. Cells this table has beyond the other's are left as they are."),
    ];

    public ImportMapsWindow(SimHost host, Func<Task>? detectHere = null)
    {
        _host = host; _detectHere = detectHere;
        Title = "Import maps";
        Width = 1280; Height = 820; MinWidth = 700; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Import maps");

        var open = new Button { Content = "Open another ROM…" };
        ToolTip.SetTip(open, "A .bin of any ROM the app knows (stock, HTS, the other tuners' ROMs, a skeleton build) or a source .asm. It is read, not opened: the ROM you have open stays as it is until you import.");
        open.Click += async (_, _) => await OpenSource();
        _detectBtn.Click += async (_, _) =>
        {
            if (_detectHere == null) return;
            _detectBtn.IsEnabled = false;
            await _detectHere();
            _detectBtn.IsEnabled = true;
            Pair();
        };
        ToolTip.SetTip(_detectBtn, "This ROM's maps are not defined yet, so nothing can be paired with them: run Detect on it (as Tools > Detect does).");
        ToolTip.SetTip(_mapsOnly, "Show only the maps (fuel, ignition, VE...). Off: every table and setting found, to pick from by hand.");
        ToolTip.SetTip(_axes, "Also write the other ROM's rpm and load breakpoints into this ROM's axes (when they have as many points), so the " +
                              "maps arrive exactly rather than resampled. Honda maps share their axes: every map here that uses the same axis " +
                              "then sits against the new breakpoints too - the preview names them.");
        _mapsOnly.IsCheckedChanged += (_, _) => Fill();
        _axes.IsCheckedChanged += (_, _) => ShowPreview();
        _filter.TextChanged += (_, _) => Fill();
        var bar = new WrapPanel { Margin = new Thickness(8, 6) };
        bar.Children.Add(open);
        foreach (var c in new Control[] { _mapsOnly, _axes, _filter, _detectBtn }) { c.Margin = new Thickness(12, 0, 0, 0); c.VerticalAlignment = VerticalAlignment.Center; bar.Children.Add(c); }

        var split = new Grid { ColumnDefinitions = new ColumnDefinitions("1*,4,2*"), Margin = new Thickness(8, 0) };
        split.ColumnDefinitions[0].MinWidth = 250; split.ColumnDefinitions[0].MaxWidth = 520;
        var listScroll = new ScrollViewer { Content = _list };
        Grid.SetColumn(listScroll, 0); split.Children.Add(listScroll);
        var gs = new GridSplitter { Width = 4 }; Grid.SetColumn(gs, 1); split.Children.Add(gs);
        var preview = BuildPreview();
        Grid.SetColumn(preview, 2); split.Children.Add(preview);

        _import.Click += async (_, _) => await ImportTicked();
        ToolTip.SetTip(_import, "Write the ticked tables into the ROM that is open, as one undo step (asks first).");
        var close = new Button { Content = "Close", IsCancel = true, MinWidth = 90 };
        close.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 6, Margin = new Thickness(8) };
        buttons.Children.Add(_import); buttons.Children.Add(close);

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*,Auto") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(bar, 1); g.Children.Add(bar);
        Grid.SetRow(_status, 2); g.Children.Add(_status);
        _status.Margin = new Thickness(10, 0, 10, 6);
        Grid.SetRow(split, 3); g.Children.Add(split);
        Grid.SetRow(buttons, 4); g.Children.Add(buttons);
        Content = g;
        _status.Text = "Open the ROM to take maps from. The app works out what it is and finds its maps; nothing changes here until you import.";
        _selTitle.Text = "Pick a table on the left to see it, this ROM's as it is, and what it would become.";
        Opened += (_, _) => CompareWindow.FitToScreen(this);
    }

    /// The right-hand side: the table's name and the view to draw it in, then the three tables one above the other.
    Control BuildPreview()
    {
        for (int k = 0; k < _viewBtns.Length; k++)
        {
            int view = k;
            var b = _viewBtns[k];
            b.FontSize = 11.5; b.Padding = new Thickness(10, 2); b.MinHeight = 0;
            b.IsChecked = k == 0;
            b.Click += (_, _) => { _view = view; for (int j = 0; j < _viewBtns.Length; j++) _viewBtns[j].IsChecked = j == view; ShowPanes(); };
        }
        ToolTip.SetTip(_viewBtns[0], "The cells with their axes, coloured by value. Hover over a cell for everything about it.");
        ToolTip.SetTip(_viewBtns[1], "Every row as a line.");
        ToolTip.SetTip(_viewBtns[2], "The whole map as a surface: right-drag to turn it, wheel to zoom.");
        _stretch.FontSize = 11.5; _stretch.Padding = new Thickness(10, 2); _stretch.MinHeight = 0;
        _stretch.IsCheckedChanged += (_, _) => ShowPanes();
        ToolTip.SetTip(_stretch, "Stretch each table to fill its panel, so the whole of it is on screen with its numbers as big as the panel allows. Off: the normal size, scrolled.");
        _scale.ItemsSource = Scalings.Select(s => s.Text).ToList();
        _scale.SelectionChanged += (_, _) =>
        {
            if (_settingScale || _selected == null || _scale.SelectedIndex < 0) return;
            _selected.Scale = Scalings[_scale.SelectedIndex].Mode;
            ShowPreview();
        };
        ToolTip.SetTip(_scale, string.Join("\n\n", Scalings.Select(s => $"{s.Text}: {s.Tip}")));
        _scaleRow.Children.Add(new TextBlock { Text = "Size / breakpoints differ:", VerticalAlignment = VerticalAlignment.Center, FontSize = 11.5, Opacity = 0.85 });
        _scaleRow.Children.Add(_scale);

        // which of the three to show: the ones left fill the room
        var paneList = new[] { _paneFrom, _paneNow, _paneAfter };
        string[] showTips =
        [
            "The other ROM's table, as it is there.",
            "This ROM's table as it is now.",
            "This ROM's table as the import would leave it: the cells it changes are marked in their corner, and hovering over one says what it was.",
        ];
        for (int k = 0; k < _showBtns.Length; k++)
        {
            int at = k;
            var b = _showBtns[k];
            b.FontSize = 11.5; b.Padding = new Thickness(10, 2); b.MinHeight = 0;
            // the other ROM's and the result to start with (the result's tip says what each cell was): room for the numbers
            b.IsChecked = k != 1;
            paneList[k].IsVisible = k != 1;
            _panes.RowDefinitions[k].Height = k != 1 ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
            ToolTip.SetTip(b, "Show or hide: " + showTips[k]);
            b.IsCheckedChanged += (_, _) =>
            {
                // at least one of them stays
                if (_showBtns.All(x => x.IsChecked != true)) { b.IsChecked = true; return; }
                bool on = b.IsChecked == true;
                paneList[at].IsVisible = on;
                _panes.RowDefinitions[at].Height = on ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
            };
        }
        var tools = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        foreach (var b in _showBtns) { b.Margin = new Thickness(0, 0, 2, 2); tools.Children.Add(b); }
        tools.Children.Add(new Border { Width = 12 });
        foreach (var b in _viewBtns) { b.Margin = new Thickness(0, 0, 2, 2); tools.Children.Add(b); }
        _stretch.Margin = new Thickness(10, 0, 14, 2); tools.Children.Add(_stretch);
        _scaleRow.Margin = new Thickness(0, 0, 0, 2); tools.Children.Add(_scaleRow);

        var head = new StackPanel { Margin = new Thickness(0, 0, 0, 2) };
        head.Children.Add(_selTitle);
        head.Children.Add(tools);
        head.Children.Add(_note);

        int row = 0;
        foreach (var p in paneList) { Grid.SetRow(p, row++); _panes.Children.Add(p); }
        var dock = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        dock.Children.Add(head);
        dock.Children.Add(_panes);
        return dock;
    }

    async Task OpenSource()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "The ROM to take maps from",
            AllowMultiple = false,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("ROM image or source") { Patterns = new[] { "*.bin", "*.rom", "*.asm" } },
                new FilePickerFileType("All files") { Patterns = new[] { "*" } },
            },
        });
        if (files.FirstOrDefault()?.TryGetLocalPath() is not { } path) return;
        await OpenPath(path);
    }

    /// Read another ROM by its path (Open another ROM..., or the UI check).
    public async Task OpenPath(string path)
    {
        byte[]? image = null;
        if (!path.EndsWith(".asm", StringComparison.OrdinalIgnoreCase))
        {
            var bytes = await File.ReadAllBytesAsync(path);
            // a 64 KB (512) chip image holds two ROMs: the half the ECU runs
            if (bytes.Length == Bus.RomSize * 2)
            {
                bool lowBlank = bytes[..Bus.RomSize].All(b => b == 0xFF) || bytes[..Bus.RomSize].All(b => b == 0);
                var pick = lowBlank ? "Upper half" : await Dialogs.Ask(this, "64 KB image",
                    $"{Path.GetFileName(path)} holds two 32 KB ROMs. Which one has the maps you want?", "Cancel", "Lower half", "Upper half");
                if (pick is null or "Cancel") return;
                image = pick == "Upper half" ? bytes[Bus.RomSize..] : bytes[..Bus.RomSize];
            }
            else if (bytes.Length > Bus.RomSize + 1) { _status.Text = $"{Path.GetFileName(path)} is {bytes.Length} bytes: not a ROM image this app reads"; return; }
        }
        _status.Text = $"reading {Path.GetFileName(path)}: working out what it is and finding its maps…";
        _list.Children.Clear(); _rows.Clear(); _src = null; _import.IsEnabled = false;
        try
        {
            _src = await Task.Run(() => Load(path, image));
            AppLog.Action("import maps", $"read {path}: {_src.Kind}, {_src.Defs.Items.Count} definitions");
            Pair();
        }
        catch (Exception ex)
        {
            _status.Text = $"could not read {Path.GetFileName(path)}: {ex.Message}";
            AppLog.Error("import maps", "reading the source failed", ex);
        }
    }

    /// The other ROM, disassembled if it is a .bin, and its maps found the way Detect finds them (or its definitions file).
    static Source Load(string path, byte[]? image)
    {
        var p = image != null ? Program66k.FromImage(image, path) : Program66k.Load(path);
        var rom = p.Image;
        var side = Path.ChangeExtension(path, null) + ".okidef.json";
        DefinitionSet defs;
        string how;
        if (File.Exists(side))
        {
            defs = DefinitionSet.Load(side);
            defs.MergeBuiltinFormulas();
            how = "names and tables from " + Path.GetFileName(side);
        }
        else
        {
            defs = p.Asm != null ? DefinitionBuilder.FromAssembly(p.Asm, Path.GetFileNameWithoutExtension(path)) : new DefinitionSet();
            defs.MergeBuiltinFormulas();
            string found = "";
            if (p.Asm != null)
                found = CalibrationDetector.Detect(defs, p.Asm, rom, p.Sources.Select(kv => (kv.Key, string.Join("\n", kv.Value))), RomReference.ShippedFor(path)).Summary;
            if (HtsLayout.Identify(rom).Layout != HtsLayout.Family.None) HtsLayout.Apply(defs, rom);
            how = found;
        }
        var kind = HtsLayout.Describe(rom);
        return new Source(path, rom, defs, (kind.Length > 0 ? kind : "a ROM") + (how.Length > 0 ? $" ({how})" : ""));
    }

    /// Pair the other ROM's tables with this one's, and list them.
    void Pair()
    {
        if (_src == null) return;
        var here = _host.Defs();
        bool noMaps = !here.Items.Any(i => i.IsTable && i.Rows > 1 && i.Cols > 1);
        _detectBtn.IsVisible = noMaps && _detectHere != null;
        var pairs = MapImport.Pair(_src.Defs, here);
        _rows.Clear();
        foreach (var p in pairs.OrderByDescending(p => p.From.IsTable && p.From.Rows > 1 && p.From.Cols > 1).ThenByDescending(p => p.Score).ThenBy(p => p.From.Category).ThenBy(p => p.From.Name))
        {
            var tick = new CheckBox { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) };
            var target = new ComboBox { MinWidth = 170, MaxWidth = 220, FontSize = 11.5 };
            var row = new Row { Pair = p, To = p.To, Tick = tick, Target = target, View = new Border() };
            // the likely ones first; the list is made when it is opened (hundreds of rows, each with hundreds of choices)
            target.ItemsSource = new[] { p.To != null ? Label(p.To) : Leave };
            target.SelectedIndex = 0;
            target.DropDownOpened += (_, _) =>
            {
                if (target.ItemCount > 1) return;
                var cands = MapImport.Candidates(p.From, _host.Defs());
                var items = new List<string> { Leave };
                items.AddRange(cands.Select(Label));
                var now = row.To != null ? Label(row.To) : Leave;
                target.ItemsSource = items;
                target.SelectedItem = now;
            };
            target.SelectionChanged += (_, _) =>
            {
                if (target.SelectedItem is not string s) return;
                var to = s == Leave ? null : _host.Defs().Items.FirstOrDefault(i => Label(i) == s);
                if (to == row.To) return;
                row.To = to;
                row.Scale = null;       // another table: its own way in
                tick.IsChecked = to != null;
                if (_selected == row) ShowPreview();
                UpdateImport();
            };
            // ticked to start with: the maps with a sure partner here
            tick.IsChecked = p.To != null && p.Score >= 70 && p.From.IsTable && p.From.Rows > 1 && p.From.Cols > 1;
            tick.IsCheckedChanged += (_, _) => UpdateImport();
            var name = new TextBlock { Text = Label(p.From), FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
            var why = new TextBlock { Text = p.To != null ? "→ " + p.Why : "no partner found here: pick one, or leave it", FontSize = 10.5, Opacity = 0.75, TextTrimming = TextTrimming.CharacterEllipsis };
            var left = new StackPanel();
            left.Children.Add(name); left.Children.Add(why);
            var pickArea = new Button { Content = left, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(6, 2), Background = Brushes.Transparent };
            pickArea.Click += (_, _) => Select(row);
            ToolTip.SetTip(pickArea, $"{p.From.Category}: {p.From.Description}");
            var line = new DockPanel { Margin = new Thickness(0, 1) };
            DockPanel.SetDock(tick, Dock.Left); line.Children.Add(tick);
            DockPanel.SetDock(target, Dock.Right); line.Children.Add(target);
            line.Children.Add(pickArea);
            row.View = line;
            _rows.Add(row);
        }
        int maps = pairs.Count(p => p.From.IsTable && p.From.Rows > 1 && p.From.Cols > 1);
        int paired = pairs.Count(p => p.To != null && p.From.IsTable && p.From.Rows > 1 && p.From.Cols > 1);
        _status.Text = $"{Path.GetFileName(_src.Path)}: {_src.Kind}. {maps} map(s) and {pairs.Count - maps} other table(s) and setting(s); " +
                       $"{paired} map(s) paired with this ROM's." + (noMaps ? " This ROM's maps are not defined yet - Detect them first." : " Tick what to bring across, and check each on the right.");
        Fill();
        UpdateImport();
        if (_rows.FirstOrDefault(r => r.Tick.IsChecked == true) is { } first) Select(first);
    }

    void Select(Row row)
    {
        if (_selected?.View is DockPanel was) was.Background = null;
        _selected = row;
        if (row.View is DockPanel now) now.Background = new SolidColorBrush(Color.FromArgb(50, 0x5a, 0x8c, 0xff));
        ShowPreview();
    }

    static string Label(ItemDef i) => i.IsTable ? $"{i.Name}  {i.Rows}x{i.Cols}" : i.Name;

    void Fill()
    {
        _list.Children.Clear();
        var f = (_filter.Text ?? "").Trim();
        foreach (var r in _rows)
        {
            var i = r.Pair.From;
            if (_mapsOnly.IsChecked == true && !(i.IsTable && i.Rows > 1 && i.Cols > 1)) continue;
            if (f.Length > 0 && !(i.Name.Contains(f, StringComparison.OrdinalIgnoreCase) || i.Category.Contains(f, StringComparison.OrdinalIgnoreCase))) continue;
            _list.Children.Add(r.View);
        }
        if (_list.Children.Count == 0 && _src != null) _list.Children.Add(new TextBlock { Text = "nothing to show (untick Maps only, or clear the filter)", Opacity = 0.7, Margin = new Thickness(6) });
    }

    void UpdateImport() => _import.IsEnabled = _rows.Any(r => r.Tick.IsChecked == true && r.To != null);

    /// One table into the worked copy, the way picked for it. Not picked yet: by breakpoints when that can be done (both tables have axes, in the same units), else stretched end to end - and that becomes the row's choice.
    MapImport.Result Run(Row row, DefinitionSet here, byte[] work)
    {
        var mode = row.Scale ?? MapImport.Scaling.Breakpoints;
        var trial = (byte[])work.Clone();
        var r = MapImport.Apply(_src!.Defs, _src.Rom, row.Pair.From, here, trial, row.To!, _axes.IsChecked == true, mode);
        if (!r.Ok && row.Scale == null)
        {
            trial = (byte[])work.Clone();
            var s = MapImport.Apply(_src.Defs, _src.Rom, row.Pair.From, here, trial, row.To!, _axes.IsChecked == true, MapImport.Scaling.Stretch);
            if (s.Ok) { row.Scale = MapImport.Scaling.Stretch; r = s with { Note = "the breakpoints cannot be matched, so stretched end to end: " + s.Note }; }
        }
        else row.Scale ??= mode;
        if (r.Ok) Array.Copy(trial, work, work.Length);
        return r;
    }

    /// The selected table: the other ROM's, and this ROM's as it is and as it would be, drawn as the Calibration page draws them.
    void ShowPreview()
    {
        if (_src == null || _selected == null) return;
        var from = _selected.Pair.From;
        var here = _host.Defs();
        _selTitle.Text = _selected.To is { } t ? $"{Label(from)}   →   {Label(t)}" : Label(from);
        _paneFrom.Title.Text = "FROM " + Path.GetFileName(_src.Path) + "   " + Label(from);
        _paneFrom.Model = Safe(() => TableModel.From(_src.Defs, _src.Rom, from), out var whyFrom);
        _paneFrom.Message = whyFrom;
        if (_selected.To is not { } to)
        {
            _note.Text = "No table here chosen for it: pick one on the right of its row.";
            _scaleRow.IsVisible = false;
            _paneNow.Model = _paneAfter.Model = null;
            _paneNow.Message = _paneAfter.Message = "";
            ShowPanes();
            return;
        }
        var now = _host.RomCopy();
        var work = (byte[])now.Clone();
        bool differ = !MapImport.SameLayout(_src.Defs, _src.Rom, from, here, now, to);
        var r = Run(_selected, here, work);
        _scaleRow.IsVisible = differ;
        _settingScale = true;
        _scale.SelectedIndex = Array.FindIndex(Scalings, s => s.Mode == (_selected.Scale ?? MapImport.Scaling.Breakpoints));
        _settingScale = false;
        _paneNow.Title.Text = "THIS ROM NOW   " + Label(to);
        _paneNow.Model = Safe(() => TableModel.From(here, now, to), out var whyNow);
        _paneNow.Message = whyNow;
        _paneAfter.Title.Text = r.Ok ? $"AFTER THE IMPORT   {r.Changed} byte(s) change" : "AFTER THE IMPORT";
        if (!r.Ok)
        {
            _note.Text = "Cannot import it: " + r.Note;
            _paneAfter.Model = null;
            _paneAfter.Message = "cannot import: " + r.Note;
        }
        else
        {
            _note.Text = char.ToUpperInvariant(r.Note[0]) + r.Note[1..] + ".";
            var after = Safe(() => TableModel.From(here, work, to), out var whyAfter);
            if (after != null && _paneNow.Model is { } nm && nm.Values.Length == after.Values.Length) after.Before = nm.Values;
            _paneAfter.Model = after;
            _paneAfter.Message = whyAfter;
        }
        ShowPanes();
    }

    void ShowPanes()
    {
        foreach (var p in new[] { _paneFrom, _paneNow, _paneAfter }) p.Show(_view, _stretch.IsChecked == true);
    }

    static TableModel? Safe(Func<TableModel> f, out string why)
    {
        why = "";
        try { return f(); } catch (Exception ex) { why = "(could not show it: " + ex.Message + ")"; return null; }
    }

    async Task ImportTicked()
    {
        if (_src == null) return;
        var picked = _rows.Where(r => r.Tick.IsChecked == true && r.To != null).ToList();
        if (picked.Count == 0) return;
        // the same table here twice would be written twice: the last one would win without saying so
        var twice = picked.GroupBy(r => r.To).Where(g => g.Count() > 1).Select(g => g.Key!.Name).ToList();
        if (twice.Count > 0) { _status.Text = $"{string.Join(", ", twice)} is picked for more than one table: choose one for each"; return; }
        var here = _host.Defs();
        var now = _host.RomCopy();
        var work = (byte[])now.Clone();
        var lines = new List<string>();
        int failed = 0;
        foreach (var r in picked)
        {
            var res = Run(r, here, work);
            if (!res.Ok) failed++;
            lines.Add($"  {r.Pair.From.Name} → {r.To!.Name}: {(res.Ok ? res.Note : "NOT IMPORTED: " + res.Note)}");
        }
        var patches = MapImport.Diff(now, work);
        if (patches.Count == 0) { _status.Text = "nothing would change: this ROM already has those values"; return; }
        if (!await Dialogs.Confirm(this, "Import these?",
                $"From {Path.GetFileName(_src.Path)} into the ROM that is open, {patches.Count} byte(s) in all:\n\n{string.Join("\n", lines)}\n\n" +
                "It is one step: Undo takes it all back.", "Import", "Not now")) return;
        int n = _host.ApplyPatches(patches, $"imported {picked.Count - failed} table(s) from {Path.GetFileName(_src.Path)}");
        AppLog.Action("import maps", $"imported {picked.Count - failed} table(s) from {_src.Path}: {n} byte(s)\n{string.Join("\n", lines)}");
        _status.Text = $"imported {picked.Count - failed} table(s) from {Path.GetFileName(_src.Path)} ({n} byte(s)); Undo on the Calibration page takes it back" +
                       (failed > 0 ? $"; {failed} could not be (see each row)" : "");
        Imported?.Invoke();
        ShowPreview();
    }

    /// Raised after an import, so the Calibration page shows the new values.
    public event Action? Imported;

    /// One of the three tables of the preview: a title, and the table in the view picked (read only).
    sealed class Pane : Border
    {
        public readonly TextBlock Title = new() { FontSize = 11, FontWeight = FontWeight.SemiBold, Opacity = 0.9, Margin = new Thickness(6, 3), TextTrimming = TextTrimming.CharacterEllipsis };
        readonly TableGrid _grid = new() { ReadOnly = true };
        readonly TableGraph _graph = new() { ReadOnly = true, MinHeight = 0 };
        readonly TableSurface _surface = new() { ReadOnly = true, MinHeight = 0 };
        readonly ScrollViewer _gridScroll = new();
        readonly ContentControl _host = new();
        readonly TextBlock _message = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10), Opacity = 0.8 };
        TableModel? _model;

        public Pane(string title)
        {
            Title.Text = title;
            Margin = new Thickness(0, 0, 0, 6);
            CornerRadius = new CornerRadius(4);
            BorderThickness = new Thickness(1);
            BorderBrush = new SolidColorBrush(Color.FromArgb(60, 255, 255, 255));
            Background = Dark.Back;
            ClipToBounds = true;
            _graph.Keys = _grid; _surface.Keys = _grid;
            _graph.SelectRange += _grid.SelectRange; _surface.SelectRange += _grid.SelectRange;
            _grid.Message += _ => { _graph.InvalidateVisual(); _surface.InvalidateVisual(); };
            _gridScroll.Content = _grid;
            var dock = new DockPanel();
            DockPanel.SetDock(Title, Dock.Top);
            dock.Children.Add(Title);
            dock.Children.Add(_host);
            Child = dock;
        }

        public TableModel? Model
        {
            get => _model;
            set { _model = value; _grid.Model = value; _graph.Model = value; _surface.Model = value; }
        }

        public string Message { get => _message.Text ?? ""; set => _message.Text = value; }

        /// Draw it: 0 the table, 1 the lines, 2 the surface (a table of one row or column has no surface: its lines).
        public void Show(int view, bool stretch)
        {
            if (_model == null) { _host.Content = _message; return; }
            if (view == 2 && (_model.Rows < 2 || _model.Cols < 2)) view = 1;
            if (_model.Rows * _model.Cols <= 1) view = 0;
            switch (view)
            {
                case 1: _host.Content = _graph; _graph.InvalidateVisual(); break;
                case 2: _host.Content = _surface; _surface.InvalidateVisual(); break;
                default:
                    var sv = stretch ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
                    _gridScroll.HorizontalScrollBarVisibility = sv; _gridScroll.VerticalScrollBarVisibility = sv;
                    _grid.HorizontalAlignment = stretch ? HorizontalAlignment.Stretch : HorizontalAlignment.Left;
                    _grid.VerticalAlignment = stretch ? VerticalAlignment.Stretch : VerticalAlignment.Top;
                    _grid.Stretch = stretch;
                    _host.Content = _gridScroll;
                    _grid.InvalidateVisual();
                    break;
            }
        }
    }
}
