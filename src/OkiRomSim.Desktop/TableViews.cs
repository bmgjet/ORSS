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
    public double[] Values { get => _values; set { _values = value; Touch(); } }
    double[] _values = Array.Empty<double>();
    public double[] Raw { get; set; } = Array.Empty<double>();
    public double[] RowAxis { get; init; } = Array.Empty<double>();
    public double[] ColAxis { get; init; } = Array.Empty<double>();
    public string RowUnit { get; init; } = "";
    public string ColUnit { get; init; } = "";
    public string Unit { get; init; } = "";
    public int Decimals { get; init; } = 1;
    /// cell index -> heat: 1 = read by the program just now, fading towards 0 = read a while ago.
    public Dictionary<int, double> Heat { get; set; } = new();
    /// Where the engine is on this table from a datalog frame, as fractional (row, col); wins over the program's reads (Tuner mode: the trace comes from the car, not the simulator).
    public (double Row, double Col)? ExternalTrace { get; set; }
    /// A logged channel averaged per cell (AFR, knock...), drawn in the cell corner.
    public double[]? Overlay { get; set; }
    public int[]? OverlayCount { get; set; }
    public string OverlayName { get; set; } = "";
    // min / max are needed for every cell's colour: work them out once per change of values
    double _min, _max;
    public double Min => _min;
    public double Max => _max;
    /// Call after changing Values in place.
    public void Touch()
    {
        double lo = double.MaxValue, hi = double.MinValue;
        foreach (var v in _values) { if (double.IsNaN(v)) continue; if (v < lo) lo = v; if (v > hi) hi = v; }
        if (lo > hi) lo = hi = 0;
        _min = lo; _max = hi;
    }
    [System.Runtime.CompilerServices.IndexerName("Cell")]
    public double this[int r, int c] => Values[r * Cols + c];

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
        if (t < 0.5) return Mix(C2, C3, (t - 0.08) / 0.42);
        return Mix(C3, C4, (t - 0.5) / 0.5);
    }

    public static Color Mix(Color a, Color b, double t)
    {
        t = Math.Clamp(t, 0, 1);
        return Color.FromRgb((byte)(a.R + (b.R - a.R) * t), (byte)(a.G + (b.G - a.G) * t), (byte)(a.B + (b.B - a.B) * t));
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

/// The table as the tuning software draws it: RPM rows down the left, load columns across the top, every cell coloured by its value, the cells the program is reading outlined in aqua with a lime trail. Click/drag/shift+arrows select; type a number (or double-click) to edit; Enter applies it to the whole selection.
public sealed class TableGrid : Control
{
    public TableModel? Model { get => _model; set { _model = value; ClampSelection(); InvalidateMeasure(); InvalidateVisual(); } }
    TableModel? _model;

    public const double CellW = 46, CellH = 19, HeadW = 58, HeadH = 20;
    static readonly Typeface Face = new(MainWindow.MonoFont);
    static readonly Typeface Bold = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.Bold);
    const double FontSize = 11;
    // laid-out text is by far the most expensive part of drawing a map; keep it between frames
    static readonly Dictionary<(string, bool, double, uint), FormattedText> TextCache = new();
    static readonly Pen CellEdge = new(new SolidColorBrush(Color.FromRgb(120, 120, 120)), 0.5);
    static readonly IBrush HeadBg = new SolidColorBrush(Color.FromRgb(224, 224, 224));
    static readonly IBrush HeadSel = new SolidColorBrush(Color.FromRgb(190, 205, 235));
    static readonly IBrush OverlayInk = new SolidColorBrush(Color.FromRgb(40, 40, 140));

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
        if (_model == null) return list;
        int r0 = Math.Min(_anchor.r, _cursor.r), r1 = Math.Max(_anchor.r, _cursor.r);
        int c0 = Math.Min(_anchor.c, _cursor.c), c1 = Math.Max(_anchor.c, _cursor.c);
        for (int r = r0; r <= r1; r++) for (int c = c0; c <= c1; c++) list.Add(r * _model.Cols + c);
        return list;
    }
    public (int R0, int C0, int R1, int C1) SelectionRect() =>
        (Math.Min(_anchor.r, _cursor.r), Math.Min(_anchor.c, _cursor.c), Math.Max(_anchor.r, _cursor.r), Math.Max(_anchor.c, _cursor.c));

    public void SelectCell(int r, int c)
    {
        _anchor = _cursor = (r, c);
        ClampSelection();
        InvalidateVisual();
    }

    void ClampSelection()
    {
        if (_model == null) return;
        (int, int) Clamp((int r, int c) p) => (Math.Clamp(p.r, 0, Math.Max(0, _model.Rows - 1)), Math.Clamp(p.c, 0, Math.Max(0, _model.Cols - 1)));
        _anchor = Clamp(_anchor); _cursor = Clamp(_cursor);
    }

    protected override Size MeasureOverride(Size availableSize) =>
        _model == null ? new Size(0, 0) : new Size(HeadW + _model.Cols * CellW + 1, HeadH + _model.Rows * CellH + 1);

    public override void Render(DrawingContext ctx)
    {
        var m = _model;
        if (m == null) return;
        var black = new Pen(Brushes.Black, 1);
        var headBg = HeadBg;
        ctx.FillRectangle(Brushes.White, new Rect(0, 0, HeadW + m.Cols * CellW, HeadH + m.Rows * CellH));
        // corner
        ctx.FillRectangle(headBg, new Rect(0, 0, HeadW, HeadH));
        Text(ctx, $"{m.RowUnit}\\{m.ColUnit}", new Rect(0, 0, HeadW, HeadH), Brushes.Black, 9);
        var (sr0, sc0, sr1, sc1) = SelectionRect();
        for (int c = 0; c < m.Cols; c++)
        {
            var rc = new Rect(HeadW + c * CellW, 0, CellW, HeadH);
            ctx.FillRectangle(c >= sc0 && c <= sc1 ? HeadSel : headBg, rc);
            Text(ctx, c < m.ColAxis.Length ? TableModel.Axis(m.ColAxis[c]) : c.ToString(), rc, Brushes.Black, FontSize, bold: true);
            ctx.DrawRectangle(null, black, rc);
        }
        var ext = m.ExternalTrace;
        for (int r = 0; r < m.Rows; r++)
        {
            var rh = new Rect(0, HeadH + r * CellH, HeadW, CellH);
            ctx.FillRectangle(r >= sr0 && r <= sr1 ? HeadSel : headBg, rh);
            Text(ctx, r < m.RowAxis.Length ? TableModel.Axis(m.RowAxis[r]) : r.ToString(), rh, Brushes.Black, FontSize, bold: true);
            ctx.DrawRectangle(null, black, rh);
            for (int c = 0; c < m.Cols; c++)
            {
                int i = r * m.Cols + c;
                var rc = new Rect(HeadW + c * CellW, HeadH + r * CellH, CellW, CellH);
                var color = m.CellColor(m.Values[i]);
                if (m.Heat.TryGetValue(i, out var h))
                    color = h >= 0.75 ? TableModel.TraceColor : TableModel.Mix(color, TableModel.TrailColor, h / 0.75 * 0.8 + 0.2);
                else if (ext is { } e && Math.Abs(e.Row - r) < 1 && Math.Abs(e.Col - c) < 1)
                    color = TableModel.Mix(color, TableModel.TraceColor, 1 - Math.Max(Math.Abs(e.Row - r), Math.Abs(e.Col - c)));
                ctx.FillRectangle(new SolidColorBrush(color), rc);
                if (m.Overlay is { } ov && i < ov.Length && !double.IsNaN(ov[i]))
                {
                    Text(ctx, m.Format(m.Values[i]), new Rect(rc.X, rc.Y - 3, rc.Width, rc.Height), Brushes.Black, FontSize - 1);
                    Text(ctx, ov[i].ToString(Math.Abs(ov[i]) >= 100 ? "0" : "0.0#", CultureInfo.InvariantCulture), new Rect(rc.X, rc.Y + 6, rc.Width, rc.Height), OverlayInk, 8);
                }
                else Text(ctx, m.Format(m.Values[i]), rc, Brushes.Black, FontSize);
                ctx.DrawRectangle(null, CellEdge, rc);
            }
        }
        // selection outline (the tuning software draws a thick black frame)
        var sel = new Rect(HeadW + sc0 * CellW, HeadH + sr0 * CellH, (sc1 - sc0 + 1) * CellW, (sr1 - sr0 + 1) * CellH);
        ctx.DrawRectangle(null, new Pen(Brushes.Black, 2.5), sel);
        ctx.DrawRectangle(null, new Pen(Brushes.White, 1), sel.Deflate(2));
        // where the program is reading, interpolated
        if (m.TraceCentre() is { } tc)
        {
            var p = new Point(HeadW + (tc.Col + 0.5) * CellW, HeadH + (tc.Row + 0.5) * CellH);
            ctx.DrawEllipse(null, new Pen(Brushes.Black, 2), p, 5, 5);
            ctx.DrawEllipse(null, new Pen(Brushes.White, 1), p, 3, 3);
        }
    }

    static void Text(DrawingContext ctx, string s, Rect rc, IBrush brush, double size, bool bold = false)
    {
        uint ink = brush is ISolidColorBrush sb ? sb.Color.ToUInt32() : 0;
        var key = (s, bold, size, ink);
        if (!TextCache.TryGetValue(key, out var ft))
        {
            if (TextCache.Count > 4000) TextCache.Clear();      // bounded: this is a cache, not a store
            ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, bold ? Bold : Face, size, brush);
            TextCache[key] = ft;
        }
        ctx.DrawText(ft, new Point(rc.X + (rc.Width - ft.Width) / 2, rc.Y + (rc.Height - ft.Height) / 2));
    }

    (int r, int c)? Hit(Point p)
    {
        if (_model == null) return null;
        int c = (int)Math.Floor((p.X - HeadW) / CellW), r = (int)Math.Floor((p.Y - HeadH) / CellH);
        if (p.X < HeadW && p.Y >= HeadH) c = -1;
        if (p.Y < HeadH && p.X >= HeadW) r = -1;
        if (r >= _model.Rows || c >= _model.Cols) return null;
        return (r, c);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        if (_model == null || Hit(e.GetPosition(this)) is not { } h) return;
        bool shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        if (h.r < 0 && h.c < 0) { _anchor = (0, 0); _cursor = (_model.Rows - 1, _model.Cols - 1); }       // corner: all
        else if (h.r < 0)                                                                              // column header
        {
            _anchor = (0, h.c); _cursor = (_model.Rows - 1, h.c);
            if (e.ClickCount == 2) { HeaderActivated?.Invoke(false, h.c); return; }
        }
        else if (h.c < 0)                                                                              // row header
        {
            _anchor = (h.r, 0); _cursor = (h.r, _model.Cols - 1);
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
        if (_model == null) return;
        var p = e.GetPosition(this);
        if (_dragging && Hit(p) is { } h && h.r >= 0 && h.c >= 0 && h != _cursor) { _cursor = h; InvalidateVisual(); Describe(); }
        if (Hit(p) is not { } over || over.r < 0 || over.c < 0)
            ToolTip.SetTip(this, null);       // off the cells (a short table leaves a lot of empty panel)
        if (Hit(p) is { } t && t.r >= 0 && t.c >= 0)
        {
            int i = t.r * _model.Cols + t.c;
            ToolTip.SetTip(this, $"[{t.r},{t.c}]  {TableModel.Axis(t.r < _model.RowAxis.Length ? _model.RowAxis[t.r] : t.r)} {_model.RowUnit} × " +
                                 $"{TableModel.Axis(t.c < _model.ColAxis.Length ? _model.ColAxis[t.c] : t.c)} {_model.ColUnit}\n" +
                                 $"value {_model.Format(_model.Values[i])} {_model.Unit}   raw {_model.Raw[i]:0} (0x{(long)_model.Raw[i]:X2})   at {_model.Item.CellAddress(i):X4}" +
                                 (_model.Heat.TryGetValue(i, out var ht) ? $"\nread by the program {(ht >= 0.75 ? "just now" : "recently")}" : "") +
                                 (_model.Overlay is { } ov && i < ov.Length && !double.IsNaN(ov[i])
                                     ? $"\n{_model.OverlayName}: {ov[i]:0.###} (average of {(_model.OverlayCount is { } oc && i < oc.Length ? oc[i] : 0)} logged samples)" : ""));
        }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e) { base.OnPointerReleased(e); _dragging = false; }

    void Describe()
    {
        if (_model == null) return;
        var sel = Selection();
        if (sel.Count == 1)
        {
            int i = sel[0];
            Message?.Invoke($"[{i / _model.Cols},{i % _model.Cols}] = {_model.Format(_model.Values[i])} {_model.Unit}  (raw {_model.Raw[i]:0}, at {_model.Item.CellAddress(i):X4})");
        }
        else
        {
            var vals = sel.Select(i => _model.Values[i]).ToList();
            Message?.Invoke($"{sel.Count} cells selected: min {_model.Format(vals.Min())}  avg {_model.Format(vals.Average())}  max {_model.Format(vals.Max())}");
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_model == null || e.Handled) return;
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
        switch (e.Key)
        {
            case Key.A when ctrl: _anchor = (0, 0); _cursor = (_model.Rows - 1, _model.Cols - 1); InvalidateVisual(); Describe(); e.Handled = true; return;
            case Key.C when ctrl: Copy(); e.Handled = true; return;
            case Key.V when ctrl: Paste(); e.Handled = true; return;
            case Key.Z when ctrl: Undo?.Invoke(); e.Handled = true; return;
            case Key.Y when ctrl: Redo?.Invoke(); e.Handled = true; return;
            case Key.Add or Key.PageUp or Key.OemCloseBrackets:
                _swallowText = true;
                NudgeCells?.Invoke(Selection(), (e.Key == Key.PageUp ? 10 : 1) * (shift ? 10 : 1)); e.Handled = true; return;
            case Key.Subtract or Key.PageDown or Key.OemOpenBrackets:
                _swallowText = true;
                NudgeCells?.Invoke(Selection(), -(e.Key == Key.PageDown ? 10 : 1) * (shift ? 10 : 1)); e.Handled = true; return;
            case Key.F2 or Key.Enter: BeginEdit(null); e.Handled = true; return;
        }
    }

    protected override void OnTextInput(TextInputEventArgs e)
    {
        base.OnTextInput(e);
        if (_swallowText) { _swallowText = false; e.Handled = true; return; }
        if (_model == null || string.IsNullOrEmpty(e.Text) || e.Handled) return;
        char ch = e.Text[0];
        if (char.IsDigit(ch) || ch is '.' or '-' or '+' or '*' or 'r') { BeginEdit(e.Text); e.Handled = true; }
        else if (ch == '=') { BeginEdit(""); e.Handled = true; }
    }

    void BeginEdit(string? initial)
    {
        if (_model == null || _host == null) return;
        var (r0, c0, _, _) = SelectionRect();
        int i = r0 * _model.Cols + c0;
        _editor.Text = initial ?? _model.Format(_model.Values[i]);
        _editor.Width = CellW + 20; _editor.Height = CellH + 2;
        var p = this.TranslatePoint(new Point(HeadW + c0 * CellW - 2, HeadH + r0 * CellH - 1), _host) ?? new Point();
        Canvas.SetLeft(_editor, p.X); Canvas.SetTop(_editor, p.Y);
        _editor.IsVisible = true;
        _editor.Focus();
        _editor.CaretIndex = _editor.Text?.Length ?? 0;
        if (initial == null) _editor.SelectAll();
        ToolTip.SetTip(_editor, "New value for the selected cells. Enter applies, Esc cancels. Prefix r for a raw value (r120), + or - for a change (+2, -0.5), * for a factor (*1.05); =-2 sets a negative value.");
    }

    void CommitEdit()
    {
        _editor.IsVisible = false;
        if (_model == null) return;
        var t = (_editor.Text ?? "").Trim();
        if (t.Length == 0) return;
        var sel = Selection();
        var inv = CultureInfo.InvariantCulture;
        if (t.StartsWith('r') && double.TryParse(t[1..], NumberStyles.Float, inv, out var raw)) { SetCells?.Invoke(sel, raw, true); return; }
        if (t.StartsWith('=')) t = t[1..].Trim();
        else if ((t[0] is '+' or '-') && double.TryParse(t, NumberStyles.Float, inv, out var delta))
        {
            // "+2" / "-2" change every selected cell by that much ("=-2" sets -2)
            foreach (var i in sel) SetCells?.Invoke(new[] { i }, _model.Values[i] + delta, false);
            return;
        }
        if (t.StartsWith('*') && double.TryParse(t[1..], NumberStyles.Float, inv, out var factor))
        {
            foreach (var i in sel) SetCells?.Invoke(new[] { i }, _model.Values[i] * factor, false);
            return;
        }
        if (double.TryParse(t, NumberStyles.Float, inv, out var v)) SetCells?.Invoke(sel, v, false);
        else Message?.Invoke($"'{t}' is not a number");
    }

    async void Copy()
    {
        if (_model == null) return;
        var (r0, c0, r1, c1) = SelectionRect();
        var sb = new System.Text.StringBuilder();
        for (int r = r0; r <= r1; r++)
            sb.AppendLine(string.Join("\t", Enumerable.Range(c0, c1 - c0 + 1).Select(c => _model.Format(_model[r, c]))));
        if (TopLevel.GetTopLevel(this)?.Clipboard is { } cb) await cb.SetTextAsync(sb.ToString());
        Message?.Invoke($"copied {(r1 - r0 + 1) * (c1 - c0 + 1)} cells");
    }

    async void Paste()
    {
        if (_model == null || TopLevel.GetTopLevel(this)?.Clipboard is not { } cb) return;
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
                if (r >= _model.Rows || c >= _model.Cols) continue;
                if (double.TryParse(parts[dc], NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) list.Add((r * _model.Cols + c, v));
            }
        }
        PasteCells?.Invoke(list);
    }
}

/// Line view: one line per row across the columns (or per column down the rows), the cell the program is reading marked, and points draggable to change a value.
public sealed class TableGraph : Control
{
    public TableModel? Model { get => _model; set { _model = value; InvalidateVisual(); } }
    TableModel? _model;
    /// false: x = columns, one line per row; true: x = rows, one line per column.
    public bool Transpose { get => _transpose; set { _transpose = value; InvalidateVisual(); } }
    bool _transpose;
    public event Action<int, double>? SetCell;
    public event Action<int>? SelectCell;
    int _dragIndex = -1, _hoverIndex = -1;
    const double Pad = 42;

    public TableGraph() { ClipToBounds = true; MinHeight = 240; }

    int Lines => _model == null ? 0 : _transpose ? _model.Cols : _model.Rows;
    int Points => _model == null ? 0 : _transpose ? _model.Rows : _model.Cols;
    int Index(int line, int point) => _transpose ? point * _model!.Cols + line : line * _model!.Cols + point;

    (double lo, double hi) Range()
    {
        var m = _model!;
        double lo = m.Min, hi = m.Max;
        if (hi - lo < 1e-9) { lo -= 1; hi += 1; }
        double pad = (hi - lo) * 0.08;
        return (lo - pad, hi + pad);
    }

    Point Pos(int point, double v)
    {
        var (lo, hi) = Range();
        double w = Bounds.Width - Pad - 12, h = Bounds.Height - Pad - 10;
        double x = Pad + (Points <= 1 ? w / 2 : point * w / (Points - 1));
        double y = 10 + h - (v - lo) / (hi - lo) * h;
        return new Point(x, y);
    }

    public override void Render(DrawingContext ctx)
    {
        ctx.FillRectangle(Dark.Back, new Rect(Bounds.Size));
        var m = _model;
        if (m == null || Points == 0) return;
        var (lo, hi) = Range();
        var grid = new Pen(Dark.Grid, 1);
        var axisPen = new Pen(Dark.Axis, 1);
        double h = Bounds.Height - Pad - 10;
        for (int k = 0; k <= 5; k++)
        {
            double v = lo + (hi - lo) * k / 5;
            double y = 10 + h - h * k / 5;
            ctx.DrawLine(grid, new Point(Pad, y), new Point(Bounds.Width - 12, y));
            Label(ctx, m.Format(v), new Point(2, y - 7), 10);
        }
        var axis = _transpose ? m.RowAxis : m.ColAxis;
        int every = Math.Max(1, Points / 12);
        for (int p = 0; p < Points; p += every)
        {
            var at = Pos(p, lo);
            ctx.DrawLine(grid, new Point(at.X, 10), new Point(at.X, 10 + h));
            Label(ctx, p < axis.Length ? TableModel.Axis(axis[p]) : p.ToString(), new Point(at.X - 12, 10 + h + 4), 10);
        }
        Label(ctx, (_transpose ? m.RowUnit : m.ColUnit) + "  →", new Point(Bounds.Width - 90, Bounds.Height - 16), 10);
        ctx.DrawLine(axisPen, new Point(Pad, 10), new Point(Pad, 10 + h));
        ctx.DrawLine(axisPen, new Point(Pad, 10 + h), new Point(Bounds.Width - 12, 10 + h));

        // where the engine is: a band down the chart at the traced x, the traced line drawn
        // thick and bright, the others dimmed, and a large marker on the interpolated value
        var tc = m.TraceCentre();
        double? traceX = null, traceLine = null;
        if (tc is { } t)
        {
            double pointPos = _transpose ? t.Row : t.Col, linePos = _transpose ? t.Col : t.Row;
            traceLine = linePos;
            double w = Bounds.Width - Pad - 12;
            traceX = Pad + (Points <= 1 ? w / 2 : Math.Clamp(pointPos, 0, Points - 1) * w / (Points - 1));
            var band = new SolidColorBrush(Color.FromArgb(55, TableModel.TraceColor.R, TableModel.TraceColor.G, TableModel.TraceColor.B));
            ctx.FillRectangle(band, new Rect(traceX.Value - 7, 10, 14, h));
            ctx.DrawLine(new Pen(new SolidColorBrush(TableModel.TraceColor), 1.5, dashStyle: DashStyle.Dash), new Point(traceX.Value, 10), new Point(traceX.Value, 10 + h));
        }
        for (int pass = 0; pass < 2; pass++)
            for (int line = 0; line < Lines; line++)
            {
                bool traced = traceLine is double tl && Math.Abs(tl - line) < 1;
                if (pass == 0 == traced) continue;      // traced lines last, on top
                var color = Lines <= 1 ? Colors.RoyalBlue : HsvLine(line, Lines);
                byte alpha = traceLine == null || traced ? (byte)255 : (byte)90;
                var pen = new Pen(new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B)), traced ? 3.2 : 1.6);
                Point? prev = null;
                for (int p = 0; p < Points; p++)
                {
                    int i = Index(line, p);
                    var pt = Pos(p, m.Values[i]);
                    if (prev is { } q) ctx.DrawLine(pen, q, pt);
                    prev = pt;
                    bool hot = m.Heat.TryGetValue(i, out var heat);
                    double rad = i == _hoverIndex || i == _dragIndex ? 4.5 : hot ? (heat >= 0.75 ? 7 : 5) : traced ? 3.2 : 2.2;
                    if (hot)
                    {
                        ctx.DrawEllipse(null, new Pen(Brushes.White, 2.5), pt, rad + 2.5, rad + 2.5);
                        ctx.DrawEllipse(new SolidColorBrush(heat >= 0.75 ? TableModel.TraceColor : TableModel.TrailColor), new Pen(Brushes.Black, 1.2), pt, rad, rad);
                    }
                    else ctx.DrawEllipse(new SolidColorBrush(Color.FromArgb(alpha, color.R, color.G, color.B)), null, pt, rad, rad);
                }
            }
        if (tc is { } tt && traceX is double tx)
        {
            // interpolated value at the trace point
            int r0 = (int)Math.Floor(Math.Clamp(tt.Row, 0, m.Rows - 1)), c0 = (int)Math.Floor(Math.Clamp(tt.Col, 0, m.Cols - 1));
            int r1 = Math.Min(r0 + 1, m.Rows - 1), c1 = Math.Min(c0 + 1, m.Cols - 1);
            double fr = Math.Clamp(tt.Row - r0, 0, 1), fc = Math.Clamp(tt.Col - c0, 0, 1);
            double v = m[r0, c0] * (1 - fr) * (1 - fc) + m[r0, c1] * (1 - fr) * fc + m[r1, c0] * fr * (1 - fc) + m[r1, c1] * fr * fc;
            var p = new Point(tx, Pos(0, v).Y);
            ctx.DrawEllipse(null, new Pen(Brushes.White, 3), p, 10, 10);
            ctx.DrawEllipse(new SolidColorBrush(TableModel.TraceColor), new Pen(Brushes.Black, 1.5), p, 7, 7);
            Label(ctx, $"{m.Format(v)} {m.Unit}", new Point(Math.Min(tx + 12, Bounds.Width - 90), p.Y - 18), 11);
        }
        if (_hoverIndex >= 0 && _hoverIndex < m.Values.Length)
        {
            int r = _hoverIndex / m.Cols, c = _hoverIndex % m.Cols;
            Label(ctx, $"[{r},{c}] {TableModel.Axis(r < m.RowAxis.Length ? m.RowAxis[r] : r)} {m.RowUnit} × {TableModel.Axis(c < m.ColAxis.Length ? m.ColAxis[c] : c)} {m.ColUnit} = {m.Format(m.Values[_hoverIndex])} {m.Unit}",
                new Point(Pad + 6, 12), 11);
        }
    }

    static Color HsvLine(int i, int n)
    {
        double hue = 220.0 - 220.0 * i / Math.Max(1, n - 1);     // blue (low rows) to red (high rows)
        double x = 1 - Math.Abs(hue / 60 % 2 - 1);
        var (r, g, b) = hue switch
        {
            < 60 => (1.0, x, 0.0), < 120 => (x, 1.0, 0.0), < 180 => (0.0, 1.0, x), _ => (0.0, x, 1.0),
        };
        return Color.FromRgb((byte)(80 + r * 175), (byte)(80 + g * 160), (byte)(80 + b * 175));
    }

    static void Label(DrawingContext ctx, string s, Point at, double size) =>
        ctx.DrawText(new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), size, Dark.Text), at);

    int Nearest(Point p)
    {
        if (_model == null) return -1;
        int best = -1; double bd = 100;
        for (int line = 0; line < Lines; line++)
            for (int q = 0; q < Points; q++)
            {
                int i = Index(line, q);
                var pt = Pos(q, _model.Values[i]);
                double d = Math.Abs(pt.X - p.X) + Math.Abs(pt.Y - p.Y);
                if (d < bd) { bd = d; best = i; }
            }
        return bd < 12 ? best : -1;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        _dragIndex = Nearest(e.GetPosition(this));
        if (_dragIndex >= 0) SelectCell?.Invoke(_dragIndex);
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (_model == null) return;
        var p = e.GetPosition(this);
        if (_dragIndex >= 0 && e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
        {
            var (lo, hi) = Range();
            double h = Bounds.Height - Pad - 10;
            double v = lo + (10 + h - p.Y) / h * (hi - lo);
            _model.Values[_dragIndex] = v;       // preview; the host writes and refreshes on release
            _model.Touch();
            InvalidateVisual();
            return;
        }
        int hover = Nearest(p);
        if (hover != _hoverIndex) { _hoverIndex = hover; InvalidateVisual(); }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (_dragIndex >= 0 && _model != null) SetCell?.Invoke(_dragIndex, _model.Values[_dragIndex]);
        _dragIndex = -1;
    }
}

/// 3D view: the table as a coloured surface. Drag to turn it, wheel to zoom; the program's current read position is marked.
public sealed class TableSurface : Control
{
    public TableModel? Model { get => _model; set { _model = value; InvalidateVisual(); } }
    TableModel? _model;
    double _yaw = -0.7, _pitch = 0.55, _zoom = 1;
    Point? _last;

    public TableSurface() { ClipToBounds = true; MinHeight = 260; }

    (Point p, double depth) Project(double x, double y, double z)
    {
        // x, y in [-1,1] (columns, rows), z in [0,1] (value)
        double cx = Math.Cos(_yaw), sx = Math.Sin(_yaw), cp = Math.Cos(_pitch), sp = Math.Sin(_pitch);
        double X = x * cx - y * sx;
        double Y = x * sx + y * cx;
        double Z = (z - 0.5) * 1.1;
        double py = Y * sp - Z * cp;
        double depth = Y * cp + Z * sp;
        double scale = Math.Min(Bounds.Width, Bounds.Height) * 0.36 * _zoom;
        return (new Point(Bounds.Width / 2 + X * scale, Bounds.Height / 2 + py * scale), depth);
    }

    public override void Render(DrawingContext ctx)
    {
        ctx.FillRectangle(Dark.Back, new Rect(Bounds.Size));
        var m = _model;
        if (m == null || m.Rows < 1 || m.Cols < 1) return;
        double lo = m.Min, hi = m.Max, span = hi - lo < 1e-9 ? 1 : hi - lo;
        double X(int c) => m.Cols == 1 ? 0 : c * 2.0 / (m.Cols - 1) - 1;
        double Y(int r) => m.Rows == 1 ? 0 : r * 2.0 / (m.Rows - 1) - 1;
        double Z(int r, int c) => (m[r, c] - lo) / span;
        var quads = new List<(double depth, Point[] pts, Color color, bool hot)>();
        int rr = Math.Max(1, m.Rows - 1), cc = Math.Max(1, m.Cols - 1);
        for (int r = 0; r < rr; r++)
            for (int c = 0; c < cc; c++)
            {
                int r1 = Math.Min(r + 1, m.Rows - 1), c1 = Math.Min(c + 1, m.Cols - 1);
                var a = Project(X(c), Y(r), Z(r, c)); var b = Project(X(c1), Y(r), Z(r, c1));
                var d = Project(X(c1), Y(r1), Z(r1, c1)); var e = Project(X(c), Y(r1), Z(r1, c));
                double v = (m[r, c] + m[r, c1] + m[r1, c1] + m[r1, c]) / 4;
                bool hot = new[] { r * m.Cols + c, r * m.Cols + c1, r1 * m.Cols + c, r1 * m.Cols + c1 }.Any(i => m.Heat.TryGetValue(i, out var h) && h >= 0.75);
                quads.Add(((a.depth + b.depth + d.depth + e.depth) / 4, new[] { a.p, b.p, d.p, e.p }, m.CellColor(v), hot));
            }
        var edge = new Pen(new SolidColorBrush(Color.FromArgb(140, 20, 20, 24)), 0.6);
        foreach (var q in quads.OrderByDescending(q => q.depth))
        {
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                g.BeginFigure(q.pts[0], true);
                for (int k = 1; k < 4; k++) g.LineTo(q.pts[k]);
                g.EndFigure(true);
            }
            ctx.DrawGeometry(new SolidColorBrush(q.hot ? TableModel.TraceColor : q.color), q.hot ? new Pen(Dark.Text, 1.2) : edge, geo);
        }
        // axis labels at the base corners
        var black = Dark.Text;
        void Lbl(string s, (Point p, double) at) => ctx.DrawText(new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), 10, black), at.p);
        Lbl($"{m.ColUnit} {TableModel.Axis(m.ColAxis.FirstOrDefault(double.NaN))}", Project(-1, 1.08, 0));
        Lbl($"{TableModel.Axis(m.ColAxis.LastOrDefault(double.NaN))}", Project(1, 1.08, 0));
        Lbl($"{m.RowUnit} {TableModel.Axis(m.RowAxis.FirstOrDefault(double.NaN))}", Project(1.08, -1, 0));
        Lbl($"{TableModel.Axis(m.RowAxis.LastOrDefault(double.NaN))}", Project(1.08, 1, 0));
        Lbl($"{m.Format(hi)} {m.Unit}", Project(-1.05, -1, 1));
        if (m.TraceCentre() is { } tc)
        {
            double x = m.Cols == 1 ? 0 : tc.Col * 2 / (m.Cols - 1) - 1, y = m.Rows == 1 ? 0 : tc.Row * 2 / (m.Rows - 1) - 1;
            int r0 = (int)Math.Round(tc.Row), c0 = (int)Math.Round(tc.Col);
            var p = Project(x, y, Z(Math.Clamp(r0, 0, m.Rows - 1), Math.Clamp(c0, 0, m.Cols - 1)) + 0.03);
            ctx.DrawEllipse(Brushes.White, new Pen(Brushes.Black, 1.5), p.p, 5, 5);
        }
        ctx.DrawText(new FormattedText("drag to rotate · wheel to zoom", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), 10, Dark.Dim), new Point(6, 4));
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e) { base.OnPointerPressed(e); _last = e.GetPosition(this); }
    protected override void OnPointerReleased(PointerReleasedEventArgs e) { base.OnPointerReleased(e); _last = null; }
    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        if (_last is not { } l) return;
        var p = e.GetPosition(this);
        _yaw += (p.X - l.X) * 0.01;
        _pitch = Math.Clamp(_pitch + (p.Y - l.Y) * 0.01, 0.05, 1.5);
        _last = p;
        InvalidateVisual();
    }
    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        _zoom = Math.Clamp(_zoom * (e.Delta.Y > 0 ? 1.1 : 0.9), 0.4, 4);
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
    public static readonly IBrush Back = new SolidColorBrush(Color.FromRgb(0x1e, 0x1f, 0x22));
    public static readonly IBrush Grid = new SolidColorBrush(Color.FromRgb(0x33, 0x36, 0x3c));
    public static readonly IBrush Axis = new SolidColorBrush(Color.FromRgb(0x8a, 0x8f, 0x98));
    public static readonly IBrush Text = new SolidColorBrush(Color.FromRgb(0xd7, 0xda, 0xe0));
    public static readonly IBrush Dim = new SolidColorBrush(Color.FromRgb(0x80, 0x84, 0x8c));
}
