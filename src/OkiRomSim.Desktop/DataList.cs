// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace OkiRomSim.Desktop;

/// A list drawn as a table, in the look of the maps and the memory map: headings that stay put, columns, alternate rows shaded, a coloured mark down the left of each row (what kind of row it is), colour in the cells that carry meaning, a tip over each row, double-click to go to it, and a line under the headings when it is empty. Drawn rather than built of controls, so thousands of rows refreshed several times a second cost next to nothing. The last column takes what width is left. The Trace, Lookup and breakpoints, Problems and Debug pages, the simulator's side panel and the datalog use it.
public sealed class DataList : UserControl
{
    public sealed record Column(string Head, double Width);
    public sealed record Cell(string Text, IBrush? Ink = null, bool Bold = false);
    /// A row. Heading: a line of its own across the columns (a group's title), bold on a tinted band.
    public sealed record Row(Cell[] Cells, IBrush? Mark = null, int Address = -1, string? Tip = null, bool Current = false, bool Heading = false, object? Tag = null);

    readonly Body _body;
    readonly ScrollViewer _scroll;
    /// Double-click (or Enter) on a row.
    public event Action<Row>? Activated;
    /// A row clicked, or moved to with the arrow keys.
    public event Action<Row>? Picked;
    /// What a right-click on a row offers: (text, what it does); null or empty for no menu.
    public Func<Row, IEnumerable<(string Text, Action Run)>>? Menu { get; set; }

    public DataList(params Column[] columns)
    {
        _body = new Body(this) { Columns = columns };
        _scroll = new ScrollViewer { Content = _body, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        _body.Scroll = _scroll;
        _scroll.ScrollChanged += (_, _) => _body.InvalidateVisual();
        Content = _scroll;
        Focusable = true;
        ClipToBounds = true;
    }

    /// The line shown under the headings while there are no rows.
    public string Empty { get => _body.Empty; set { _body.Empty = value; _body.InvalidateVisual(); } }

    /// Row height: 20 suits a page, a side panel packs them closer.
    public double RowHeight { get => _body.RowH; set { _body.RowH = value; _body.InvalidateMeasure(); } }

    /// Without the headings (for a panel whose title already says what the columns are).
    public bool ShowHeader { get => _body.Top > 0; set { _body.Top = value ? 22 : 0; _body.InvalidateMeasure(); } }

    /// Font size of the cells.
    public double CellFontSize { get => _body.FontSize; set { _body.FontSize = value; _body.ClearCache(); _body.InvalidateVisual(); } }

    public IReadOnlyList<Row> Rows => _body.Rows;
    public Row? Selected => _body.Selected >= 0 && _body.Selected < _body.Rows.Count ? _body.Rows[_body.Selected] : null;
    public int SelectedIndex
    {
        get => _body.Selected;
        set { _body.Selected = value < _body.Rows.Count ? value : -1; _body.InvalidateVisual(); }
    }

    /// New rows; with `follow`, the view keeps to the newest (the bottom) unless it was scrolled up to read.
    public void SetRows(IReadOnlyList<Row> rows, bool follow = false)
    {
        bool atEnd = _scroll.Offset.Y >= _scroll.Extent.Height - _scroll.Viewport.Height - (_body.RowH * 2);
        _body.Rows = rows;
        if (_body.Selected >= rows.Count) _body.Selected = -1;
        _body.InvalidateMeasure();
        _body.InvalidateVisual();
        if (follow && atEnd) Avalonia.Threading.Dispatcher.UIThread.Post(() => _scroll.ScrollToEnd(), Avalonia.Threading.DispatcherPriority.Background);
    }

    /// Bring a row into view: in the middle with `centre`, else only as far as needed.
    public void ScrollTo(int index, bool centre = true)
    {
        if (index < 0 || index >= _body.Rows.Count) return;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            double rh = _body.RowH, top = _body.Top, y = top + (index * rh), vh = _scroll.Viewport.Height, oy = _scroll.Offset.Y;
            if (vh <= 0) return;
            if (!centre && y >= oy + top && y + rh <= oy + vh) return;
            double to = centre ? y - ((vh - rh) / 2) : y < oy + top ? y - top : y + rh - vh;
            _scroll.Offset = new Vector(_scroll.Offset.X, Math.Clamp(to, 0, Math.Max(0, _scroll.Extent.Height - vh)));
        }, Avalonia.Threading.DispatcherPriority.Background);
    }

    static readonly IBrush HeadBg = new SolidColorBrush(Color.FromRgb(0x2b, 0x2e, 0x35));
    static readonly IBrush HeadLine = new SolidColorBrush(Color.FromRgb(0x3c, 0x40, 0x48));
    static readonly IBrush Alt = new SolidColorBrush(Color.FromArgb(16, 255, 255, 255));
    static readonly IBrush Sel = new SolidColorBrush(Color.FromArgb(70, 0x3a, 0x8d, 0xff));
    static readonly IBrush Hov = new SolidColorBrush(Color.FromArgb(28, 255, 255, 255));
    static readonly IBrush CurrentBg = new SolidColorBrush(Color.FromArgb(46, 0x00, 0xd0, 0xd0));
    static readonly IBrush HeadingBg = new SolidColorBrush(Color.FromArgb(30, 0x46, 0x8c, 0xff));

    // colours the pages share, so a kind of row always looks the same
    public static readonly IBrush Code = new SolidColorBrush(Color.FromRgb(0x3c, 0xc8, 0x5a));
    public static readonly IBrush Data = new SolidColorBrush(Color.FromRgb(0x46, 0x8c, 0xff));
    public static readonly IBrush Address = new SolidColorBrush(Color.FromRgb(0x9a, 0xa4, 0xb4));
    public static readonly IBrush Label = new SolidColorBrush(Color.FromRgb(0xe6, 0xc0, 0x7a));
    public static readonly IBrush Jump = new SolidColorBrush(Color.FromRgb(0xff, 0x9d, 0x5c));
    public static readonly IBrush Call = new SolidColorBrush(Color.FromRgb(0x7f, 0xc4, 0xff));
    public static readonly IBrush Error = new SolidColorBrush(Color.FromRgb(0xff, 0x5c, 0x5c));
    public static readonly IBrush Warning = new SolidColorBrush(Color.FromRgb(0xff, 0xc1, 0x4d));
    public static readonly IBrush Good = new SolidColorBrush(Color.FromRgb(0x5c, 0xd6, 0x7a));
    public static readonly IBrush Purple = new SolidColorBrush(Color.FromRgb(0xc0, 0x8c, 0xff));
    public static readonly IBrush Text = Dark.Text;
    public static readonly IBrush Dim = Dark.Dim;

    /// An instruction's mnemonic coloured by what it does: jumps and branches, calls and returns, the rest.
    public static IBrush MnemonicInk(string instruction)
    {
        var op = instruction.TrimStart().Split(' ', 2)[0].ToUpperInvariant();
        return op is "CAL" or "SCAL" or "VCAL" or "RT" or "RTI" or "BRK" ? Call
             : op.StartsWith('J') || op is "SJ" or "DJNZ" ? Jump
             : Text;
    }

    sealed class Body(DataList owner) : Control
    {
        public double RowH = 20, Top = 22, FontSize = 12;
        public Column[] Columns = [];
        public IReadOnlyList<Row> Rows = [];
        public ScrollViewer? Scroll;
        public string Empty = "";
        public int Selected = -1;
        int _hover = -1;
        static readonly Typeface Mono = new(MainWindow.MonoFont);
        static readonly Typeface MonoBold = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.Bold);
        static readonly Typeface Ui = new(FontFamily.Default);
        readonly Dictionary<(string, bool, uint, double), FormattedText> _cache = [];

        public void ClearCache() => _cache.Clear();

        double Width0 => Columns.Sum(c => c.Width) + 12;
        double ViewW => Scroll?.Viewport.Width is > 0 and var w ? w : Bounds.Width;
        /// The last column: its own width, or what is left of the view.
        double LastWidth => Columns.Length == 0 ? 0 : Math.Max(Columns[^1].Width, ViewW - (Width0 - Columns[^1].Width));

        protected override Size MeasureOverride(Size availableSize) => new(Width0, Top + (Rows.Count * RowH) + 4);

        FormattedText Ft(string s, IBrush ink, bool bold, double maxW)
        {
            uint k = ink is ISolidColorBrush sb ? sb.Color.ToUInt32() : 0;
            var key = (s, bold, k, Math.Round(maxW));
            if (!_cache.TryGetValue(key, out var ft))
            {
                if (_cache.Count > 6000) _cache.Clear();
                ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, bold ? MonoBold : Mono, FontSize, ink)
                { MaxTextWidth = Math.Max(1, maxW), MaxLineCount = 1, Trimming = TextTrimming.CharacterEllipsis };
                _cache[key] = ft;
            }
            return ft;
        }

        public override void Render(DrawingContext ctx)
        {
            ctx.FillRectangle(Dark.Back, new Rect(Bounds.Size));
            double y0 = Scroll?.Offset.Y ?? 0, x0 = Scroll?.Offset.X ?? 0, h = Scroll?.Viewport.Height ?? Bounds.Height;
            double fullW = Math.Max(Bounds.Width, Width0);
            if (Rows.Count == 0 && Empty.Length > 0)
            {
                // under the headings, lined up with the first column as the values would be
                var ft = new FormattedText(Empty, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Ui, 12.5, Dim)
                { MaxTextWidth = Math.Max(100, ViewW - 28), TextAlignment = TextAlignment.Left };
                ctx.DrawText(ft, new Point(x0 + 12, y0 + Top + 10));
            }
            int first = Math.Max(0, (int)((y0 - Top) / RowH)), last = Math.Min(Rows.Count - 1, (int)((y0 + h) / RowH) + 1);
            for (int i = first; i <= last; i++)
            {
                var r = Rows[i];
                double y = Top + (i * RowH);
                var rc = new Rect(0, y, fullW, RowH);
                if (r.Heading)
                {
                    ctx.FillRectangle(HeadingBg, rc);
                    if (r.Mark != null) ctx.FillRectangle(r.Mark, new Rect(0, y + 2, 3, RowH - 4), 1.5f);
                    double hx = 8;
                    foreach (var hc in r.Cells)
                    {
                        var hft = Ft(hc.Text, hc.Ink ?? Text, true, Math.Max(40, fullW - hx - 8));
                        ctx.DrawText(hft, new Point(hx + 4, y + ((RowH - hft.Height) / 2)));
                        hx += hft.Width + 18;
                    }
                    continue;
                }
                if (i == Selected) ctx.FillRectangle(Sel, rc);
                else if (r.Current) ctx.FillRectangle(CurrentBg, rc);
                else if (i == _hover) ctx.FillRectangle(Hov, rc);
                else if (i % 2 == 1) ctx.FillRectangle(Alt, rc);
                if (r.Mark != null) ctx.FillRectangle(r.Mark, new Rect(0, y + 2, 3, RowH - 4), 1.5f);
                double x = 8;
                for (int c = 0; c < Columns.Length && c < r.Cells.Length; c++)
                {
                    var cell = r.Cells[c];
                    double w = c == Columns.Length - 1 ? LastWidth : Columns[c].Width;
                    if (cell.Text.Length > 0)
                    {
                        var ft = Ft(cell.Text, cell.Ink ?? Text, cell.Bold, w - 10);
                        ctx.DrawText(ft, new Point(x + 4, y + ((RowH - ft.Height) / 2)));
                    }
                    x += w;
                }
            }
            if (Top <= 0) return;
            // the headings stay at the top of the view
            var head = new Rect(0, y0, fullW, Top);
            ctx.FillRectangle(HeadBg, head);
            ctx.DrawLine(new Pen(HeadLine, 1), new Point(0, y0 + Top - 0.5), new Point(head.Width, y0 + Top - 0.5));
            double hx2 = 8;
            for (int c = 0; c < Columns.Length; c++)
            {
                var ft = Ft(Columns[c].Head, Dim, true, Columns[c].Width - 10);
                ctx.DrawText(ft, new Point(hx2 + 4, y0 + ((Top - ft.Height) / 2)));
                hx2 += c == Columns.Length - 1 ? LastWidth : Columns[c].Width;
            }
        }

        int RowAt(Point p)
        {
            int i = (int)Math.Floor((p.Y - Top) / RowH);
            return i >= 0 && i < Rows.Count && !Rows[i].Heading && p.Y >= (Scroll?.Offset.Y ?? 0) + Top ? i : -1;
        }

        protected override void OnPointerMoved(PointerEventArgs e)
        {
            base.OnPointerMoved(e);
            int i = RowAt(e.GetPosition(this));
            if (i == _hover) return;
            _hover = i;
            ToolTip.SetTip(this, i < 0 ? null : Rows[i].Tip);
            InvalidateVisual();
        }

        protected override void OnPointerExited(PointerEventArgs e) { base.OnPointerExited(e); _hover = -1; InvalidateVisual(); }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            base.OnPointerPressed(e);
            int i = RowAt(e.GetPosition(this));
            if (i < 0) return;
            Selected = i;
            InvalidateVisual();
            owner.Focus();
            owner.Picked?.Invoke(Rows[i]);
            if (e.GetCurrentPoint(this).Properties.IsRightButtonPressed)
            {
                var items = owner.Menu?.Invoke(Rows[i])?.ToList();
                if (items is { Count: > 0 })
                {
                    var menu = new ContextMenu();
                    foreach (var (text, run) in items)
                    {
                        var mi = new MenuItem { Header = text };
                        mi.Click += (_, _) => run();
                        menu.Items.Add(mi);
                    }
                    menu.Open(this);
                    e.Handled = true;
                }
                return;
            }
            if (e.ClickCount == 2) owner.Activated?.Invoke(Rows[i]);
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_body.Rows.Count == 0) return;
        int s = _body.Selected;
        switch (e.Key)
        {
            case Key.Down: s = Math.Min(_body.Rows.Count - 1, s + 1); while (s < _body.Rows.Count - 1 && _body.Rows[s].Heading) s++; break;
            case Key.Up: s = Math.Max(0, s - 1); while (s > 0 && _body.Rows[s].Heading) s--; break;
            case Key.Enter when Selected is { } row: Activated?.Invoke(row); e.Handled = true; return;
            default: return;
        }
        _body.Selected = s;
        ScrollTo(s, centre: false);
        _body.InvalidateVisual();
        if (Selected is { } picked) Picked?.Invoke(picked);
        e.Handled = true;
    }
}
