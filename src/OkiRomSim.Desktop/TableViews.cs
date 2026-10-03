// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Media;
using Avalonia.Styling;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// What a table view draws: the cells, their axes, and where the running program has been reading from it. Shared by the grid, line and 3D views so they always agree.
public sealed class TableModel
{
    public required ItemDef Item { get; init; }
    public int Rows { get; init; }
    public int Cols { get; init; }
    public double[] Values { get; set { field = value; Touch(); } } = [];

    public double[] Raw { get; set; } = [];
    public double[] RowAxis { get; init; } = [];
    public double[] ColAxis { get; init; } = [];
    public string RowUnit { get; init; } = "";
    public string ColUnit { get; init; } = "";
    public string Unit { get; init; } = "";
    public int Decimals { get; init; } = 1;
    /// cell index -> heat: 1 = read by the program just now, fading towards 0 = read a while ago.
    public Dictionary<int, double> Heat { get; set; } = [];
    /// Where the engine is on this table from a datalog frame, as fractional (row, col); wins over the program's reads (Tuner mode: the trace comes from the car, not the simulator).
    public (double Row, double Col)? ExternalTrace { get; set; }
    /// Where the engine has been (Tuner mode), oldest first, with each point's age as 0 (now) to 1 (the end of the trail).
    public List<(double Row, double Col, double Age)> TrailPath { get; set; } = [];
    /// A logged channel averaged per cell (AFR, knock...), drawn in the cell corner.
    public double[]? Overlay { get; set; }
    public int[]? OverlayCount { get; set; }
    public string OverlayName { get; set; } = "";
    /// The values before a change (the Import maps preview): cells that differ are marked, and their tip says by how much.
    public double[]? Before { get; set; }

    /// A table as the ROM has it now: its cells, axes and units, for a view that only shows it (a preview).
    public static TableModel From(DefinitionSet defs, byte[] rom, ItemDef item)
    {
        var cells = RomData.Read(defs, rom, item);
        string AxisUnit(AxisDef? a, string fallback)
        {
            if (a == null) return fallback;
            if (a.Unit.Length > 0) return a.Unit;
            try { return defs.Formula(a.Formula).Unit is { Length: > 0 } u ? u : fallback; } catch { return fallback; }
        }
        FormulaDef f;
        try { f = defs.Formula(item.Formula); } catch { f = Builtin.Raw; }
        int rows = item.IsTable ? item.Rows : 1, cols = item.IsTable ? item.Cols : 1;
        string ru = AxisUnit(item.RowAxis, "row"), cu = AxisUnit(item.ColAxis, "col");
        return new TableModel
        {
            Item = item, Rows = rows, Cols = cols,
            Values = Shown([.. cells.Select(c => c.Value)], f.Unit), Raw = [.. cells.Select(c => c.Raw)],
            RowAxis = Shown(item.RowAxis == null ? [.. Enumerable.Range(0, rows).Select(i => (double)i)] : RomData.AxisValues(defs, rom, item.RowAxis, rows), ru),
            ColAxis = Shown(item.ColAxis == null ? [.. Enumerable.Range(0, cols).Select(i => (double)i)] : RomData.AxisValues(defs, rom, item.ColAxis, cols), cu),
            RowUnit = Units.Label(Units.Shown(ru)), ColUnit = Units.Label(Units.Shown(cu)),
            Unit = Units.Label(Units.Shown(f.Unit)), Decimals = Math.Min(f.Decimals, 2),
        };
    }

    /// Values kept in `unit`, in the unit picked for it in Settings > Units (unchanged when that is the same).
    public static double[] Shown(double[] values, string unit)
    {
        if (Units.Shown(unit) == unit) return values;
        return [.. values.Select(v => Units.Show(v, unit))];
    }

    // min / max are needed for every cell's colour: work them out once per change of values
    public double Min { get; private set; }
    public double Max { get; private set; }
    /// Call after changing Values in place.
    public void Touch()
    {
        double lo = double.MaxValue, hi = double.MinValue;
        foreach (var v in Values) { if (double.IsNaN(v)) continue; if (v < lo) lo = v; if (v > hi) hi = v; }
        if (lo > hi) lo = hi = 0;
        Min = lo; Max = hi;
    }
    [System.Runtime.CompilerServices.IndexerName("Cell")]
    public double this[int r, int c] => Values[(r * Cols) + c];

    public string Format(double v) => double.IsNaN(v) ? "" : v.ToString("F" + Math.Clamp(Decimals, 0, 4), CultureInfo.InvariantCulture);
    public static string Axis(double v) => double.IsNaN(v) ? "-" : Math.Abs(v) >= 100 ? v.ToString("0", CultureInfo.InvariantCulture) : v.ToString("0.##", CultureInfo.InvariantCulture);

    // the familiar map colours: light cyan -> light green -> yellow -> red as the value rises
    static Color C1 = Color.FromRgb(128, 255, 255), C2 = Color.FromRgb(98, 255, 98),
                 C3 = Color.FromRgb(255, 255, 0), C4 = Color.FromRgb(255, 0, 0);
    public static Color TraceColor { get; private set; } = Color.FromRgb(0, 255, 255);   // "trace" (aqua)
    public static Color TrailColor { get; private set; } = Color.FromRgb(0, 255, 0);     // "trail" (lime)

    public static void SetColours(Color low, Color mid, Color high, Color max, Color trace, Color trail)
    {
        C1 = low; C2 = mid; C3 = high; C4 = max; TraceColor = trace; TrailColor = trail;
    }

    public Color CellColor(double v)
    {
        double lo = Min, hi = Max;
        if (double.IsNaN(v) || hi <= lo) return C2;
        double t = Math.Clamp((v - lo) / (hi - lo), 0, 1);
        if (t < 0.08) return Mix(C1, C2, t / 0.08);
        return t < 0.5 ? Mix(C2, C3, (t - 0.08) / 0.42) : Mix(C3, C4, (t - 0.5) / 0.5);
    }

    public static Color Mix(Color a, Color b, double t)
    {
        t = Math.Clamp(t, 0, 1);
        return Color.FromRgb((byte)(a.R + ((b.R - a.R) * t)), (byte)(a.G + ((b.G - a.G) * t)), (byte)(a.B + ((b.B - a.B) * t)));
    }

    /// Where the reads are centred, as fractional (row, col), or null when nothing is hot.
    public (double Row, double Col)? TraceCentre()
    {
        if (ExternalTrace is { } ext) return ext;
        double w = 0, r = 0, c = 0;
        foreach (var (i, h) in Heat)
        {
            if (h < 0.75) continue;
            w += h; r += h * (i / Cols); c += h * (i % Cols);
        }
        return w > 0 ? (r / w, c / w) : null;
    }
}

/// The table editing keys (Settings > Hot keys > Table editing): what each does, the keys it starts with, and the keys set now. Each action takes up to two key combinations; the Table, Line and 3D views all answer to them.
public static class TableKeys
{
    public sealed record Entry(string Id, string What, string Defaults);

    public static readonly Entry[] All =
    [
        new("Up one step", "The selected cells up by the smallest step the table stores", "PageUp|OemCloseBrackets|Add"),
        new("Down one step", "The selected cells down by the smallest step", "PageDown|OemOpenBrackets|Subtract"),
        new("Up ten steps", "The selected cells up by ten steps", "Shift+PageUp|Shift+OemCloseBrackets"),
        new("Down ten steps", "The selected cells down by ten steps", "Shift+PageDown|Shift+OemOpenBrackets"),
        new("Up 1 %", "The selected cells up by 1 %", "Ctrl+PageUp"),
        new("Down 1 %", "The selected cells down by 1 %", "Ctrl+PageDown"),
        new("Up 5 %", "The selected cells up by 5 %", "Ctrl+Shift+PageUp"),
        new("Down 5 %", "The selected cells down by 5 %", "Ctrl+Shift+PageDown"),
        new("Set to the amount", "The selected cells set to the amount in the box above the table", ""),
        new("Add the amount", "The amount in the box above the table added to the selected cells", ""),
        new("Change by the amount in %", "The selected cells changed by the amount in the box, in percent", ""),
        new("Interpolate across", "A straight line across each row between the first and last selected columns", "H"),
        new("Interpolate down", "A straight line down each column between the first and last selected rows", "V"),
        new("Smooth", "Each selected cell averaged with its selected neighbours", "S"),
        new("Edit value", "Type a new value for the selected cells", "F2|Enter"),
        new("Select all", "Select every cell", "Ctrl+A"),
        new("Copy cells", "Copy the selected cells", "Ctrl+C"),
        new("Paste cells", "Paste into the table from the selected cell", "Ctrl+V"),
        new("Copy table", "Copy the whole table with its axes", "Ctrl+Shift+C"),
        new("Paste table", "Paste a whole table, resampled onto this table's axes when they differ", "Ctrl+Shift+V"),
        new("Undo", "Undo the last change", "Ctrl+Z"),
        new("Redo", "Put back what Undo took away", "Ctrl+Y|Ctrl+Shift+Z"),
        new("Reset the 3D view", "Put the 3D view back where it started", "Home"),
    ];

    public static Dictionary<string, string> Defaults() => All.ToDictionary(e => e.Id, e => e.Defaults, StringComparer.OrdinalIgnoreCase);

    static Dictionary<string, KeyGesture[]> _keys = Parse(Defaults());

    /// The keys set in Settings (action -> "Key|Key").
    public static void Use(IReadOnlyDictionary<string, string>? set)
    {
        var d = Defaults();
        if (set != null) foreach (var (k, v) in set) if (d.ContainsKey(k)) d[k] = v;
        _keys = Parse(d);
    }

    static Dictionary<string, KeyGesture[]> Parse(Dictionary<string, string> d) =>
        d.ToDictionary(kv => kv.Key, kv => Gestures(kv.Value), StringComparer.OrdinalIgnoreCase);

    public static KeyGesture[] Gestures(string text) =>
        [.. text.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(t => { try { return KeyGesture.Parse(t); } catch { return null; } }).OfType<KeyGesture>()];

    /// The action a key press is, or null.
    public static string? Match(KeyEventArgs e)
    {
        foreach (var (id, gs) in _keys)
            foreach (var g in gs)
                if (g.Matches(e)) return id;
        return null;
    }

    public static KeyGesture? First(string id) => _keys.TryGetValue(id, out var g) && g.Length > 0 ? g[0] : null;

    /// "Page Up or ]" for the help and the tips.
    public static string Display(string id) =>
        _keys.TryGetValue(id, out var g) && g.Length > 0 ? string.Join("  or  ", g.Select(Pretty)) : "(no key)";

    public static string Pretty(KeyGesture g) => g.ToString()
        .Replace("OemCloseBrackets", "]").Replace("OemOpenBrackets", "[").Replace("OemPlus", "=").Replace("OemMinus", "-")
        .Replace("PageUp", "Page Up").Replace("PageDown", "Page Down").Replace("OemComma", ",").Replace("OemPeriod", ".")
        .Replace("Add", "Num +").Replace("Subtract", "Num -");
}

/// The table as the tuning software draws it: RPM rows down the left, load columns across the top, every cell coloured by its value, the cells the program is reading outlined in aqua with a lime trail. Click/drag/shift+arrows select; type a number (or double-click) to edit; Enter applies it to the whole selection.
public sealed class TableGrid : Control
{
    public TableModel? Model { get; set { field = value; ClampSelection(); InvalidateMeasure(); InvalidateVisual(); } }

    /// A grid that shows numbers it does not own (the O2 / knock tables read out of a datalog): selecting and copying still work, typing and nudging do nothing.
    public bool ReadOnly { get; set; }

    /// The cell and heading sizes at their natural size; stretched, the table fills its panel and they grow (or shrink) with it.
    public const double BaseCellW = 46, BaseCellH = 19, BaseHeadW = 58, BaseHeadH = 20;
    double CellW = BaseCellW, CellH = BaseCellH, HeadW = BaseHeadW, HeadH = BaseHeadH, _font = FontSize;
    static readonly Typeface Face = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.SemiBold);
    static readonly Typeface Bold = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.Bold);
    const double FontSize = 11;
    // laid-out text is by far the most expensive part of drawing a map; keep it between frames
    static readonly Dictionary<(string, bool, double, uint), FormattedText> TextCache = [];
    static readonly Dictionary<uint, IBrush> CellBrushes = [];
    static IBrush BrushOf(Color c)
    {
        uint k = c.ToUInt32();
        if (CellBrushes.TryGetValue(k, out var b)) return b;
        if (CellBrushes.Count > 2000) CellBrushes.Clear();
        return CellBrushes[k] = AppTheme.Brush(c, tile: true);
    }
    static LinearGradientBrush TileVertical(params (Color C, double At)[] stops) => AppTheme.Track(Plain(stops), tile: true);
    static LinearGradientBrush Vertical(params (Color C, double At)[] stops) => AppTheme.Track(Plain(stops));
    static LinearGradientBrush Plain((Color C, double At)[] stops)
    {
        var g = new LinearGradientBrush { StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative) };
        foreach (var (c, at) in stops) g.GradientStops.Add(new GradientStop(c, at));
        return g;
    }
    // every cell a lit tile: bright along its top edge, the colour itself through the middle, a little shade at the foot
    static readonly IBrush Gloss = TileVertical((Color.FromArgb(95, 255, 255, 255), 0), (Color.FromArgb(28, 255, 255, 255), 0.42),
                                            (Color.FromArgb(0, 0, 0, 0), 0.55), (Color.FromArgb(46, 0, 0, 0), 1));
    static readonly IBrush HeadBg = Vertical((Color.FromRgb(0x34, 0x38, 0x41), 0), (Color.FromRgb(0x23, 0x26, 0x2c), 1));
    static readonly IBrush HeadSel = Vertical((Color.FromRgb(0x3a, 0x6d, 0xa3), 0), (Color.FromRgb(0x25, 0x4a, 0x73), 1));
    static readonly IBrush HeadHover = Vertical((Color.FromRgb(0x45, 0x4b, 0x57), 0), (Color.FromRgb(0x2e, 0x32, 0x3a), 1));
    static readonly IBrush Ink = AppTheme.Brush(Color.FromRgb(0x12, 0x14, 0x18), tile: true);
    static readonly IBrush InkLight = AppTheme.Brush(Color.FromRgb(0xf2, 0xf4, 0xf8), tile: true);
    static readonly IBrush OverlayInk = AppTheme.Brush(Color.FromRgb(0x1c, 0x2a, 0x8c), tile: true);
    static readonly IBrush OverlayPill = AppTheme.Brush(Color.FromArgb(120, 255, 255, 255), tile: true);
    static readonly IBrush SelWash = AppTheme.Brush(Color.FromArgb(46, 255, 255, 255), tile: true);
    static readonly Pen SelGlow = new(AppTheme.Brush(Color.FromArgb(90, 0, 0, 0), tile: true), 6);
    static readonly Pen SelOuter = new(AppTheme.Brush(Color.FromRgb(0x0a, 0x0b, 0x0d), tile: true), 3);
    static readonly Pen SelInner = new(AppTheme.Brush(Colors.White, tile: true), 1.5);
    static readonly Pen HoverPen = new(AppTheme.Brush(Colors.White, tile: true), 1.5);
    static readonly Pen HoverShade = new(AppTheme.Brush(Color.FromArgb(160, 0, 0, 0), tile: true), 3);
    static readonly Pen HeadEdge = new(AppTheme.Brush(Color.FromRgb(0x14, 0x15, 0x18)), 1);
    static readonly IBrush Changed = AppTheme.Brush(Color.FromArgb(200, 0x10, 0x10, 0x10), tile: true);

    /// Fill the panel: the cells grow (or shrink) so the whole table is on screen and its numbers - the small ones in the corner of each cell too - are as big as the panel allows.
    public bool Stretch { get; set { field = value; InvalidateMeasure(); InvalidateVisual(); } }
    /// More lines for the tip over a cell (the Import maps preview: what it was and what it will be).
    public Func<int, string?>? ExtraInfo { get; set; }
    (int r, int c) _hover = (-1, -1);
    /// A read-only grid (a preview, a table read out of a log) shows no selection until one is made on it.
    bool _picked;

    (int r, int c) _anchor, _cursor;
    bool _dragging, _swallowText;
    readonly TextBox _editor = new() { FontFamily = MainWindow.MonoFont, FontSize = FontSize, Padding = new Thickness(2, 0), MinHeight = 0, IsVisible = false };
    Canvas? _host;

    /// (cell indexes, new value, value is raw)
    public event Action<IReadOnlyList<int>, double, bool>? SetCells;
    /// A header was double-clicked: (row header?, which one). The page opens the axis behind it so the breakpoint can be edited where it lives.
    public event Action<bool, int>? HeaderActivated;
    /// (cell indexes, raw delta)
    public event Action<IReadOnlyList<int>, int>? NudgeCells;
    public event Action<List<(int Index, double Value)>>? PasteCells;
    public event Action? Undo, Redo;
    public event Action<string>? Message;
    /// A table action by name, for the page to carry out on the selection: "ih" / "iv" interpolate across / down, "smooth", "pct:+1" / "pct:-5" change by a percentage, "set" / "add" / "pct" with the amount box.
    public event Action<string>? Command;

    /// Every key the table views answer to, as set now, for the right-click menu and the help.
    public static IEnumerable<(string Keys, string What)> KeyHelp =>
    [
        ("Type a number, Enter", "Set the selected cells (r120 = raw, +2 / -2 = change by, *1.05 = multiply)"),
        ("Double-click", "Edit the cell"),
        ("Arrows", "Move (Shift+arrows: select)"),
        ("Drag", "Select (in the Line and 3D views: drag a point to change it, drag round points to select them)"),
        .. TableKeys.All.Where(k => TableKeys.First(k.Id) != null).Select(k => (TableKeys.Display(k.Id), k.What)),
    ];

    public TableGrid()
    {
        Focusable = true;
        ClipToBounds = true;
        _editor.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { CommitEdit(); e.Handled = true; Focus(); }
            else if (e.Key == Key.Escape) { _editor.IsVisible = false; e.Handled = true; Focus(); }
        };
        _editor.LostFocus += (_, _) => _editor.IsVisible = false;
    }

    /// The editing box lives on an overlay canvas supplied by the parent.
    public void AttachEditorHost(Canvas host) { _host = host; host.Children.Add(_editor); }

    public IReadOnlyList<int> Selection()
    {
        var list = new List<int>();
        if (Model == null) return list;
        int r0 = Math.Min(_anchor.r, _cursor.r), r1 = Math.Max(_anchor.r, _cursor.r);
        int c0 = Math.Min(_anchor.c, _cursor.c), c1 = Math.Max(_anchor.c, _cursor.c);
        for (int r = r0; r <= r1; r++) for (int c = c0; c <= c1; c++) list.Add((r * Model.Cols) + c);
        return list;
    }
    public (int R0, int C0, int R1, int C1) SelectionRect() =>
        (Math.Min(_anchor.r, _cursor.r), Math.Min(_anchor.c, _cursor.c), Math.Max(_anchor.r, _cursor.r), Math.Max(_anchor.c, _cursor.c));

    /// The right-click menu opens on the cells and their headers, not on the empty panel round a small table.
    public bool MenuAllowed(Point p) => Model != null && p.X <= HeadW + (Model.Cols * CellW) && p.Y <= HeadH + (Model.Rows * CellH);

    /// Select a block of cells (a box dragged round points in the Line or 3D view).
    public void SelectRange(int r0, int c0, int r1, int c1)
    {
        _picked = true;
        _anchor = (r0, c0); _cursor = (r1, c1);
        ClampSelection();
        InvalidateVisual();
        Describe();
    }

    public void SelectCell(int r, int c)
    {
        _anchor = _cursor = (r, c);
        ClampSelection();
        InvalidateVisual();
    }

    /// Select a cell and scroll it (with a cell of margin round it) into view.
    public void FocusCell(int r, int c)
    {
        SelectCell(r, c);
        RaiseEvent(new RequestBringIntoViewEventArgs
        {
            RoutedEvent = RequestBringIntoViewEvent, TargetObject = this,
            TargetRect = new Rect(HeadW + ((c - 1) * CellW), HeadH + ((r - 1) * CellH), CellW * 3, CellH * 3),
        });
    }

    void ClampSelection()
    {
        if (Model == null) return;
        (int, int) Clamp((int r, int c) p) => (Math.Clamp(p.r, 0, Math.Max(0, Model.Rows - 1)), Math.Clamp(p.c, 0, Math.Max(0, Model.Cols - 1)));
        _anchor = Clamp(_anchor); _cursor = Clamp(_cursor);
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Model == null) return new Size(0, 0);
        // stretched in a panel that gives it a size: all of it (the cells are worked out from it when it is arranged)
        if (Stretch && !double.IsInfinity(availableSize.Width) && !double.IsInfinity(availableSize.Height)) return availableSize;
        var (cw, ch, hw, hh, _) = Natural();
        return new Size(hw + (Model.Cols * cw) + 1, hh + (Model.Rows * ch) + 1);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        Fit(finalSize);
        return base.ArrangeOverride(finalSize);
    }

    /// The sizes unstretched: bigger for a finger in touch screen mode.
    static (double Cw, double Ch, double Hw, double Hh, double Font) Natural() =>
        TouchMode.On ? (58, 32, 64, 32, 13.5) : (BaseCellW, BaseCellH, BaseHeadW, BaseHeadH, FontSize);

    /// The cell, heading and text sizes for the space the table has.
    void Fit(Size size)
    {
        var m = Model;
        if (m == null || !Stretch || size.Width < 40 || size.Height < 30)
        {
            (CellW, CellH, HeadW, HeadH, _font) = Natural();
            return;
        }
        // the row headings are a column and a quarter wide, the column headings a row high (all of it on screen, however small that makes it: hovering over a cell tells its value)
        CellW = Math.Max(8, (size.Width - 1) / (m.Cols + 1.25));
        CellH = Math.Max(5, (size.Height - 1) / (m.Rows + 1));
        HeadW = Math.Max(20, CellW * 1.25);
        HeadH = CellH;
        // a number of six characters has to fit across a cell, and the text sit in its height
        _font = Math.Clamp(Math.Min(CellH * 0.62, CellW / 3.9), 5, 30);
    }

    public override void Render(DrawingContext ctx)
    {
        var m = Model;
        if (m == null) return;
        double tw = HeadW + (m.Cols * CellW), th = HeadH + (m.Rows * CellH);
        ctx.FillRectangle(Dark.Back, Stretch ? new Rect(Bounds.Size) : new Rect(0, 0, tw + 1, th + 1));
        double gap = CellW > 24 && CellH > 14 ? 1 : 0.5;
        float round = (float)Math.Min(3, Math.Min(CellW, CellH) / 7);
        var (sr0, sc0, sr1, sc1) = SelectionRect();
        // corner: the units of the two axes
        var corner = new Rect(0, 0, HeadW, HeadH).Deflate(gap / 2);
        ctx.FillRectangle(HeadBg, corner, round);
        Text(ctx, $"{m.RowUnit}\\{m.ColUnit}", corner, Dark.Dim, Math.Max(7.5, _font * 0.78));
        for (int c = 0; c < m.Cols; c++)
        {
            var rc = new Rect(HeadW + (c * CellW), 0, CellW, HeadH).Deflate(gap / 2);
            ctx.FillRectangle(c >= sc0 && c <= sc1 ? HeadSel : c == _hover.c ? HeadHover : HeadBg, rc, round);
            Text(ctx, c < m.ColAxis.Length ? TableModel.Axis(m.ColAxis[c]) : c.ToString(), rc, Dark.Text, _font, bold: true);
        }
        var ext = m.ExternalTrace;
        var before = m.Before;
        for (int r = 0; r < m.Rows; r++)
        {
            var rh = new Rect(0, HeadH + (r * CellH), HeadW, CellH).Deflate(gap / 2);
            ctx.FillRectangle(r >= sr0 && r <= sr1 ? HeadSel : r == _hover.r ? HeadHover : HeadBg, rh, round);
            Text(ctx, r < m.RowAxis.Length ? TableModel.Axis(m.RowAxis[r]) : r.ToString(), rh, Dark.Text, _font, bold: true);
            for (int c = 0; c < m.Cols; c++)
            {
                int i = (r * m.Cols) + c;
                var rc = new Rect(HeadW + (c * CellW), HeadH + (r * CellH), CellW, CellH).Deflate(gap / 2);
                var color = m.CellColor(m.Values[i]);
                if (m.Heat.TryGetValue(i, out var h))
                    color = h >= 0.75 ? TableModel.TraceColor : TableModel.Mix(color, TableModel.TrailColor, 0.45 + (h / 0.75 * 0.55));
                else if (ext is { } e && Math.Abs(e.Row - r) < 1 && Math.Abs(e.Col - c) < 1)
                    color = TableModel.Mix(color, TableModel.TraceColor, 1 - Math.Max(Math.Abs(e.Row - r), Math.Abs(e.Col - c)));
                ctx.FillRectangle(BrushOf(color), rc, round);
                if (Perf.Effects) ctx.FillRectangle(Gloss, rc, round);      // a gradient on every cell: the first thing a slow machine is spared
                // a lit cell framed too, bright where the engine is and fading along the trail, so it shows on any colour
                if (m.Heat.TryGetValue(i, out var lit))
                    ctx.DrawRectangle(null, new Pen(AppTheme.Brush(Color.FromArgb((byte)(70 + (185 * Math.Min(1, lit / 0.75))), 255, 255, 255)), lit >= 0.75 ? 2.2 : 1.4),
                                      rc.Deflate(1), round, round);
                // dark figures on every cell, the red ones too: a table reads as one piece (only a colour set in Settings dark enough to lose them gets light ones)
                var ink = (0.299 * color.R) + (0.587 * color.G) + (0.114 * color.B) > 60 ? Ink : InkLight;
                if (m.Overlay is { } ov && i < ov.Length && !double.IsNaN(ov[i]))
                {
                    // the value in the top of the cell, the logged number under it on a pale pill
                    double small = Math.Max(7, _font * 0.78);
                    var top = new Rect(rc.X, rc.Y, rc.Width, rc.Height * 0.56);
                    var foot = new Rect(rc.X + 2, rc.Y + (rc.Height * 0.54), rc.Width - 4, rc.Height * 0.44);
                    Text(ctx, m.Format(m.Values[i]), top, ink, Math.Max(7, _font * 0.9));
                    if (foot.Height >= 8) ctx.FillRectangle(OverlayPill, foot, (float)Math.Min(4, foot.Height / 2));
                    Text(ctx, ov[i].ToString(Math.Abs(ov[i]) >= 100 ? "0" : "0.0#", CultureInfo.InvariantCulture), foot, OverlayInk, small, bold: true);
                }
                else Text(ctx, m.Format(m.Values[i]), rc, ink, _font);
                // a cell the preview would change: a small dark corner
                if (before != null && i < before.Length && Math.Abs(before[i] - m.Values[i]) > 1e-9)
                {
                    double k = Math.Min(rc.Width, rc.Height) * 0.34;
                    var g = new StreamGeometry();
                    using (var gc = g.Open())
                    {
                        gc.BeginFigure(new Point(rc.Right - k, rc.Top), true);
                        gc.LineTo(new Point(rc.Right, rc.Top));
                        gc.LineTo(new Point(rc.Right, rc.Top + k));
                        gc.EndFigure(true);
                    }
                    ctx.DrawGeometry(Changed, null, g);
                }
            }
        }
        // the selection: a wash over it and a dark frame with a white line inside, which reads on every colour
        if (!ReadOnly || _picked)
        {
            var sel = new Rect(HeadW + (sc0 * CellW), HeadH + (sr0 * CellH), (sc1 - sc0 + 1) * CellW, (sr1 - sr0 + 1) * CellH);
            ctx.FillRectangle(SelWash, sel.Deflate(gap), round);
            ctx.DrawRectangle(null, SelGlow, sel, round + 2, round + 2);
            ctx.DrawRectangle(null, SelOuter, sel, round + 1, round + 1);
            ctx.DrawRectangle(null, SelInner, sel.Deflate(2), round, round);
        }
        // the cell under the pointer
        if (_hover.r >= 0 && _hover.c >= 0 && _hover.r < m.Rows && _hover.c < m.Cols)
        {
            var hc = new Rect(HeadW + (_hover.c * CellW), HeadH + (_hover.r * CellH), CellW, CellH);
            ctx.DrawRectangle(null, HoverShade, hc.Deflate(1), round, round);
            ctx.DrawRectangle(null, HoverPen, hc.Deflate(1), round, round);
        }
        // the way the engine came (Tuner mode): a line through where it was, fading with age
        if (m.TrailPath.Count > 1)
        {
            Point At((double Row, double Col, double Age) t) => new(HeadW + ((t.Col + 0.5) * CellW), HeadH + ((t.Row + 0.5) * CellH));
            for (int k = 1; k < m.TrailPath.Count; k++)
            {
                var (a, b) = (m.TrailPath[k - 1], m.TrailPath[k]);
                byte alpha = (byte)(230 * (1 - b.Age));
                ctx.DrawLine(new Pen(AppTheme.Brush(Color.FromArgb((byte)(alpha / 2), 0, 0, 0)), 5.5, lineCap: PenLineCap.Round), At(a), At(b));
                ctx.DrawLine(new Pen(AppTheme.Brush(Color.FromArgb(alpha, TableModel.TraceColor.R, TableModel.TraceColor.G, TableModel.TraceColor.B)), 3, lineCap: PenLineCap.Round), At(a), At(b));
            }
        }
        // where the program is reading, interpolated: a glowing ring
        if (m.TraceCentre() is { } tc)
        {
            var p = new Point(HeadW + ((tc.Col + 0.5) * CellW), HeadH + ((tc.Row + 0.5) * CellH));
            double rad = Math.Clamp(Math.Min(CellW, CellH) * 0.3, 5, 14);
            ctx.DrawEllipse(BrushOf(Color.FromArgb(70, TableModel.TraceColor.R, TableModel.TraceColor.G, TableModel.TraceColor.B)), null, p, rad * 1.9, rad * 1.9);
            ctx.DrawEllipse(null, new Pen(AppTheme.Black, 3), p, rad, rad);
            ctx.DrawEllipse(null, new Pen(AppTheme.White, 1.5), p, rad, rad);
            ctx.DrawEllipse(Brushes.White, null, p, 1.8, 1.8);
        }
    }

    static void Text(DrawingContext ctx, string s, Rect rc, IBrush brush, double size, bool bold = false)
    {
        size = Math.Round(size * 2) / 2;       // half-point steps, so the cache is not filled with sizes a hair apart
        uint ink = brush is ISolidColorBrush sb ? sb.Color.ToUInt32() : 0;
        var key = (s, bold, size, ink);
        if (!TextCache.TryGetValue(key, out var ft))
        {
            if (TextCache.Count > 4000) TextCache.Clear();      // bounded: this is a cache, not a store
            ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, bold ? Bold : Face, size, brush);
            TextCache[key] = ft;
        }
        ctx.DrawText(ft, new Point(rc.X + ((rc.Width - ft.Width) / 2), rc.Y + ((rc.Height - ft.Height) / 2)));
    }

    (int r, int c)? Hit(Point p)
    {
        if (Model == null) return null;
        int c = (int)Math.Floor((p.X - HeadW) / CellW), r = (int)Math.Floor((p.Y - HeadH) / CellH);
        if (p.X < HeadW && p.Y >= HeadH) c = -1;
        if (p.Y < HeadH && p.X >= HeadW) r = -1;
        return r >= Model.Rows || c >= Model.Cols ? null : (r, c);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        if (Model == null || Hit(e.GetPosition(this)) is not { } h) return;
        _picked = true;
        bool shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        if (e.GetCurrentPoint(this).Properties.IsRightButtonPressed)
        {
            // right-click: on a cell outside the selection, that cell; inside it, the selection stays for the menu
            var (sr0, sc0, sr1, sc1) = SelectionRect();
            if (h.r >= 0 && h.c >= 0 && (h.r < sr0 || h.r > sr1 || h.c < sc0 || h.c > sc1)) { _anchor = _cursor = h; InvalidateVisual(); Describe(); }
            return;
        }
        if (h.r < 0 && h.c < 0) { _anchor = (0, 0); _cursor = (Model.Rows - 1, Model.Cols - 1); }       // corner: all
        else if (h.r < 0)                                                                              // column header
        {
            _anchor = (0, h.c); _cursor = (Model.Rows - 1, h.c);
            if (e.ClickCount == 2) { HeaderActivated?.Invoke(false, h.c); return; }
        }
        else if (h.c < 0)                                                                              // row header
        {
            _anchor = (h.r, 0); _cursor = (h.r, Model.Cols - 1);
            if (e.ClickCount == 2) { HeaderActivated?.Invoke(true, h.r); return; }
        }
        else
        {
            if (e.ClickCount == 2) { _anchor = _cursor = h; BeginEdit(null); return; }
            if (!shift) _anchor = h;
            _cursor = h;
            _dragging = true;
        }
        InvalidateVisual();
        Describe();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (Model == null) return;
        var p = e.GetPosition(this);
        if (_dragging && Hit(p) is { } h && h.r >= 0 && h.c >= 0 && h != _cursor) { _cursor = h; InvalidateVisual(); Describe(); }
        var over = Hit(p) is { } o && o.r >= 0 && o.c >= 0 ? o : (-1, -1);
        if (over != _hover) { _hover = over; InvalidateVisual(); }
        if (over.Item1 < 0) { ToolTip.SetTip(this, null); return; }      // off the cells (a short table leaves a lot of empty panel)
        ToolTip.SetTip(this, CellInfo(over.Item1, over.Item2));
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        if (_hover != (-1, -1)) { _hover = (-1, -1); InvalidateVisual(); }
    }

    /// Everything worth knowing about one cell, for the tip over it.
    string CellInfo(int r, int c)
    {
        var m = Model!;
        int i = (r * m.Cols) + c;
        var inv = CultureInfo.InvariantCulture;
        double v = m.Values[i];
        var sb = new System.Text.StringBuilder();
        sb.Append($"{m.Item.Name}  [{r},{c}]\n");
        if (m.Rows > 1) sb.Append($"{TableModel.Axis(r < m.RowAxis.Length ? m.RowAxis[r] : r)} {m.RowUnit}");
        if (m.Rows > 1 && m.Cols > 1) sb.Append("  ×  ");
        if (m.Cols > 1) sb.Append($"{TableModel.Axis(c < m.ColAxis.Length ? m.ColAxis[c] : c)} {m.ColUnit}");
        sb.Append('\n');
        sb.Append($"value  {m.Format(v)} {m.Unit}\n");
        if (i < m.Raw.Length) sb.Append($"raw    {m.Raw[i]:0} (0x{(long)m.Raw[i]:X2})   at {m.Item.CellAddress(i):X4}\n");
        if (m.Max > m.Min) sb.Append($"table  {m.Format(m.Min)} to {m.Format(m.Max)} {m.Unit}: this cell is {(v - m.Min) * 100 / (m.Max - m.Min):0} % of the way up\n");
        // its neighbours, so a step out of line shows
        string Nb(int rr, int cc, string where)
        {
            if (rr < 0 || cc < 0 || rr >= m.Rows || cc >= m.Cols) return "";
            double n = m[rr, cc], d = v - n;
            string pct = Math.Abs(n) > 1e-9 ? $", {(d * 100 / Math.Abs(n)).ToString("+0.#;-0.#;0", inv)} %" : "";
            return $"{where} {m.Format(n)} ({(d >= 0 ? "+" : "")}{m.Format(d)}{pct})   ";
        }
        var nbs = (Nb(r, c - 1, "left") + Nb(r - 1, c, "above")).TrimEnd();
        if (nbs.Length > 0) sb.Append($"next to it: {nbs}\n");
        if (m.Before is { } b && i < b.Length && !double.IsNaN(b[i]))
        {
            double d = v - b[i];
            sb.Append(Math.Abs(d) < 1e-9 ? "unchanged\n"
                : $"was {m.Format(b[i])} {m.Unit}: {(d >= 0 ? "+" : "")}{m.Format(d)}{(Math.Abs(b[i]) > 1e-9 ? $" ({(d * 100 / Math.Abs(b[i])).ToString("+0.#;-0.#", inv)} %)" : "")}\n");
        }
        if (m.Heat.TryGetValue(i, out var ht)) sb.Append($"read by the program {(ht >= 0.75 ? "just now" : "recently")}\n");
        if (m.ExternalTrace is { } et && Math.Abs(et.Row - r) < 1 && Math.Abs(et.Col - c) < 1) sb.Append("the engine is here now\n");
        if (m.Overlay is { } ov && i < ov.Length && !double.IsNaN(ov[i]))
            sb.Append($"{m.OverlayName}: {ov[i]:0.###} (average of {(m.OverlayCount is { } oc && i < oc.Length ? oc[i] : 0)} logged samples)\n");
        if (ExtraInfo?.Invoke(i) is { Length: > 0 } extra) sb.Append(extra).Append('\n');
        return sb.ToString().TrimEnd();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e) { base.OnPointerReleased(e); _dragging = false; }

    void Describe()
    {
        if (Model == null) return;
        var sel = Selection();
        if (sel.Count == 1)
        {
            int i = sel[0];
            Message?.Invoke($"[{i / Model.Cols},{i % Model.Cols}] = {Model.Format(Model.Values[i])} {Model.Unit}  (raw {Model.Raw[i]:0}, at {Model.Item.CellAddress(i):X4})");
        }
        else
        {
            var vals = sel.Select(i => Model.Values[i]).ToList();
            Message?.Invoke($"{sel.Count} cells selected: min {Model.Format(vals.Min())}  avg {Model.Format(vals.Average())}  max {Model.Format(vals.Max())}");
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        HandleKey(e);
    }

    /// The table keys (see KeyHelp); the line and 3D views hand their keys here so they all work the same.
    public void HandleKey(KeyEventArgs e)
    {
        _swallowText = false;
        if (Model == null || e.Handled) return;
        bool shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift), ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        (int dr, int dc) move = e.Key switch
        {
            Key.Up => (-1, 0), Key.Down => (1, 0), Key.Left => (0, -1), Key.Right => (0, 1), _ => (0, 0),
        };
        if (move != (0, 0))
        {
            _cursor = (_cursor.r + move.dr, _cursor.c + move.dc);
            if (!shift) _anchor = _cursor;
            ClampSelection(); _anchor = shift ? _anchor : _cursor;
            InvalidateVisual(); Describe();
            e.Handled = true; return;
        }
        if (TableKeys.Match(e) is not { } id || !Run(id)) return;
        // a key that also types a character (H, ], +) must not start an edit with it as well
        _swallowText = true;
        e.Handled = true;
    }

    /// Carry out a table action by its name (TableKeys); false when it is not one for the grid.
    public bool Run(string id)
    {
        switch (id)
        {
            case "Up one step": Nudge(1); return true;
            case "Down one step": Nudge(-1); return true;
            case "Up ten steps": Nudge(10); return true;
            case "Down ten steps": Nudge(-10); return true;
            case "Up 1 %": RunCommand("pct:+1"); return true;
            case "Down 1 %": RunCommand("pct:-1"); return true;
            case "Up 5 %": RunCommand("pct:+5"); return true;
            case "Down 5 %": RunCommand("pct:-5"); return true;
            case "Set to the amount": RunCommand("set"); return true;
            case "Add the amount": RunCommand("add"); return true;
            case "Change by the amount in %": RunCommand("pct"); return true;
            case "Interpolate across": RunCommand("ih"); return true;
            case "Interpolate down": RunCommand("iv"); return true;
            case "Smooth": RunCommand("smooth"); return true;
            case "Edit value": BeginEdit(null); return true;
            case "Select all": SelectAll(); return true;
            case "Copy cells": Copy(); return true;
            case "Paste cells": Paste(); return true;
            case "Copy table": CopyTable(); return true;
            case "Paste table": PasteTable(); return true;
            case "Undo": Undo?.Invoke(); return true;
            case "Redo": Redo?.Invoke(); return true;
            default: return false;
        }
    }

    public void Nudge(int steps) { if (!ReadOnly) NudgeCells?.Invoke(Selection(), steps); }
    /// Move the selection (or, extending, grow it) as the arrow keys do: the touch pad's arrows.
    public void Move(int dr, int dc, bool extend)
    {
        if (Model == null) return;
        _picked = true;
        _cursor = (_cursor.r + dr, _cursor.c + dc);
        if (!extend) _anchor = _cursor;
        ClampSelection();
        if (!extend) _anchor = _cursor;
        FocusCellView(_cursor.r, _cursor.c);
        InvalidateVisual(); Describe();
    }
    void FocusCellView(int r, int c) => RaiseEvent(new RequestBringIntoViewEventArgs
    {
        RoutedEvent = RequestBringIntoViewEvent, TargetObject = this,
        TargetRect = new Rect(HeadW + ((c - 1) * CellW), HeadH + ((r - 1) * CellH), CellW * 3, CellH * 3),
    });
    public void SelectAll() { if (Model == null) return; _anchor = (0, 0); _cursor = (Model.Rows - 1, Model.Cols - 1); InvalidateVisual(); Describe(); }
    public void Edit() => BeginEdit(null);
    public void DoCopy() => Copy();
    public void DoPaste() => Paste();
    public void DoCopyTable() => CopyTable();
    public void DoPasteTable() => PasteTable();
    public void RunCommand(string op) { if (!ReadOnly) Command?.Invoke(op); }
    public void DoUndo() => Undo?.Invoke();
    public void DoRedo() => Redo?.Invoke();

    /// The whole table with its axes: a header line of the column axis, then each row's axis value and cells (tab-separated, so a spreadsheet takes it as it is).
    async void CopyTable()
    {
        if (Model == null) return;
        var m = Model;
        var inv = CultureInfo.InvariantCulture;
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"{m.RowUnit}\\{m.ColUnit}\t" + string.Join("\t", Enumerable.Range(0, m.Cols).Select(c => c < m.ColAxis.Length ? m.ColAxis[c].ToString("0.####", inv) : c.ToString())));
        for (int r = 0; r < m.Rows; r++)
            sb.AppendLine((r < m.RowAxis.Length ? m.RowAxis[r].ToString("0.####", inv) : r.ToString()) + "\t" +
                          string.Join("\t", Enumerable.Range(0, m.Cols).Select(c => m[r, c].ToString("0.####", inv))));
        if (TopLevel.GetTopLevel(this)?.Clipboard is { } cb) await cb.SetTextAsync(sb.ToString());
        Message?.Invoke($"copied the whole table ({m.Rows} x {m.Cols}) with its axes - Ctrl+Shift+V pastes it into another table");
    }

    /// Paste a whole table. With axes (as Copy table writes them) and different axes from this table, it is resampled onto this table's axes (straight lines between the copied points, the ends held); without axes, the same size is needed.
    async void PasteTable()
    {
        if (Model == null || ReadOnly || TopLevel.GetTopLevel(this)?.Clipboard is not { } cb) return;
        var text = await cb.TryGetTextAsync();
        if (string.IsNullOrWhiteSpace(text)) return;
        var m = Model;
        var rows = text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries)
                       .Select(l => l.Split(new[] { '\t', ',', ';' }, StringSplitOptions.None).Select(x => x.Trim()).ToArray()).ToList();
        static bool Num(string x, out double v) => double.TryParse(x, NumberStyles.Float, CultureInfo.InvariantCulture, out v);
        bool withAxes = rows.Count > 1 && !Num(rows[0][0], out _);
        var list = new List<(int, double)>();
        if (withAxes)
        {
            var colAxis = rows[0].Skip(1).Select(x => Num(x, out var v) ? v : double.NaN).ToArray();
            var body = rows.Skip(1).Where(r => r.Length > 1).ToList();
            var rowAxis = body.Select(r => Num(r[0], out var v) ? v : double.NaN).ToArray();
            var vals = body.Select(r => r.Skip(1).Select(x => Num(x, out var v) ? v : double.NaN).ToArray()).ToArray();
            if (colAxis.Length == 0 || rowAxis.Length == 0 || colAxis.Any(double.IsNaN) || rowAxis.Any(double.IsNaN) || vals.Any(v => v.Length < colAxis.Length || v.Any(double.IsNaN)))
            { Message?.Invoke("the clipboard's table has gaps in it"); return; }
            for (int r = 0; r < m.Rows; r++)
                for (int c = 0; c < m.Cols; c++)
                {
                    double rv = r < m.RowAxis.Length ? m.RowAxis[r] : r, cv = c < m.ColAxis.Length ? m.ColAxis[c] : c;
                    list.Add(((r * m.Cols) + c, Bilinear(rowAxis, colAxis, vals, rv, cv)));
                }
            bool same = rowAxis.Length == m.Rows && colAxis.Length == m.Cols;
            Message?.Invoke(same ? "pasted the table" : $"pasted a {rowAxis.Length} x {colAxis.Length} table, resampled onto this {m.Rows} x {m.Cols} one");
        }
        else
        {
            var vals = rows.Select(r => r.Where(x => x.Length > 0).Select(x => Num(x, out var v) ? v : double.NaN).ToArray()).ToList();
            if (vals.Count != m.Rows || vals.Any(v => v.Length != m.Cols))
            { Message?.Invoke($"the clipboard has {vals.Count} x {vals.FirstOrDefault()?.Length ?? 0} numbers without axes; this table is {m.Rows} x {m.Cols} (copy it with Ctrl+Shift+C to paste across sizes)"); return; }
            for (int r = 0; r < m.Rows; r++) for (int c = 0; c < m.Cols; c++) if (!double.IsNaN(vals[r][c])) list.Add(((r * m.Cols) + c, vals[r][c]));
            Message?.Invoke("pasted the table");
        }
        PasteCells?.Invoke(list);
    }

    static double Bilinear(double[] ra, double[] ca, double[][] v, double r, double c)
    {
        static (int, int, double) Bracket(double[] axis, double x)
        {
            if (axis.Length == 1) return (0, 0, 0);
            bool up = axis[^1] >= axis[0];
            for (int i = 0; i < axis.Length - 1; i++)
            {
                double a = axis[i], b = axis[i + 1];
                bool inside = up ? x >= a && x <= b : x <= a && x >= b;
                if (inside) return (i, i + 1, b == a ? 0 : (x - a) / (b - a));
            }
            bool below = up ? x < axis[0] : x > axis[0];
            return below ? (0, 0, 0) : (axis.Length - 1, axis.Length - 1, 0);
        }
        var (r0, r1, fr) = Bracket(ra, r);
        var (c0, c1, fc) = Bracket(ca, c);
        return (v[r0][c0] * (1 - fr) * (1 - fc)) + (v[r0][c1] * (1 - fr) * fc) + (v[r1][c0] * fr * (1 - fc)) + (v[r1][c1] * fr * fc);
    }

    protected override void OnTextInput(TextInputEventArgs e)
    {
        base.OnTextInput(e);
        if (_swallowText) { _swallowText = false; e.Handled = true; return; }
        if (Model == null || string.IsNullOrEmpty(e.Text) || e.Handled) return;
        char ch = e.Text[0];
        if (char.IsDigit(ch) || ch is '.' or '-' or '+' or '*' or 'r') { BeginEdit(e.Text); e.Handled = true; }
        else if (ch == '=') { BeginEdit(""); e.Handled = true; }
    }

    void BeginEdit(string? initial)
    {
        if (Model == null || _host == null) return;
        if (ReadOnly) { Message?.Invoke("these numbers came from the log, not from the ROM: they cannot be edited here"); return; }
        var (r0, c0, _, _) = SelectionRect();
        int i = (r0 * Model.Cols) + c0;
        _editor.Text = initial ?? Model.Format(Model.Values[i]);
        _editor.FontSize = Math.Max(FontSize, _font);
        _editor.Width = Math.Max(CellW + 20, _editor.FontSize * 6); _editor.Height = Math.Max(CellH + 2, _editor.FontSize + 8);
        var p = this.TranslatePoint(new Point(HeadW + (c0 * CellW) - 2, HeadH + (r0 * CellH) - 1), _host) ?? new Point();
        Canvas.SetLeft(_editor, p.X); Canvas.SetTop(_editor, p.Y);
        _editor.IsVisible = true;
        _editor.Focus();
        _editor.CaretIndex = _editor.Text?.Length ?? 0;
        if (initial == null) _editor.SelectAll();
        ToolTip.SetTip(_editor, "New value for the selected cells. Enter applies, Esc cancels. Prefix r for a raw value (r120), + or - for a change (+2, -0.5), * for a factor (*1.05); =-2 sets a negative value.");
    }

    /// Each selected cell to a value of its own, as one edit (a typed "+2" or "*1.05"): the values, and what to call the change.
    public event Action<IReadOnlyList<(int Index, double Value)>, string>? SetEach;

    void CommitEdit()
    {
        _editor.IsVisible = false;
        if (Model == null) return;
        var t = (_editor.Text ?? "").Trim();
        if (t.Length == 0) return;
        var sel = Selection();
        var inv = CultureInfo.InvariantCulture;
        if (t.StartsWith('r') && double.TryParse(t[1..], NumberStyles.Float, inv, out var raw)) { SetCells?.Invoke(sel, raw, true); return; }
        if (t.StartsWith('=')) t = t[1..].Trim();
        else if ((t[0] is '+' or '-') && double.TryParse(t, NumberStyles.Float, inv, out var delta))
        {
            // "+2" / "-2" change every selected cell by that much ("=-2" sets -2): one edit for all of them (one undo step, one write), not one per cell
            SetEach?.Invoke([.. sel.Select(i => (i, Model.Values[i] + delta))], $"{(delta >= 0 ? "+" : "")}{delta:0.###}");
            return;
        }
        if (t.StartsWith('*') && double.TryParse(t[1..], NumberStyles.Float, inv, out var factor))
        {
            SetEach?.Invoke([.. sel.Select(i => (i, Model.Values[i] * factor))], $"x {factor:0.###}");
            return;
        }
        if (double.TryParse(t, NumberStyles.Float, inv, out var v)) SetCells?.Invoke(sel, v, false);
        else Message?.Invoke($"'{t}' is not a number");
    }

    async void Copy()
    {
        if (Model == null) return;
        var (r0, c0, r1, c1) = SelectionRect();
        var sb = new System.Text.StringBuilder();
        for (int r = r0; r <= r1; r++)
            sb.AppendLine(string.Join("\t", Enumerable.Range(c0, c1 - c0 + 1).Select(c => Model.Format(Model[r, c]))));
        if (TopLevel.GetTopLevel(this)?.Clipboard is { } cb) await cb.SetTextAsync(sb.ToString());
        Message?.Invoke($"copied {(r1 - r0 + 1) * (c1 - c0 + 1)} cells");
    }

    async void Paste()
    {
        if (Model == null || ReadOnly || TopLevel.GetTopLevel(this)?.Clipboard is not { } cb) return;
        var text = await cb.TryGetTextAsync();
        if (string.IsNullOrWhiteSpace(text)) return;
        var (r0, c0, _, _) = SelectionRect();
        var list = new List<(int, double)>();
        var lines = text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        for (int dr = 0; dr < lines.Length; dr++)
        {
            var parts = lines[dr].Split(new[] { '\t', ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries);
            for (int dc = 0; dc < parts.Length; dc++)
            {
                int r = r0 + dr, c = c0 + dc;
                if (r >= Model.Rows || c >= Model.Cols) continue;
                if (double.TryParse(parts[dc], NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) list.Add(((r * Model.Cols) + c, v));
            }
        }
        PasteCells?.Invoke(list);
    }
}

/// Line view: one line per row across the columns (or per column down the rows), the cell the program is reading marked. Drag a point up or down to change it (every selected point moves with it), drag a box round points to select them.
public sealed class TableGraph : Control
{
    public TableModel? Model { get; set { field = value; InvalidateVisual(); } }

    /// false: x = columns, one line per row; true: x = rows, one line per column.
    public bool Transpose { get; set { field = value; InvalidateVisual(); } }

    /// Points dragged to new values: (cell, value) for each, written when the button is let go.
    public event Action<IReadOnlyList<(int Index, double Value)>>? SetCells;
    /// Cells picked here (a point clicked, or a box dragged round points): the block of rows and columns they span.
    public event Action<int, int, int, int>? SelectRange;
    /// The table grid: its selection is drawn here, and the keys go to it (so they work the same in every view).
    public TableGrid? Keys { get; set; }
    /// A view that only shows the table (a preview): its points cannot be dragged.
    public bool ReadOnly { get; set; }
    int _dragIndex = -1, _hoverIndex = -1;
    (int Index, double Start)[] _dragCells = [];
    double _dragStartValue;
    // the value scale is held still while a point is dragged, so the point stays under the pointer
    (double lo, double hi)? _frozen;
    Point? _bandStart, _bandEnd;
    const double Pad = 42;
    /// How near the pointer has to be to a point to take it (pixels).
    const double Grab = 16;
    /// Room down the right for the lines' names (none for a single line, or too many to name).
    const double LabelRoom = 52;
    double Right => Lines > 1 && Lines <= 40 ? LabelRoom : 12;

    public TableGraph() { ClipToBounds = true; MinHeight = 240; Focusable = true; }

    protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); Keys?.HandleKey(e); if (e.Handled) InvalidateVisual(); }

    int Lines => Model == null ? 0 : Transpose ? Model.Cols : Model.Rows;
    int Points => Model == null ? 0 : Transpose ? Model.Rows : Model.Cols;
    int Index(int line, int point) => Transpose ? (point * Model!.Cols) + line : (line * Model!.Cols) + point;

    (double lo, double hi) Range()
    {
        if (_frozen is { } f) return f;
        var m = Model!;
        double lo = m.Min, hi = m.Max;
        if (hi - lo < 1e-9) { lo -= 1; hi += 1; }
        double pad = (hi - lo) * 0.08;
        return (lo - pad, hi + pad);
    }

    Point Pos(int point, double v)
    {
        var (lo, hi) = Range();
        double w = Bounds.Width - Pad - Right, h = Bounds.Height - Pad - 10;
        double x = Pad + (Points <= 1 ? w / 2 : point * w / (Points - 1));
        double y = 10 + h - ((v - lo) / (hi - lo) * h);
        return new Point(x, y);
    }

    Point PosOf(int i) => Pos(Transpose ? i / Model!.Cols : i % Model!.Cols, Model.Values[i]);

    Rect PlotRect => new(Pad - 6, 4, Math.Max(0, Bounds.Width - Pad - Right + 6), Math.Max(0, Bounds.Height - Pad - 4));

    /// The right-click menu opens on the chart (its points and the area between the axes), not on the margins.
    public bool MenuAllowed(Point p) => Model != null && (Nearest(p) >= 0 || PlotRect.Contains(p));

    public override void Render(DrawingContext ctx)
    {
        ctx.FillRectangle(Dark.Back, new Rect(Bounds.Size));
        var m = Model;
        if (m == null || Points == 0) return;
        var (lo, hi) = Range();
        // the plot on a panel lit from above, so the lines stand off it
        var panel = new Rect(Pad, 10, Math.Max(0, Bounds.Width - Pad - Right), Math.Max(0, Bounds.Height - Pad - 10));
        ctx.FillRectangle(new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
            GradientStops = { new GradientStop(AppTheme.Map(Color.FromRgb(0x2b, 0x2e, 0x35)), 0), new GradientStop(AppTheme.Map(Color.FromRgb(0x1a, 0x1b, 0x1f)), 1) },
        }, panel, 4);
        var grid = new Pen(Dark.Grid, 1);
        var axisPen = new Pen(Dark.Axis, 1);
        double h = Bounds.Height - Pad - 10;
        for (int k = 0; k <= 5; k++)
        {
            double v = lo + ((hi - lo) * k / 5);
            double y = 10 + h - (h * k / 5);
            ctx.DrawLine(grid, new Point(Pad, y), new Point(Bounds.Width - Right, y));
            Label(ctx, m.Format(v), new Point(2, y - 7), 10);
        }
        var axis = Transpose ? m.RowAxis : m.ColAxis;
        int every = Math.Max(1, Points / 12);
        for (int p = 0; p < Points; p += every)
        {
            var at = Pos(p, lo);
            ctx.DrawLine(grid, new Point(at.X, 10), new Point(at.X, 10 + h));
            Label(ctx, p < axis.Length ? TableModel.Axis(axis[p]) : p.ToString(), new Point(at.X - 12, 10 + h + 4), 10);
        }
        Label(ctx, (Transpose ? m.RowUnit : m.ColUnit) + "  →", new Point(Bounds.Width - 90, Bounds.Height - 16), 10);
        ctx.DrawLine(axisPen, new Point(Pad, 10), new Point(Pad, 10 + h));
        ctx.DrawLine(axisPen, new Point(Pad, 10 + h), new Point(Bounds.Width - Right, 10 + h));

        // where the engine is: a band down the chart at the traced x, the traced line drawn thick and bright, the others dimmed, and a large marker on the interpolated value
        var tc = m.TraceCentre();
        double? traceX = null, traceLine = null;
        if (tc is { } t)
        {
            double pointPos = Transpose ? t.Row : t.Col, linePos = Transpose ? t.Col : t.Row;
            traceLine = linePos;
            double w = Bounds.Width - Pad - Right;
            traceX = Pad + (Points <= 1 ? w / 2 : Math.Clamp(pointPos, 0, Points - 1) * w / (Points - 1));
            var band = AppTheme.Brush(Color.FromArgb(55, TableModel.TraceColor.R, TableModel.TraceColor.G, TableModel.TraceColor.B));
            ctx.FillRectangle(band, new Rect(traceX.Value - 7, 10, 14, h));
            ctx.DrawLine(new Pen(AppTheme.Brush(TableModel.TraceColor), 1.5, dashStyle: DashStyle.Dash), new Point(traceX.Value, 10), new Point(traceX.Value, 10 + h));
        }
        var selected = Keys?.Model == m ? Keys.Selection().ToHashSet() : [];
        var rowAxis = Transpose ? m.ColAxis : m.RowAxis;
        var labels = new List<(double Y, string Text, Color Color)>();
        for (int pass = 0; pass < 2; pass++)
            for (int line = 0; line < Lines; line++)
            {
                bool traced = traceLine is double tl && Math.Abs(tl - line) < 1;
                if (pass == 0 == traced) continue;      // traced lines last, on top
                var color = Lines <= 1 ? Color.FromRgb(0x5a, 0x8c, 0xff) : HsvLine(line, Lines);
                byte alpha = traceLine == null || traced ? (byte)255 : (byte)95;
                var pts = new Point[Points];
                for (int p = 0; p < Points; p++) pts[p] = Pos(p, m.Values[Index(line, p)]);
                // the one line on its own, or the one the engine is on: a soft wash of its colour down to the axis
                if (Lines == 1 || traced) FillUnder(ctx, pts, 10 + h, color);
                Tube(ctx, pts, color, alpha, traced ? 4.4 : Lines > 16 ? 2.0 : 2.6);
                for (int p = 0; p < Points; p++)
                {
                    int i = Index(line, p);
                    var pt = pts[p];
                    bool hot = m.Heat.TryGetValue(i, out var heat);
                    bool sel = selected.Contains(i);
                    double rad = i == _hoverIndex || i == _dragIndex ? 8 : hot ? (heat >= 0.75 ? 8 : 6) : sel ? 6 : traced ? 5.2 : 4.2;
                    if (sel) ctx.DrawEllipse(null, new Pen(AppTheme.White, 2), pt, rad + 3, rad + 3);
                    if (hot)
                    {
                        ctx.DrawEllipse(null, new Pen(AppTheme.White, 2.5), pt, rad + 2.5, rad + 2.5);
                        Sphere(ctx, pt, rad, heat >= 0.75 ? TableModel.TraceColor : TableModel.TrailColor, 255);
                    }
                    else Sphere(ctx, pt, rad, color, alpha);
                }
                if (Lines > 1 && Points > 0)
                    labels.Add((pts[^1].Y, line < rowAxis.Length ? TableModel.Axis(rowAxis[line]) : line.ToString(), Color.FromArgb(alpha, color.R, color.G, color.B)));
            }
        // each line's name (its row / column heading) at its right-hand end, nudged apart where they would overlap
        if (labels.Count is > 0 and <= 40)
        {
            double last = double.NegativeInfinity;
            foreach (var (y, text, c) in labels.OrderBy(l => l.Y))
            {
                double at = Math.Max(y - 6, last + 12);
                last = at;
                ctx.DrawText(new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), 9.5,
                             AppTheme.Brush(c)), new Point(Bounds.Width - LabelRoom + 4, at));
            }
        }
        if (tc is { } tt && traceX is double tx)
        {
            // interpolated value at the trace point
            int r0 = (int)Math.Floor(Math.Clamp(tt.Row, 0, m.Rows - 1)), c0 = (int)Math.Floor(Math.Clamp(tt.Col, 0, m.Cols - 1));
            int r1 = Math.Min(r0 + 1, m.Rows - 1), c1 = Math.Min(c0 + 1, m.Cols - 1);
            double fr = Math.Clamp(tt.Row - r0, 0, 1), fc = Math.Clamp(tt.Col - c0, 0, 1);
            double v = (m[r0, c0] * (1 - fr) * (1 - fc)) + (m[r0, c1] * (1 - fr) * fc) + (m[r1, c0] * fr * (1 - fc)) + (m[r1, c1] * fr * fc);
            var p = new Point(tx, Pos(0, v).Y);
            ctx.DrawEllipse(null, new Pen(AppTheme.White, 3), p, 10, 10);
            ctx.DrawEllipse(AppTheme.Brush(TableModel.TraceColor), new Pen(AppTheme.Black, 1.5), p, 7, 7);
            var readout = new FormattedText($"{m.Format(v)} {m.Unit}", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), 11.5, Dark.Text);
            var at = new Point(Math.Min(tx + 14, Bounds.Width - Right - readout.Width - 10), p.Y - 26);
            ctx.DrawRectangle(AppTheme.Brush(Color.FromArgb(215, 14, 15, 18)), new Pen(AppTheme.Brush(TableModel.TraceColor), 1),
                              new Rect(at.X - 5, at.Y - 2, readout.Width + 10, readout.Height + 4), 4, 4);
            ctx.DrawText(readout, at);
        }
        if (_hoverIndex >= 0 && _hoverIndex < m.Values.Length)
        {
            int r = _hoverIndex / m.Cols, c = _hoverIndex % m.Cols;
            Label(ctx, $"[{r},{c}] {TableModel.Axis(r < m.RowAxis.Length ? m.RowAxis[r] : r)} {m.RowUnit} × {TableModel.Axis(c < m.ColAxis.Length ? m.ColAxis[c] : c)} {m.ColUnit} = {m.Format(m.Values[_hoverIndex])} {m.Unit}",
                new Point(Pad + 6, 12), 11);
        }
        Band.Draw(ctx, _bandStart, _bandEnd);
    }

    /// A line drawn as a lit tube: a soft shadow below it, a deeper shade of its colour for the body, and a bright streak along its upper edge.
    static void Tube(DrawingContext ctx, Point[] pts, Color c, byte alpha, double width)
    {
        if (pts.Length < 2) return;
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            g.BeginFigure(pts[0], false);
            for (int k = 1; k < pts.Length; k++) g.LineTo(pts[k]);
            g.EndFigure(false);
        }
        Pen P(Color col, byte a, double w) => new(AppTheme.Brush(Color.FromArgb(a, col.R, col.G, col.B)), w, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
        using (ctx.PushTransform(Matrix.CreateTranslation(1.6, 2.6)))
            ctx.DrawGeometry(null, P(Colors.Black, (byte)(alpha * 0.5), width + 2.5), geo);
        ctx.DrawGeometry(null, P(Mix(c, Colors.Black, 0.45), alpha, width + 1.4), geo);
        ctx.DrawGeometry(null, P(c, alpha, width), geo);
        using (ctx.PushTransform(Matrix.CreateTranslation(0, -width * 0.2)))
            ctx.DrawGeometry(null, P(Mix(c, Colors.White, 0.6), (byte)(alpha * 0.85), Math.Max(0.8, width * 0.32)), geo);
    }

    /// A point as a small shaded ball: lit from the upper left, darker towards its far edge.
    static void Sphere(DrawingContext ctx, Point at, double r, Color c, byte alpha)
    {
        ctx.DrawEllipse(AppTheme.Brush(Color.FromArgb((byte)(alpha * 0.45), 0, 0, 0)), null, at + new Point(1.2, 1.8), r, r);
        var ball = new RadialGradientBrush
        {
            Center = new RelativePoint(0.35, 0.3, RelativeUnit.Relative), GradientOrigin = new RelativePoint(0.35, 0.3, RelativeUnit.Relative),
            RadiusX = new RelativeScalar(0.75, RelativeUnit.Relative), RadiusY = new RelativeScalar(0.75, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(alpha, 255, 255, 255), 0),
                new GradientStop(With(Mix(c, Colors.White, 0.25), alpha), 0.3),
                new GradientStop(With(c, alpha), 0.65),
                new GradientStop(With(Mix(c, Colors.Black, 0.55), alpha), 1),
            },
        };
        ctx.DrawEllipse(ball, null, at, r, r);
    }

    /// A wash of the line's colour from the line down to the axis, fading out as it goes.
    static void FillUnder(DrawingContext ctx, Point[] pts, double floor, Color c)
    {
        if (pts.Length < 2) return;
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            g.BeginFigure(new Point(pts[0].X, floor), true);
            foreach (var p in pts) g.LineTo(p);
            g.LineTo(new Point(pts[^1].X, floor));
            g.EndFigure(true);
        }
        double top = pts.Min(p => p.Y);
        ctx.DrawGeometry(new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, top, RelativeUnit.Absolute), EndPoint = new RelativePoint(0, floor, RelativeUnit.Absolute),
            GradientStops = { new GradientStop(Color.FromArgb(70, c.R, c.G, c.B), 0), new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 1) },
        }, null, geo);
    }

    static Color Mix(Color a, Color b, double t) =>
        Color.FromRgb((byte)(a.R + ((b.R - a.R) * t)), (byte)(a.G + ((b.G - a.G) * t)), (byte)(a.B + ((b.B - a.B) * t)));
    static Color With(Color c, byte alpha) => Color.FromArgb(alpha, c.R, c.G, c.B);

    static Color HsvLine(int i, int n)
    {
        double hue = 220.0 - (220.0 * i / Math.Max(1, n - 1));     // blue (low rows) to red (high rows)
        double x = 1 - Math.Abs((hue / 60 % 2) - 1);
        var (r, g, b) = hue switch
        {
            < 60 => (1.0, x, 0.0), < 120 => (x, 1.0, 0.0), < 180 => (0.0, 1.0, x), _ => (0.0, x, 1.0),
        };
        return Color.FromRgb((byte)(80 + (r * 175)), (byte)(80 + (g * 160)), (byte)(80 + (b * 175)));
    }

    static void Label(DrawingContext ctx, string s, Point at, double size) =>
        ctx.DrawText(new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), size, Dark.Text), at);

    int Nearest(Point p)
    {
        if (Model == null) return -1;
        int best = -1; double bd = 100;
        for (int line = 0; line < Lines; line++)
            for (int q = 0; q < Points; q++)
            {
                int i = Index(line, q);
                var pt = Pos(q, Model.Values[i]);
                double d = Math.Sqrt(((pt.X - p.X) * (pt.X - p.X)) + ((pt.Y - p.Y) * (pt.Y - p.Y)));
                if (d < bd) { bd = d; best = i; }
            }
        return bd <= Grab ? best : -1;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        var pt = e.GetCurrentPoint(this);
        if (Model == null || !pt.Properties.IsLeftButtonPressed) return;
        var p = pt.Position;
        _dragIndex = ReadOnly ? -1 : Nearest(p);
        if (_dragIndex >= 0)
        {
            if (!TableDrag.Begin(Model, Keys, _dragIndex, e.KeyModifiers.HasFlag(KeyModifiers.Shift), SelectRange, out _dragCells)) _dragIndex = -1;
            _dragStartValue = _dragIndex >= 0 ? Model.Values[_dragIndex] : 0;
            _frozen = null;
            _frozen = Range();
        }
        else if (PlotRect.Contains(p)) _bandStart = _bandEnd = p;
        InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (Model == null) return;
        var p = e.GetPosition(this);
        if (_dragIndex >= 0 && e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            var (lo, hi) = Range();
            double h = Bounds.Height - Pad - 10;
            double v = lo + ((10 + h - p.Y) / h * (hi - lo));
            foreach (var (i, start) in _dragCells) Model.Values[i] = start + (v - _dragStartValue);     // preview; the host writes and refreshes on release
            Model.Touch();
            InvalidateVisual();
            return;
        }
        if (_bandStart != null) { _bandEnd = p; InvalidateVisual(); return; }
        int hover = Nearest(p);
        if (hover != _hoverIndex) { _hoverIndex = hover; InvalidateVisual(); }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (Model != null)
        {
            if (_dragIndex >= 0) TableDrag.End(Model, _dragCells, SetCells);
            if (Band.Picked(_bandStart, _bandEnd, Model, PosOf) is { } range) SelectRange?.Invoke(range.R0, range.C0, range.R1, range.C1);
        }
        _dragIndex = -1; _dragCells = []; _frozen = null;
        _bandStart = _bandEnd = null;
        InvalidateVisual();
    }
}

/// Picking and dragging points in the Line and 3D views, the same in both.
static class TableDrag
{
    /// A point was pressed: with Shift, the selection grows to take it in (and nothing is dragged); on a point already in a selection of several, the whole selection is dragged; otherwise the point alone is selected and dragged.
    public static bool Begin(TableModel m, TableGrid? keys, int index, bool shift, Action<int, int, int, int>? select, out (int Index, double Start)[] cells)
    {
        int r = index / m.Cols, c = index % m.Cols;
        var sel = keys?.Model == m ? keys.Selection() : [];
        cells = [];
        if (shift && keys?.Model == m)
        {
            var (r0, c0, r1, c1) = keys.SelectionRect();
            select?.Invoke(Math.Min(r0, r), Math.Min(c0, c), Math.Max(r1, r), Math.Max(c1, c));
            return false;
        }
        if (!(sel.Count > 1 && sel.Contains(index))) { select?.Invoke(r, c, r, c); sel = [index]; }
        cells = [.. sel.Select(i => (i, m.Values[i]))];
        return true;
    }

    /// The button was let go: the points that moved are written (and the rest left as they were).
    public static void End(TableModel m, (int Index, double Start)[] cells, Action<IReadOnlyList<(int Index, double Value)>>? write)
    {
        if (cells.Length == 0 || cells.All(x => m.Values[x.Index] == x.Start)) return;
        write?.Invoke([.. cells.Select(x => (x.Index, m.Values[x.Index]))]);
    }
}

/// The box dragged round points to select them.
static class Band
{
    static readonly IBrush Fill = AppTheme.Brush(Color.FromArgb(45, 120, 170, 255));
    static readonly Pen Edge = new(AppTheme.Brush(Color.FromRgb(120, 170, 255)), 1, dashStyle: DashStyle.Dash);

    public static Rect Of(Point a, Point b) => new(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));

    public static void Draw(DrawingContext ctx, Point? a, Point? b)
    {
        if (a is not { } p || b is not { } q) return;
        var r = Of(p, q);
        ctx.FillRectangle(Fill, r);
        ctx.DrawRectangle(null, Edge, r);
    }

    /// The rows and columns the points inside the box span, or null (a click, or nothing inside).
    public static (int R0, int C0, int R1, int C1)? Picked(Point? a, Point? b, TableModel m, Func<int, Point> pos)
    {
        if (a is not { } p || b is not { } q) return null;
        var r = Of(p, q);
        if (r.Width < 4 && r.Height < 4) return null;
        var inside = Enumerable.Range(0, m.Values.Length).Where(i => r.Contains(pos(i))).ToList();
        if (inside.Count == 0) return null;
        return (inside.Min(i => i / m.Cols), inside.Min(i => i % m.Cols), inside.Max(i => i / m.Cols), inside.Max(i => i % m.Cols));
    }
}

/// 3D view: the table as a coloured surface, with its scales on the edges nearest you and a colour key. Left-drag a point up or down to change it (the selected points move together), left-drag round points to select them, right-drag to turn the view, middle-drag to move it, wheel to zoom, double-click the background (or Home) to put it back; the table keys work here too.
public sealed class TableSurface : Control
{
    public TableModel? Model { get; set { field = value; InvalidateVisual(); } }
    /// The table grid: its selection is drawn and edited here, and the keys go to it.
    public TableGrid? Keys { get; set; }
    /// A view that only shows the table (a preview): its points cannot be dragged.
    public bool ReadOnly { get; set; }
    /// Points dragged to new values: (cell, value) for each, written when the button is let go.
    public event Action<IReadOnlyList<(int Index, double Value)>>? SetCells;
    /// Cells picked here: the block of rows and columns they span.
    public event Action<int, int, int, int>? SelectRange;

    const double Yaw0 = -0.7, Pitch0 = 0.55;
    double _yaw = Yaw0, _pitch = Pitch0, _zoom = 1, _panX, _panY;
    Point? _turn, _pan;
    Point _rightDown;
    bool _rightDragged;
    int _dragIndex = -1, _hoverIndex = -1;
    (int Index, double Start)[] _dragCells = [];
    double _dragStartY;
    // the value scale is held still while points are dragged
    bool _frozen;
    double _lo, _hi;
    Point? _bandStart, _bandEnd;
    readonly List<Point[]> _quads = [];
    const double Grab = 14;

    static readonly Typeface Face = new(MainWindow.MonoFont);
    static readonly Typeface BoldFace = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.Bold);
    static readonly IBrush PlateBg = AppTheme.Brush(Color.FromArgb(200, 14, 15, 18));
    static readonly IBrush RowInk = AppTheme.Brush(Color.FromRgb(255, 190, 110));
    static readonly IBrush ColInk = AppTheme.Brush(Color.FromRgb(120, 200, 255));
    static readonly IBrush ValueInk = AppTheme.Brush(Color.FromRgb(170, 240, 150));

    public TableSurface()
    {
        ClipToBounds = true; MinHeight = 260; Focusable = true;
        // two fingers: pinch to zoom (a touch screen)
        GestureRecognizers.Add(new PinchGestureRecognizer());
        double pinchFrom = 1;
        AddHandler(Gestures.PinchEvent, (_, e) => { if (e.Scale > 0) { _zoom = Math.Clamp(pinchFrom * e.Scale, 0.3, 6); InvalidateVisual(); } });
        AddHandler(Gestures.PinchEndedEvent, (_, _) => pinchFrom = _zoom);
        PointerPressed += (_, _) => pinchFrom = _zoom;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (TableKeys.Match(e) == "Reset the 3D view") { SetView("reset"); e.Handled = true; return; }
        Keys?.HandleKey(e);
        if (e.Handled) InvalidateVisual();
    }

    /// A table action that belongs to this view (Reset the 3D view); false for the others.
    public bool Run(string id)
    {
        if (id != "Reset the 3D view") return false;
        SetView("reset");
        return true;
    }

    /// Turn the view to an exact angle (the pictures of the 3D view being turned round).
    public void SetAngles(double yaw, double pitch) { _yaw = yaw; _pitch = pitch; InvalidateVisual(); }

    /// "reset" (where it starts), "top", "front", "side", "under", "left" / "right" (an eighth of a turn), "up" / "down" (tilt).
    public void SetView(string view)
    {
        switch (view)
        {
            case "reset": _yaw = Yaw0; _pitch = Pitch0; _zoom = 1; _panX = _panY = 0; break;
            case "top": _yaw = 0; _pitch = Math.PI / 2; break;
            case "front": _yaw = 0; _pitch = 0.12; break;
            case "side": _yaw = -Math.PI / 2; _pitch = 0.12; break;
            case "under": _pitch = -0.6; break;
            case "left": _yaw -= Math.PI / 4; break;
            case "right": _yaw += Math.PI / 4; break;
            case "up": _pitch = Math.Clamp(_pitch + 0.2, -1.2, Math.PI / 2); break;
            case "down": _pitch = Math.Clamp(_pitch - 0.2, -1.2, Math.PI / 2); break;
            case "zoomin": _zoom = Math.Clamp(_zoom * 1.25, 0.3, 6); break;
            case "zoomout": _zoom = Math.Clamp(_zoom / 1.25, 0.3, 6); break;
        }
        InvalidateVisual();
    }

    (double lo, double hi) Scale() => _frozen ? (_lo, _hi) : (Model!.Min, Model.Max);
    double Zv(double v) { var (lo, hi) = Scale(); return (v - lo) / (hi - lo < 1e-9 ? 1 : hi - lo); }
    double Xc(int c) => Model!.Cols == 1 ? 0 : (c * 2.0 / (Model.Cols - 1)) - 1;
    double Yr(int r) => Model!.Rows == 1 ? 0 : (r * 2.0 / (Model.Rows - 1)) - 1;

    /// Where each cell's point is on screen now.
    Point PointOf(int i) => Project(Xc(i % Model!.Cols), Yr(i / Model.Cols), Zv(Model.Values[i])).p;

    int Nearest(Point p)
    {
        if (Model == null) return -1;
        int best = -1; double bd = Grab;
        for (int i = 0; i < Model.Values.Length; i++)
        {
            var q = PointOf(i);
            double d = Math.Sqrt(((q.X - p.X) * (q.X - p.X)) + ((q.Y - p.Y) * (q.Y - p.Y)));
            if (d <= bd) { bd = d; best = i; }
        }
        return best;
    }

    double UnitScale => Math.Min(Bounds.Width, Bounds.Height) * 0.32 * _zoom;

    (Point p, double depth) Project(double x, double y, double z)
    {
        // x, y in [-1,1] (columns, rows), z in [0,1] (value)
        double cx = Math.Cos(_yaw), sx = Math.Sin(_yaw), cp = Math.Cos(_pitch), sp = Math.Sin(_pitch);
        double X = (x * cx) - (y * sx);
        double Y = (x * sx) + (y * cx);
        double Z = (z - 0.5) * 1.1;
        double py = (Y * sp) - (Z * cp);
        double depth = (Y * cp) + (Z * sp);
        double scale = UnitScale;
        return (new Point((Bounds.Width / 2) + _panX + (X * scale), (Bounds.Height / 2) + _panY + (py * scale)), depth);
    }

    /// Over the table itself: on a point or on the surface.
    public bool OverTable(Point p) => Model != null && (Nearest(p) >= 0 || _quads.Any(q => Inside(q, p)));
    /// The right-click menu opens on the table, and not at the end of a right-drag that turned the view.
    public bool MenuAllowed(Point p) => !_rightDragged && OverTable(p);

    static bool Inside(Point[] poly, Point p)
    {
        bool inside = false;
        for (int i = 0, j = poly.Length - 1; i < poly.Length; j = i++)
            if ((poly[i].Y > p.Y) != (poly[j].Y > p.Y) && p.X < ((poly[j].X - poly[i].X) * (p.Y - poly[i].Y) / (poly[j].Y - poly[i].Y)) + poly[i].X)
                inside = !inside;
        return inside;
    }

    /// Text on a dark plate, so a scale reads over the surface and the grid. align: 0 left, 0.5 centre, 1 right of `at`.
    static void Plate(DrawingContext ctx, string s, Point at, double size, IBrush ink, bool bold = false, double align = 0.5)
    {
        if (s.Length == 0) return;
        var ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, bold ? BoldFace : Face, size, ink);
        var r = new Rect(at.X - (ft.Width * align) - 3, at.Y - (ft.Height / 2) - 1, ft.Width + 6, ft.Height + 2);
        ctx.FillRectangle(PlateBg, r, 3);
        ctx.DrawText(ft, new Point(r.X + 3, r.Y + 1));
    }

    static string AxisText(double[] axis, int i) => i < axis.Length ? TableModel.Axis(axis[i]) : i.ToString();

    public override void Render(DrawingContext ctx)
    {
        ctx.FillRectangle(Dark.Back, new Rect(Bounds.Size));
        _quads.Clear();
        var m = Model;
        if (m == null || m.Rows < 1 || m.Cols < 1) return;
        var (lo, hi) = Scale();
        double span = hi - lo < 1e-9 ? 1 : hi - lo;
        double Z(int r, int c) => Zv(m[r, c]);

        // the floor: its outline and a line under every column and row it is labelled at
        var floorPen = new Pen(Dark.Grid, 1);
        var edgePen = new Pen(Dark.Axis, 1.2);
        // the edges nearest you carry the scales: the column axis along the lower edge on screen, the row axis along the right one
        double yEdge = Project(0, 1, 0).p.Y >= Project(0, -1, 0).p.Y ? 1 : -1;
        double xEdge = Project(1, 0, 0).p.X >= Project(-1, 0, 0).p.X ? 1 : -1;
        int everyC = Math.Max(1, (int)Math.Ceiling(m.Cols / 8.0)), everyR = Math.Max(1, (int)Math.Ceiling(m.Rows / 8.0));
        var colTicks = Enumerable.Range(0, m.Cols).Where(c => c % everyC == 0 || c == m.Cols - 1).ToList();
        var rowTicks = Enumerable.Range(0, m.Rows).Where(r => r % everyR == 0 || r == m.Rows - 1).ToList();
        foreach (var c in colTicks) ctx.DrawLine(floorPen, Project(Xc(c), -1, 0).p, Project(Xc(c), 1, 0).p);
        foreach (var r in rowTicks) ctx.DrawLine(floorPen, Project(-1, Yr(r), 0).p, Project(1, Yr(r), 0).p);
        var corners = new[] { Project(-1, -1, 0).p, Project(1, -1, 0).p, Project(1, 1, 0).p, Project(-1, 1, 0).p };
        for (int k = 0; k < 4; k++) ctx.DrawLine(edgePen, corners[k], corners[(k + 1) % 4]);

        // the value post, at the far corner, with a tick at every quarter of the range (not from straight above: it would be a dot)
        bool post = Math.Abs(Math.Cos(_pitch)) > 0.25;
        var postBase = Project(-xEdge, -yEdge, 0);
        if (post)
        {
            ctx.DrawLine(new Pen(ValueInk, 1.2), postBase.p, Project(-xEdge, -yEdge, 1).p);
            for (int k = 0; k <= 4; k++)
            {
                var at = Project(-xEdge, -yEdge, k / 4.0).p;
                ctx.DrawLine(new Pen(ValueInk, 1.2), at, new Point(at.X - 6, at.Y));
                Plate(ctx, m.Format(lo + (span * k / 4)), new Point(at.X - 9, at.Y), 11, ValueInk, align: 1);
            }
            Plate(ctx, m.Unit, new Point(Project(-xEdge, -yEdge, 1).p.X, Project(-xEdge, -yEdge, 1).p.Y - 16), 12, ValueInk, bold: true);
        }

        // the surface, back to front
        var quads = new List<(double depth, Point[] pts, Color color, bool hot)>();
        int rr = Math.Max(1, m.Rows - 1), cc = Math.Max(1, m.Cols - 1);
        for (int r = 0; r < rr; r++)
            for (int c = 0; c < cc; c++)
            {
                int r1 = Math.Min(r + 1, m.Rows - 1), c1 = Math.Min(c + 1, m.Cols - 1);
                var a = Project(Xc(c), Yr(r), Z(r, c)); var b = Project(Xc(c1), Yr(r), Z(r, c1));
                var d = Project(Xc(c1), Yr(r1), Z(r1, c1)); var e = Project(Xc(c), Yr(r1), Z(r1, c));
                double v = (m[r, c] + m[r, c1] + m[r1, c1] + m[r1, c]) / 4;
                bool hot = new[] { (r * m.Cols) + c, (r * m.Cols) + c1, (r1 * m.Cols) + c, (r1 * m.Cols) + c1 }.Any(i => m.Heat.TryGetValue(i, out var h) && h >= 0.75);
                quads.Add(((a.depth + b.depth + d.depth + e.depth) / 4, new[] { a.p, b.p, d.p, e.p }, m.CellColor(v), hot));
            }
        var edge = new Pen(AppTheme.Brush(Color.FromArgb(140, 20, 20, 24)), 0.6);
        foreach (var q in quads.OrderByDescending(q => q.depth))
        {
            _quads.Add(q.pts);
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                g.BeginFigure(q.pts[0], true);
                for (int k = 1; k < 4; k++) g.LineTo(q.pts[k]);
                g.EndFigure(true);
            }
            ctx.DrawGeometry(AppTheme.Brush(q.hot ? TableModel.TraceColor : q.color), q.hot ? new Pen(Dark.Text, 1.2) : edge, geo);
        }

        // the scales on the near edges, over the surface so they are never hidden
        foreach (var c in colTicks) Plate(ctx, AxisText(m.ColAxis, c), Project(Xc(c), yEdge * 1.14, 0).p, 11, ColInk);
        foreach (var r in rowTicks) Plate(ctx, AxisText(m.RowAxis, r), Project(xEdge * 1.14, Yr(r), 0).p, 11, RowInk, align: 0);
        Plate(ctx, m.ColUnit + "  →", Project(0, yEdge * 1.36, 0).p, 12, ColInk, bold: true);
        Plate(ctx, m.RowUnit + "  →", Project(xEdge * 1.42, 0, 0).p, 12, RowInk, bold: true, align: 0);

        // the colour key, down the right-hand side
        double keyH = Math.Clamp(Bounds.Height - 120, 60, 220), keyX = Bounds.Width - 26, keyY = 44;
        for (int k = 0; k < 40; k++)
        {
            double t0 = 1 - (k / 40.0);
            ctx.FillRectangle(AppTheme.Brush(m.CellColor(lo + (span * t0))), new Rect(keyX, keyY + (keyH * k / 40), 14, (keyH / 40) + 0.5));
        }
        ctx.DrawRectangle(null, new Pen(Dark.Axis, 1), new Rect(keyX, keyY, 14, keyH));
        Plate(ctx, m.Format(hi), new Point(keyX - 4, keyY), 11, Dark.Text, align: 1);
        Plate(ctx, m.Format((lo + hi) / 2), new Point(keyX - 4, keyY + (keyH / 2)), 11, Dark.Text, align: 1);
        Plate(ctx, m.Format(lo), new Point(keyX - 4, keyY + keyH), 11, Dark.Text, align: 1);
        Plate(ctx, m.Unit, new Point(keyX + 7, keyY - 14), 11, Dark.Text, bold: true);

        if (m.TraceCentre() is { } tc)
        {
            double x = m.Cols == 1 ? 0 : (tc.Col * 2 / (m.Cols - 1)) - 1, y = m.Rows == 1 ? 0 : (tc.Row * 2 / (m.Rows - 1)) - 1;
            int r0 = (int)Math.Round(tc.Row), c0 = (int)Math.Round(tc.Col);
            var p = Project(x, y, Z(Math.Clamp(r0, 0, m.Rows - 1), Math.Clamp(c0, 0, m.Cols - 1)) + 0.03);
            ctx.DrawEllipse(Brushes.White, new Pen(AppTheme.Black, 1.5), p.p, 5, 5);
        }
        // the points: the selected cells and the one under the pointer, large enough to take hold of
        var sel = Keys?.Model == m ? Keys.Selection() : [];
        foreach (var i in sel.Append(_hoverIndex).Append(_dragIndex).Where(i => i >= 0 && i < m.Values.Length).Distinct())
        {
            var q = PointOf(i);
            bool active = i == _hoverIndex || i == _dragIndex;
            ctx.DrawEllipse(AppTheme.Brush(active ? Colors.White : TableModel.TrailColor), new Pen(AppTheme.Black, 1.2), q, active ? 7 : 5, active ? 7 : 5);
        }
        if (_hoverIndex >= 0 && _hoverIndex < m.Values.Length)
        {
            int r = _hoverIndex / m.Cols, c = _hoverIndex % m.Cols;
            Plate(ctx, $"[{r},{c}]  {AxisText(m.RowAxis, r)} {m.RowUnit} × {AxisText(m.ColAxis, c)} {m.ColUnit} = {m.Format(m.Values[_hoverIndex])} {m.Unit}",
                new Point(6, 24), 12, Dark.Text, align: 0);
        }
        Band.Draw(ctx, _bandStart, _bandEnd);
        ctx.DrawText(new FormattedText("left-drag a point: change it (selected points move together) · left-drag round points: select · right-drag: turn · middle-drag: move · wheel: zoom · double-click or Home: reset",
            CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 10, Dark.Dim), new Point(6, 4));
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        var pt = e.GetCurrentPoint(this);
        var p = pt.Position;
        if (pt.Properties.IsRightButtonPressed) { _turn = p; _rightDown = p; _rightDragged = false; return; }
        if (pt.Properties.IsMiddleButtonPressed) { _pan = p; return; }
        if (!pt.Properties.IsLeftButtonPressed || Model == null) return;
        _dragIndex = ReadOnly ? -1 : Nearest(p);
        if (_dragIndex >= 0)
        {
            if (!TableDrag.Begin(Model, Keys, _dragIndex, e.KeyModifiers.HasFlag(KeyModifiers.Shift), SelectRange, out _dragCells)) _dragIndex = -1;
            _lo = Model.Min; _hi = Model.Max; _frozen = true;
            _dragStartY = p.Y;
        }
        else if (e.ClickCount == 2) SetView("reset");
        else _bandStart = _bandEnd = p;
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (Model != null)
        {
            if (_dragIndex >= 0) TableDrag.End(Model, _dragCells, SetCells);
            if (Band.Picked(_bandStart, _bandEnd, Model, PointOf) is { } range) SelectRange?.Invoke(range.R0, range.C0, range.R1, range.C1);
        }
        _dragIndex = -1; _dragCells = []; _frozen = false;
        _bandStart = _bandEnd = null;
        _turn = null; _pan = null;
        InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var p = e.GetPosition(this);
        if (_dragIndex >= 0 && Model != null)
        {
            // up the screen is up the scale: the table's whole range over the height of the surface
            double span = Math.Max(1e-9, _hi - _lo);
            double height = UnitScale * 1.1 * Math.Max(0.15, Math.Abs(Math.Cos(_pitch)));
            double d = (_dragStartY - p.Y) / Math.Max(20, height) * span;
            foreach (var (i, start) in _dragCells) Model.Values[i] = start + d;
            InvalidateVisual();
            return;
        }
        if (_bandStart != null) { _bandEnd = p; InvalidateVisual(); return; }
        if (_turn is { } l)
        {
            if (Math.Abs(p.X - _rightDown.X) + Math.Abs(p.Y - _rightDown.Y) > 4) _rightDragged = true;
            _yaw += (p.X - l.X) * 0.01;
            _pitch = Math.Clamp(_pitch + ((p.Y - l.Y) * 0.01), -1.2, Math.PI / 2);
            _turn = p;
            InvalidateVisual();
            return;
        }
        if (_pan is { } q)
        {
            _panX += p.X - q.X; _panY += p.Y - q.Y;
            _pan = p;
            InvalidateVisual();
            return;
        }
        int hover = Nearest(p);
        if (hover != _hoverIndex) { _hoverIndex = hover; InvalidateVisual(); }
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        _zoom = Math.Clamp(_zoom * (e.Delta.Y > 0 ? 1.1 : 0.9), 0.3, 6);
        InvalidateVisual();
        e.Handled = true;
    }
}

public static class UiStyles
{
    /// Take a control out of whatever it is in now. Moving a control between panels (the Definition bar, Tuner mode, the lower tabs) throws "already has a visual parent" unless the old parent lets go first, and a logical parent can be any of these.
    public static T Adopt<T>(T c) where T : Control
    {
        switch (c.Parent)
        {
            case Panel p: p.Children.Remove(c); break;
            case ContentControl cc when ReferenceEquals(cc.Content, c): cc.Content = null; break;
            case Decorator d when ReferenceEquals(d.Child, c): d.Child = null; break;
            case ContentPresenter cp when ReferenceEquals(cp.Content, c): cp.Content = null; break;
            case ItemsControl ic: ic.Items.Remove(c); break;
        }
        return c;
    }

    /// Tighter rows for long lists (the Fluent default leaves a lot of air around each item).
    public static T Compact<T>(T list) where T : ListBox
    {
        list.Styles.Add(new Avalonia.Styling.Style(x => x.OfType<ListBoxItem>())
        {
            Setters =
            {
                new Avalonia.Styling.Setter(Avalonia.Controls.Primitives.TemplatedControl.PaddingProperty, new Thickness(6, 1)),
                new Avalonia.Styling.Setter(Avalonia.Layout.Layoutable.MinHeightProperty, 0d),
            },
        });
        return list;
    }
}

/// Colours for the dark-theme chart views (the table grid keeps the the tuning software white look).
static class Dark
{
    public static readonly IBrush Back = AppTheme.Brush(Color.FromRgb(0x1e, 0x1f, 0x22));
    public static readonly IBrush Grid = AppTheme.Brush(Color.FromRgb(0x33, 0x36, 0x3c));
    public static readonly IBrush Axis = AppTheme.Brush(Color.FromRgb(0x8a, 0x8f, 0x98));
    public static readonly IBrush Text = AppTheme.Brush(Color.FromRgb(0xd7, 0xda, 0xe0));
    public static readonly IBrush Dim = AppTheme.Brush(Color.FromRgb(0x80, 0x84, 0x8c));
}
