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
public sealed class ZoomHost : LayoutTransformControl
{
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
            else LayoutTransform = Math.Abs(field - 1) < 0.001 ? null : new ScaleTransform(field, field);
        }
    } = 1;

    void OnWheel(object? sender, PointerWheelEventArgs e)
    {
        if (!e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.Delta.Y == 0) return;
        Zoom += e.Delta.Y > 0 ? 0.1 : -0.1;
        ZoomChanged?.Invoke(Key, Zoom);
        e.Handled = true;
    }
}

/// Debug page: a console for everything - user actions, errors (with their stack traces), MCP tool calls and the address they came from, serial traffic, simulator events.
public sealed class DebugView : UserControl
{
    readonly ListBox _list = UiStyles.Compact(new ListBox { FontFamily = MainWindow.MonoFont, FontSize = 11 });
    readonly TextBox _detail = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = MainWindow.MonoFont, FontSize = 11 };
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
        var bar = new WrapPanel { Margin = new Thickness(4) };
        foreach (var k in Enum.GetValues<LogKind>())
        {
            var cb = new CheckBox { Content = k.ToString(), IsChecked = true, FontSize = 11, Margin = new Thickness(0, 0, 8, 0) };
            cb.IsCheckedChanged += (_, _) => { _dirty = true; Tick(); };
            _kinds[k] = cb;
            bar.Children.Add(cb);
        }
        ToolTip.SetTip(_kinds[LogKind.Action], "Buttons pressed and other things you did.");
        ToolTip.SetTip(_kinds[LogKind.Error], "Exceptions caught anywhere in the app, with the stack trace in the detail box.");
        ToolTip.SetTip(_kinds[LogKind.Mcp], "Tool calls from LLM agents: the client address (or stdio), the tool, its arguments and the time it took.");
        ToolTip.SetTip(_kinds[LogKind.Serial], "Datalog, wideband and emulator traffic summaries.");
        _filter.TextChanged += (_, _) => { _dirty = true; Tick(); };
        bar.Children.Add(_filter);
        bar.Children.Add(Btn("Clear", () => { AppLog.Clear(); _all.Clear(); _dirty = true; Tick(); }, "Forget every entry."));
        bar.Children.Add(Btn("Copy", Copy, "Copy the shown entries (with details) to the clipboard."));
        bar.Children.Add(Btn("Save…", Save, "Write the shown entries to a text file."));
        bar.Children.Add(_follow);
        bar.Children.Add(_count);
        _list.SelectionChanged += (_, _) =>
        {
            int i = _list.SelectedIndex;
            if (i >= 0 && i < _shown.Count) _detail.Text = Format(_shown[i]) + (_shown[i].Detail is { } d ? "\n\n" + d : "");
        };
        ToolTip.SetTip(_list, "Everything that happened, newest at the bottom. Select an entry to see its details.");
        var split = new Grid { RowDefinitions = new RowDefinitions("*,4,110") };
        Grid.SetRow(_list, 0); split.Children.Add(_list);
        var gs = new GridSplitter { Height = 4, ResizeDirection = GridResizeDirection.Rows }; Grid.SetRow(gs, 1); split.Children.Add(gs);
        Grid.SetRow(_detail, 2); split.Children.Add(_detail);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(split, 1); g.Children.Add(split);
        Content = g;
    }

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(7, 2) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
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
        int sel = _list.SelectedIndex;
        _list.ItemsSource = _shown.Select(Format).ToList();
        _count.Text = $"{_shown.Count} shown, {_all.Count} kept, {_all.Count(e => e.Kind == LogKind.Error)} errors";
        if (_follow.IsChecked == true && _shown.Count > 0) { try { _list.ScrollIntoView(_shown.Count - 1); } catch { } }
        else if (sel >= 0 && sel < _shown.Count) _list.SelectedIndex = sel;
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
            if (path != null) File.WriteAllText(path, Dump());
        }
        catch (Exception ex) { AppLog.Error("debug", "save failed", ex); }
    }
}
