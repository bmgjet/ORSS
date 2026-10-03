// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Wraps a panel so Ctrl + mouse wheel over it zooms it (and only it). The zoom is reported so it can be remembered; `apply` replaces the default scale transform (the source editor changes its font size instead, which stays sharp and keeps its scrolling).
public sealed class ZoomHost : Decorator
{
    // A LayoutTransformControl lays a scaled child out at the child's own width and centres it: a zoomed panel then left a strip down both sides (the calibration list pushed in from the edge). Here the child is always given the whole panel, measured and arranged at panel / zoom and drawn scaled from the top-left corner.
    protected override Size MeasureOverride(Size available)
    {
        if (Child == null) return default;
        double z = Scale;
        Child.Measure(new Size(available.Width / z, available.Height / z));
        return new Size(Math.Min(available.Width, Child.DesiredSize.Width * z), Math.Min(available.Height, Child.DesiredSize.Height * z));
    }

    protected override Size ArrangeOverride(Size final)
    {
        if (Child == null) return final;
        double z = Scale;
        Child.RenderTransformOrigin = RelativePoint.TopLeft;
        Child.RenderTransform = Math.Abs(z - 1) < 0.001 ? null : new ScaleTransform(z, z);
        Child.Arrange(new Rect(0, 0, final.Width / z, final.Height / z));
        return final;
    }

    /// The scale the child is drawn at (1 when a callback applies the zoom some other way, a font size say).
    double Scale => _apply != null ? 1 : Zoom;

    public string Key { get; }
    readonly Action<double>? _apply;

    public event Action<string, double>? ZoomChanged;

    public ZoomHost(string key, Control child, Action<double>? apply = null)
    {
        Key = key; _apply = apply;
        Child = child;
        AddHandler(PointerWheelChangedEvent, OnWheel, RoutingStrategies.Tunnel);
        ToolTip.SetShowDelay(this, 1500);
    }

    public double Zoom
    {
        get;
        set
        {
            field = Math.Round(Math.Clamp(value, 0.5, 3), 2);
            if (_apply != null) _apply(field);
            InvalidateMeasure();
        }
    } = 1;

    void OnWheel(object? sender, PointerWheelEventArgs e)
    {
        if (!e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.Delta.Y == 0) return;
        // a panel inside this one that zooms on its own (the gauges in the datalog) takes the wheel over itself
        for (var v = e.Source as Avalonia.Visual; v != null && !ReferenceEquals(v, this); v = Avalonia.VisualTree.VisualExtensions.GetVisualParent(v))
            if (v is ZoomHost) return;
        Zoom += e.Delta.Y > 0 ? 0.1 : -0.1;
        ZoomChanged?.Invoke(Key, Zoom);
        e.Handled = true;
    }
}

/// Debug page: a console for everything - user actions, errors (with their stack traces), MCP tool calls and the address they came from, serial traffic, simulator events.
public sealed class DebugView : UserControl
{
    readonly DataList _list = new(new("Time", 96), new("Kind", 64), new("Source", 150), new("Message", 300))
    {
        Empty = "Nothing logged yet (or nothing matches the filter and the kinds ticked).",
    };
    readonly TextBox _detail = new()
    {
        IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = MainWindow.MonoFont, FontSize = 11,
        BorderThickness = new Thickness(0), Background = Brushes.Transparent, Watermark = "pick an entry to see all of it here",
    };
    readonly TextBox _filter = new() { Watermark = "filter", Width = 220 };
    readonly Dictionary<LogKind, CheckBox> _kinds = [];
    readonly CheckBox _follow = new() { Content = "follow newest", IsChecked = true, FontSize = 11 };
    readonly TextBlock _count = new() { FontSize = 11, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    readonly List<LogEntry> _all = [];
    List<LogEntry> _shown = [];
    long _last;
    bool _dirty = true;
    readonly Func<TopLevel?> _top;

    public DebugView(Func<TopLevel?> top)
    {
        _top = top;
        var bar = new WrapPanel { Margin = new Thickness(6, 4), VerticalAlignment = VerticalAlignment.Center };
        foreach (var k in Enum.GetValues<LogKind>())
        {
            var cb = new CheckBox
            {
                Content = new TextBlock { Text = k.ToString(), Foreground = KindInk(k), FontWeight = FontWeight.SemiBold, FontSize = 11.5 },
                IsChecked = true, Margin = new Thickness(0, 0, 10, 0),
            };
            cb.IsCheckedChanged += (_, _) => { _dirty = true; Tick(); };
            _kinds[k] = cb;
            bar.Children.Add(cb);
        }
        ToolTip.SetTip(_kinds[LogKind.Action], "Buttons pressed and other things you did.");
        ToolTip.SetTip(_kinds[LogKind.Error], "Exceptions caught anywhere in the app, with the stack trace in the detail box.");
        ToolTip.SetTip(_kinds[LogKind.Mcp], "Tool calls from MCP clients: the client address (or stdio), the tool, its arguments and the time it took.");
        ToolTip.SetTip(_kinds[LogKind.Serial], "Datalog, wideband and emulator traffic summaries.");
        _filter.TextChanged += (_, _) => { _dirty = true; Tick(); };
        bar.Children.Add(Panels.Divider());
        bar.Children.Add(_filter);
        bar.Children.Add(Btn("Clear", () => { AppLog.Clear(); _all.Clear(); _dirty = true; Tick(); }, "Forget every entry."));
        bar.Children.Add(Btn("Copy", Copy, "Copy the shown entries (with details) to the clipboard."));
        bar.Children.Add(Btn("Save…", Save, "Write the shown entries to a text file."));
        bar.Children.Add(_follow);
        bar.Children.Add(_count);
        _list.Picked += r => { if (r.Tag is LogEntry e) _detail.Text = Format(e) + (e.Detail is { } d ? "\n\n" + d : ""); };
        ToolTip.SetTip(_list, "Everything that happened, newest at the bottom. Pick an entry to see all of it below.");
        var split = new Grid { RowDefinitions = new RowDefinitions("*,6,120"), Margin = new Thickness(8, 8, 8, 0) };
        split.Children.Add(Panels.Card("Log", _list));
        var gs = new GridSplitter { Height = 6, ResizeDirection = GridResizeDirection.Rows, Background = Brushes.Transparent }; Grid.SetRow(gs, 1); split.Children.Add(gs);
        var detail = Panels.Card("Detail", _detail);
        Grid.SetRow(detail, 2); split.Children.Add(detail);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        var barBox = Panels.BarAround(bar);
        Grid.SetRow(barBox, 0); g.Children.Add(barBox);
        Grid.SetRow(split, 1); g.Children.Add(split);
        Content = g;
    }

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(8, 3) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    static IBrush KindInk(LogKind k) => k switch
    {
        LogKind.Error => DataList.Error,
        LogKind.Warning => DataList.Warning,
        LogKind.Action => DataList.Label,
        LogKind.Mcp => DataList.Purple,
        LogKind.Serial => DataList.Call,
        LogKind.Sim => DataList.Code,
        _ => DataList.Address,
    };

    static DataList.Row Row(LogEntry e)
    {
        var ink = KindInk(e.Kind);
        bool bad = e.Kind is LogKind.Error or LogKind.Warning;
        return new DataList.Row(
            [new(e.Time.ToString("HH:mm:ss.fff"), DataList.Dim), new(e.Kind.ToString(), ink, bad), new(e.Source, DataList.Address),
             new(e.Message.Replace('\n', ' ') + (e.Detail != null ? "  …" : ""), bad ? ink : DataList.Text)],
            ink, Tip: e.Detail == null ? null : "has details: pick it to see them below", Tag: e);
    }

    static string Format(LogEntry e) => $"{e.Time:HH:mm:ss.fff} {e.Kind,-7} {e.Source,-18} {e.Message.Replace('\n', ' ')}";

    /// Pull new entries in (called on the UI refresh tick while the page is showing).
    public void Tick()
    {
        var fresh = AppLog.Since(_last);
        if (fresh.Count > 0)
        {
            _last = fresh[^1].Serial;
            _all.AddRange(fresh);
            if (_all.Count > 6000) _all.RemoveRange(0, _all.Count - 5000);
            _dirty = true;
        }
        if (!_dirty) return;
        _dirty = false;
        var f = (_filter.Text ?? "").Trim();
        _shown = [.. _all.Where(e => _kinds[e.Kind].IsChecked == true &&
                                 (f.Length == 0 || e.Message.Contains(f, StringComparison.OrdinalIgnoreCase) || e.Source.Contains(f, StringComparison.OrdinalIgnoreCase)))
                     .TakeLast(3000)];
        _list.SetRows([.. _shown.Select(Row)]);
        if (_follow.IsChecked == true) _list.ScrollTo(_shown.Count - 1, centre: false);
        int errors = _all.Count(e => e.Kind == LogKind.Error);
        _count.Text = $"{_shown.Count} shown · {_all.Count} kept · {errors} error{(errors == 1 ? "" : "s")}";
        _count.Foreground = errors > 0 ? DataList.Error : DataList.Dim;
    }

    string Dump() => string.Join("\n", _shown.Select(e => Format(e) + (e.Detail is { } d ? "\n    " + d.Replace("\n", "\n    ") : "")));

    async void Copy()
    {
        try { if (_top()?.Clipboard is { } cb) await cb.SetTextAsync(Dump()); }
        catch (Exception ex) { AppLog.Error("debug", "copy failed", ex); }
    }

    async void Save()
    {
        try
        {
            var top = _top();
            if (top == null) return;
            var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Save the debug log", SuggestedFileName = $"okiromsim_{DateTime.Now:yyyyMMdd_HHmm}.log", DefaultExtension = "log",
            });
            var path = file?.TryGetLocalPath();
            if (path != null) SafeFile.WriteAllText(path, Dump());
        }
        catch (Exception ex) { AppLog.Error("debug", "save failed", ex); }
    }
}
