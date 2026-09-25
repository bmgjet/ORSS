// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// A whole datalog as a graph: several channels against time, on one set of axes, with a cursor that reads every channel at the moment it sits on and moves the rest of the program with it. The gauges show what is happening now; this shows what happened. It is the view you want when a cell went lean two seconds after a gear change and you need to see the throttle, the load and the AFR line up - which is exactly what a rolling gauge cannot show you. Each channel is drawn on its own scale (its own minimum and maximum over the log, or a scale you fix), so rpm and lambda share a window without one flattening the other. Dragging the cursor moves the Datalog page's position too, so the map's trace marker follows it.
public sealed class DatalogGraphWindow : Window
{
    public DatalogGraphPanel Panel { get; }

    /// One channel on the graph: which log field, what colour, and the scale it is drawn against.
    public sealed class Channel
    {
        public string Name = "";
        public Color Colour;
        public bool Shown = true;
        /// Null means "fit this channel to the log"; set both to pin it.
        public double? Min, Max;
        public double[] Values = [];
        public double Lo, Hi;
    }

    public DatalogGraphWindow(Func<IReadOnlyList<LogFrame>> frames, Action<int>? seek = null)
    {
        Title = "Datalog graph";
        Width = 1100; Height = 680; MinWidth = 640; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var chrome = DarkChrome.Apply(this, "Datalog graph");
        Panel = new DatalogGraphPanel(frames, seek, Close);
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(chrome, 0); g.Children.Add(chrome);
        Grid.SetRow(Panel, 1); g.Children.Add(Panel);
        Content = g;
    }
}

/// The graph itself, with its channel list and toolbar: in its own window, or in the datalog panel beside the map (Datalogging > Graph). While a log plays back a bar marks the frame on screen; while logging live the graph grows as frames arrive and follows the newest.
public sealed class DatalogGraphPanel : UserControl
{
    readonly Func<IReadOnlyList<LogFrame>> _frames;
    readonly Action<int>? _seek;
    readonly GraphCanvas _canvas = new();
    readonly StackPanel _channelList = new();
    readonly TextBlock _readout = new()
    {
        FontFamily = MainWindow.MonoFont, FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8, 4),
    };
    readonly TextBlock _status = new() { FontSize = 11, Opacity = 0.8, Margin = new Thickness(8, 2), TextWrapping = TextWrapping.Wrap };
    readonly List<DatalogGraphWindow.Channel> _channels = [];
    readonly ColumnDefinition _sideColumn;

    /// The colours channels are handed out in, in order: distinguishable, and the same every time so a graph you have looked at before still reads the same way.
    static readonly Color[] Palette =
    {
        Color.FromRgb(0x4e, 0xc9, 0xf0), Color.FromRgb(0x7a, 0xd9, 0x6a), Color.FromRgb(0xff, 0xc4, 0x4a),
        Color.FromRgb(0xff, 0x77, 0x77), Color.FromRgb(0xc2, 0x8c, 0xff), Color.FromRgb(0x5a, 0xd9, 0xc0),
        Color.FromRgb(0xff, 0x9a, 0x5a), Color.FromRgb(0xb0, 0xbe, 0xc5),
    };

    /// The channels a tuner wants first, so the graph opens on something useful rather than empty.
    static readonly string[] Preferred = { "rpm", "map_kpa", "tps_pct", "afr", "inj_ms", "ign_deg", "knock", "ect_c" };

    public DatalogGraphPanel(Func<IReadOnlyList<LogFrame>> frames, Action<int>? seek = null, Action? close = null, bool compact = false)
    {
        _frames = frames; _seek = seek;
        _sideColumn = new ColumnDefinition(compact ? new GridLength(0) : new GridLength(230));

        var bar = new WrapPanel { Margin = new Thickness(8, 4) };
        bar.Children.Add(Btn("Reload", Reload, "Read the log again - use it after logging more, or loading another one."));
        bar.Children.Add(Btn("Fit", () => { _canvas.ResetZoom(); Redraw(); }, "Show the whole log again."));
        bar.Children.Add(Btn("Channels", () => _sideColumn.Width = _sideColumn.Width.Value > 0 ? new GridLength(0) : new GridLength(compact ? 170 : 230),
            "Show or hide the channel list."));
        bar.Children.Add(Btn("Save template…", SaveTemplate, "Keep this set of channels, their colours and their scales, to use on the next log."));
        bar.Children.Add(Toolbar.Menu("Templates", Toolbar.Log, Toolbar.Entry.Submenu(Toolbar.Log, "Load", "Channel sets saved earlier.", TemplateEntries)));
        bar.Children.Add(Btn("Export CSV…", ExportCsv, "Write the channels on the graph, over the range on screen, to a CSV file."));
        if (close != null) bar.Children.Add(Btn("Close", close, "Close the graph."));

        _canvas.Moved += OnCursorMoved;
        _canvas.Channels = _channels;

        var side = new DockPanel { Margin = new Thickness(4) };
        var head = new TextBlock { Text = "CHANNELS", FontSize = 10, Opacity = 0.6, Margin = new Thickness(6, 4) };
        DockPanel.SetDock(head, Dock.Top);
        side.Children.Add(head);
        side.Children.Add(new ScrollViewer { Content = _channelList });

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Star));
        body.ColumnDefinitions.Add(new ColumnDefinition(new GridLength(4)));
        body.ColumnDefinitions.Add(_sideColumn);
        var left = new DockPanel();
        DockPanel.SetDock(_readout, Dock.Bottom);
        DockPanel.SetDock(_status, Dock.Bottom);
        left.Children.Add(_status);
        left.Children.Add(_readout);
        left.Children.Add(_canvas);
        Grid.SetColumn(left, 0); body.Children.Add(left);
        var split = new GridSplitter { Width = 4 }; Grid.SetColumn(split, 1); body.Children.Add(split);
        Grid.SetColumn(side, 2); body.Children.Add(side);

        var g = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        g.Children.Add(bar);
        g.Children.Add(body);
        Content = g;

        Reload();
    }

    Window? Owner => TopLevel.GetTopLevel(this) as Window;

    /// Where the log is now (a replay, the slider, or the newest frame live): the bar is drawn there, and a live log is read again as it grows so the line is drawn as it comes in.
    public void Follow(int index, bool live)
    {
        var log = _frames();
        bool changed = !ReferenceEquals(log, _canvas.Frames) || log.Count != _canvas.Frames.Count;
        // live, the log grows every few ms: read it again a couple of times a second, not every tick
        if (changed && (!live || (DateTime.UtcNow - _lastReload).TotalMilliseconds >= 400))
        {
            _lastReload = DateTime.UtcNow;
            Reload(quiet: true);
        }
        _canvas.SetPlayhead(live ? _canvas.Frames.Count - 1 : index, live);
    }
    DateTime _lastReload;

    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 0), FontSize = 11.5, Padding = new Thickness(7, 2) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    // ---------------------------------------------------------------- the data

    void Reload() => Reload(quiet: false);

    void Reload(bool quiet)
    {
        var log = _frames();
        _canvas.Frames = log;
        if (log.Count == 0)
        {
            _channels.Clear();
            BuildChannelList();
            _status.Text = "no frames yet: log a drive, or load one on the Datalog page";
            Redraw();
            return;
        }
        // listed only when a frame's set of channels changes: a 50,000-frame log no longer lists them 50,000 times
        var available = LogFrame.AllChannels(log).OrderBy(c => c, StringComparer.OrdinalIgnoreCase).ToList();
        // keep whatever was already on the graph, and start off with the ones a tuner wants
        if (_channels.Count == 0)
            foreach (var name in Preferred.Where(n => available.Contains(n, StringComparer.OrdinalIgnoreCase)))
                _channels.Add(new DatalogGraphWindow.Channel { Name = name, Colour = Palette[_channels.Count % Palette.Length] });
        foreach (var name in available)
            if (!_channels.Any(c => c.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                _channels.Add(new DatalogGraphWindow.Channel
                {
                    Name = name, Shown = false, Colour = Palette[_channels.Count % Palette.Length],
                });
        _channels.RemoveAll(c => !available.Contains(c.Name, StringComparer.OrdinalIgnoreCase));

        bool listChanged = _listed != _channels.Count;
        foreach (var c in _channels) Sample(c, log);
        if (!quiet || listChanged) { BuildChannelList(); _listed = _channels.Count; }
        double span = log[^1].T - log[0].T;
        _status.Text = $"{log.Count:N0} frames over {span:0.#} s, {_channels.Count(c => c.Shown)} of {_channels.Count} channels shown. " +
                       "Drag to move the cursor, wheel to zoom, drag with the right button to pan.";
        Redraw();
    }

    /// One value per frame for a channel, and the range it covers. A frame with nothing for it leaves a gap rather than a zero, so a channel that starts part-way through the log does not get a false line back to the origin.
    static void Sample(DatalogGraphWindow.Channel c, IReadOnlyList<LogFrame> log)
    {
        c.Values = new double[log.Count];
        double lo = double.MaxValue, hi = double.MinValue;
        for (int i = 0; i < log.Count; i++)
        {
            double v = log[i].Get(c.Name) ?? double.NaN;
            c.Values[i] = v;
            if (double.IsNaN(v)) continue;
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (lo > hi) { lo = 0; hi = 1; }
        if (Math.Abs(hi - lo) < 1e-9) { lo -= 1; hi += 1; }
        c.Lo = c.Min ?? lo;
        c.Hi = c.Max ?? hi;
        if (c.Hi <= c.Lo) c.Hi = c.Lo + 1;
    }

    int _listed = -1;

    void BuildChannelList()
    {
        _channelList.Children.Clear();
        foreach (var c in _channels)
        {
            var channel = c;
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Margin = new Thickness(2, 1) };
            var tick = new CheckBox { IsChecked = c.Shown, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0) };
            tick.IsCheckedChanged += (_, _) => { channel.Shown = tick.IsChecked == true; Redraw(); UpdateStatus(); };
            Grid.SetColumn(tick, 0); row.Children.Add(tick);

            var label = new TextBlock
            {
                Text = c.Name, FontSize = 11.5, VerticalAlignment = VerticalAlignment.Center,
                Foreground = new SolidColorBrush(c.Colour), TextTrimming = TextTrimming.CharacterEllipsis,
            };
            ToolTip.SetTip(label, $"{c.Name}: {Fmt(c.Lo)} to {Fmt(c.Hi)}" +
                                  (c.Min != null || c.Max != null ? " (scale fixed)" : " (fitted to the log)") +
                                  "\nClick the swatch to change the colour; the boxes below pin the scale.");
            Grid.SetColumn(label, 1); row.Children.Add(label);

            var swatch = new Button
            {
                Width = 16, Height = 16, Padding = new Thickness(0), Margin = new Thickness(2, 0),
                Background = new SolidColorBrush(c.Colour), BorderThickness = new Thickness(0),
            };
            swatch.Click += (_, _) =>
            {
                // step through the palette: a colour picker per channel is more ceremony than this needs
                int at = Array.IndexOf(Palette, channel.Colour);
                channel.Colour = Palette[(at + 1 + Palette.Length) % Palette.Length];
                BuildChannelList();
                Redraw();
            };
            ToolTip.SetTip(swatch, "Next colour.");
            Grid.SetColumn(swatch, 2); row.Children.Add(swatch);
            _channelList.Children.Add(row);

            if (!c.Shown) continue;
            var scale = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, Margin = new Thickness(22, 0, 2, 4) };
            scale.Children.Add(ScaleBox(channel, min: true));
            scale.Children.Add(new TextBlock { Text = "–", FontSize = 10, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center });
            scale.Children.Add(ScaleBox(channel, min: false));
            var fit = new Button { Content = "fit", FontSize = 10, Padding = new Thickness(4, 0), Margin = new Thickness(2, 0) };
            fit.Click += (_, _) => { channel.Min = channel.Max = null; Sample(channel, _canvas.Frames); BuildChannelList(); Redraw(); };
            ToolTip.SetTip(fit, "Back to the channel's own range over this log.");
            scale.Children.Add(fit);
            _channelList.Children.Add(scale);
        }
    }

    TextBox ScaleBox(DatalogGraphWindow.Channel c, bool min)
    {
        var box = new TextBox
        {
            Text = Fmt(min ? c.Lo : c.Hi), Width = 58, FontSize = 10.5, Padding = new Thickness(3, 0),
            FontFamily = MainWindow.MonoFont,
        };
        ToolTip.SetTip(box, min ? "Bottom of this channel's scale." : "Top of this channel's scale.");
        box.LostFocus += (_, _) =>
        {
            if (double.TryParse(box.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
            {
                if (min) c.Min = v; else c.Max = v;
                Sample(c, _canvas.Frames);
                Redraw();
            }
            box.Text = Fmt(min ? c.Lo : c.Hi);
        };
        return box;
    }

    static string Fmt(double v) =>
        double.IsNaN(v) ? "-"
        : Math.Abs(v) >= 1000 ? v.ToString("0", CultureInfo.InvariantCulture)
        : Math.Abs(v) >= 10 ? v.ToString("0.#", CultureInfo.InvariantCulture)
        : v.ToString("0.##", CultureInfo.InvariantCulture);

    void UpdateStatus()
    {
        var log = _canvas.Frames;
        if (log.Count == 0) return;
        _status.Text = $"{log.Count:N0} frames over {log[^1].T - log[0].T:0.#} s, " +
                       $"{_channels.Count(c => c.Shown)} of {_channels.Count} channels shown.";
    }

    void Redraw() => _canvas.InvalidateVisual();

    /// The cursor landed on a frame: read every shown channel at it, and move the rest of the program there too so the map's trace marker follows.
    void OnCursorMoved(int index)
    {
        var log = _canvas.Frames;
        if (index < 0 || index >= log.Count) { _readout.Text = ""; return; }
        var f = log[index];
        var parts = _channels.Where(c => c.Shown)
            .Select(c => $"{c.Name} {(index < c.Values.Length && !double.IsNaN(c.Values[index]) ? Fmt(c.Values[index]) : "-")}");
        _readout.Text = $"t {f.T:0.00} s   frame {index:N0}   " + string.Join("   ", parts);
        _seek?.Invoke(index);
    }

    // ---------------------------------------------------------------- templates

    /// Where channel sets are kept, beside the gauge dashboards.
    static string Dir => Path.Combine(AppSettings.Dir, "graphs");

    sealed class GraphTemplate
    {
        public string Name { get; set; } = "";
        public List<Row> Channels { get; set; } = [];
        public sealed class Row
        {
            public string Name { get; set; } = "";
            public string Colour { get; set; } = "";
            public bool Shown { get; set; }
            public double? Min { get; set; }
            public double? Max { get; set; }
        }
    }

    async void SaveTemplate()
    {
        var box = new TextBox { Width = 240, Watermark = "name for this channel set" };
        if (Owner is not { } owner) return;
        var ok = await Dialogs.Prompt(owner, "Save a graph template", "These channels, their colours and their scales, kept for the next log.", box);
        if (!ok || string.IsNullOrWhiteSpace(box.Text)) return;
        try
        {
            Directory.CreateDirectory(Dir);
            var t = new GraphTemplate
            {
                Name = box.Text!.Trim(),
                Channels = [.. _channels.Select(c => new GraphTemplate.Row
                {
                    Name = c.Name, Shown = c.Shown, Min = c.Min, Max = c.Max,
                    Colour = $"#{c.Colour.R:X2}{c.Colour.G:X2}{c.Colour.B:X2}",
                })],
            };
            var path = Path.Combine(Dir, Sanitise(t.Name) + ".graph.json");
            File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(t, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
            _status.Text = "saved " + path;
            AppLog.Action("datalog", "saved the graph template " + t.Name);
        }
        catch (Exception ex) { _status.Text = "could not save: " + ex.Message; AppLog.Error("datalog", "graph template save failed", ex); }
    }

    static string Sanitise(string name) => string.Join("_", name.Split(Path.GetInvalidFileNameChars()));

    Toolbar.Entry[] TemplateEntries()
    {
        var files = Directory.Exists(Dir) ? Directory.GetFiles(Dir, "*.graph.json") : [];
        if (files.Length == 0) return [new Toolbar.Entry("", "(none saved yet)", "Save a template and it appears here.", () => { })];
        return [.. files.Select(path => new Toolbar.Entry(Toolbar.Log,
            Path.GetFileName(path).Replace(".graph.json", ""), path, () => LoadTemplate(path)))];
    }

    void LoadTemplate(string path)
    {
        try
        {
            var t = System.Text.Json.JsonSerializer.Deserialize<GraphTemplate>(File.ReadAllText(path));
            if (t == null) return;
            foreach (var row in t.Channels)
            {
                var c = _channels.FirstOrDefault(x => x.Name.Equals(row.Name, StringComparison.OrdinalIgnoreCase));
                // a template can name a channel this log does not have; add it switched off rather than silently dropping it, so it comes back when a log that has it is loaded
                if (c == null) continue;
                c.Shown = row.Shown; c.Min = row.Min; c.Max = row.Max;
                try { c.Colour = Color.Parse(row.Colour); } catch { }
                Sample(c, _canvas.Frames);
            }
            foreach (var c in _channels)
                if (!t.Channels.Any(r => r.Name.Equals(c.Name, StringComparison.OrdinalIgnoreCase))) c.Shown = false;
            BuildChannelList();
            Redraw();
            int missing = t.Channels.Count(r => !_channels.Any(c => c.Name.Equals(r.Name, StringComparison.OrdinalIgnoreCase)));
            _status.Text = $"{Path.GetFileName(path)}: {_channels.Count(c => c.Shown)} channel(s) shown" +
                           (missing > 0 ? $"; {missing} the template names are not in this log" : "");
        }
        catch (Exception ex) { _status.Text = "could not open: " + ex.Message; AppLog.Error("datalog", "graph template load failed", ex); }
    }

    async void ExportCsv()
    {
        var log = _canvas.Frames;
        var shown = _channels.Where(c => c.Shown).ToList();
        if (log.Count == 0 || shown.Count == 0) { _status.Text = "nothing on the graph to export"; return; }
        try
        {
            if (TopLevel.GetTopLevel(this) is not { } top) return;
            var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Export the channels on the graph",
                SuggestedFileName = "graph.csv", DefaultExtension = "csv",
                FileTypeChoices = [new FilePickerFileType("CSV") { Patterns = ["*.csv"] }],
            });
            var path = file?.TryGetLocalPath();
            if (path == null) return;
            var (from, to) = _canvas.VisibleRange();
            var sb = new System.Text.StringBuilder("time_s," + string.Join(",", shown.Select(c => c.Name)) + "\n");
            for (int i = from; i <= to && i < log.Count; i++)
            {
                sb.Append(log[i].T.ToString("0.000", CultureInfo.InvariantCulture));
                foreach (var c in shown)
                    sb.Append(',').Append(i < c.Values.Length && !double.IsNaN(c.Values[i])
                        ? c.Values[i].ToString("0.###", CultureInfo.InvariantCulture) : "");
                sb.Append('\n');
            }
            File.WriteAllText(path, sb.ToString());
            _status.Text = $"wrote {path}: {to - from + 1:N0} rows, {shown.Count} channels";
        }
        catch (Exception ex) { _status.Text = "export failed: " + ex.Message; AppLog.Error("datalog", "graph export failed", ex); }
    }
}

/// The plot itself: every shown channel drawn on its own scale over a shared time axis, with a cursor, wheel zoom and right-button pan.
public sealed class GraphCanvas : Control
{
    public IReadOnlyList<LogFrame> Frames = [];
    public List<DatalogGraphWindow.Channel> Channels = [];
    /// The cursor moved to this frame.
    public event Action<int>? Moved;

    double _from, _to = 1;              // the visible span, as fractions of the log
    int _cursor = -1;
    bool _dragging, _panning;
    Point _panFrom;

    static readonly IBrush Face = new SolidColorBrush(Color.FromRgb(0x12, 0x13, 0x16));
    static readonly IPen Grid = new Pen(new SolidColorBrush(Color.FromRgb(0x2a, 0x2d, 0x33)), 1);
    static readonly IBrush Ink = new SolidColorBrush(Color.FromRgb(0xb0, 0xb6, 0xc0));
    static readonly IPen CursorPen = new Pen(new SolidColorBrush(Color.FromRgb(0xff, 0xff, 0xff)), 1, DashStyle.Dash);

    public GraphCanvas()
    {
        Focusable = true;
        ClipToBounds = true;
    }

    public void ResetZoom() { _from = 0; _to = 1; }

    int _playhead = -1;
    bool _live;

    /// The frame a replay (or the live log) is at: drawn as a bar. Live, a zoomed-in view slides along so the newest frame stays on screen.
    public void SetPlayhead(int index, bool live)
    {
        if (index == _playhead && live == _live) return;
        _playhead = index; _live = live;
        if (Frames.Count > 1 && index >= 0)
        {
            double at = (double)index / (Frames.Count - 1), span = _to - _from;
            if (span < 1 && (at > _to || at < _from)) { _from = Math.Clamp(at - (live ? span * 0.95 : span / 2), 0, 1 - span); _to = _from + span; }
        }
        InvalidateVisual();
    }

    static readonly IBrush PlayBrush = new SolidColorBrush(Color.FromRgb(0xff, 0xd0, 0x30));
    static readonly IPen PlayPen = new Pen(PlayBrush, 2.5);
    static readonly IBrush PlayBand = new SolidColorBrush(Color.FromArgb(0x38, 0xff, 0xd0, 0x30));
    static readonly IBrush TipBack = new SolidColorBrush(Color.FromArgb(0xe8, 0x20, 0x22, 0x27));
    static readonly IPen TipEdge = new Pen(new SolidColorBrush(Color.FromRgb(0x5a, 0x5e, 0x68)), 1);
    static readonly IBrush TipInk = new SolidColorBrush(Color.FromRgb(0xe8, 0xea, 0xee));
    static readonly IPen TipRing = new Pen(TipInk, 1);

    /// The line under the pointer (when not dragging): which channel, and at which frame.
    (DatalogGraphWindow.Channel Ch, int Frame)? _hover;

    /// The frames at the edges of what is on screen.
    public (int From, int To) VisibleRange()
    {
        if (Frames.Count == 0) return (0, 0);
        int a = (int)Math.Clamp(_from * (Frames.Count - 1), 0, Frames.Count - 1);
        int b = (int)Math.Clamp(_to * (Frames.Count - 1), 0, Frames.Count - 1);
        return (Math.Min(a, b), Math.Max(a, b));
    }

    const double Left = 52, Right = 8, Top = 8, Bottom = 22;

    Rect Plot => new(Left, Top, Math.Max(10, Bounds.Width - Left - Right), Math.Max(10, Bounds.Height - Top - Bottom));

    public override void Render(DrawingContext c)
    {
        var r = new Rect(0, 0, Bounds.Width, Bounds.Height);
        c.FillRectangle(Face, r);
        var plot = Plot;
        c.DrawRectangle(null, Grid, plot);
        if (Frames.Count < 2)
        {
            Text(c, "no log to draw", new Point(plot.X + 8, plot.Y + 8), 12, Ink);
            return;
        }
        var (from, to) = VisibleRange();
        if (to <= from) return;

        // the time axis
        double t0 = Frames[from].T, t1 = Frames[to].T;
        for (int i = 0; i <= 8; i++)
        {
            double x = plot.X + (plot.Width * i / 8);
            c.DrawLine(Grid, new Point(x, plot.Y), new Point(x, plot.Bottom));
            double t = t0 + ((t1 - t0) * i / 8);
            Text(c, t.ToString("0.#", CultureInfo.InvariantCulture) + "s", new Point(x - 12, plot.Bottom + 4), 10, Ink);
        }
        // and a horizontal grid, labelled 0-100% because every channel has its own scale
        for (int i = 0; i <= 4; i++)
        {
            double y = plot.Y + (plot.Height * i / 4);
            c.DrawLine(Grid, new Point(plot.X, y), new Point(plot.Right, y));
            Text(c, $"{100 - (i * 25)}%", new Point(4, y - 6), 10, Ink);
        }

        int count = to - from;
        foreach (var ch in Channels)
        {
            if (!ch.Shown || ch.Values.Length == 0) continue;
            double span = Math.Max(1e-9, ch.Hi - ch.Lo);
            var pen = new Pen(new SolidColorBrush(ch.Colour), 1.4, lineJoin: PenLineJoin.Round);
            var geo = new StreamGeometry();
            using (var g = geo.Open())
            {
                bool started = false;
                // one point per pixel at most: a 50,000-frame log would otherwise cost more to draw than it is worth, and nothing would be visible that is not visible this way
                int step = Math.Max(1, count / Math.Max(1, (int)plot.Width));
                for (int i = from; i <= to; i += step)
                {
                    double v = ch.Values[Math.Min(i, ch.Values.Length - 1)];
                    if (double.IsNaN(v)) { if (started) { g.EndFigure(false); started = false; } continue; }
                    double x = plot.X + (plot.Width * (i - from) / (double)count);
                    double y = plot.Bottom - (plot.Height * Math.Clamp((v - ch.Lo) / span, 0, 1));
                    var pt = new Point(x, y);
                    if (!started) { g.BeginFigure(pt, false); started = true; }
                    else g.LineTo(pt);
                }
                if (started) g.EndFigure(false);
            }
            c.DrawGeometry(null, pen, geo);
        }

        if (_playhead >= from && _playhead <= to)
        {
            // a glowing band, a solid bar, arrow heads at both ends and the time on a tab: easy to find at a glance
            double x = plot.X + (plot.Width * (_playhead - from) / (double)count);
            c.FillRectangle(PlayBand, new Rect(x - 5, plot.Y, 10, plot.Height));
            c.DrawLine(PlayPen, new Point(x, plot.Y), new Point(x, plot.Bottom));
            var head = new StreamGeometry();
            using (var g = head.Open())
            {
                g.BeginFigure(new Point(x - 6, plot.Y), true); g.LineTo(new Point(x + 6, plot.Y)); g.LineTo(new Point(x, plot.Y + 8)); g.EndFigure(true);
                g.BeginFigure(new Point(x - 6, plot.Bottom), true); g.LineTo(new Point(x + 6, plot.Bottom)); g.LineTo(new Point(x, plot.Bottom - 8)); g.EndFigure(true);
            }
            c.DrawGeometry(PlayBrush, null, head);
            string tag = (_live ? "LIVE " : "") + Frames[Math.Min(_playhead, Frames.Count - 1)].T.ToString("0.0", CultureInfo.InvariantCulture) + "s";
            var ft = Formatted(tag, 10.5, Brushes.Black);
            double tx = Math.Clamp(x + 9, plot.X + 3, Math.Max(plot.X + 3, plot.Right - ft.Width - 6));
            c.FillRectangle(PlayBrush, new Rect(tx - 3, plot.Y + 2, ft.Width + 6, ft.Height + 2), 3);
            c.DrawText(ft, new Point(tx, plot.Y + 3));
        }
        if (_cursor >= from && _cursor <= to)
        {
            double x = plot.X + (plot.Width * (_cursor - from) / (double)count);
            c.DrawLine(CursorPen, new Point(x, plot.Y), new Point(x, plot.Bottom));
            foreach (var ch in Channels)
            {
                if (!ch.Shown || _cursor >= ch.Values.Length) continue;
                double v = ch.Values[_cursor];
                if (double.IsNaN(v)) continue;
                double y = plot.Bottom - (plot.Height * Math.Clamp((v - ch.Lo) / Math.Max(1e-9, ch.Hi - ch.Lo), 0, 1));
                c.DrawEllipse(new SolidColorBrush(ch.Colour), null, new Point(x, y), 2.5, 2.5);
            }
        }

        // the line under the pointer: its sensor's name and its value there, beside a dot on the line
        if (_hover is { } h && h.Frame >= from && h.Frame <= to && h.Frame < h.Ch.Values.Length && !double.IsNaN(h.Ch.Values[h.Frame]))
        {
            double v = h.Ch.Values[h.Frame];
            double x = plot.X + (plot.Width * (h.Frame - from) / (double)count);
            double y = plot.Bottom - (plot.Height * Math.Clamp((v - h.Ch.Lo) / Math.Max(1e-9, h.Ch.Hi - h.Ch.Lo), 0, 1));
            var brush = new SolidColorBrush(h.Ch.Colour);
            c.DrawEllipse(brush, TipRing, new Point(x, y), 4, 4);
            var ft = Formatted($"{h.Ch.Name}: {Value(v)}   at {Frames[h.Frame].T.ToString("0.00", CultureInfo.InvariantCulture)}s", 11.5, TipInk);
            double bw = ft.Width + 22, bh = ft.Height + 8;
            double bx = x + 12 + bw > Bounds.Width ? x - 12 - bw : x + 12;
            double by = Math.Clamp(y - bh - 6, 0, Math.Max(0, Bounds.Height - bh));
            var box = new Rect(Math.Max(0, bx), by, bw, bh);
            c.DrawRectangle(TipBack, TipEdge, box, 3, 3);
            c.FillRectangle(brush, new Rect(box.X + 6, box.Y + (bh / 2) - 4, 8, 8));
            c.DrawText(ft, new Point(box.X + 17, box.Y + 4));
        }
    }

    static string Value(double v) => Math.Abs(v) >= 1000 ? v.ToString("0", CultureInfo.InvariantCulture)
                                   : Math.Abs(v) >= 10 ? v.ToString("0.0", CultureInfo.InvariantCulture)
                                   : v.ToString("0.###", CultureInfo.InvariantCulture);

    static FormattedText Formatted(string s, double size, IBrush brush) =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface(MainWindow.MonoFont), size, brush);

    /// The shown channel whose line passes nearest the pointer (within a few pixels), and the frame under it.
    (DatalogGraphWindow.Channel Ch, int Frame)? HitLine(Point pos)
    {
        var plot = Plot;
        if (Frames.Count < 2 || !plot.Contains(pos)) return null;
        int frame = FrameAt(pos.X);
        DatalogGraphWindow.Channel? best = null;
        double bestD = 9;
        foreach (var ch in Channels)
        {
            if (!ch.Shown || frame >= ch.Values.Length) continue;
            double v = ch.Values[frame];
            if (double.IsNaN(v)) continue;
            double y = plot.Bottom - (plot.Height * Math.Clamp((v - ch.Lo) / Math.Max(1e-9, ch.Hi - ch.Lo), 0, 1));
            double d = Math.Abs(y - pos.Y);
            if (d < bestD) { bestD = d; best = ch; }
        }
        return best == null ? null : (best, frame);
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        base.OnPointerExited(e);
        if (_hover != null) { _hover = null; InvalidateVisual(); }
    }

    static void Text(DrawingContext c, string s, Point at, double size, IBrush brush) =>
        c.DrawText(new FormattedText(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                                     new Typeface(MainWindow.MonoFont), size, brush), at);

    int FrameAt(double x)
    {
        var (from, to) = VisibleRange();
        var plot = Plot;
        double f = Math.Clamp((x - plot.X) / plot.Width, 0, 1);
        return from + (int)Math.Round(f * (to - from));
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        Focus();
        var p = e.GetCurrentPoint(this);
        if (p.Properties.IsRightButtonPressed) { _panning = true; _panFrom = p.Position; e.Pointer.Capture(this); return; }
        _dragging = true;
        e.Pointer.Capture(this);
        _cursor = FrameAt(p.Position.X);
        Moved?.Invoke(_cursor);
        InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var pos = e.GetPosition(this);
        if (_panning)
        {
            double dx = (pos.X - _panFrom.X) / Math.Max(1, Plot.Width) * (_to - _from);
            double span = _to - _from;
            _from = Math.Clamp(_from - dx, 0, 1 - span);
            _to = _from + span;
            _panFrom = pos;
            InvalidateVisual();
            return;
        }
        if (!_dragging)
        {
            var hit = HitLine(pos);
            // redraw only when what is under the pointer changed, not on every pixel it moves
            if (!Equals(hit?.Ch, _hover?.Ch) || hit?.Frame != _hover?.Frame) { _hover = hit; InvalidateVisual(); }
            return;
        }
        _hover = null;
        _cursor = FrameAt(pos.X);
        Moved?.Invoke(_cursor);
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        _dragging = _panning = false;
        e.Pointer.Capture(null);
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        var plot = Plot;
        // zoom about the pointer, so what is under it stays under it
        double at = _from + (Math.Clamp((e.GetPosition(this).X - plot.X) / plot.Width, 0, 1) * (_to - _from));
        double factor = e.Delta.Y > 0 ? 0.8 : 1.25;
        double span = Math.Clamp((_to - _from) * factor, 1e-4, 1);
        _from = Math.Clamp(at - (span / 2), 0, 1 - span);
        _to = _from + span;
        e.Handled = true;
        InvalidateVisual();
    }
}
