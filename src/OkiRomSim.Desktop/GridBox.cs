// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// A spreadsheet the same shape and colour as the fuel and ignition maps, for numbers that are not in the ROM: the AFR targets, the correction curves, and the O2 / knock tables read out of a datalog. It is the very same <see cref="TableGrid"/> the Calibration page draws its maps with, so the cell colours, the selection frame, typing a value, +/- nudging, Ctrl+C/V and the axis headers all behave exactly as they do there. What it works on is a plain array of numbers with its own axes, rather than a definition in the ROM.
public sealed class GridBox : UserControl
{
    readonly TableGrid _grid = new();
    readonly Canvas _overlay = new();
    readonly TextBlock _note = new() { FontSize = 11, Opacity = 0.8, Margin = new Thickness(4, 2), TextWrapping = TextWrapping.Wrap };
    TableModel? _model;

    /// A cell (or a selection) was edited; the argument is the whole table again.
    public event Action<double[]>? Changed;
    /// A header was double-clicked: (row header?, index). Left unhandled, nothing happens.
    public event Action<bool, int>? HeaderActivated;

    /// False makes the grid show only: no typing, no nudging, no pasting.
    public bool Editable { get => !_grid.ReadOnly; set => _grid.ReadOnly = !value; }

    public GridBox()
    {
        _grid.HorizontalAlignment = HorizontalAlignment.Left;
        _grid.VerticalAlignment = VerticalAlignment.Top;
        var host = new Panel();
        host.Children.Add(_grid);
        host.Children.Add(_overlay);
        _grid.AttachEditorHost(_overlay);
        _grid.Message += m => _note.Text = m;
        _grid.SetCells += (cells, v, _) => Apply(cells, _ => v);
        _grid.NudgeCells += (cells, d) => Apply(cells, i => _model!.Values[i] + (d * Step));
        _grid.PasteCells += list =>
        {
            var dict = list.ToDictionary(x => x.Index, x => x.Value);
            Apply([.. dict.Keys], i => dict[i]);
        };
        // a typed "+2" / "*1.05": each selected cell to a value of its own
        _grid.SetEach += (list, _) =>
        {
            var dict = list.ToDictionary(x => x.Index, x => x.Value);
            Apply([.. dict.Keys], i => dict[i]);
        };
        _grid.HeaderActivated += (row, i) => HeaderActivated?.Invoke(row, i);
        var dock = new DockPanel();
        DockPanel.SetDock(_note, Dock.Bottom);
        dock.Children.Add(_note);
        dock.Children.Add(new ScrollViewer
        {
            Content = host,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        });
        Content = dock;
    }

    /// How much one +/- nudge moves a cell (the ROM maps step one stored count; here it is whatever the numbers are in).
    public double Step { get; set; } = 0.1;

    /// The line under the grid (what is selected, or a message).
    public string Note { get => _note.Text ?? ""; set => _note.Text = value; }

    public double[] Values => _model?.Values ?? [];
    public int Rows => _model?.Rows ?? 0;
    public int Cols => _model?.Cols ?? 0;

    /// Fill the grid. `values` is row-major, `rowAxis`/`colAxis` are the breakpoints shown in the headers.
    public void Set(double[] rowAxis, double[] colAxis, double[] values, string rowUnit, string colUnit, string unit, int decimals)
    {
        int rows = Math.Max(1, rowAxis.Length), cols = Math.Max(1, colAxis.Length);
        if (values.Length != rows * cols)
        {
            var fixedUp = new double[rows * cols];
            for (int i = 0; i < fixedUp.Length; i++) fixedUp[i] = i < values.Length ? values[i] : double.NaN;
            values = fixedUp;
        }
        _model = new TableModel
        {
            // the grid wants a definition to name its cells; nothing here is in the ROM, so a stand-in of the right shape is all it needs
            Item = new ItemDef { Name = "table", Address = 0, Rows = rows, Cols = cols, Type = CellType.U8 },
            Rows = rows, Cols = cols,
            Values = values, Raw = [.. values],
            RowAxis = rowAxis, ColAxis = colAxis,
            RowUnit = rowUnit, ColUnit = colUnit, Unit = unit, Decimals = decimals,
        };
        _grid.Model = _model;
        _grid.InvalidateMeasure();
        _grid.InvalidateVisual();
    }

    /// A second number drawn small under each cell (the O2 table's distance from target, say). Null clears it.
    public void SetOverlay(double[]? values, int[]? counts, string name)
    {
        if (_model == null) return;
        _model.Overlay = values; _model.OverlayCount = counts; _model.OverlayName = name;
        _grid.InvalidateVisual();
    }

    public void SelectCell(int row, int col) => _grid.SelectCell(row, col);
    public IReadOnlyList<int> Selection() => _grid.Selection();
    public (int R0, int C0, int R1, int C1) SelectionRect() => _grid.SelectionRect();

    void Apply(IReadOnlyList<int> cells, Func<int, double> value)
    {
        if (_model == null || !Editable || cells.Count == 0) return;
        foreach (var i in cells)
            if (i >= 0 && i < _model.Values.Length) _model.Values[i] = value(i);
        _model.Touch();
        _model.Raw = [.. _model.Values];
        _grid.InvalidateVisual();
        Changed?.Invoke(_model.Values);
    }

    /// Set every cell without raising Changed (loading).
    public void Replace(double[] values)
    {
        if (_model == null) return;
        for (int i = 0; i < _model.Values.Length; i++) _model.Values[i] = i < values.Length ? values[i] : double.NaN;
        _model.Touch();
        _model.Raw = [.. _model.Values];
        _grid.InvalidateVisual();
    }

    public static string Fmt(double v, int decimals = 2) =>
        double.IsNaN(v) ? "" : v.ToString("0." + new string('#', Math.Clamp(decimals, 0, 4)), CultureInfo.InvariantCulture);

    /// "800, 1000, 1500" -> the numbers, for the little axis boxes beside a grid.
    public static double[] ParseAxis(string? text) =>
        [.. (text ?? "").Split([',', ';', '\t', ' '], StringSplitOptions.RemoveEmptyEntries)
            .Select(s => double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : double.NaN)
            .Where(v => !double.IsNaN(v))];

    public static string AxisText(IEnumerable<double> axis) => string.Join(", ", axis.Select(v => Fmt(v, 3)));
}
