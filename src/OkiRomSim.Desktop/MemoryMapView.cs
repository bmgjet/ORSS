// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using OkiRomSim.Calibration;

namespace OkiRomSim.Desktop;

/// The Memory page's map: every RAM byte the ROM uses, by name (RamMap: definitions, the datalog frame, the tables that store their result there, the source's names), with its raw value, its value in real units through the right formula, and the code that wrote it last (recorded as the simulator runs). Double-click a row to change it - once, or held there against whatever the ROM writes - and it takes effect in the running program at once.
public sealed class MemoryMapView : UserControl
{
    readonly SimHost _host;
    readonly MapGrid _grid;
    readonly TextBox _filter = new() { Watermark = "filter: name, address, source", Width = 220 };
    readonly CheckBox _named = new() { Content = "Named only", IsChecked = true, VerticalAlignment = VerticalAlignment.Center };
    readonly CheckBox _written = new() { Content = "Written only", IsChecked = false, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _info = new() { FontSize = 11, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0) };
    /// Go to an address in the source (a writer's instruction).
    public event Action<int>? GoToCode;
    public event Action<string>? Status;

    public MemoryMapView(SimHost host)
    {
        _host = host;
        _grid = new MapGrid(this);
        var scroll = new ScrollViewer { Content = _grid, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        _grid.Scroll = scroll;
        scroll.ScrollChanged += (_, _) => _grid.InvalidateVisual();
        _filter.TextChanged += (_, _) => Rebuild();
        _named.IsCheckedChanged += (_, _) => Rebuild();
        _written.IsCheckedChanged += (_, _) => Rebuild();
        ToolTip.SetTip(_named, "Only the bytes something names (a definition, the datalog frame, a table's result, the source). Off: every RAM byte.");
        ToolTip.SetTip(_written, "Only the bytes the program has written since it started (the ones in use).");
        var edit = Btn("Change…", "Change the selected byte (or word) now: once, or held there whatever the ROM writes.", () => _grid.EditSelected());
        var release = Btn("Release all", "Let go of every byte held at a value.", () => { foreach (var a in _grid.HeldNow()) _host.HoldRam(a, null); _grid.InvalidateVisual(); });
        var bar = new WrapPanel { Margin = new Thickness(4) };
        foreach (var c in new Control[] { _filter, _named, _written, edit, release, _info }) { c.Margin = new Thickness(0, 0, 8, 0); bar.Children.Add(c); }
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        root.Children.Add(bar);
        root.Children.Add(scroll);
        Content = root;
    }

    static Button Btn(string text, string tip, Action a)
    {
        var b = new Button { Content = text, Padding = new Thickness(8, 2), MinHeight = 0 };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => a();
        return b;
    }

    IReadOnlyList<RamEntry> _map = [];
    object? _mapFor;

    /// Called while the page is shown: new values, and the list again when the ROM changed.
    public void Refresh()
    {
        var map = _host.RamMapNow();
        if (!ReferenceEquals(map, _mapFor)) { _mapFor = map; _map = map; Rebuild(); }
        _grid.Ram = _host.ReadMemory(0, RamMap.RamEnd);
        _grid.InvalidateVisual();
    }

    void Rebuild()
    {
        var byAddr = _map.ToDictionary(e => e.Address);
        var f = (_filter.Text ?? "").Trim();
        var rows = new List<Row>();
        for (int a = 0; a < RamMap.RamEnd; a++)
        {
            byAddr.TryGetValue(a, out var e);
            if (e is { Size: 0 }) continue;                  // the high byte of a word: shown with its low byte
            if (_named.IsChecked == true && e == null) continue;
            if (_written.IsChecked == true && _host.RamWriters(a).Writes == 0) continue;
            var name = e?.Name ?? "";
            if (f.Length > 0 && !(name.Contains(f, StringComparison.OrdinalIgnoreCase) || a.ToString("X3").Contains(f, StringComparison.OrdinalIgnoreCase)
                                  || (e?.Source ?? "").Contains(f, StringComparison.OrdinalIgnoreCase))) continue;
            rows.Add(new Row(a, e));
        }
        _grid.Rows = rows;
        _info.Text = $"{rows.Count} of {RamMap.RamEnd} bytes (0-{RamMap.RamEnd - 1:X3}h: the SFRs, then RAM); {_map.Count(e => e.Size > 0)} named";
        _grid.InvalidateMeasure();
        _grid.InvalidateVisual();
    }

    sealed record Row(int Address, RamEntry? Entry);

    /// Change a byte (or word) of RAM: in real units through its formula, or raw (r12, 0x3F, 3Fh), once or held.
    async void Edit(int addr, RamEntry? e)
    {
        if (TopLevel.GetTopLevel(this) is not Window owner) return;
        var defs = _host.Defs();
        int size = Math.Max(1, e?.Size ?? 1);
        var ram = _host.ReadMemory(0, RamMap.RamEnd);
        var (raw, text) = e != null ? RamMap.Read(defs, e, ram) : (ram[addr], "");
        var box = new TextBox { Text = text.Length > 0 ? text.Split(' ')[0] : ((int)raw).ToString(), Width = 160, FontFamily = MainWindow.MonoFont };
        var held = _host.IsHeld(addr);
        var w = new Window
        {
            Title = $"Change {addr:X3}h", Width = 420, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
        };
        string? pressed = null;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var (label, key, tip) in new[]
        {
            ("Write once", "once", "Write it now; the ROM may write its own value straight after."),
            ("Hold", "hold", "Write it and hold it there: the ROM's own writes are undone as they happen, until Release."),
            ("Release", "release", "Let the ROM write it again."),
            ("Cancel", "cancel", ""),
        })
        {
            var b = new Button { Content = label, IsEnabled = key != "release" || held };
            if (tip.Length > 0) ToolTip.SetTip(b, tip);
            b.Click += (_, _) => { pressed = key; w.Close(); };
            buttons.Children.Add(b);
        }
        var body = new StackPanel { Margin = new Thickness(14), Spacing = 8 };
        body.Children.Add(new TextBlock { Text = $"{addr:X3}h  {e?.Name ?? "(no name)"}", FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(new TextBlock
        {
            Text = $"now raw {(int)raw} (0x{(int)raw:X2}){(text.Length > 0 ? $" = {text}" : "")}{(e?.Formula is { Length: > 0 } fo && fo is not ("x" or "raw") ? $"   formula {fo}" : "")}" +
                   (held ? "\nheld at this value" : "") +
                   "\nType a value in real units, or a raw number: r120, 0x78 or 78h.",
            FontSize = 11.5, Opacity = 0.8, TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(box);
        body.Children.Add(buttons);
        // the dark title bar the rest of the app has
        var chrome = DarkChrome.Apply(w, w.Title);
        var page = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        page.Children.Add(chrome);
        page.Children.Add(body);
        w.Content = page;
        box.AttachedToVisualTree += (_, _) => { box.Focus(); box.SelectAll(); };
        await w.ShowDialog(owner);
        if (pressed is null or "cancel") return;
        if (pressed == "release") { _host.HoldRam(addr, null, size); Status?.Invoke($"{addr:X3}h released"); return; }
        var t = (box.Text ?? "").Trim();
        int? value = null;
        if (t.StartsWith('r') && int.TryParse(t[1..], out var r1)) value = r1;
        else if (t.StartsWith("0x", StringComparison.OrdinalIgnoreCase) && int.TryParse(t[2..], NumberStyles.HexNumber, null, out var h1)) value = h1;
        else if (t.EndsWith('h') && int.TryParse(t[..^1], NumberStyles.HexNumber, null, out var h2)) value = h2;
        else if (double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var real))
            value = e != null ? RamMap.ToRaw(defs, e, real) : (int)Math.Round(real);
        if (value is not int v) { Status?.Invoke($"'{t}' is not a value"); return; }
        v = Math.Clamp(v, 0, size >= 2 ? 0xFFFF : 0xFF);
        var bytes = size >= 2 ? new[] { (byte)v, (byte)(v >> 8) } : new[] { (byte)v };
        if (pressed == "hold") _host.HoldRam(addr, bytes, bytes.Length);
        else _host.WriteRamBytes(addr, bytes);
        OkiRomSim.Core.AppLog.Action("memory", $"{addr:X3}h {(pressed == "hold" ? "held at" : "set to")} {v} (0x{v:X})");
        Status?.Invoke($"{addr:X3}h {(pressed == "hold" ? "held at" : "set to")} {v} (0x{v:X}){(pressed == "once" ? " - the ROM may write it again; Hold keeps it" : "")}");
        Refresh();
    }

    /// The rows, drawn rather than made of controls: a thousand of them, refreshed several times a second.
    sealed class MapGrid(MemoryMapView owner) : Control
    {
        public List<Row> Rows = [];
        public byte[] Ram = new byte[RamMap.RamEnd];
        public ScrollViewer? Scroll;
        int _selected = -1, _hover = -1;
        const double RowH = 20, Top = 22;
        static readonly double[] Cols = [0, 64, 320, 420, 560, 960];      // address, name, raw, value, written by, writes
        static readonly string[] Heads = ["Address", "Name", "Raw", "Value", "Written by (newest first)", "Writes"];
        static readonly Typeface Mono = new(MainWindow.MonoFont);
        static readonly Typeface Bold = new(MainWindow.MonoFont, FontStyle.Normal, FontWeight.Bold);
        static readonly IBrush HeadBg = new SolidColorBrush(Color.FromRgb(0x2b, 0x2e, 0x35));
        static readonly IBrush Alt = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255));
        static readonly IBrush Sel = new SolidColorBrush(Color.FromArgb(70, 0x3a, 0x8d, 0xff));
        static readonly IBrush Hov = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255));
        static readonly IBrush HeldInk = new SolidColorBrush(Color.FromRgb(0xff, 0xb0, 0x40));
        static readonly IBrush ValueInk = new SolidColorBrush(Color.FromRgb(0x7f, 0xe0, 0x9a));

        protected override Size MeasureOverride(Size availableSize) => new(Cols[^1] + 90, Top + (Rows.Count * RowH) + 4);

        void Text(DrawingContext ctx, string s, double x, double y, IBrush ink, bool bold = false, double maxW = 0)
        {
            var ft = new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, bold ? Bold : Mono, 12, ink);
            if (maxW > 0) { ft.MaxTextWidth = maxW; ft.MaxLineCount = 1; ft.Trimming = TextTrimming.CharacterEllipsis; }
            ctx.DrawText(ft, new Point(x + 6, y + ((RowH - ft.Height) / 2)));
        }

        public override void Render(DrawingContext ctx)
        {
            ctx.FillRectangle(Dark.Back, new Rect(Bounds.Size));
            double y0 = Scroll?.Offset.Y ?? 0, h = Scroll?.Viewport.Height ?? Bounds.Height;
            int first = Math.Max(0, (int)((y0 - Top) / RowH)), last = Math.Min(Rows.Count - 1, (int)((y0 + h) / RowH) + 1);
            var defs = owner._host.Defs();
            for (int i = first; i <= last; i++)
            {
                var r = Rows[i];
                double y = Top + (i * RowH);
                var rc = new Rect(0, y, Bounds.Width, RowH);
                if (i == _selected) ctx.FillRectangle(Sel, rc);
                else if (i == _hover) ctx.FillRectangle(Hov, rc);
                else if (i % 2 == 1) ctx.FillRectangle(Alt, rc);
                bool held = owner._host.IsHeld(r.Address);
                int size = Math.Max(1, r.Entry?.Size ?? 1);
                int raw = size >= 2 ? Ram[r.Address] | (Ram[Math.Min(Ram.Length - 1, r.Address + 1)] << 8) : Ram[r.Address];
                Text(ctx, $"{r.Address:X3}h", Cols[0], y, Dark.Dim);
                Text(ctx, r.Entry?.Name ?? "", Cols[1], y, Dark.Text, maxW: Cols[2] - Cols[1] - 10);
                Text(ctx, size >= 2 ? $"{raw:X4}  {raw}" : $"{raw:X2}  {raw}", Cols[2], y, held ? HeldInk : Dark.Text);
                if (r.Entry != null)
                {
                    var (_, text) = RamMap.Read(defs, r.Entry, Ram);
                    Text(ctx, text + (held ? "  (held)" : ""), Cols[3], y, held ? HeldInk : ValueInk, maxW: Cols[4] - Cols[3] - 10);
                }
                else if (held) Text(ctx, "(held)", Cols[3], y, HeldInk);
                var (pcs, writes) = owner._host.RamWriters(r.Address);
                if (pcs.Length > 0) Text(ctx, string.Join("   ", pcs.Take(2).Select(pc => owner._host.Where(pc))), Cols[4], y, Dark.Dim, maxW: Cols[5] - Cols[4] - 10);
                Text(ctx, writes == 0 ? "" : writes.ToString("N0", CultureInfo.InvariantCulture), Cols[5], y, Dark.Dim);
            }
            // the headings stay at the top of the view
            var head = new Rect(0, y0, Bounds.Width, Top);
            ctx.FillRectangle(HeadBg, head);
            for (int c = 0; c < Heads.Length; c++) Text(ctx, Heads[c], Cols[c], y0, Dark.Text, bold: true);
        }

        int RowAt(Point p) { int i = (int)Math.Floor((p.Y - Top) / RowH); return i >= 0 && i < Rows.Count && p.Y >= (Scroll?.Offset.Y ?? 0) + Top ? i : -1; }

        protected override void OnPointerMoved(PointerEventArgs e)
        {
            base.OnPointerMoved(e);
            int i = RowAt(e.GetPosition(this));
            if (i != _hover) { _hover = i; InvalidateVisual(); ToolTip.SetTip(this, i < 0 ? null : Tip(Rows[i])); }
        }

        protected override void OnPointerExited(PointerEventArgs e) { base.OnPointerExited(e); _hover = -1; InvalidateVisual(); }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            base.OnPointerPressed(e);
            int i = RowAt(e.GetPosition(this));
            if (i < 0) return;
            _selected = i;
            InvalidateVisual();
            if (e.ClickCount == 2) owner.Edit(Rows[i].Address, Rows[i].Entry);
            else if (e.GetCurrentPoint(this).Properties.IsRightButtonPressed) Menu(Rows[i]).Open(this);
        }

        public void EditSelected()
        {
            if (_selected >= 0 && _selected < Rows.Count) owner.Edit(Rows[_selected].Address, Rows[_selected].Entry);
            else owner.Status?.Invoke("pick a row first");
        }

        public IEnumerable<int> HeldNow() => Enumerable.Range(0, RamMap.RamEnd).Where(owner._host.IsHeld).ToList();

        ContextMenu Menu(Row r)
        {
            var m = new ContextMenu();
            var edit = new MenuItem { Header = "Change…" };
            edit.Click += (_, _) => owner.Edit(r.Address, r.Entry);
            m.Items.Add(edit);
            if (owner._host.IsHeld(r.Address))
            {
                var rel = new MenuItem { Header = "Release" };
                rel.Click += (_, _) => { owner._host.HoldRam(r.Address, null, Math.Max(1, r.Entry?.Size ?? 1)); InvalidateVisual(); };
                m.Items.Add(rel);
            }
            foreach (var pc in owner._host.RamWriters(r.Address).Pcs)
            {
                var go = new MenuItem { Header = "Go to the code: " + owner._host.Where(pc) };
                go.Click += (_, _) => owner.GoToCode?.Invoke(pc);
                m.Items.Add(go);
            }
            return m;
        }

        string Tip(Row r)
        {
            var e = r.Entry;
            var (pcs, writes) = owner._host.RamWriters(r.Address);
            var sb = new System.Text.StringBuilder();
            sb.AppendLine($"{r.Address:X3}h  {e?.Name ?? "(no name)"}");
            if (e != null)
            {
                sb.AppendLine($"from: {e.Source}{(e.Formula is { Length: > 0 } f && f is not ("x" or "raw") ? $";  formula {f}" : "")}{(e.Size >= 2 ? ";  a word (low byte first)" : "")}");
                if (e.Description.Length > 0) sb.AppendLine(e.Description);
            }
            sb.AppendLine(writes == 0 ? "not written since the program started" : $"written {writes:N0} times; by:");
            foreach (var pc in pcs) sb.AppendLine("  " + owner._host.Where(pc));
            sb.Append("Double-click to change it; right-click to go to the code that writes it.");
            return sb.ToString();
        }
    }
}
