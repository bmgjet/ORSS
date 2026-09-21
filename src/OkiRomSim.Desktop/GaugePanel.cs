using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// The dashboard on the Datalog page: gauges you build yourself - dials, bars, numbers, trigger lights and rolling graphs - fed by the logged channels.
/// New / Load / Save / Templates work on a layout (a .gauges.json file); Create widget pops the selected gauge out into its own small window that floats over everything else, so the one reading that matters can sit where you can see it while you drive or tune.
public sealed class GaugePanel : UserControl
{
    /// Where dashboards are kept between runs.
    public static string Dir => Path.Combine(AppSettings.Dir, "gauges");

    readonly Canvas _canvas = new() { Background = new SolidColorBrush(Color.FromRgb(0x16, 0x17, 0x1a)) };
    readonly TextBlock _hint = new() { FontSize = 11, Opacity = 0.75, Margin = new Thickness(6, 2), TextWrapping = TextWrapping.Wrap };
    readonly List<GaugeControl> _gauges = new();
    readonly Func<IEnumerable<string>> _channels;
    readonly Func<TopLevel?> _top;
    GaugeControl? _selected;
    GaugeLayout _layout = new();
    readonly List<GaugeWindow> _windows = new();

    public GaugePanel(Func<IEnumerable<string>> channels, Func<TopLevel?> top)
    {
        _channels = channels; _top = top;

        var bar = new WrapPanel { Margin = new Thickness(4, 2) };
        bar.Children.Add(Toolbar.Button(Toolbar.Add, "New", "Add a gauge to the dashboard.", () => AddGauge(null)));
        bar.Children.Add(Toolbar.Button(Toolbar.Open, "Load", "Open a dashboard saved earlier.", Load));
        bar.Children.Add(Toolbar.Button(Toolbar.Save, "Save", "Save this dashboard to a file.", Save));
        var templates = Toolbar.Menu("Templates", Toolbar.Gauge,
            GaugeLayout.Templates.Select(t => new Toolbar.Entry(Toolbar.Gauge, t, $"Replace the dashboard with the {t} template.", () => UseTemplate(t))).ToArray());
        bar.Children.Add(templates);
        bar.Children.Add(Toolbar.Button(Toolbar.Gauge, "Create widget",
            "Pop the selected gauge out into its own floating window: drag it anywhere on screen, resize it, roll it up or close it.", PopOut));
        bar.Children.Add(Toolbar.Button("✎", "Edit", "Change the selected gauge: channel, range, warning level, kind.", () => { if (_selected != null) AddGauge(_selected); }));
        bar.Children.Add(Toolbar.Button(Toolbar.Delete, "Remove", "Take the selected gauge off the dashboard.", RemoveSelected));

        _hint.Text = "No gauges yet: New adds one, or start from a template. Drag a gauge to move it, drag its bottom-right corner to resize.";
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(_hint, Dock.Bottom);
        dock.Children.Add(bar);
        dock.Children.Add(_hint);
        dock.Children.Add(new ScrollViewer
        {
            Content = _canvas,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
        });
        Content = dock;
    }

    // ------------------------------------------------------------------ frames

    /// Readings from outside the ECU (Settings > Datalog), merged into every frame the gauges see so an external channel reads exactly like a logged one.
    public ExternalData? External { get; set; }

    /// Feed every gauge (on the dashboard and in its own window) the newest reading.
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
        foreach (var w in _windows) w.Gauge.Clear();
    }

    // ------------------------------------------------------------------ layout

    public GaugeLayout Layout
    {
        get
        {
            _layout.Gauges = _gauges.Select(g => g.Spec).ToList();
            _layout.Widgets = _windows.Where(w => !w.IsGone).Select(w => w.AsWidget()).ToList();
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
        Apply(GaugeLayout.Template(name));
        AppLog.Action("gauges", "template " + name);
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

    void BeginDrag(GaugeControl g, PointerPressedEventArgs e)
    {
        Select(g);
        _grab = e.GetPosition(g);
        _resizing = _grab.X > g.Bounds.Width - 14 && _grab.Y > g.Bounds.Height - 14;
        e.Pointer.Capture(g);
        e.Handled = true;
    }

    void Drag(GaugeControl g, PointerEventArgs e)
    {
        if (!Equals(e.Pointer.Captured, g)) return;
        var p = e.GetPosition(_canvas);
        if (_resizing)
        {
            g.Spec.Width = g.Width = Math.Max(70, p.X - g.Spec.X);
            g.Spec.Height = g.Height = Math.Max(50, p.Y - g.Spec.Y);
        }
        else
        {
            g.Spec.X = Math.Max(0, p.X - _grab.X);
            g.Spec.Y = Math.Max(0, p.Y - _grab.Y);
            Canvas.SetLeft(g, g.Spec.X); Canvas.SetTop(g, g.Spec.Y);
        }
        g.InvalidateVisual();
    }

    void EndDrag(GaugeControl g, PointerReleasedEventArgs e)
    {
        e.Pointer.Capture(null);
        _resizing = false;
        UpdateCanvasSize();
    }

    // ------------------------------------------------------------------ actions

    async void AddGauge(GaugeControl? edit)
    {
        if (_top() is not Window owner) return;
        var spec = edit?.Spec.Clone() ?? new GaugeSpec { Channel = _channels().FirstOrDefault() ?? "rpm" };
        var dlg = new GaugeEditor(spec, _channels());
        await dlg.ShowDialog(owner);
        if (dlg.Result == null) return;
        if (edit != null)
        {
            _canvas.Children.Remove(edit);
            _gauges.Remove(edit);
        }
        Place(dlg.Result);
        AppLog.Action("gauges", $"{(edit == null ? "added" : "edited")} {dlg.Result.Kind} gauge for {dlg.Result.Channel}");
    }

    void RemoveSelected()
    {
        if (_selected == null) return;
        _canvas.Children.Remove(_selected);
        _gauges.Remove(_selected);
        Select(_gauges.LastOrDefault());
        UpdateCanvasSize();
    }

    void PopOut()
    {
        if (_selected == null) { _hint.Text = "select a gauge first (click it), then Create widget floats it over everything else"; return; }
        Open(new GaugeWidget
        {
            Gauge = _selected.Spec.Clone(),
            Width = Math.Max(160, _selected.Spec.Width), Height = Math.Max(110, _selected.Spec.Height) + 28,
            X = double.NaN, Y = double.NaN,
        });
        AppLog.Action("gauges", "created a floating widget for " + _selected.Spec.Title);
    }

    void Open(GaugeWidget widget)
    {
        if (_top() is not Window owner) return;
        var w = new GaugeWindow(widget);
        _windows.Add(w);
        w.Show(owner);
    }

    /// Put back the widgets that were on screen last time. They are opened once the owner window exists, so this is safe to call while the page is still being built.
    void RestoreWidgets(List<GaugeWidget> widgets)
    {
        if (widgets.Count == 0) return;
        Avalonia.Threading.Dispatcher.UIThread.Post(() =>
        {
            foreach (var widget in widgets.Take(24))
            {
                if (_windows.Any(w => !w.IsGone && w.Gauge.Spec.Title == widget.Gauge.Title)) continue;
                Open(widget);
            }
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
        try
        {
            _layout.Name = Path.GetFileNameWithoutExtension(path).Replace(".gauges", "");
            Layout.Save(path);
            _hint.Text = $"dashboard saved to {path}";
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
        if (path == null) return;
        try
        {
            Apply(GaugeLayout.Load(path));
            _hint.Text = $"{Path.GetFileName(path)}: {_gauges.Count} gauge(s)";
        }
        catch (Exception ex) { _hint.Text = "could not open: " + ex.Message; AppLog.Error("gauges", "load failed", ex); }
    }

    /// The dashboard left on screen last time, so it comes back with the program.
    static string LastPath => Path.Combine(Dir, "last.gauges.json");

    public void LoadLast()
    {
        try { if (File.Exists(LastPath)) Apply(GaugeLayout.Load(LastPath)); }
        catch (Exception ex) { AppLog.Error("gauges", "could not read the last dashboard", ex); }
    }

    public void SaveLast()
    {
        try
        {
            if (_gauges.Count == 0 && !File.Exists(LastPath)) return;
            Directory.CreateDirectory(Dir);
            Layout.Save(LastPath);
        }
        catch (Exception ex) { AppLog.Error("gauges", "could not keep the dashboard", ex); }
    }

    public void CloseWidgets()
    {
        foreach (var w in _windows.ToList()) w.Close();
        _windows.Clear();
    }
}

/// One gauge in its own window: floats over the app, can be dragged anywhere on screen, resized, rolled up to its title bar or closed.
public sealed class GaugeWindow : Window
{
    public GaugeControl Gauge { get; }
    /// True once this widget has been closed, so the panel can let go of it.
    public bool IsGone { get; private set; }
    double _fullHeight;

    public GaugeWindow(GaugeWidget widget)
    {
        var spec = widget.Gauge;
        Gauge = new GaugeControl(spec) { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
        Gauge.Width = double.NaN; Gauge.Height = double.NaN;
        Title = spec.Title;
        Width = Math.Max(120, widget.Width); Height = Math.Max(80, widget.Height);
        _fullHeight = Height;
        MinWidth = 110; MinHeight = 58;
        Topmost = widget.Topmost;
        ShowInTaskbar = false;
        // no frame at all: a border-only window still shows a pale strip along the top on
        // Windows, which looked like a scratch across the widget
        SystemDecorations = SystemDecorations.None;
        Background = new SolidColorBrush(DarkChrome.Background);
        Icon = DarkChrome.LoadWindowIcon();
        if (!double.IsNaN(widget.X) && !double.IsNaN(widget.Y))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = new PixelPoint((int)widget.X, (int)widget.Y);
        }

        var title = new TextBlock { Text = spec.Title, FontSize = 11, Margin = new Thickness(8, 0), VerticalAlignment = VerticalAlignment.Center };
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Height = 24, Background = new SolidColorBrush(DarkChrome.Panel) };
        var drag = new Border { Background = Brushes.Transparent, Child = title };
        drag.PointerPressed += (_, e) => { if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e); };
        drag.DoubleTapped += (_, _) => RollUp();
        Grid.SetColumn(drag, 0); bar.Children.Add(drag);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Small("📌", "Keep the widget above other windows, or let it go behind them.",
            () => Topmost = !Topmost));
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
        grip.PointerPressed += (_, e) => BeginResizeDrag(WindowEdge.SouthEast, e);
        ToolTip.SetTip(grip, "Drag to resize the widget.");

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(Gauge, 1); g.Children.Add(Gauge);
        var overlay = new Panel();
        overlay.Children.Add(g);
        overlay.Children.Add(grip);
        Content = overlay;
        Closing += (_, _) => IsGone = true;
    }

    /// Where this widget is now, for the dashboard file.
    public GaugeWidget AsWidget() => new()
    {
        Gauge = Gauge.Spec, X = Position.X, Y = Position.Y,
        Width = double.IsNaN(Width) ? Bounds.Width : Width,
        Height = _rolled ? _fullHeight : (double.IsNaN(Height) ? Bounds.Height : Height),
        Topmost = Topmost,
    };

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

    public void Show(LogFrame? f) => Gauge.Show(f);
}
