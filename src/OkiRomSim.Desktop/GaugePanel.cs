// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The dashboard on the Datalog page: gauges you build yourself - dials, bars, numbers, trigger lights and rolling graphs - fed by the logged channels. New / Load / Save / Templates work on a layout (a .gauges.json file); Create widget pops the selected gauge out into its own small window that floats over everything else, so the one reading that matters can sit where you can see it while you drive or tune.
public sealed class GaugePanel : UserControl
{
    /// Where dashboards are kept between runs.
    public static string Dir => Path.Combine(AppSettings.Dir, "gauges");

    readonly Canvas _canvas = new() { Background = AppTheme.Brush(Color.FromRgb(0x16, 0x17, 0x1a)) };
    readonly TextBlock _hint = new() { FontSize = 11, Opacity = 0.75, Margin = new Thickness(6, 2), TextWrapping = TextWrapping.Wrap };
    readonly List<GaugeControl> _gauges = [];
    readonly Func<IEnumerable<string>> _channels;
    readonly Func<TopLevel?> _top;
    GaugeControl? _selected;
    GaugeLayout _layout = new();
    readonly List<GaugeWindow> _windows = [];
    readonly ScrollViewer _scroll;

    public GaugePanel(Func<IEnumerable<string>> channels, Func<TopLevel?> top)
    {
        _channels = channels; _top = top;

        // one short line, so a narrow panel keeps its room for the gauges: the dashboard's files and the floating widgets in two drop-downs, the everyday edits as icons
        var bar = new WrapPanel { Margin = new Thickness(4, 2) };
        bar.Children.Add(Toolbar.Menu("Dashboard", Toolbar.Gauge, () =>
        [
            new Toolbar.Entry(Toolbar.Add, "New gauge", "Add a gauge to the dashboard.", () => AddGauge(null)),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Save, "Save…", "Save this dashboard - the gauges, where they sit, and any floating widget made from them - to a file you can come back to.", Save),
            new Toolbar.Entry(Toolbar.Open, "Load…", "Open a dashboard saved earlier, in place of this one.", Load),
            Toolbar.Entry.Submenu(Toolbar.Restore, "Recent", "Dashboards saved or opened lately.", RecentEntries),
            Toolbar.Entry.Submenu(Toolbar.Gauge, "Templates", "Replace the dashboard with a ready-made one.",
                () => [.. GaugeLayout.Templates.Select(t => new Toolbar.Entry(Toolbar.Gauge, t, $"Replace the dashboard with the {t} template.", () => UseTemplate(t)))]),
        ]));
        bar.Children.Add(Toolbar.Menu("Widgets", "▦", () =>
        [
            new Toolbar.Entry(Toolbar.Gauge, "Create widget",
                "Float this dashboard over everything else: one window holding every gauge on it, laid out as it is here. Drag it anywhere on screen, " +
                "resize it (the gauges scale with it), roll it up to its title bar, or close it.", PopOutAll),
            new Toolbar.Entry(Toolbar.Gauge, "Widget of the selected gauge", "Float only the selected gauge, in a window of its own.", PopOut),
            Toolbar.Entry.Line,
            new Toolbar.Entry("▽", "Hide", "Put the floating widgets out of the way without closing them - Unhide brings them back exactly where they were.", Hide),
            new Toolbar.Entry("△", "Unhide", "Bring the hidden widgets back.", Unhide),
            new Toolbar.Entry("⚓", "Parent to the main window",
                "The widgets sit over the main window only, move with it and minimize with it (again to let them go). Widgets created while this is on are parented too.",
                ToggleParent, Checked: () => _parented),
            new Toolbar.Entry("▦", "Arrange", "Line the widgets up next to each other in the free space on the main window, starting from its bottom-right corner.", Arrange),
        ]));
        bar.Children.Add(Toolbar.IconButton(Toolbar.Add, "New gauge on the dashboard.", () => AddGauge(null)));
        bar.Children.Add(Toolbar.IconButton("✎", "Edit the selected gauge: channel, range, warning level, kind.", () => { if (_selected != null) AddGauge(_selected); }));
        bar.Children.Add(Toolbar.IconButton(Toolbar.Delete, "Take the selected gauge off the dashboard (Delete key).", RemoveSelected));
        bar.Children.Add(Toolbar.IconButton("↶", "Undo the last change to the dashboard - adding, editing, removing, moving or resizing a gauge, a template or a load (Ctrl+Z).", Undo));
        bar.Children.Add(Toolbar.IconButton("↷", "Put back what Undo took away (Ctrl+Y).", Redo));

        // Delete and Ctrl+Z / Ctrl+Y work while the dashboard has the keyboard (click a gauge or the space around them)
        Focusable = true;
        _canvas.PointerPressed += (_, _) => { Select(null); Focus(); };
        KeyDown += (_, e) =>
        {
            bool ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
            if (e.Key == Key.Delete && _selected != null) { RemoveSelected(); e.Handled = true; }
            else if (ctrl && e.Key == Key.Z && !e.KeyModifiers.HasFlag(KeyModifiers.Shift)) { Undo(); e.Handled = true; }
            else if (ctrl && (e.Key == Key.Y || (e.Key == Key.Z && e.KeyModifiers.HasFlag(KeyModifiers.Shift)))) { Redo(); e.Handled = true; }
        };

        _hint.Text = "No gauges yet: New adds one, or start from a template. Drag a gauge to move it, drag its bottom-right corner to resize.";
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(_hint, Dock.Bottom);
        dock.Children.Add(bar);
        dock.Children.Add(_hint);
        _scroll = new ScrollViewer
        {
            Content = _canvas,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        };
        dock.Children.Add(_scroll);
        Content = dock;
    }

    // ------------------------------------------------------------------ frames

    /// Readings from outside the ECU (Settings > Emulator & datalog), merged into every frame the gauges see so an external channel reads exactly like a logged one.
    public ExternalData? External { get; set; }

    /// Feed every gauge (on the dashboard and in its own window) the newest reading. A replay's frames from the last one fed (exclusive) to `now` (inclusive): every gauge's history gets all of them, so a fast replay or a jump along the slider draws the same line a slow replay does.
    public void Feed(IReadOnlyList<LogFrame> log, int lastFed, int now)
    {
        if (now < 0 || now >= log.Count) { Show(null); return; }
        int from = lastFed + 1;
        if (lastFed < 0 || now < lastFed || now - lastFed > 20000)
        {
            // a fresh start (or a jump back): the history is rebuilt from the seconds before this frame
            ClearHistory();
            double seconds = _gauges.Concat(_windows.SelectMany(w => w.Gauges)).Select(g => g.Spec.Seconds).DefaultIfEmpty(20).Max();
            from = now;
            while (from > 0 && log[from - 1].T >= log[now].T - seconds && now - from < 20000) from--;
        }
        for (int i = from; i < now; i++)
        {
            foreach (var g in _gauges) g.Add(log[i]);
            foreach (var w in _windows) foreach (var g in w.Gauges) g.Add(log[i]);
        }
        Show(log[now]);
    }

    public void Show(LogFrame? f)
    {
        f = WithExternal(f);
        foreach (var g in _gauges) g.Show(f);
        foreach (var w in _windows.ToList()) { if (w.IsGone) _windows.Remove(w); else w.Show(f); }
    }

    LogFrame? WithExternal(LogFrame? f)
    {
        var ext = External?.Values;
        if (ext == null || ext.Count == 0) return f;
        // a frame of its own when nothing is logging, so external gauges still read
        var frame = f ?? new LogFrame { T = (DateTime.UtcNow - _started).TotalSeconds };
        foreach (var (k, v) in ext) frame.Extra[k] = v;
        return frame;
    }

    readonly DateTime _started = DateTime.UtcNow;

    public void ClearHistory()
    {
        foreach (var g in _gauges) g.Clear();
        foreach (var w in _windows) w.ClearHistory();
    }

    // ------------------------------------------------------------------ layout

    public GaugeLayout Layout
    {
        get
        {
            _layout.Gauges = [.. _gauges.Select(g => g.Spec)];
            var origin = _top() is Window owner ? owner.PointToScreen(new Point(0, 0)) : (PixelPoint?)null;
            _layout.Widgets = [.. _windows.Where(w => !w.IsGone).Select(w => w.AsWidget(origin))];
            return _layout;
        }
    }

    public void Apply(GaugeLayout layout)
    {
        _layout = layout;
        _canvas.Children.Clear();
        _gauges.Clear();
        _selected = null;
        foreach (var spec in layout.Gauges) Place(spec);
        Select(null);
        RestoreWidgets(layout.Widgets);
        UpdateHint();
    }

    void UseTemplate(string name)
    {
        Remember();
        var t = GaugeLayout.Template(name);
        t.Widgets = [];
        Apply(t);
        AppLog.Action("gauges", "template " + name);
    }

    // ------------------------------------------------------------------ undo

    readonly Stack<string> _undo = new(), _redo = new();

    /// Remember the dashboard as it is now, before something changes it.
    void Remember()
    {
        _undo.Push(new GaugeLayout { Name = _layout.Name, Gauges = [.. _gauges.Select(g => g.Spec.Clone())] }.ToJson());
        if (_undo.Count > 100) { var keep = _undo.Take(100).Reverse().ToList(); _undo.Clear(); foreach (var k in keep) _undo.Push(k); }
        _redo.Clear();
    }

    string Now() => new GaugeLayout { Name = _layout.Name, Gauges = [.. _gauges.Select(g => g.Spec.Clone())] }.ToJson();

    void Undo()
    {
        if (_undo.Count == 0) { _hint.Text = "nothing to undo"; return; }
        _redo.Push(Now());
        Restore(_undo.Pop());
        _hint.Text = $"undone ({_undo.Count} more)";
    }

    void Redo()
    {
        if (_redo.Count == 0) { _hint.Text = "nothing to redo"; return; }
        _undo.Push(Now());
        Restore(_redo.Pop());
        _hint.Text = "redone";
    }

    /// Put a remembered dashboard back (the floating widgets are left as they are).
    void Restore(string json)
    {
        var l = GaugeLayout.FromJson(json);
        _canvas.Children.Clear();
        _gauges.Clear();
        _selected = null;
        foreach (var spec in l.Gauges) Place(spec);
        Select(null);
        UpdateCanvasSize();
        UpdateHint();
    }

    void Place(GaugeSpec spec)
    {
        var g = new GaugeControl(spec);
        Canvas.SetLeft(g, spec.X); Canvas.SetTop(g, spec.Y);
        g.PointerPressed += (_, e) => BeginDrag(g, e);
        g.PointerMoved += (_, e) => Drag(g, e);
        g.PointerReleased += (_, e) => EndDrag(g, e);
        g.DoubleTapped += (_, _) => AddGauge(g);
        _canvas.Children.Add(g);
        _gauges.Add(g);
        Select(g);
        UpdateCanvasSize();
    }

    void UpdateCanvasSize()
    {
        _canvas.Width = Math.Max(200, _gauges.Count == 0 ? 200 : _gauges.Max(g => g.Spec.X + g.Spec.Width) + 12);
        _canvas.Height = Math.Max(140, _gauges.Count == 0 ? 140 : _gauges.Max(g => g.Spec.Y + g.Spec.Height) + 12);
    }

    void Select(GaugeControl? g)
    {
        _selected = g;
        foreach (var other in _gauges)
            other.Opacity = g == null || other == g ? 1 : 0.82;
        UpdateHint();
    }

    void UpdateHint() =>
        _hint.Text = _gauges.Count == 0
            ? "No gauges yet: New adds one, or start from a template. Drag a gauge to move it, drag its bottom-right corner to resize."
            : $"{_gauges.Count} gauge(s){(_selected != null ? $", {_selected.Spec.Title} selected (double-click to edit)" : "")}. " +
              "Drag to move, bottom-right corner to resize, Create widget floats one over everything else.";

    // ------------------------------------------------------------------ drag / resize

    Point _grab;
    bool _resizing;

    string? _beforeDrag;

    void BeginDrag(GaugeControl g, PointerPressedEventArgs e)
    {
        Select(g);
        Focus();
        _beforeDrag = Now();
        _grab = e.GetPosition(g);
        _resizing = _grab.X > g.Bounds.Width - 14 && _grab.Y > g.Bounds.Height - 14;
        e.Pointer.Capture(g);
        e.Handled = true;
    }

    void Drag(GaugeControl g, PointerEventArgs e)
    {
        if (!Equals(e.Pointer.Captured, g)) return;
        var p = e.GetPosition(_canvas);
        // kept inside the part of the dashboard that is on screen, so a gauge can't be lost off its edge
        var view = _scroll.Viewport;
        double right = _scroll.Offset.X + (view.Width > 0 ? view.Width : 400), bottom = _scroll.Offset.Y + (view.Height > 0 ? view.Height : 300);
        if (_resizing)
        {
            g.Spec.Width = g.Width = Math.Max(70, Math.Min(p.X, right) - g.Spec.X);
            g.Spec.Height = g.Height = Math.Max(50, Math.Min(p.Y, bottom) - g.Spec.Y);
        }
        else
        {
            g.Spec.X = Math.Clamp(p.X - _grab.X, 0, Math.Max(0, right - Math.Min(g.Spec.Width, right)));
            g.Spec.Y = Math.Clamp(p.Y - _grab.Y, 0, Math.Max(0, bottom - Math.Min(g.Spec.Height, bottom)));
            Canvas.SetLeft(g, g.Spec.X); Canvas.SetTop(g, g.Spec.Y);
        }
        g.InvalidateVisual();
    }

    void EndDrag(GaugeControl g, PointerReleasedEventArgs e)
    {
        e.Pointer.Capture(null);
        _resizing = false;
        UpdateCanvasSize();
        // a move or a resize is one step to undo; a click that moved nothing is not
        if (_beforeDrag != null && _beforeDrag != Now())
        {
            _undo.Push(_beforeDrag);
            _redo.Clear();
        }
        _beforeDrag = null;
    }

    // ------------------------------------------------------------------ actions

    async void AddGauge(GaugeControl? edit)
    {
        if (_top() is not Window owner) return;
        var spec = edit?.Spec.Clone() ?? new GaugeSpec { Channel = _channels().FirstOrDefault() ?? "rpm" };
        var dlg = new GaugeEditor(spec, _channels(), isEdit: edit != null);
        await Dialogs.ShowModal(dlg, owner);
        if (dlg.Result == null) return;
        Remember();
        if (edit != null)
        {
            _canvas.Children.Remove(edit);
            _gauges.Remove(edit);
        }
        Place(dlg.Result);
        AppLog.Action("gauges", $"{(edit == null ? "added" : "edited")} {dlg.Result.Kind} gauge for {dlg.Result.Channel}");
    }

    /// Gauges for logged values (the datalog's values list, right-click): one each, laid out under the gauges already on the dashboard - or floated together in a widget of their own. No kind given: a lamp for an on / off value, a dial for the rpm, a bar for the rest.
    public void AddFor(IReadOnlyList<(string Channel, double Value)> values, GaugeKind? kind, bool widget)
    {
        if (values.Count == 0) return;
        var specs = values.Select(v => SpecFor(v.Channel, v.Value, kind ?? AutoKind(v.Channel))).ToList();
        // a flow of rows across the dashboard's width, under what is on it
        double width = Math.Max(240, Bounds.Width > 0 ? Bounds.Width - 16 : 600);
        double x = 0, y = widget || _gauges.Count == 0 ? 0 : _gauges.Max(g => g.Spec.Y + g.Spec.Height) + 8, rowH = 0;
        foreach (var sp in specs)
        {
            if (x > 0 && x + sp.Width > width) { x = 0; y += rowH + 8; rowH = 0; }
            sp.X = x; sp.Y = y;
            x += sp.Width + 8; rowH = Math.Max(rowH, sp.Height);
        }
        if (widget)
        {
            Open(Widget(specs));
            _hint.Text = $"{specs.Count} gauge(s) floating in a window of their own";
        }
        else
        {
            Remember();
            foreach (var sp in specs) Place(sp);
            _hint.Text = $"{specs.Count} gauge(s) added: drag to move, double-click to change one";
        }
        AppLog.Action("gauges", $"{(widget ? "floated" : "added")} {specs.Count} gauge(s) for {string.Join(", ", specs.Select(sp => sp.Channel))}");
    }

    /// How many gauges are on the dashboard.
    public int Count => _gauges.Count;

    /// On / off values (flags, cuts, limiters, switches): a lamp suits them.
    public static bool IsOnOff(string ch) =>
        ch is "vtec" or "fuel_pump" or "fuel_cut" or "overrun_cut" or "rev_limit" or "mil" or "ac" or "fan" || ch.StartsWith("limit_", StringComparison.Ordinal)
        || ch.EndsWith("_on", StringComparison.Ordinal) || ch.EndsWith("_sw", StringComparison.Ordinal) || ch.EndsWith("_active", StringComparison.Ordinal);

    static GaugeKind AutoKind(string ch) => IsOnOff(ch) ? GaugeKind.Light : ch == "rpm" ? GaugeKind.Dial : GaugeKind.Bar;

    /// A gauge of this kind for a channel: the range of the ones known, else one round the value it shows now.
    static GaugeSpec SpecFor(string ch, double value, GaugeKind kind)
    {
        var (min, max, warn, below, dec) = ch switch
        {
            "rpm" => (0.0, 9000.0, (double?)7500, false, 0),
            "map_kpa" or "baro_kpa" => (0, 250, null, false, 0),
            "tps_pct" => (0, 100, null, false, 0),
            "ect_c" => (-20, 130, 105, false, 0),
            "iat_c" => (-20, 90, 60, false, 0),
            "speed_kmh" => (0, 260, null, false, 0),
            "batt_v" => (8, 16, 11.5, true, 1),
            "o2_v" => (0, 1.1, null, false, 2),
            "afr" or "wideband_afr" => (10, 20, null, false, 1),
            "ign_deg" or "ign_table_deg" => (-10, 50, null, false, 1),
            "inj_ms" => (0, 25, null, false, 2),
            _ when IsOnOff(ch) => (0, 1, 0.5, false, 0),
            _ => Around(value),
        };
        var sp = new GaugeSpec
        {
            Kind = kind, Channel = ch, Unit = LogFrame.UnitOf(ch), Min = min, Max = max, Warn = warn, WarnBelow = below, Decimals = dec,
        };
        // a lamp lights past its warning level: half way, for a value that is not on / off
        if (kind == GaugeKind.Light && sp.Warn == null) sp.Warn = (min + max) / 2;
        (sp.Width, sp.Height) = kind switch
        {
            GaugeKind.Dial or GaugeKind.Arc => (180, 160),
            GaugeKind.Bar => (240, 70),
            GaugeKind.Number => (170, 80),
            GaugeKind.Light => (120, 90),
            GaugeKind.Graph or GaugeKind.BarGraph => (320, 140),
            GaugeKind.ShiftLights => (260, 70),
            _ => (180, 140),
        };
        return sp;
    }

    /// A range for a value nothing is known about: from 0 (or a round number below it) to a round number well above it.
    static (double, double, double?, bool, int) Around(double v)
    {
        if (double.IsNaN(v) || v == 0) return (0, 255, null, false, 0);
        double mag = Math.Pow(10, Math.Floor(Math.Log10(Math.Abs(v))));
        double hi = Math.Ceiling(Math.Abs(v) * 2 / mag) * mag;
        int dec = Math.Abs(v) < 10 ? 2 : Math.Abs(v) < 100 ? 1 : 0;
        return v < 0 ? (-hi, hi, null, false, dec) : (0, hi, null, false, dec);
    }

    void RemoveSelected()
    {
        if (_selected == null) return;
        Remember();
        _canvas.Children.Remove(_selected);
        _gauges.Remove(_selected);
        Select(_gauges.LastOrDefault());
        UpdateCanvasSize();
    }

    /// Create widget floats the whole dashboard: ONE window holding every gauge that is on it, in the same arrangement. A panel with a dial, a bar and a graph on it becomes a single window with all three, not three windows to place and close one at a time.
    void PopOutAll()
    {
        if (_gauges.Count == 0) { _hint.Text = "there are no gauges to float: New adds one, or start from a template"; return; }
        var specs = _gauges.Select(g => g.Spec.Clone()).ToList();
        Open(Widget(specs));
        _hint.Text = $"{specs.Count} gauge(s) floating in one window - drag its title bar to move it, the corner to resize, \u2715 to close";
        AppLog.Action("gauges", $"floated the dashboard ({specs.Count} gauges) as one widget");
    }

    void PopOut()
    {
        if (_selected == null) { _hint.Text = "select a gauge first (click it), then Widget (selected) floats just that one"; return; }
        Open(Widget([_selected.Spec.Clone()]));
        AppLog.Action("gauges", "floated " + _selected.Spec.Title);
    }

    /// A widget sized to the gauges going into it, packed to the top-left corner of its window.
    static GaugeWidget Widget(List<GaugeSpec> specs)
    {
        double w = specs.Count == 0 ? 200 : specs.Max(g => g.X + g.Width) - specs.Min(g => g.X);
        double h = specs.Count == 0 ? 140 : specs.Max(g => g.Y + g.Height) - specs.Min(g => g.Y);
        return new GaugeWidget
        {
            Gauges = specs,
            Width = Math.Max(160, w + 12), Height = Math.Max(110, h + 12) + 24,
            X = double.NaN, Y = double.NaN,
        };
    }

    void Open(GaugeWidget widget)
    {
        if (_top() is not Window owner) return;
        Hook(owner);
        // a new widget follows the Parent button; one read back from a file keeps what it was saved as
        if (double.IsNaN(widget.X)) widget.Parented = _parented;
        var w = new GaugeWindow(widget) { Home = owner };
        if (widget.Parented && !double.IsNaN(widget.X) && !double.IsNaN(widget.Y))
        {
            var o = owner.PointToScreen(new Point(0, 0));
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Position = new PixelPoint(o.X + (int)widget.X, o.Y + (int)widget.Y);
        }
        _windows.Add(w);
        w.Show(owner);
        if (widget.Hidden) w.SetHidden(true);
        if (widget.Parented && owner.WindowState == WindowState.Minimized) w.SetParked(true);
    }

    // ------------------------------------------------------------------ parent / arrange

    bool _parented;
    Window? _owner;
    PixelPoint _ownerPos;

    IEnumerable<GaugeWindow> ParentedWindows() => _windows.Where(w => !w.IsGone && w.Parented);

    /// Follow the main window: parented widgets move with it and go away while it is minimized.
    void Hook(Window owner)
    {
        if (ReferenceEquals(_owner, owner)) return;
        _owner = owner;
        _ownerPos = owner.Position;
        owner.PositionChanged += (_, e) =>
        {
            // Windows parks a minimized window at about -32000, -32000: the jump there and back is not a move, and carrying it over threw every parented widget off the screen when the window came back
            static bool Parked(PixelPoint p) => p.X <= -10000 || p.Y <= -10000;
            var was = _ownerPos;
            _ownerPos = e.Point;
            if (Parked(was) || Parked(e.Point) || owner.WindowState == WindowState.Minimized || _restoring) return;
            int dx = e.Point.X - was.X, dy = e.Point.Y - was.Y;
            if (dx == 0 && dy == 0) return;
            foreach (var w in ParentedWindows())
                if (w.WindowState == WindowState.Normal) w.Position = new PixelPoint(w.Position.X + dx, w.Position.Y + dy);
        };
        owner.PropertyChanged += (_, e) =>
        {
            if (e.Property != Window.WindowStateProperty) return;
            bool min = owner.WindowState == WindowState.Minimized;
            var before = (WindowState?)e.OldValue;
            if (!min)
            {
                _ownerPos = owner.Position;
                // coming back from minimized (to normal or maximized): the window settles over the next moment, and its position changes then are its own, not a drag to follow
                if (before == WindowState.Minimized)
                {
                    _restoring = true;
                    DispatcherTimer.RunOnce(() => { _restoring = false; _ownerPos = owner.Position; KeepOnScreen(owner); }, TimeSpan.FromMilliseconds(400));
                }
            }
            foreach (var w in ParentedWindows()) w.SetParked(min);
        };
    }

    bool _restoring;

    /// A widget that has ended up off every screen comes back onto the main window.
    void KeepOnScreen(Window owner)
    {
        if (owner.WindowState == WindowState.Minimized) return;
        var screens = owner.Screens.All;
        if (screens.Count == 0) return;
        var tl = owner.PointToScreen(new Point(0, 0));
        int n = 0;
        foreach (var w in _windows.Where(w => !w.IsGone && !w.Hidden))
        {
            var r = new PixelRect(w.Position, w.PixelSize);
            if (screens.Any(sc => sc.WorkingArea.Intersects(r) && sc.WorkingArea.Intersect(r).Width >= 40 && sc.WorkingArea.Intersect(r).Height >= 20)) continue;
            w.Position = new PixelPoint(tl.X + 60 + (n * 30), tl.Y + 90 + (n * 30));
            n++;
        }
        if (n > 0) AppLog.Info("gauges", $"{n} widget(s) were off the screen: put back on the main window");
    }

    /// Parent every widget to the main window, or let them all go again.
    void ToggleParent()
    {
        var live = _windows.Where(w => !w.IsGone).ToList();
        _parented = live.Count > 0 ? live.Any(w => !w.Parented) : !_parented;
        foreach (var w in live) w.SetParented(_parented);
        _hint.Text = _parented
            ? $"{live.Count} widget(s) parented to the main window - they move and minimize with it (Parent again lets them go)"
            : $"{live.Count} widget(s) floating free again";
        AppLog.Action("gauges", (_parented ? "parented " : "unparented ") + live.Count + " widget(s)");
    }

    /// Put the widgets side by side on the main window, in rows filling from its bottom-right corner leftwards and then upwards, the tallest first, so they sit together in one block out of the way of the menus.
    void Arrange()
    {
        if (_top() is not Window owner) return;
        var live = _windows.Where(w => !w.IsGone && !w.Hidden).OrderByDescending(w => w.PixelSize.Height).ToList();
        if (live.Count == 0) { _hint.Text = "there are no widgets on screen to arrange"; return; }
        if (owner.WindowState == WindowState.Minimized) return;
        double s = owner.RenderScaling;
        var tl = owner.PointToScreen(new Point(0, 0));
        var br = owner.PointToScreen(new Point(owner.ClientSize.Width, owner.ClientSize.Height));
        int gap = (int)(6 * s);
        // clear of the status line along the bottom of the main window
        int right = br.X - gap, bottom = br.Y - (int)(26 * s), top = tl.Y + (int)(60 * s);
        int x = right, y = bottom, rowH = 0, placed = 0;
        foreach (var w in live)
        {
            if (w.WindowState != WindowState.Normal) w.WindowState = WindowState.Normal;
            var size = w.PixelSize;
            // the row is full: start another above it
            if (x != right && x - size.Width < tl.X + gap) { y -= rowH + gap; x = right; rowH = 0; }
            w.Position = new PixelPoint(Math.Max(tl.X + gap, x - size.Width), Math.Max(top, y - size.Height));
            x -= size.Width + gap;
            rowH = Math.Max(rowH, size.Height);
            placed++;
        }
        _hint.Text = $"{placed} widget(s) arranged on the main window" + (_parented ? "" : " - Parent keeps them there when it moves");
        AppLog.Action("gauges", $"arranged {placed} widget(s)");
    }

    /// Put the floating widgets away without losing them: the layout, the positions and the sizes are all still there, and Unhide brings them straight back.
    void Hide()
    {
        var live = _windows.Where(w => !w.IsGone && !w.Hidden).ToList();
        if (live.Count == 0) { _hint.Text = _windows.Any(w => !w.IsGone) ? "the widgets are already hidden - press Unhide" : "there is nothing floating to hide"; return; }
        foreach (var w in live) w.SetHidden(true);
        _hint.Text = $"{live.Count} widget(s) hidden - Unhide brings them back where they were";
        AppLog.Action("gauges", $"hid {live.Count} widget(s)");
    }

    void Unhide()
    {
        var hidden = _windows.Where(w => !w.IsGone && w.Hidden).ToList();
        if (hidden.Count == 0) { _hint.Text = "no widget is hidden"; return; }
        foreach (var w in hidden) w.SetHidden(false);
        _hint.Text = $"{hidden.Count} widget(s) back on screen";
        AppLog.Action("gauges", $"unhid {hidden.Count} widget(s)");
    }

    /// Put back the widgets that were on screen last time (hidden ones stay hidden until Unhide). They are opened once the owner window exists, so this is safe to call while the page is still being built.
    void RestoreWidgets(List<GaugeWidget> widgets)
    {
        if (widgets.Count == 0) return;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            foreach (var widget in widgets.Take(24))
                if (widget.Specs().Count > 0) Open(widget);
            _parented = _windows.Any(w => !w.IsGone && w.Parented);
        }, Avalonia.Threading.DispatcherPriority.Background);
    }

    async void Save()
    {
        if (_top() is not TopLevel top) return;
        Directory.CreateDirectory(Dir);
        var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save the dashboard",
            SuggestedFileName = (_layout.Name.Length > 0 ? _layout.Name : "dashboard") + ".gauges.json",
            DefaultExtension = "json",
            FileTypeChoices = new[] { new FilePickerFileType("Gauge dashboard") { Patterns = new[] { "*.gauges.json", "*.json" } } },
            SuggestedStartLocation = await top.StorageProvider.TryGetFolderFromPathAsync(Dir),
        });
        var path = file?.TryGetLocalPath();
        if (path == null) return;
        SaveTo(path);
    }

    void SaveTo(string path)
    {
        try
        {
            _layout.Name = Path.GetFileNameWithoutExtension(path).Replace(".gauges", "");
            Layout.Save(path);
            Remember(path);
            _hint.Text = $"dashboard saved to {path} ({_gauges.Count} gauge(s)" +
                         (_windows.Count(w => !w.IsGone) > 0 ? $", {_windows.Count(w => !w.IsGone)} floating" : "") + ")";
            AppLog.Action("gauges", "saved the dashboard to " + path);
        }
        catch (Exception ex) { _hint.Text = "could not save: " + ex.Message; AppLog.Error("gauges", "save failed", ex); }
    }

    async void Load()
    {
        if (_top() is not TopLevel top) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Open a dashboard",
            AllowMultiple = false,
            FileTypeFilter = new[] { new FilePickerFileType("Gauge dashboard") { Patterns = new[] { "*.gauges.json", "*.json" } } },
            SuggestedStartLocation = await top.StorageProvider.TryGetFolderFromPathAsync(Dir),
        });
        var path = files.FirstOrDefault()?.TryGetLocalPath();
        if (path != null) LoadFrom(path);
    }

    /// Open a dashboard file: the gauges come back on the panel and any widget that was floating when it was saved opens again where it was.
    public void LoadFrom(string path)
    {
        try
        {
            Remember();
            CloseWidgets();
            Apply(GaugeLayout.Load(path));
            Remember(path);
            _hint.Text = $"{Path.GetFileName(path)}: {_gauges.Count} gauge(s)" +
                         (_layout.Widgets.Count > 0 ? $", {_layout.Widgets.Count} floating widget(s)" : "");
            AppLog.Action("gauges", "opened the dashboard " + path);
        }
        catch (Exception ex) { _hint.Text = "could not open: " + ex.Message; AppLog.Error("gauges", "load failed", ex); }
    }

    // ------------------------------------------------------------------ recent

    /// Dashboards saved or opened lately, newest first. Kept beside the dashboards themselves so the list survives a new settings file.
    static string RecentPath => Path.Combine(Dir, "recent.txt");

    static List<string> Recent()
    {
        try { return File.Exists(RecentPath) ? [.. File.ReadAllLines(RecentPath).Where(l => l.Trim().Length > 0)] : []; }
        catch { return []; }
    }

    static void Remember(string path)
    {
        try
        {
            var list = Recent();
            list.RemoveAll(p => p.Equals(path, StringComparison.OrdinalIgnoreCase));
            list.Insert(0, path);
            Directory.CreateDirectory(Dir);
            SafeFile.WriteAllLines(RecentPath, list.Take(12));
        }
        catch (Exception ex) { AppLog.Error("gauges", "could not keep the recent list", ex); }
    }

    Toolbar.Entry[] RecentEntries()
    {
        var list = Recent().Where(File.Exists).ToList();
        if (list.Count == 0) return [new Toolbar.Entry("", "(none yet)", "Save a dashboard and it appears here.", () => { })];
        return
        [
            .. list.Select(path => new Toolbar.Entry(Toolbar.Gauge, Path.GetFileName(path).Replace(".gauges.json", "").Replace(".json", ""),
                                                     path, () => LoadFrom(path))),
            Toolbar.Entry.Line,
            new Toolbar.Entry(Toolbar.Clear, "Forget the list", "Empty this menu (the files themselves are left alone).", () =>
            {
                try { File.Delete(RecentPath); } catch { }
                _hint.Text = "the recent list is empty";
            }),
        ];
    }

    // ------------------------------------------------------------------ profiles

    /// Which dashboard this is: Tuner mode and the simulator keep their own, because they are used for different things (a tuner wants AFR and knock in front of him; the simulator wants what the ROM is driving). Each is kept in its own file, gauges, widgets and all.
    public string Profile { get; private set; } = "simulator";

    /// The dashboard left on screen last time for a mode, so it comes back with the program.
    static string PathFor(string profile) => Path.Combine(Dir, $"last-{profile}.gauges.json");

    /// The single dashboard earlier builds kept, used once to start both modes off.
    static string LegacyPath => Path.Combine(Dir, "last.gauges.json");

    /// Switch to another mode's dashboard: this one (and where its widgets sit) is written out first, then the other is put back exactly as it was left.
    public void UseProfile(string profile)
    {
        if (profile == Profile && _loaded) return;
        if (_loaded) SaveLast();
        CloseWidgets();
        Profile = profile;
        _loaded = true;
        try
        {
            var path = PathFor(profile);
            if (!File.Exists(path) && File.Exists(LegacyPath)) path = LegacyPath;
            if (File.Exists(path))
            {
                var layout = GaugeLayout.Load(path);
                layout.Name = profile;
                Apply(layout);
            }
            else Apply(GaugeLayout.Template(profile.Equals("simulator", StringComparison.OrdinalIgnoreCase) ? "Simulator" : "Wideband tuning"));
        }
        catch (Exception ex)
        {
            AppLog.Error("gauges", "could not read the " + profile + " dashboard", ex);
            Apply(new GaugeLayout { Name = profile });
        }
        _hint.Text = $"{Profile} gauges: {_gauges.Count} on the dashboard" +
                     (_windows.Count(w => !w.IsGone) > 0 ? $", {_windows.Count(w => !w.IsGone)} floating" : "");
    }
    bool _loaded;

    public void LoadLast() => UseProfile(Profile);

    public void SaveLast()
    {
        if (UiCheck.Active) return;
        try
        {
            var path = PathFor(Profile);
            if (_gauges.Count == 0 && _windows.Count == 0 && !File.Exists(path)) return;
            Directory.CreateDirectory(Dir);
            Layout.Save(path);
        }
        catch (Exception ex) { AppLog.Error("gauges", "could not keep the dashboard", ex); }
    }

    public void CloseWidgets()
    {
        foreach (var w in _windows.ToList()) w.Close();
        _windows.Clear();
    }
}


/// A floating dashboard: one frameless window holding the whole collection of gauges that was on the panel, in the same arrangement. It sits over everything else, can be dragged anywhere on screen, resized (the gauges scale with the window, so the collection keeps its shape), rolled up to its title bar, hidden out of the way, or closed.
public sealed class GaugeWindow : Window
{
    readonly List<GaugeControl> _gauges = [];
    readonly Canvas _canvas = new();
    readonly LayoutTransformControl _scaler = new();
    readonly Panel _host = new() { ClipToBounds = true };
    double _contentW, _contentH;
    /// True once this widget has been closed, so the panel can let go of it.
    public bool IsGone { get; private set; }
    /// Put away by Hide (the window still exists, with everything in it).
    public bool Hidden { get; private set; }
    double _fullHeight;
    readonly bool _topmostWanted;

    /// Every gauge in the window, for feeding readings and for writing the layout back out.
    public IReadOnlyList<GaugeControl> Gauges => _gauges;

    public GaugeWindow(GaugeWidget widget)
    {
        var specs = widget.Specs();
        if (specs.Count == 0) specs = [new GaugeSpec()];
        // pack the collection into the corner of the window, keeping the gaps between the gauges
        double x0 = specs.Min(g => g.X), y0 = specs.Min(g => g.Y);
        _contentW = Math.Max(60, specs.Max(g => g.X + g.Width) - x0);
        _contentH = Math.Max(40, specs.Max(g => g.Y + g.Height) - y0);
        foreach (var spec in specs)
        {
            var g = new GaugeControl(spec) { Width = spec.Width, Height = spec.Height };
            Canvas.SetLeft(g, spec.X - x0);
            Canvas.SetTop(g, spec.Y - y0);
            _canvas.Children.Add(g);
            _gauges.Add(g);
            HookGauge(g);
        }
        _canvas.Width = _contentW; _canvas.Height = _contentH;

        Title = widget.Title;
        Width = Math.Max(120, widget.Width); Height = Math.Max(80, widget.Height);
        _fullHeight = Height;
        MinWidth = 110; MinHeight = 58;
        _topmostWanted = widget.Topmost;
        Parented = widget.Parented;
        Topmost = widget.Topmost && !widget.Parented;
        ShowInTaskbar = false;
        // no frame at all: a border-only window still shows a pale strip along the top on Windows, which looked like a scratch across the widget
        SystemDecorations = SystemDecorations.None;
        Background = AppTheme.Brush(DarkChrome.Background);
        Icon = DarkChrome.LoadWindowIcon();
        if (!double.IsNaN(widget.X) && !double.IsNaN(widget.Y))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = new PixelPoint((int)widget.X, (int)widget.Y);
        }

        var title = new TextBlock
        {
            Text = specs.Count > 1 ? $"{specs.Count} gauges" : specs[0].Title,
            FontSize = 11, Margin = new Thickness(8, 0), VerticalAlignment = VerticalAlignment.Center,
        };
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Height = 24, Background = AppTheme.Brush(DarkChrome.Panel) };
        var drag = new Border { Background = Brushes.Transparent, Child = title };
        drag.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
            BeginMoveDrag(e);
            // on Windows the drag has finished by now: pull the widget back if it was left off the screen
            KeepOnScreen();
        };
        drag.DoubleTapped += (_, _) => RollUp();
        ToolTip.SetTip(drag, specs.Count > 1
            ? string.Join(", ", specs.Select(g => g.Title)) + "\nDrag to move the whole set; double-click to roll it up."
            : "Drag to move; double-click to roll it up.");
        Grid.SetColumn(drag, 0); bar.Children.Add(drag);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Small("\U0001F4CC", "Keep the widget above other windows, or let it go behind them (a widget parented to the main window only sits over the main window).",
            () => { if (!Parented) Topmost = !Topmost; }));
        buttons.Children.Add(Small("_", "Roll the widget up to its title bar (again to restore it).", RollUp));
        buttons.Children.Add(Small("□", "Make the widget as big as the screen, or put it back.",
            () => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized));
        buttons.Children.Add(Small("✕", "Close this widget.", Close));
        Grid.SetColumn(buttons, 1); bar.Children.Add(buttons);

        // a grip in the corner, since a window with no frame has no edges to pull
        var grip = new Border
        {
            Width = 14, Height = 14, Background = Brushes.Transparent, Cursor = new Cursor(StandardCursorType.BottomRightCorner),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Child = new TextBlock { Text = "◢", FontSize = 10, Opacity = 0.5 },
        };
        grip.PointerPressed += (_, e) => { BeginResizeDrag(WindowEdge.SouthEast, e); KeepOnScreen(); };
        ToolTip.SetTip(grip, "Drag to resize the widget; the gauges scale with it. Each gauge also moves (drag it) and resizes (drag its own bottom-right corner) on its own.");

        _scaler.Child = _canvas;
        var g2 = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g2.Children.Add(bar);
        var host = _host;
        host.Children.Add(_scaler);
        Grid.SetRow(host, 1); g2.Children.Add(host);
        var overlay = new Panel();
        overlay.Children.Add(g2);
        overlay.Children.Add(grip);
        Content = overlay;
        // the gauges fill whatever room the window has, keeping their proportions
        host.SizeChanged += (_, e) => Rescale(e.NewSize);
        Closing += (_, _) => IsGone = true;
        Opened += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(KeepOnScreen, Avalonia.Threading.DispatcherPriority.Background);
    }

    /// Pull the widget back onto the screen it is mostly on (or the main screen when it is on none), whole if it fits - one saved on a monitor that is no longer plugged in comes back into view.
    public void KeepOnScreen()
    {
        if (IsGone || Hidden || WindowState != WindowState.Normal) return;
        var scr = Screens.ScreenFromWindow(this) ?? Screens.ScreenFromPoint(Position) ?? Screens.Primary;
        if (scr == null) return;
        var wa = scr.WorkingArea;
        var size = PixelSize;
        int x = Math.Clamp(Position.X, wa.X, Math.Max(wa.X, wa.Right - size.Width));
        int y = Math.Clamp(Position.Y, wa.Y, Math.Max(wa.Y, wa.Bottom - size.Height));
        if (x != Position.X || y != Position.Y) Position = new PixelPoint(x, y);
    }

    // ------------------------------------------------------------------ moving and resizing a gauge inside the widget

    static readonly Cursor CornerCursor = new(StandardCursorType.BottomRightCorner), MoveCursor = new(StandardCursorType.SizeAll);
    GaugeControl? _editing;
    bool _editResize;
    Point _editGrab;

    static bool InCorner(GaugeControl g, Point at) => at.X > g.Bounds.Width - 16 && at.Y > g.Bounds.Height - 16;

    void HookGauge(GaugeControl g)
    {
        ToolTip.SetTip(g, "Drag to move this gauge inside the widget; drag its bottom-right corner to resize just this one.");
        g.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(g).Properties.IsLeftButtonPressed) return;
            var at = e.GetPosition(g);
            _editing = g; _editResize = InCorner(g, at); _editGrab = at;
            e.Pointer.Capture(g);
            e.Handled = true;
        };
        g.PointerMoved += (_, e) =>
        {
            if (_editing != g || !Equals(e.Pointer.Captured, g))
            {
                var want = InCorner(g, e.GetPosition(g)) ? CornerCursor : MoveCursor;
                if (!ReferenceEquals(g.Cursor, want)) g.Cursor = want;
                return;
            }
            var p = e.GetPosition(_canvas);
            double left = Canvas.GetLeft(g), top = Canvas.GetTop(g);
            if (_editResize)
            {
                g.Width = g.Spec.Width = Math.Max(50, p.X - left);
                g.Height = g.Spec.Height = Math.Max(36, p.Y - top);
            }
            else
            {
                Canvas.SetLeft(g, Math.Max(0, p.X - _editGrab.X));
                Canvas.SetTop(g, Math.Max(0, p.Y - _editGrab.Y));
            }
            _canvas.Width = Math.Max(_canvas.Width, Canvas.GetLeft(g) + g.Width);
            _canvas.Height = Math.Max(_canvas.Height, Canvas.GetTop(g) + g.Height);
            g.InvalidateVisual();
        };
        g.PointerReleased += (_, e) =>
        {
            if (_editing != g) return;
            e.Pointer.Capture(null);
            _editing = null;
            Refit();
        };
    }

    /// After a gauge moved or changed size: pack the set back into the corner and grow or shrink the window so everything keeps the scale it had (the other gauges do not jump in size).
    void Refit()
    {
        if (_gauges.Count == 0) return;
        double k = (_scaler.LayoutTransform as ScaleTransform)?.ScaleX ?? 1;
        double minX = _gauges.Min(Canvas.GetLeft), minY = _gauges.Min(Canvas.GetTop);
        foreach (var g in _gauges)
        {
            Canvas.SetLeft(g, Canvas.GetLeft(g) - minX); Canvas.SetTop(g, Canvas.GetTop(g) - minY);
            g.Spec.X = Canvas.GetLeft(g); g.Spec.Y = Canvas.GetTop(g);
        }
        _contentW = Math.Max(60, _gauges.Max(g => Canvas.GetLeft(g) + g.Width));
        _contentH = Math.Max(40, _gauges.Max(g => Canvas.GetTop(g) + g.Height));
        _canvas.Width = _contentW; _canvas.Height = _contentH;
        if (_rolled) return;
        Width = Math.Max(MinWidth, (_contentW * k) + 6);
        Height = _fullHeight = Math.Max(MinHeight, (_contentH * k) + 6 + 24);
        Rescale(new Size(Width, Height - 24));
        Avalonia.Threading.Dispatcher.UIThread.Post(KeepOnScreen, Avalonia.Threading.DispatcherPriority.Background);
    }

    void Rescale(Size area)
    {
        if (_rolled || area.Width < 8 || area.Height < 8) return;
        double k = Math.Min((area.Width - 6) / _contentW, (area.Height - 6) / _contentH);
        k = Math.Clamp(k, 0.25, 6);
        _scaler.LayoutTransform = Math.Abs(k - 1) < 0.01 ? null : new ScaleTransform(k, k);
    }

    /// Where this widget is now, and what is in it, for the dashboard file. A parented widget is kept relative to `origin` (the main window's top-left corner on screen), so it comes back on the main window wherever that opens.
    public GaugeWidget AsWidget(PixelPoint? origin = null) => new()
    {
        Gauges = [.. _gauges.Select(g => g.Spec)],
        X = Position.X - (Parented && origin is { } o ? o.X : 0), Y = Position.Y - (Parented && origin is { } o2 ? o2.Y : 0),
        Width = double.IsNaN(Width) ? Bounds.Width : Width,
        Height = _rolled ? _fullHeight : (double.IsNaN(Height) ? Bounds.Height : Height),
        Topmost = _topmostWanted, Hidden = Hidden, Parented = Parented,
    };

    /// Hide (or bring back) the window without closing it, so the layout and its position survive.
    public void SetHidden(bool hidden)
    {
        Hidden = hidden;
        if (hidden) { Topmost = false; base.Hide(); }
        else if (!_parked) { ShowAgain(); Topmost = !Parented && _topmostWanted; }
    }

    /// Parented to the main window: it stays over the main window only (not over other programs), moves when the main window moves, and goes away while the main window is minimized.
    public bool Parented { get; private set; }

    public void SetParented(bool on)
    {
        Parented = on;
        if (!Hidden && !_parked) Topmost = !on && _topmostWanted;
    }

    bool _parked;

    /// The main window was minimized (true) or restored (false): a parented widget goes and comes back with it.
    public void SetParked(bool parked)
    {
        if (!Parented || parked == _parked) return;
        _parked = parked;
        if (Hidden) return;
        if (parked) base.Hide(); else ShowAgain();
    }

    /// The main window it was opened over. Hiding a window lets go of its owner; shown again without one it went behind the main window - as good as gone - so it is always shown again over the window it belongs to.
    public Window? Home { get; set; }

    void ShowAgain()
    {
        if (IsVisible) return;
        if (Home is { } home && home.IsVisible) Show(home); else Show();
    }

    /// The window's size on screen, in pixels, as it is drawn now (rolled up or not).
    public PixelSize PixelSize => new((int)Math.Ceiling(Bounds.Width * RenderScaling), (int)Math.Ceiling(Bounds.Height * RenderScaling));

    bool _rolled;
    void RollUp()
    {
        if (_rolled) { Height = _fullHeight; _rolled = false; return; }
        _fullHeight = Height;
        Height = 28;
        _rolled = true;
    }

    static Button Small(string glyph, string tip, Action run)
    {
        var b = new Button
        {
            Content = glyph, Width = 26, Height = 26, Padding = new Thickness(0), FontSize = 11,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0),
        };
        b.Click += (_, _) => run();
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// The newest reading, to every gauge in the window.
    public void Show(LogFrame? f)
    {
        foreach (var g in _gauges) g.Show(f);
    }

    public void ClearHistory()
    {
        foreach (var g in _gauges) g.Clear();
    }
}
