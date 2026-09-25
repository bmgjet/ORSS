// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Assembler;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Datalog page: every value the ECU sends in a parameter list (plus the wideband and aux channels), the raw packets going back and forth, and playback of saved logs. The port, protocol, wideband and aux channels are set in Settings. With a simulator behind it the page also drives the simulated engine with the log and compares what the simulated ECU does with what the car's did, listing the code that ran. In Tuner mode it sits beside the Calibration page in a compact form and marks the cell the car is in on the map.
public sealed class DatalogView : UserControl
{
    readonly SimHost _host;
    readonly Func<TopLevel?> _top;
    public readonly DatalogEngine Engine;
    List<LogFrame> _loaded = [];
    string _loadedName = "";
    bool _compact;

    readonly Button _connect;
    readonly Slider _pos = new() { Minimum = 0, Maximum = 0, MinWidth = 160, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _posText = new() { FontFamily = MainWindow.MonoFont, FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0) };
    readonly TextBlock _status = new() { Text = "", FontSize = 11, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    readonly ListBox _params = UiStyles.Compact(new ListBox { FontFamily = MainWindow.MonoFont, FontSize = 11.5 });
    /// The gauges built on this page (and any floating widgets made from them).
    public GaugePanel Gauges { get; }
    readonly TextBlock _compare = new() { FontFamily = MainWindow.MonoFont, FontSize = 11.5 };
    readonly ListBox _code = UiStyles.Compact(new ListBox { FontFamily = MainWindow.MonoFont, FontSize = 11 });
    readonly ContentControl _body = new();
    /// The top of the panel: the frame's parameters, or the log as a graph (Datalogging > Parameters / Graph).
    readonly ContentControl _paramHost = new();
    DatalogGraphPanel? _graphPanel;
    bool _showGraph;
    /// How fast a replay runs against the log's own clock (Datalogging > Play rate).
    double _rate = 1;
    public static readonly double[] Rates = [0.2, 0.5, 1, 2, 5, 10];
    int _fedIndex = -1;
    List<int> _codeAddrs = [];
    ulong _codeSince;
    bool _settingPos;
    DateTime _lastCode, _lastParams;
    // playback without a simulator (Tuner mode): step through frames in wall time
    readonly DispatcherTimer _playTimer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    DateTime _playWallStart; double _playLogStart; int _playIndex = -1;

    public bool DriveSimulator { get; set; } = true;
    public string Port { get; set; } = "";
    public string Protocol { get; set; } = "auto";
    public int Baud { get; set; } = 38400;
    public event Action<int>? GoToAddress;
    /// Every frame the page shows (live, played back or selected), for the calibration trace.
    public event Action<LogFrame?>? CurrentFrameChanged;
    public LogFrame? Current { get; private set; }

    public DatalogView(SimHost host, Func<TopLevel?> top)
    {
        _host = host; _top = top;
        Engine = new DatalogEngine(host);
        Gauges = new GaugePanel(Channels, top);
        _connect = Btn("Connect", ToggleConnect, "Start or stop logging on the port set in Settings > Datalog ('simulator' logs the ROM running here, through its own serial port).");
        Engine.Frame += OnLiveFrame;
        _playTimer.Tick += (_, _) => PlayTick();

        _pos.PropertyChanged += (_, e) =>
        {
            if (e.Property != Slider.ValueProperty || _settingPos) return;
            var log = Log();
            if (log.Count == 0) return;
            int i = Math.Clamp((int)_pos.Value, 0, log.Count - 1);
            ShowFrame(i);
            var f = log[i];
            SetCurrent(f);
            if (!_host.PlaybackActive && DriveSimulator && !_compact && _host.LoadedPath != null) _host.ApplyFrame(f);
        };
        ToolTip.SetTip(_pos, "Position in the loaded log. Drag to look at a moment (the calibration map marks where the engine was).");
        ToolTip.SetTip(_params, "Every value in the latest frame: decoded, with its unit and the raw byte(s). Wideband and aux channels (Settings > Datalog) are added at the bottom.");
        ToolTip.SetTip(Gauges, "Your own gauges: dials, bars, numbers, trigger lights and rolling graphs of any logged channel. Create widget floats one over everything else.");
        ToolTip.SetTip(_compare, "The frame's readings from the car next to what the simulated ECU is doing with them.");
        ToolTip.SetTip(_code, "Routines and branches of the assembly that ran since the log started driving the simulator, in address order. Double-click to go to one.");
        _code.DoubleTapped += (_, _) =>
        {
            int i = _code.SelectedIndex;
            if (i >= 0 && i < _codeAddrs.Count) GoToAddress?.Invoke(_codeAddrs[i]);
        };
        Content = _body;
        SetCompact(false);
        _compare.Text = "No log yet. Connect (the port is set in Settings > Datalog), or Load log…";
    }

    static TextBlock Lbl(string t) => new() { Text = t, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 6, 0), FontSize = 11, FontWeight = FontWeight.Bold };
    static TextBlock Head(string t) => new() { Text = t.ToUpperInvariant(), FontSize = 10, Opacity = 0.6, Margin = new Thickness(0, 2) };
    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(7, 2) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    static void Detach(Control c) => UiStyles.Adopt(c);

    /// Full page (simulator mode) or a narrow side panel (Tuner mode).
    public void SetCompact(bool compact)
    {
        _compact = compact;
        // Tuner mode and the simulator keep their own gauges: the dashboard on screen (and where its floating widgets sit) is written out, and the other mode's is put back as it was left
        Gauges.UseProfile(compact ? "tuner" : "simulator");
        foreach (var c in new Control[] { _connect, _pos, _posText, _status, _paramHost, Gauges, _compare, _code }) Detach(c);
        UiStyles.Adopt(_params);
        if (_graphPanel != null) UiStyles.Adopt(_graphPanel);
        _paramHost.Content = _showGraph ? GraphPanel() : _params;
        var row1 = new WrapPanel { Margin = new Thickness(4, 4, 4, 2) };
        // beside the map (Tuner mode) these live in the calibration bar's Datalogging menu
        if (!compact)
        {
        row1.Children.Add(_connect);
        row1.Children.Add(Btn("Load log…", LoadLog,
            "Open a log: an .rlog (the datalog, the ROM it ran on and the tuning settings in one file), a binary datalog (DATALOGGER header) or a CSV " +
            "(rpm, map_kpa, tps_pct, ect_c, iat_c, o2_v, batt_v, speed_kmh, afr, ...)."));
        row1.Children.Add(Btn("Save log…", SaveLog, "Write the frames logged from the car (or the loaded log) to a CSV file, every channel and the raw frame included."));
        row1.Children.Add(Btn("Clear", ClearAll, "Stop logging and put the page back to how it started: no frames, no loaded log, no packets."));
        row1.Children.Add(Btn("Graph…", OpenGraph,
            "The whole log as a graph: any set of channels against time on one set of axes, each on its own scale, with a cursor " +
            "that reads them all at the moment it sits on and moves the position here with it. Channel sets can be saved as templates."));
        row1.Children.Add(Btn("Detect layout", DetectLayout,
            "Work out how this ROM datalogs, from the ROM itself: its serial code is read for the command bytes it answers, each is tried in a simulator " +
            "until one returns a checksummed frame, and then every engine input is changed in turn to see which byte of the frame follows it."));
        }
        var row2 = new WrapPanel { Margin = new Thickness(4, 2) };
        row2.Children.Add(Lbl("Log"));
        row2.Children.Add(Btn("▶ Play", Play, compact ? "Replay the loaded log in real time: the map marks where the engine was, frame by frame." :
            "Run the simulator from the selected frame, stepping through the log in simulated time."));
        row2.Children.Add(Btn("■ Stop", StopAll, "Stop playback and stop logging (disconnects the port)."));
        row2.Children.Add(Btn("◀", () => StepFrame(-1), "Previous frame."));
        row2.Children.Add(Btn("▶", () => StepFrame(1), "Next frame."));
        row2.Children.Add(_pos);
        row2.Children.Add(_posText);
        _status.Margin = new Thickness(6, 2);

        if (compact)
        {
            // controls and the frame's values on top, gauges below them, with a splitter between: the gauges start a little under half the panel and can be dragged as large as the screen allows, which matters on a big monitor where the rest is empty space
            var top = new StackPanel();
            top.Children.Add(new TextBlock { Text = "DATALOG", FontSize = 11, FontWeight = FontWeight.Bold, Margin = new Thickness(6, 4, 0, 0) });
            top.Children.Add(row2); top.Children.Add(_status);
            var upper = new DockPanel();
            DockPanel.SetDock(top, Dock.Top);
            upper.Children.Add(top);
            upper.Children.Add(_paramHost);

            var lower = new DockPanel();
            var gaugeHead = Head("  gauges");
            DockPanel.SetDock(gaugeHead, Dock.Top);
            lower.Children.Add(gaugeHead);
            Gauges.Height = double.NaN;
            lower.Children.Add(Gauges);

            var split = new Grid { Margin = new Thickness(2), RowDefinitions = new RowDefinitions("5*,4,4*") };
            Grid.SetRow(upper, 0); split.Children.Add(upper);
            var gs = new GridSplitter { Height = 4, ResizeDirection = GridResizeDirection.Rows, HorizontalAlignment = HorizontalAlignment.Stretch };
            ToolTip.SetTip(gs, "Drag to give the gauges more (or less) of the panel.");
            Grid.SetRow(gs, 1); split.Children.Add(gs);
            Grid.SetRow(lower, 2); split.Children.Add(lower);
            _body.Content = split;
        }
        else
        {
            row1.Children.Add(Btn("Clear code list", () => { _codeSince = _host.Sim.Cpu.Cycles; _code.ItemsSource = null; }, "Start the 'code that ran' list afresh from now."));
            var body = new Grid { ColumnDefinitions = new ColumnDefinitions("300,6,*,6,Auto,6,*") };
            var p1 = new DockPanel();
            p1.Children.Add(_paramHost);
            Grid.SetColumn(p1, 0); body.Children.Add(p1);
            var p2 = new DockPanel();
            var h2 = Head("gauges");
            DockPanel.SetDock(h2, Dock.Top); p2.Children.Add(h2);
            Gauges.Height = double.NaN;
            p2.Children.Add(Gauges);
            Grid.SetColumn(p2, 2); body.Children.Add(p2);
            var p3 = new ScrollViewer { Content = _compare, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto };
            Grid.SetColumn(p3, 4); body.Children.Add(p3);
            var p4 = new DockPanel();
            var h4 = Head("code that ran for this log"); DockPanel.SetDock(h4, Dock.Top); p4.Children.Add(h4); p4.Children.Add(_code);
            Grid.SetColumn(p4, 6); body.Children.Add(p4);
            var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto,*"), Margin = new Thickness(0, 0, 0, 4) };
            Grid.SetRow(row1, 0); g.Children.Add(row1);
            Grid.SetRow(row2, 1); g.Children.Add(row2);
            Grid.SetRow(_status, 2); g.Children.Add(_status);
            Grid.SetRow(body, 3); g.Children.Add(body);
            body.Margin = new Thickness(6, 4);
            _body.Content = g;
        }
        UpdateConnect();
    }

    // ------------------------------------------------------------------ live

    void ToggleConnect()
    {
        if (Engine.Running || _connecting)
        {
            // stopping can block on a port that is not answering: off the UI thread as well
            _connecting = false;
            _connect.IsEnabled = false;
            _status.Text = "disconnecting…";
            Task.Run(() =>
            {
                try { Engine.Stop(); } catch (Exception ex) { AppLog.Error("datalog", "stop failed", ex); }
                Dispatcher.UIThread.Post(() => { _connect.IsEnabled = true; UpdateConnect(); _status.Text = Engine.Status; });
            });
            AppLog.Action("datalog", "disconnect");
            return;
        }
        var port = Port.Length > 0 ? Port : SerialLink.Ports().FirstOrDefault() ?? "";
        if (port.Length == 0) { _status.Text = "no serial port: pick one in Settings > Datalog (or 'simulator' to log the ROM running here)"; return; }
        if (port == "simulator" && _host.LoadedPath == null) { _status.Text = "open a ROM first to log it in the simulator"; return; }
        _codeSince = _host.Sim.Cpu.Cycles;
        if (DriveSimulator && !_compact && port != "simulator" && !_host.IsRunning && _host.LoadedPath != null) _host.Control("run");
        _connecting = true;
        _connect.IsEnabled = false;
        _connect.Content = "Connecting…";
        _status.Text = $"opening {port}…";
        AppLog.Action("datalog", $"connect {port} ({Protocol}, {Baud})");
        // opening a serial port, the handshake and protocol detection all wait on the cable: none of it happens on the UI thread
        Task.Run(() =>
        {
            string? error = null;
            try { Engine.Start(port, Protocol, Baud); }
            catch (Exception ex) { error = ex.Message; AppLog.Error("datalog", "connect failed", ex); }
            Dispatcher.UIThread.Post(() =>
            {
                _connecting = false;
                _connect.IsEnabled = true;
                UpdateConnect();
                if (error != null) _status.Text = "cannot open the port: " + error;
            });
        });
    }
    bool _connecting;

    DatalogGraphWindow? _graph;

    /// The log as a graph. One window at a time: opening it again brings the one that is up to the front rather than stacking another on it.
    void OpenGraph()
    {
        if (_top() is not Window owner) return;
        if (_graph is { } open)
        {
            try { open.Activate(); return; }
            catch { _graph = null; }      // it had been closed
        }
        var w = new DatalogGraphWindow(GraphFrames, Seek);
        _graph = w;
        w.Closed += (_, _) => { if (ReferenceEquals(_graph, w)) _graph = null; };
        w.Show(owner);
    }

    /// What the graphs draw: the live recording while logging, else the log the slider works on.
    IReadOnlyList<LogFrame> GraphFrames() => Engine.Running ? Engine.Frames() : Log();

    /// The graph for the top of the panel, made the first time it is asked for.
    DatalogGraphPanel GraphPanel() => _graphPanel ??= new DatalogGraphPanel(GraphFrames, Seek, compact: true);

    /// A graph cursor moved: take the rest of the page with it, so the map's trace marker follows.
    void Seek(int i)
    {
        var log = Log();
        if (i < 0 || i >= log.Count) return;
        _settingPos = true;
        _pos.Value = i;
        _settingPos = false;
        ShowFrame(i);
        SetCurrent(log[i]);
    }

    /// Put the graph (true) or the parameter list at the top of the panel.
    public void ShowGraph(bool graph)
    {
        _showGraph = graph;
        UiStyles.Adopt(_params);
        if (_graphPanel != null) UiStyles.Adopt(_graphPanel);
        _paramHost.Content = graph ? GraphPanel() : _params;
        if (!graph && Current != null) _params.ItemsSource = Parameters(Current);
    }

    /// Replay speed against the log's clock; a replay running now carries on from where it is.
    public void SetRate(double rate)
    {
        var log = _loaded;
        if (_playTimer.IsEnabled && _playIndex >= 0 && _playIndex < log.Count)
        {
            _playWallStart = DateTime.Now;
            _playLogStart = log[_playIndex].T;
        }
        _rate = rate;
        _status.Text = $"replay speed {rate:0.#}x";
        AppLog.Action("datalog", $"play rate {rate}x");
    }

    public double Rate => _rate;

    /// The Datalogging menu (on the calibration bar beside the map): everything that used to be buttons along the top of this panel.
    public Toolbar.Entry[] MenuEntries(Func<bool> liveTrace, Action<bool> setLiveTrace) =>
    [
        new Toolbar.Entry(Toolbar.Log, Engine.Running ? "Disconnect" : "Connect",
            "Start or stop logging on the port set in Settings > Datalog ('simulator' logs the ROM running here, through its own serial port).", ToggleConnect),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Open, "Load log…",
            "Open a log: an .rlog (the datalog, the ROM it ran on and the tuning settings in one file), a binary datalog or a CSV.", LoadLog),
        new Toolbar.Entry(Toolbar.Save, "Save log…", "Write the frames logged from the car (or the loaded log) to a CSV file.", SaveLog),
        new Toolbar.Entry(Toolbar.Clear, "Clear", "Stop logging and put the panel back to how it started: no frames, no loaded log, no packets.", ClearAll),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Log, "Graph", "Show the log as a graph at the top of the datalog panel, with a bar where the replay is (live, it draws as it logs).",
            () => ShowGraph(true), Checked: () => _showGraph),
        new Toolbar.Entry(Toolbar.Log, "Parameters", "Show every value of the current frame at the top of the datalog panel.",
            () => ShowGraph(false), Checked: () => !_showGraph),
        new Toolbar.Entry(Toolbar.Log, "Graph window…", "The graph in a window of its own, as large as you like.", OpenGraph),
        Toolbar.Entry.Line,
        Toolbar.Entry.Submenu(Toolbar.Run, "Play rate", "How fast Play replays the log against its own clock.",
            () => [.. Rates.Select(r => new Toolbar.Entry("", $"{r:0.#}x", $"Replay at {r:0.#} times real time.", () => SetRate(r), Checked: () => Math.Abs(_rate - r) < 1e-9))]),
        new Toolbar.Entry("", "Live trace", "Mark the cell the engine is in on the map on screen.", () => setLiveTrace(!liveTrace()), Checked: liveTrace),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Detect, "Detect layout",
            "Work out how this ROM datalogs, from the ROM itself: the serial code is read for the command bytes it answers, each is tried in a simulator.", DetectLayout),
    ];

    /// Work the protocol out from the ROM itself (in a simulator, off the UI thread).
    void DetectLayout()
    {
        var rom = _host.RomBytes(0, Bus.RomSize);
        if (_host.LoadedPath == null) { _status.Text = "open a ROM first"; return; }
        if (Engine.Running) { _status.Text = "stop logging first"; return; }
        _status.Text = "reading the ROM's serial code and probing it in a simulator…";
        AppLog.Action("datalog", "detect layout");
        Task.Run(() =>
        {
            try
            {
                var r = DatalogLayout.Detect(rom, m => Dispatcher.UIThread.Post(() => _status.Text = m));
                AppLog.Write(LogKind.Serial, "datalog", "layout detection:\n" + r.Report.TrimEnd());
                Dispatcher.UIThread.Post(() =>
                {
                    if (r.Known != null)
                    {
                        Protocol = r.Known.Name;
                        _status.Text = $"this ROM speaks {r.Known.Name}: {r.Known.Description}. Protocol set; Connect to log it.";
                    }
                    else if (r.Protocol != null)
                    {
                        Engine.Detected = r.Protocol;
                        Protocol = r.Protocol.Name;
                        _status.Text = "detected: " + r.Protocol.Description + ". Connect to log it.";
                    }
                    else _status.Text = "nothing found - see the Debug page for what was tried.";
                    DetectedLayoutChanged?.Invoke(Engine.Detected);
                });
            }
            catch (Exception ex)
            {
                AppLog.Error("datalog", "layout detection failed", ex);
                Dispatcher.UIThread.Post(() => _status.Text = "layout detection failed: " + ex.Message);
            }
        });
    }

    /// Raised when a layout has been detected, so it can be saved with the project.
    public event Action<DetectedProtocol?>? DetectedLayoutChanged;

    public void Start() { if (!Engine.Running) ToggleConnect(); }
    public void Stop() { if (Engine.Running) ToggleConnect(); }

    void UpdateConnect() => _connect.Content = Engine.Running ? "Disconnect" : "Connect";

    void OnLiveFrame(LogFrame f)
    {
        // feeding the simulator the car's readings makes no sense when the simulator is the source
        if (DriveSimulator && !_compact && Engine.Source != "simulator") _host.ApplyFrame(f);
    }

    void SetCurrent(LogFrame? f)
    {
        Current = f;
        CurrentFrameChanged?.Invoke(f);
    }

    /// Frames for overlays and MCP: the live recording if there is one, else the loaded log.
    public IReadOnlyList<LogFrame> Frames()
    {
        var rec = Engine.Frames();
        return rec.Count > 0 ? rec : _loaded;
    }

    /// What Play, the slider and the frame buttons work on: the loaded log, or what has been recorded live (taken as a snapshot so it stops growing under the slider).
    List<LogFrame> Log()
    {
        if (_loaded.Count == 0)
        {
            var rec = Engine.Frames();
            if (rec.Count > 0) { _loaded = rec; _loadedName = "live recording"; }
        }
        if (_loaded.Count > 0 && Math.Abs(_pos.Maximum - (_loaded.Count - 1)) > 0.5)
        {
            _settingPos = true;
            _pos.Maximum = _loaded.Count - 1;
            _settingPos = false;
        }
        return _loaded;
    }

    /// Everything back to how the page started.
    public void ClearAll()
    {
        _playTimer.Stop();
        _playIndex = -1;
        _host.StopPlayback();
        Engine.Stop();
        Engine.ClearFrames();
        _loaded = [];
        _loadedName = "";
        Gauges.ClearHistory();
        _params.ItemsSource = null;
        _codeAddrs = [];
        _code.ItemsSource = null;
        _codeSince = 0;
        _settingPos = true;
        _pos.Maximum = 0; _pos.Value = 0;
        _settingPos = false;
        _posText.Text = "";
        SetCurrent(null);
        _compare.Text = "No log yet. Connect (the port is set in Settings > Datalog), or Load log…";
        _status.Text = "cleared";
        UpdateConnect();
        AppLog.Action("datalog", "cleared");
    }

    /// Stop playback and logging. What was recorded stays: it becomes the log the slider, the frame buttons and Play work on, so you can track back through the drive you just did.
    public void StopAll()
    {
        _playTimer.Stop();
        _playIndex = -1;
        _host.StopPlayback();
        if (Engine.Running) Engine.Stop();
        var rec = Engine.Frames();
        if (_loaded.Count == 0 && rec.Count > 0)
        {
            _loaded = [.. rec];                 // a copy, so the next connection cannot move it under the slider
            _loadedName = "live recording";
        }
        var log = Log();
        if (log.Count > 0)
        {
            _settingPos = true;
            _pos.Maximum = log.Count - 1;
            _pos.Value = log.Count - 1;
            _settingPos = false;
            ShowFrame(log.Count - 1);
            SetCurrent(log[^1]);
        }
        UpdateConnect();
        _status.Text = log.Count > 0
            ? $"stopped: {log.Count} frames kept - the slider and ◀ ▶ track back through them, Play replays them"
            : "stopped: " + Engine.Status;
        AppLog.Action("datalog", "stopped");
    }

    /// Stop replaying (leaving the frames alone): used when the page goes away.
    public void StopPlayback()
    {
        if (!_playTimer.IsEnabled) return;
        _playTimer.Stop();
        _playIndex = -1;
        _host.StopPlayback();
        _status.Text = "replay stopped";
    }

    public IEnumerable<string> Channels() => (Engine.Latest ?? Current ?? _loaded.FirstOrDefault())?.Channels() ?? [];

    // ------------------------------------------------------------------ files

    async void LoadLog()
    {
        try
        {
            var top = _top();
            if (top == null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "Open datalog",
                FileTypeFilter = new[] { new FilePickerFileType("Datalogs") { Patterns = new[] { "*.rlog", "*.csv", "*.hdl", "*.hml", "*.dlf", "*.bml", "*.log", "*.txt", "*.*" } } },
            });
            var path = files.FirstOrDefault()?.TryGetLocalPath();
            if (path != null) LoadFile(path);
        }
        catch (Exception ex) { _status.Text = "cannot read the log: " + ex.Message; AppLog.Error("datalog", "load failed", ex); }
    }

    /// An .rlog also carries the ROM the car was running (PROG) and the tuning settings (SET).
    public event Action<byte[], string>? RomFromLog;

    public string LoadFile(string path)
    {
        byte[]? rom = null;
        if (path.EndsWith(".rlog", StringComparison.OrdinalIgnoreCase))
        {
            var r = LogFile.LoadRlog(path);
            _loaded = r.Frames;
            rom = r.Rom;
            if (r.Settings is { Length: > 0 }) AppLog.Info("datalog", $"{Path.GetFileName(path)} carries tuning settings ({r.Settings.Length} bytes of XML)");
        }
        else _loaded = LogFile.Load(path);
        foreach (var f in _loaded) Engine.Enrich(f);     // aux channels from the raw frames
        _loadedName = Path.GetFileName(path);
        _settingPos = true;
        _pos.Maximum = Math.Max(0, _loaded.Count - 1);
        _pos.Value = 0;
        _settingPos = false;
        ShowFrame(0);
        if (_loaded.Count > 0) SetCurrent(_loaded[0]);
        _status.Text = $"{_loadedName}: {_loaded.Count} frames, {(_loaded.Count > 0 ? _loaded[^1].T : 0):F1} s. Play replays it.";
        AppLog.Action("datalog", $"loaded {path} ({_loaded.Count} frames)");
        if (rom is { Length: > 0 })
        {
            _status.Text += " It also carries the ROM the car was running.";
            RomFromLog?.Invoke(rom, Path.GetFileNameWithoutExtension(path));
        }
        return _status.Text;
    }

    async void SaveLog()
    {
        var frames = Engine.Frames();
        if (frames.Count == 0) frames = _loaded;
        if (frames.Count == 0) { _status.Text = "nothing logged yet"; return; }
        try
        {
            var top = _top();
            if (top == null) return;
            var file = await top.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Save datalog",
                SuggestedFileName = $"log_{DateTime.Now:yyyyMMdd_HHmm}.csv",
                DefaultExtension = "csv",
                FileTypeChoices = new[] { new FilePickerFileType("CSV") { Patterns = new[] { "*.csv" } } },
            });
            var path = file?.TryGetLocalPath();
            if (path == null) return;
            LogFile.SaveCsv(path, frames);
            _status.Text = $"saved {frames.Count} frames to {path}";
        }
        catch (Exception ex) { _status.Text = ex.Message; AppLog.Error("datalog", "save failed", ex); }
    }

    // ------------------------------------------------------------------ playback

    void Play()
    {
        var log = Log();
        if (log.Count == 0) { _status.Text = "nothing to replay: load a log, or log from the car first"; return; }
        if (Engine.Running) { _status.Text = "stop logging first (Stop), then Play replays what was recorded"; return; }
        int from = Math.Clamp((int)_pos.Value, 0, log.Count - 1);
        // replay in wall time; when the simulator is behind it, each frame's readings go onto its inputs as they come (that also works when the ROM is not running)
        _playIndex = from;
        _playWallStart = DateTime.Now;
        _playLogStart = log[from].T;
        _codeSince = _host.Sim.Cpu.Cycles;
        if (DriveSimulator && !_compact && _host.LoadedPath != null && !_host.IsRunning) _host.Control("run");
        _playTimer.Start();
        _status.Text = $"replaying from frame {from + 1} of {log.Count} at {_rate:0.#}x" + (DriveSimulator && !_compact ? " through the simulator" : "");
        AppLog.Action("datalog", $"play from frame {from}");
    }



    void PlayTick()
    {
        var log = _loaded;
        if (_playIndex < 0 || log.Count == 0) { _playTimer.Stop(); return; }
        double t = ((DateTime.Now - _playWallStart).TotalSeconds * _rate) + _playLogStart;
        while (_playIndex + 1 < log.Count && log[_playIndex + 1].T <= t) _playIndex++;
        _settingPos = true; _pos.Value = _playIndex; _settingPos = false;
        ShowFrame(_playIndex);
        var f = log[_playIndex];
        SetCurrent(f);
        if (DriveSimulator && !_compact && _host.LoadedPath != null) _host.ApplyFrame(f);
        if (_playIndex + 1 >= log.Count) { _playTimer.Stop(); _status.Text = $"replay finished ({log.Count} frames)"; }
    }

    void StepFrame(int d)
    {
        var log = Log();
        if (log.Count == 0) { _status.Text = "nothing to step through: load a log, or log from the car first"; return; }
        _playTimer.Stop();
        int i = Math.Clamp((int)_pos.Value + d, 0, log.Count - 1);
        _settingPos = true;
        _pos.Value = i;
        _settingPos = false;
        ShowFrame(i);
        SetCurrent(log[i]);
        if (DriveSimulator && !_compact && _host.LoadedPath != null) _host.ApplyFrame(log[i]);
    }

    void ShowFrame(int i)
    {
        if (i < 0 || i >= _loaded.Count) return;
        _posText.Text = $"{i + 1}/{_loaded.Count}  {_loaded[i].T:F2} s";
    }

    // ------------------------------------------------------------------ refresh

    /// Called on the UI refresh tick (the page is showing, or Tuner mode's side panel).
    public void Tick(SimHost.Snapshot? s)
    {
        UpdateConnect();
        LogFrame? f = null;
        string source = "";
        if (_host.PlaybackActive && _loaded.Count > 0)
        {
            int i = Math.Clamp(_host.PlaybackIndex, 0, _loaded.Count - 1);
            f = _loaded[i];
            _settingPos = true; _pos.Value = i; _settingPos = false;
            ShowFrame(i);
            source = $"playback frame {i + 1}/{_loaded.Count}";
            if (f != Current) SetCurrent(f);
        }
        else if (Engine.Running && Engine.Latest != null)
        {
            f = Engine.Latest;
            source = $"live {Engine.Protocol?.Name}";
            if (f != Current) SetCurrent(f);
        }
        else if (_playTimer.IsEnabled || _loaded.Count > 0) { f = Current; source = _loadedName; }

        var wb = Engine.Wideband.Status;
        string state = Engine.Running
            ? $"{Engine.Status} · {Engine.Good} frames, {Engine.Bad} missed · {Engine.FramesPerSecond:0.0}/s · {Engine.FrameCount} kept"
            : Engine.Status;
        if (wb != "off") state += " · wideband " + wb;
        if (Engine.Running || !_status.Text!.StartsWith(_loadedName) || _loadedName.Length == 0) _status.Text = state;

        if ((DateTime.UtcNow - _lastParams).TotalMilliseconds > 120)
        {
            _lastParams = DateTime.UtcNow;
            if (f != null && !_showGraph) _params.ItemsSource = Parameters(f);
            // a replay (or the slider) feeds the gauges every frame it passed, not just the one it landed on, so a fast replay draws the same line a slow one does
            int at = Engine.Running || _loaded.Count == 0 ? -1 : Math.Clamp((int)_pos.Value, 0, _loaded.Count - 1);
            if (at >= 0 && f != null && ReferenceEquals(f, _loaded[at])) { Gauges.Feed(_loaded, _fedIndex, at); _fedIndex = at; }
            else { Gauges.Show(f); _fedIndex = -1; }
        }
        if (!_compact && s != null && f != null) _compare.Text = Compare(f, s, source);
        // the graphs mark where the log is (the replay, the slider) or run live with the logger
        int where = Math.Clamp((int)_pos.Value, 0, Math.Max(0, _loaded.Count - 1));
        if (_showGraph) _graphPanel?.Follow(where, Engine.Running);
        _graph?.Panel.Follow(where, Engine.Running);
        if (!_compact && (DateTime.UtcNow - _lastCode).TotalMilliseconds > 700 && (_host.PlaybackActive || Engine.Running || _codeSince > 0))
        {
            _lastCode = DateTime.UtcNow;
            UpdateCodeList();
        }
    }

    static List<string> Parameters(LogFrame f)
    {
        var rows = new List<string>();
        foreach (var ch in f.Channels())
        {
            var v = f.Get(ch);
            if (v is not double d) continue;
            string unit = LogFrame.Units.GetValueOrDefault(ch, "");
            string text = ch is "vtec" or "fuel_pump" ? (d != 0 ? "ON" : "off") : d.ToString(Math.Abs(d) >= 1000 ? "0" : "0.###", CultureInfo.InvariantCulture);
            rows.Add($"{ch,-14} {text,10} {unit}");
        }
        if (f.Raw != null)
        {
            rows.Add("");
            rows.Add($"raw frame ({f.Raw.Length} bytes{(f.Protocol != null ? ", " + f.Protocol : "")}):");
            for (int i = 0; i < f.Raw.Length; i += 8)
                rows.Add($"  {i,2}: " + string.Join(" ", f.Raw.Skip(i).Take(8).Select(b => b.ToString("X2"))));
        }
        return rows;
    }

    static string Compare(LogFrame f, SimHost.Snapshot s, string source)
    {
        var o = s.Outputs;
        var inj = o.InjectorMs.Where(v => v > 0).DefaultIfEmpty(0).Average();
        string V(double? v, string fmt = "0.##") => v is double x ? x.ToString(fmt, CultureInfo.InvariantCulture) : "-";
        string B(bool? b) => b is bool x ? (x ? "on" : "off") : "-";
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"{source}   t = {f.T:F2} s");
        sb.AppendLine();
        sb.AppendLine("                     car (log)    simulator");
        sb.AppendLine($"RPM                  {V(f.Rpm, "0"),9}    {s.Rpm,9:0}");
        sb.AppendLine($"MAP kPa              {V(f.MapKpa, "0.0"),9}    {s.Map,9:0.0}");
        sb.AppendLine($"TPS %                {V(f.TpsPct, "0.0"),9}    {s.Tps,9:0.0}");
        sb.AppendLine($"ECT °C               {V(f.EctC, "0"),9}    {s.Ect,9:0}");
        sb.AppendLine($"IAT °C               {V(f.IatC, "0"),9}    {s.Iat,9:0}");
        sb.AppendLine($"O2 V                 {V(f.O2V, "0.00"),9}    {s.O2,9:0.00}");
        sb.AppendLine($"Battery V            {V(f.BattV, "0.0"),9}    {s.Vbatt,9:0.0}");
        sb.AppendLine($"Speed km/h           {V(f.SpeedKmh, "0"),9}    {s.SpeedKmh,9:0}");
        sb.AppendLine();
        sb.AppendLine("What the ECU does     car (log)    simulator   difference");
        string diff = f.InjMs is double lm && inj > 0 ? $"{(inj - lm) / Math.Max(0.01, lm) * 100,+6:+0;-0}%" : "";
        sb.AppendLine($"Injector pulse ms    {V(f.InjMs, "0.00"),9}    {(inj > 0 ? inj.ToString("0.00", CultureInfo.InvariantCulture) : "-"),9}   {diff}");
        sb.AppendLine($"Fuel pump            {B(f.FuelPump),9}    {B(o.FuelPump),9}   {(f.FuelPump is bool fp && fp != o.FuelPump ? "DIFFERS" : "")}");
        sb.AppendLine($"VTEC solenoid        {B(f.Vtec),9}    {B(o.Vtec),9}   {(f.Vtec is bool vt && vt != o.Vtec ? "DIFFERS" : "")}");
        sb.AppendLine($"Ignition ° (final)   {V(f.IgnDeg, "0.00"),9}");
        if (f.Get("afr") is double afr) sb.AppendLine($"Wideband AFR         {afr,9:0.00}");
        sb.AppendLine();
        sb.AppendLine("The simulator runs the ROM on screen with the car's sensor");
        sb.AppendLine("readings. Where the columns differ, the code (right) shows");
        sb.AppendLine("which path the simulated ECU took.");
        return sb.ToString();
    }

    /// Code labels whose code ran since the log started driving the simulator.
    void UpdateCodeList()
    {
        var asm = _host.Assembly;
        if (asm == null) return;
        var (now, exec, _, _) = _host.SimHits();
        ulong since = _codeSince;
        var labels = asm.Symbols.Values
            .Where(sy => sy.Kind == SymbolKind.Label && sy.Value >= 0x38 && sy.Value < Bus.RomSize && exec[sy.Value] > since)
            .OrderBy(sy => sy.Value).ToList();
        var rows = new List<string>();
        var addrs = new List<int>();
        foreach (var l in labels)
        {
            double ago = (now - Math.Min(now, exec[l.Value])) / Bus.CpuHz;
            rows.Add($"{l.Value:X4}  {l.Name,-30} {(ago < 0.05 ? "running" : $"{ago * 1000:0} ms ago"),12}");
            addrs.Add((int)l.Value);
        }
        _codeAddrs = addrs;
        _code.ItemsSource = rows.Count == 0 ? ["(nothing yet: play a log or connect)"] : rows;
    }

    public void Shutdown() => Engine.Dispose();
}
