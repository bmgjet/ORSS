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
    readonly TextBlock _status = new() { Text = "", FontSize = 11.5, Opacity = 0.9, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    /// The state at a glance: green logging, blue replaying, grey idle.
    readonly Avalonia.Controls.Shapes.Ellipse _stateDot = new() { Width = 9, Height = 9, Fill = DataList.Dim, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
    readonly TextBlock _stateText = new() { Text = "not connected", FontSize = 11.5, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    readonly DataList _params = new(new("Channel", 130), new("Value", 96), new("Unit", 60)) { RowHeight = 19, Empty = "No frame yet: connect, or load a log." };
    readonly CheckBox _rawBox = new() { Content = "raw bytes", FontSize = 11, MinHeight = 0, Padding = new Thickness(4, 0), VerticalAlignment = VerticalAlignment.Center };
    Border? _valuesCard;
    /// The gauges zoom on their own (Ctrl + wheel over them), apart from the rest of the datalog panel.
    ZoomHost? _gaugeZoom;
    string GaugeZoomKey => _compact ? "Tuner gauges" : "Gauges";

    /// Settings > Panel zoom changed: the gauges take theirs.
    public void ApplyGaugeZoom() { if (_gaugeZoom != null) _gaugeZoom.Zoom = Settings?.Invoke().Zoom(GaugeZoomKey) ?? 1; }

    ZoomHost GaugeZoom()
    {
        if (_gaugeZoom == null)
        {
            _gaugeZoom = new ZoomHost("Gauges", new Panel());
            _gaugeZoom.ZoomChanged += (_, z) =>
            {
                if (Settings?.Invoke() is { } s) s.PanelZoom[GaugeZoomKey] = z;
                _status.Text = $"gauges zoom {z * 100:0}% (Ctrl + wheel over them; reset in Settings > Panel zoom)";
            };
        }
        _gaugeZoom.Child = null;
        _gaugeZoom.Zoom = Settings?.Invoke().Zoom(GaugeZoomKey) ?? 1;
        _gaugeZoom.Child = UiStyles.Adopt(Gauges);
        return UiStyles.Adopt(_gaugeZoom);        // out of the card of the layout before
    }
    /// Graph <-> the frame's values, at the top of the panel.
    readonly Button _viewBtn = new() { Margin = new Thickness(6, 1, 2, 1), FontSize = 11.5, Padding = new Thickness(8, 3) };
    readonly CheckBox _smoothBox = new() { Content = "Smooth values", FontSize = 11.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0) };
    /// The gauges built on this page (and any floating widgets made from them).
    public GaugePanel Gauges { get; }
    readonly DataList _compare = new(new("Reading", 150), new("Car (log)", 90), new("Simulator", 90), new("Difference", 90))
    {
        RowHeight = 19, Empty = "No log yet. Connect (the port is set in Settings > Emulator & datalog), or Load log…",
    };
    readonly DataList _code = new(new("Addr", 56), new("Routine", 220), new("Ran", 90)) { RowHeight = 19, Empty = "Nothing yet: play a log or connect." };
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
    DateTime _lastCode, _lastParams, _lastGauges;
    // playback without a simulator (Tuner mode): step through frames in wall time ~30 steps a second: the replay (and its gauges, values and graph cursor) moves as smoothly as it plays
    readonly DispatcherTimer _playTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    DateTime _playWallStart; double _playLogStart; int _playIndex = -1;

    public bool DriveSimulator { get; set; } = true;
    public string Port { get; set; } = "";
    /// The emulator's port from Settings: not to be guessed for the datalog.
    public string EmulatorPort { get; set; } = "";
    public string Protocol { get; set; } = "auto";
    /// The channel stream's channels (read and kept by the main window, in the settings).
    public Func<List<string>>? GetStreamChannels;
    public Action<List<string>>? SetStreamChannels;
    /// What the stream sends to the ECU's serial inputs (SerialInputMap.Save), kept the same way.
    public Func<List<string>>? GetSerialInputs;
    public Action<List<string>>? SetSerialInputs;

    /// The port, protocol and line speed from Settings. Changed while logging, the link starts again with them, so the values and the graph show what the new link sends.
    public void SetLink(string port, string protocol, int baud)
    {
        bool changed = Port != port || !Protocol.Equals(protocol, StringComparison.OrdinalIgnoreCase) || Baud != baud;
        Port = port; Protocol = protocol; Baud = baud;
        if (changed && (Engine.Running || Engine.Watch.Wanted) && Engine.External == null && !_connecting) Reconnect("the datalog settings changed");
    }

    /// Stop the link and start it again with the settings as they are now (off the UI thread: both wait on the cable).
    void Reconnect(string why)
    {
        var port = ChosenPort();
        if (port.Length == 0) return;
        _connecting = true;
        _connect.IsEnabled = false;
        _status.Text = why + ": connecting again…";
        AppLog.Action("datalog", why + $": reconnect {port} ({Protocol}, {Baud})");
        Task.Run(() =>
        {
            string? error = null;
            try { Engine.Stop(); Engine.Start(port, Protocol, Baud); }
            catch (Exception ex) { error = ex.Message; AppLog.Error("datalog", "reconnect failed", ex); }
            Dispatcher.UIThread.Post(() =>
            {
                _connecting = false;
                _connect.IsEnabled = true;
                UpdateConnect();
                if (error != null) _status.Text = "cannot open the port: " + error;
            });
        });
    }

    /// The port set in Settings; with none, the first one that is not the emulator's.
    string ChosenPort() => Port.Length > 0 ? Port
        : SerialLink.Ports().FirstOrDefault(p => !p.Equals(_host.Emulator.PortName, StringComparison.OrdinalIgnoreCase)
                                                 && !p.Equals(EmulatorPort, StringComparison.OrdinalIgnoreCase)) ?? "";
    public int Baud { get; set; } = 38400;
    public event Action<int>? GoToAddress;
    /// Every frame the page shows (live, played back or selected), for the calibration trace.
    public event Action<LogFrame?>? CurrentFrameChanged;
    /// A reading to show on the maps (the dyno's double-click): the calibration page puts the engine's place on the table open.
    public event Action<LogFrame>? ShowOnMaps;
    public void ShowFrameOnMaps(LogFrame f) => ShowOnMaps?.Invoke(f);
    /// Open Settings at a page ("Dyno", "Units").
    public event Action<string>? OpenSettingsPage;
    public void OpenSettingsAt(string page) => OpenSettingsPage?.Invoke(page);
    /// Settings changed from a window of this page (the dyno's): saved, and applied.
    public event Action? SettingsChanged;
    public void SaveSettings() => SettingsChanged?.Invoke();
    /// Settings were saved or applied (units, the dyno's): windows of this page show them.
    public event Action? SettingsApplied;
    public void RaiseSettingsApplied() => SettingsApplied?.Invoke();
    internal SimHost Host => _host;
    public LogFrame? Current { get; private set; }

    /// Where the panel sizes are kept (AppSettings.PanelSizes): the app's settings as they are now.
    public Func<AppSettings>? Settings { get; }

    /// Panes side by side (or one above another) with a divider between each pair that can be dragged; the sizes are remembered under `key`. `defaults` are GridLength strings, one per pane ("300", "3*").
    Grid Split(string key, bool across, string[] defaults, params Control[] panes)
    {
        var saved = Settings?.Invoke().PanelSizes.TryGetValue(key, out var t) == true ? t.Split('|') : [];
        var sizes = saved.Length == panes.Length ? saved : defaults;
        var g = new Grid();
        for (int i = 0; i < panes.Length; i++)
        {
            GridLength len;
            try { len = GridLength.Parse(sizes[i]); } catch { len = GridLength.Parse(defaults[i]); }
            if (i > 0)
            {
                var gs = new GridSplitter
                {
                    ResizeDirection = across ? GridResizeDirection.Columns : GridResizeDirection.Rows,
                    Background = AppTheme.Brush(Color.FromArgb(70, 255, 255, 255)),
                };
                if (across) { gs.Width = 6; gs.VerticalAlignment = VerticalAlignment.Stretch; } else { gs.Height = 6; gs.HorizontalAlignment = HorizontalAlignment.Stretch; }
                ToolTip.SetTip(gs, "Drag to make the panels either side larger or smaller (remembered). Reset panels puts them back.");
                gs.DragCompleted += (_, _) =>
                {
                    if (Settings?.Invoke() is not { } s) return;
                    var now = across ? g.ColumnDefinitions.Where((_, k) => k % 2 == 0).Select(d => d.Width) : g.RowDefinitions.Where((_, k) => k % 2 == 0).Select(d => d.Height);
                    s.PanelSizes[key] = string.Join("|", now.Select(l => l.ToString()));
                };
                if (across) { g.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto)); Grid.SetColumn(gs, g.ColumnDefinitions.Count - 1); }
                else { g.RowDefinitions.Add(new RowDefinition(GridLength.Auto)); Grid.SetRow(gs, g.RowDefinitions.Count - 1); }
                g.Children.Add(gs);
            }
            if (across) { g.ColumnDefinitions.Add(new ColumnDefinition(len) { MinWidth = 80 }); Grid.SetColumn(panes[i], g.ColumnDefinitions.Count - 1); }
            else { g.RowDefinitions.Add(new RowDefinition(len) { MinHeight = 60 }); Grid.SetRow(panes[i], g.RowDefinitions.Count - 1); }
            g.Children.Add(panes[i]);
        }
        return g;
    }

    /// Put the dragged panel sizes back to how they start.
    void ResetPanels()
    {
        if (Settings?.Invoke() is { } s) { s.PanelSizes.Remove("Datalog.simulator"); s.PanelSizes.Remove("Datalog.tuner"); }
        SetCompact(_compact);
        _status.Text = "panels put back to their starting sizes";
    }

    public DatalogView(SimHost host, Func<TopLevel?> top, Func<AppSettings>? settings = null)
    {
        _host = host; _top = top; Settings = settings;
        Engine = new DatalogEngine(host);
        Gauges = new GaugePanel(Channels, top);
        Engine.Watch.Message += m => Dispatcher.UIThread.Post(() => { _status.Text = m; UpdateConnect(); });
        _connect = Btn("Connect", ToggleConnect, "Start or stop logging on the port set in Settings > Emulator & datalog ('simulator' logs the ROM running here, through its own serial port).");
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
        ToolTip.SetTip(_params, "Every value in the latest frame: decoded, with its unit and the raw byte(s). Wideband and aux channels (Settings > Emulator & datalog) are added at the bottom.\n\n" +
                                "Pick several: Ctrl+click, Shift+click, or drag a box over them (Ctrl+A all). Right-click for gauges of the ones picked.");
        _params.MultiSelect = true;
        _params.SelectionMenu = ValuesMenu;
        ToolTip.SetTip(Gauges, "Your own gauges: dials, bars, numbers, trigger lights and rolling graphs of any logged channel. Create widget floats one over everything else.");
        ToolTip.SetTip(_compare, "The frame's readings from the car next to what the simulated ECU is doing with them.");
        ToolTip.SetTip(_code, "Routines and branches of the assembly that ran since the log started driving the simulator, in address order. Double-click to go to one.");
        _code.Activated += r => { if (r.Address >= 0) GoToAddress?.Invoke(r.Address); };
        ToolTip.SetTip(_rawBox, "Show the frame's bytes as the ECU sent them, under the values.");
        _rawBox.IsCheckedChanged += (_, _) => { if (Current != null) ShowParameters(Current); };
        ToolTip.SetTip(_smoothBox, "Take the noise out of the values: a reading far from the ones either side of it (6000 rpm, 28 rpm, 6000 rpm) is dropped as a " +
                                   "spike and the good readings are blended. How many frames and how far is a spike: Settings > Emulator & datalog.");
        _viewBtn.Click += (_, _) => ShowGraph(!_showGraph);
        ShowViewButton();
        _smoothBox.IsCheckedChanged += (_, _) => { if (_smoothBox.IsChecked == true != Engine.Smooth.Enabled) SetSmoothing(_smoothBox.IsChecked == true); };
        Content = _body;
        SetCompact(false);
    }

    /// Datalogging > Smooth values (and the box on the page): on or off, remembered.
    public void SetSmoothing(bool on)
    {
        Engine.Smooth.Enabled = on;
        Engine.Smooth.Reset();
        _smoothBox.IsChecked = on;
        if (Settings?.Invoke() is { } s) { s.DatalogSmooth = on; s.Save(); }
        _status.Text = on ? $"smoothing: spikes dropped, {Engine.Smooth.Frames} frames blended" : "smoothing off: values as they come";
        AppLog.Action("datalog", on ? "smoothing on" : "smoothing off");
    }

    /// Datalog > Channels…: the channel stream's channels, ticked in a list.
    public async Task OpenChannels()
    {
        if (_top() is not Window owner) return;
        var w = new DatalogChannelsWindow(GetStreamChannels?.Invoke() ?? [.. DatalogChannels.Defaults], GetSerialInputs?.Invoke() ?? [],
                                          Engine.Protocol as ChannelStream, Channels());
        await Dialogs.ShowModal(w, owner);
        if (w.Result is not { } r) return;
        SetStreamChannels?.Invoke(r);
        ChannelStream.Selected = r;
        if (w.Inputs is { } inputs)
        {
            SetSerialInputs?.Invoke([.. inputs.Select(m => m.Save())]);
            Engine.SerialInputs = inputs;
        }
        var picks = DatalogChannels.Picks(r);
        var (fps, slowEvery) = DatalogChannels.Rate(picks);
        // logging now: the ROM gets the new list between frames, and the values and the graph follow it
        bool live = Engine.Reconfigure();
        // logging with a protocol whose frame is fixed (the HTS 20h frame a skeleton ROM also answers): the picks change nothing until it is the channel stream - offered, and the link started again with it
        if (!live && Engine.Running && Engine.Protocol is not ChannelStream && Engine.External == null &&
            await Dialogs.Confirm(owner, "Use the channel stream?",
                $"The datalog is connected with {Engine.Protocol?.Name ?? "a protocol"}, which always sends the same frame: the channels picked are only sent by the channel stream (a skeleton ROM with its datalog). Connect again with the channel stream now?",
                "Connect with the channel stream", "Not now"))
        {
            var port = ChosenPort();
            await Task.Run(() => { try { Engine.Stop(); Engine.Start(port, "Channel stream", Baud); } catch (Exception ex) { AppLog.Error("datalog", "reconnect failed", ex); } });
            live = true;
        }
        // what the ROM cannot send is said, not dropped quietly: the stream reports it once the new list is taken
        if (live) _ = Task.Run(async () =>
        {
            await Task.Delay(1500);
            if (Engine.Protocol is ChannelStream { Dropped.Count: > 0 } cs2)
                Dispatcher.UIThread.Post(() => _status.Text = $"not in this ROM, so not logged: {string.Join(", ", cs2.Dropped)}. " +
                    (cs2.TableSize < DatalogChannels.TableSizeAll ? "Add 'Datalogging: every channel' (File > Change functions) to log them." : ""));
        });
        _status.Text = $"channel stream: {picks.Count} channel(s), {DatalogChannels.FrameBytes(picks)} bytes a frame, about {fps:0} frames a second" +
                       (slowEvery > 0 ? $", each slow one every {(slowEvery < 1 ? $"{slowEvery * 1000:0} ms" : $"{slowEvery:0.0} s")}" : "") +
                       (live ? " - sent to the ECU" : Engine.Running ? " - used from the next connect (this protocol picks no channels)" : " - used from the next connect");
        AppLog.Action("datalog", "stream channels: " + string.Join(", ", r));
    }

    /// The layout check: channels picked as the Channels window would.
    internal void SetPicksForCheck(string[] picks)
    {
        SetStreamChannels?.Invoke([.. picks]);
        ChannelStream.Selected = [.. picks];
        Engine.Reconfigure();
    }

    /// The channels the values list shows now.
    internal List<string> ShownParameterNames() => [.. _shownNames];
    List<string> _shownNames = [];

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
        foreach (var c in new Control[] { _connect, _pos, _posText, _status, _paramHost, Gauges, _compare, _code, _rawBox, _smoothBox, _stateDot, _stateText }) Detach(c);
        UiStyles.Adopt(_params);
        if (_graphPanel != null) UiStyles.Adopt(_graphPanel);
        _paramHost.Content = _showGraph ? GraphPanel() : _params;
        var row1 = new WrapPanel { Margin = new Thickness(6, 4), VerticalAlignment = VerticalAlignment.Center };
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
        row1.Children.Add(Btn("Channels…", () => _ = OpenChannels(),
            "Pick what the channel stream logs (the skeleton ROM's datalog module): a box for every value it can send - untick what the car does not have."));
        row1.Children.Add(Btn("Detect layout", DetectLayout,
            "Work out how this ROM datalogs, from the ROM itself: its serial code is read for the command bytes it answers, each is tried in a simulator " +
            "until one returns a checksummed frame, and then every engine input is changed in turn to see which byte of the frame follows it."));
        row1.Children.Add(_smoothBox);
        }
        var row2 = new WrapPanel { Margin = new Thickness(0, 2), VerticalAlignment = VerticalAlignment.Center };
        row2.Children.Add(Btn("▶ Play", Play, compact ? "Replay the loaded log in real time: the map marks where the engine was, frame by frame." :
            "Run the simulator from the selected frame, stepping through the log in simulated time."));
        row2.Children.Add(Btn("❚❚ Pause", Pause, "Hold the replay on the frame it is on: Play carries on from there (the slider and ◀ ▶ still move it)."));
        row2.Children.Add(Btn("■ Stop", StopAll, "Stop playback and stop logging (disconnects the port)."));
        row2.Children.Add(Btn("◀", () => StepFrame(-1), "Previous frame."));
        row2.Children.Add(Btn("▶", () => StepFrame(1), "Next frame."));
        row2.Children.Add(_pos);
        row2.Children.Add(_posText);
        UiStyles.Adopt(_viewBtn);
        row2.Children.Add(_viewBtn);
        _status.Margin = new Thickness(0, 2, 0, 0);
        var state = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        state.Children.Add(_stateDot); state.Children.Add(_stateText);
        // the log's controls and how it is going, in a card of their own
        var logBox = new StackPanel { Margin = new Thickness(10, 0, 10, 8) };
        logBox.Children.Add(row2);
        logBox.Children.Add(_status);
        var logCard = Panels.Card(compact ? "Datalog" : "Log", logBox, state);

        if (compact)
        {
            // the log and the frame's values on top, gauges below them, with a splitter between: the gauges start a little under half the panel and can be dragged as large as the screen allows, which matters on a big monitor where the rest is empty space
            var upper = new DockPanel();
            DockPanel.SetDock(logCard, Dock.Top);
            upper.Children.Add(logCard);
            upper.Children.Add(_valuesCard = Panels.Card(_showGraph ? "Graph" : "Values", _paramHost, _rawBox));

            Gauges.Height = double.NaN;
            var lower = Panels.Card("Gauges", GaugeZoom());

            var split = Split("Datalog.tuner", false, ["5*", "4*"], upper, lower);
            split.Margin = new Thickness(8, 8, 8, 0);
            _body.Content = split;
        }
        else
        {
            row1.Children.Add(Btn("Clear code list", () => { _codeSince = _host.Sim.Cpu.Cycles; _code.SetRows([]); }, "Start the 'code that ran' list afresh from now."));
            row1.Children.Add(Btn("Reset panels", ResetPanels, "Put the panels back to the sizes they start at (the dividers between them can be dragged, and are remembered)."));
            var p1 = _valuesCard = Panels.Card(_showGraph ? "Graph" : "Values", _paramHost, _rawBox);
            Gauges.Height = double.NaN;
            var p2 = Panels.Card("Gauges", GaugeZoom());
            var p3 = Panels.Card("Car and simulator", _compare);
            var p4 = Panels.Card("Code that ran for this log", _code);
            // the gauges get the most room to start with; every divider can be dragged
            var body = Split("Datalog.simulator", true, ["2*", "5*", "1.5*", "1.5*"], p1, p2, p3, p4);
            var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*") };
            var bar = Panels.BarAround(row1);
            Grid.SetRow(bar, 0); g.Children.Add(bar);
            logCard.Margin = new Thickness(8, 8, 8, 0);
            Grid.SetRow(logCard, 1); g.Children.Add(logCard);
            Grid.SetRow(body, 2); g.Children.Add(body);
            body.Margin = new Thickness(8, 8, 8, 4);
            _body.Content = g;
        }
        UpdateConnect();
    }

    // ------------------------------------------------------------------ live

    bool _resumeAfterEmulator;

    /// Something else needs the emulator's port for a while (Demon onboard logging): the datalog through it stops, and ResumeAfterEmulator starts it again. Runs on the UI thread; the stop itself waits for the logging thread.
    public void PauseForEmulator()
    {
        _resumeAfterEmulator = Engine.Running;
        if (!_resumeAfterEmulator) return;
        try { Engine.Stop(); } catch (Exception ex) { AppLog.Error("datalog", "stop failed", ex); }
        UpdateConnect();
        _status.Text = "paused: the emulator's port is busy";
    }

    public void ResumeAfterEmulator()
    {
        if (!_resumeAfterEmulator) return;
        _resumeAfterEmulator = false;
        if (!Engine.Running) ToggleConnect();
    }

    /// Frames from somewhere other than a file (the Demon's onboard sessions), shown and replayed like a loaded log.
    public void LoadFrames(List<LogFrame> frames, string name)
    {
        _loaded = frames;
        foreach (var f in _loaded) Engine.Enrich(f);
        SmoothLoaded();
        _loadedName = name;
        _settingPos = true;
        _pos.Maximum = Math.Max(0, _loaded.Count - 1);
        _pos.Value = 0;
        _settingPos = false;
        ShowFrame(0);
        if (_loaded.Count > 0) SetCurrent(_loaded[0]);
        _status.Text = $"{name}: {_loaded.Count} frames, {(_loaded.Count > 0 ? _loaded[^1].T : 0):F1} s. Play replays it.";
        AppLog.Action("datalog", $"loaded {name} ({_loaded.Count} frames)");
    }

    /// A plugin driving the emulator and its datalog in place of the app's own link, or null.
    public Func<IEmulatorTakeover?>? Takeover { get; set; }

    void ToggleConnect()
    {
        if (Takeover?.Invoke() is { } t) { t.ToggleConnect(); UpdateConnect(); return; }
        if (Engine.Running || _connecting || Engine.Watch.Wanted)
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
        // no port set: the first one - but never the emulator's (the one it has open, or is set to use), which a guess used to take whenever the emulator was not connected at that moment, and then held on to
        var port = ChosenPort();
        if (port.Length == 0) { _status.Text = "no serial port: pick one in Settings > Emulator & datalog (or 'simulator' to log the ROM running here)"; return; }
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
    ServiceWindow? _service;
    void OpenService()
    {
        if (_top() is not Window owner) return;
        if (_service is { } open) { try { open.Activate(); return; } catch { _service = null; } }
        var w = new ServiceWindow(Engine, _host);
        _service = w;
        w.Closed += (_, _) => { if (ReferenceEquals(_service, w)) _service = null; };
        w.Show(owner);
    }

    DynoWindow? _dyno;

    /// The dyno as it is (for a project): the profile picked and the runs ticked, or null when it is closed.
    public (string Profile, List<string> Ticked)? DynoState() => _dyno?.ViewState();

    /// A project opened: the dyno shows what it showed when it was saved (opened if it was open; one already open reloads its runs).
    public void RestoreDyno(bool open, string profile, List<string> ticked)
    {
        if (_dyno == null && !open) return;
        if (_dyno == null) OpenDyno();
        _dyno?.RestoreView(profile, ticked);
    }

    void OpenDyno()
    {
        if (_top() is not Window owner) return;
        if (_dyno is { } open) { try { open.Activate(); return; } catch { _dyno = null; } }
        var w = new DynoWindow(this);
        _dyno = w;
        w.Closed += (_, _) => { if (ReferenceEquals(_dyno, w)) _dyno = null; };
        w.Show(owner);
    }

    void OpenOnboard()
    {
        if (_top() is not Window owner) return;
        new OnboardWindow(_host, this, Settings).Show(owner);
    }

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
    IReadOnlyList<LogFrame> GraphFrames()
    {
        if (!Engine.Running) return Log();
        // live, the graph asks on every tick and each answer is a copy of the whole recording (up to 50,000 frames: 400 KB on the large-object heap, many times a second). The graph only redraws a few times a second, so one copy serves a quarter of a second.
        long now = Environment.TickCount64;
        if (_graphSnap == null || now - _graphSnapAt >= 250) { _graphSnap = Engine.Frames(); _graphSnapAt = now; }
        return _graphSnap;
    }
    List<LogFrame>? _graphSnap;
    long _graphSnapAt;

    /// The graph for the top of the panel, made the first time it is asked for.
    DatalogGraphPanel GraphPanel() => _graphPanel ??= new DatalogGraphPanel(GraphFrames, Seek, compact: true);

    /// A graph cursor moved: take the rest of the page with it, so the map's trace marker follows.
    void Seek(int i)
    {
        var log = Log();
        if (i < 0 || i >= log.Count) return;
        // replaying: carry on from the frame picked on the graph (a click or a double-click there jumps the replay to it)
        if (_playTimer.IsEnabled)
        {
            _playIndex = i;
            _playWallStart = DateTime.Now;
            _playLogStart = log[i].T;
            _playShown = -1;
            _status.Text = $"replaying from frame {i + 1} of {log.Count} at {_rate:0.#}x";
        }
        _settingPos = true;
        _pos.Value = i;
        _settingPos = false;
        ShowFrame(i);
        SetCurrent(log[i]);
    }

    void ShowViewButton()
    {
        _viewBtn.Content = _showGraph ? "≡ Values" : "📈 Graph";
        ToolTip.SetTip(_viewBtn, _showGraph ? "Show the frame's values instead of the graph." : "Show the log as a graph instead of the frame's values.");
    }

    /// What a project keeps of the datalog: the frames loaded (or recorded), the name, where the slider was.
    public (IReadOnlyList<LogFrame> Frames, string Name, int Position) SavedLog()
    {
        var log = _loaded.Count > 0 ? _loaded : Engine.Frames();
        return (log, _loadedName.Length > 0 ? _loadedName : "recording", Math.Clamp((int)_pos.Value, 0, Math.Max(0, log.Count - 1)));
    }

    /// A project opened with a datalog in it: the frames back, at the frame the slider was on.
    public void RestoreLog(List<LogFrame> frames, string name, int position)
    {
        LoadFrames(frames, name);
        if (frames.Count > 0) Seek(Math.Clamp(position, 0, frames.Count - 1));
    }

    /// The UI check: replay a made-up log.
    internal void PlayForCheck() => Play();

    /// Hold the replay where it is; Play carries on from that frame.
    void Pause()
    {
        if (_playTimer.IsEnabled)
        {
            _playTimer.Stop();
            _playIndex = -1;
            _host.StopPlayback();
            _status.Text = $"paused at frame {(int)_pos.Value + 1} of {Log().Count} - Play carries on from here";
            AppLog.Action("datalog", $"paused at frame {(int)_pos.Value}");
            ShowState();
            return;
        }
        _status.Text = Engine.Running ? "logging live: Stop ends it, and what was recorded can then be replayed and paused" : "nothing is playing";
    }

    /// Put the graph (true) or the parameter list at the top of the panel.
    public void ShowGraph(bool graph)
    {
        _showGraph = graph;
        UiStyles.Adopt(_params);
        if (_graphPanel != null) UiStyles.Adopt(_graphPanel);
        _paramHost.Content = graph ? GraphPanel() : _params;
        if (_valuesCard != null) Panels.Retitle(_valuesCard, graph ? "Graph" : "Values");
        ShowViewButton();
        if (!graph && Current != null) ShowParameters(Current);
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
        Takeover?.Invoke() is { } t
            ? new Toolbar.Entry(Toolbar.Log, (t.Connected ? "Disconnect " : "Connect ") + t.Name,
                $"{t.Name} is in charge of the emulator and its datalog: its device's link. {t.Status}", ToggleConnect)
            : new Toolbar.Entry(Toolbar.Log, Engine.Running ? "Disconnect" : "Connect",
                "Start or stop logging on the port set in Settings > Emulator & datalog ('simulator' logs the ROM running here, through its own serial port).", ToggleConnect),
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
        new Toolbar.Entry("", "Smooth values",
            "Take the noise out of the values: a reading far from the ones either side of it (6000 rpm, 28 rpm, 6000 rpm) is dropped as a spike and " +
            "the good readings are blended. How many frames and how far is a spike: Settings > Emulator & datalog.",
            () => SetSmoothing(!Engine.Smooth.Enabled), Checked: () => Engine.Smooth.Enabled),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Log, "Channels…", "Pick what the channel stream logs (the skeleton ROM's datalog module): untick what the car does not have.", () => _ = OpenChannels()),
        Toolbar.Entry.Line,
        new Toolbar.Entry(Toolbar.Detect, "Codes and service…",
            "The trouble codes the ECU has stored and its check-engine lamp, read from the datalog, with Clear codes; on the skeleton ROM also injectors off, " +
            "timing locked for a timing light, the maps picked and the GIO outputs forced on - over the datalog cable.", OpenService),
        new Toolbar.Entry(Toolbar.Gauge, "Virtual dyno…",
            "Power and torque from the datalog: an inertia dyno (the car spins a roller of known inertia) or a strip run (the car's own weight on a " +
            "straight, flat stretch). Triggers start and stop each run; runs are kept, replayed, overlaid, raced head to head and printed.", OpenDyno),
        new Toolbar.Entry(Toolbar.Log, "Demon onboard logging…",
            "Set up a Moates Demon to log the ECU by itself, into its own memory, with no laptop in the car; read its sessions back here.", OpenOnboard),
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

    public void Stop() { if (Engine.Running || Engine.Watch.Wanted) ToggleConnect(); }
    /// Start logging on the port set in Settings, unless it is already going.
    public void Start() { if (!(Engine.Running || _connecting || Engine.Watch.Wanted)) ToggleConnect(); }

    public void UpdateConnect() => _connect.Content = Takeover?.Invoke() is { } t ? (t.Connected || t.Connecting ? "Disconnect" : "Connect")
                                                   : Engine.Running || Engine.Watch.Wanted ? "Disconnect" : "Connect";

    /// The state of the link to the car, for the dot on the Datalogging menu.
    public (LinkState State, string Tip) LinkStatus()
    {
        if (Takeover?.Invoke() is { } t)
            return t.Connected && Engine.Fresh ? (LinkState.Connected, $"Datalogging: {t.Name} - {Engine.FramesPerSecond:0} frames a second")
                 : t.Connected || t.Connecting ? (LinkState.Reconnecting, $"Datalogging: {t.Name} - {t.Status}")
                 : (LinkState.Off, $"Datalogging: {t.Name} is not connected. Connect it from this menu.");
        if (Engine.External is { } ext)
            return Engine.Fresh ? (LinkState.Connected, $"Datalogging: {Engine.Status} ({Engine.FramesPerSecond:0} frames a second)")
                                : (LinkState.Reconnecting, $"Datalogging: waiting for frames from {ext}");
        var w = Engine.Watch;
        return w.State switch
        {
            LinkState.Connected => (LinkState.Connected, $"Datalogging: connected - {Engine.Status} ({Engine.FramesPerSecond:0} frames a second)"),
            LinkState.Reconnecting => (LinkState.Reconnecting, w.Attempt == 0 ? "Datalogging: connecting - " + Engine.Status
                                                                               : $"Datalogging: the link was lost - trying again ({w.Attempt} of {LinkSupervisor.Attempts})"),
            _ => (LinkState.Off, "Datalogging: not connected. " + (Engine.Status.Length > 0 ? Engine.Status : "") ),
        };
    }

    void OnLiveFrame(LogFrame f)
    {
        // feeding the simulator the car's readings makes no sense when the simulator is the source
        if (DriveSimulator && !_compact && Engine.Source != "simulator") _host.ApplyFrame(f);
        // where the engine is goes to the map as each frame arrives, not on the next screen refresh: the cell lit (and the one Lock to live cell edits) is the one this frame says. Frames that come quicker than the screen can take are folded into one: only the newest is shown
        if (Interlocked.Exchange(ref _framePosted, 1) == 0)
            Dispatcher.UIThread.Post(() =>
            {
                Volatile.Write(ref _framePosted, 0);
                if (Engine.Running && Engine.Latest is { } latest && !ReferenceEquals(latest, Current) && !_playTimer.IsEnabled && !_host.PlaybackActive)
                    SetCurrent(latest);
            }, DispatcherPriority.Input);
    }
    int _framePosted;

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
        _params.SetRows([]);
        _codeAddrs = [];
        _code.SetRows([]);
        _codeSince = 0;
        _settingPos = true;
        _pos.Maximum = 0; _pos.Value = 0;
        _settingPos = false;
        _posText.Text = "";
        SetCurrent(null);
        _compare.SetRows([]);
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

    /// The channels on offer: the live ones while logging, else every channel of the log loaded (not what an earlier session logged).
    public IEnumerable<string> Channels() =>
        Engine.Running && Engine.Latest is { } live ? live.Channels()
        : _loaded.Count > 0 ? LogFrame.AllChannels(_loaded)
        : (Current ?? Engine.Latest)?.Channels() ?? [];

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
                FileTypeFilter = new[]
                {
                    new FilePickerFileType("Datalogs") { Patterns = new[] { "*.rlog", "*.csv", "*.hdl", "*.hml", "*.dlf", "*.bml", "*.log" } },
                    new FilePickerFileType("Rom Sim Studio logs (.rlog)") { Patterns = new[] { "*.rlog" } },
                    new FilePickerFileType("CSV") { Patterns = new[] { "*.csv" } },
                    new FilePickerFileType("Binary datalogs (.hdl .hml .dlf .bml .log)") { Patterns = new[] { "*.hdl", "*.hml", "*.dlf", "*.bml", "*.log" } },
                    new FilePickerFileType("All files") { Patterns = new[] { "*.*" } },
                },
            });
            var path = files.FirstOrDefault()?.TryGetLocalPath();
            if (path != null) LoadFile(path);
        }
        catch (Exception ex) { _status.Text = "cannot read the log: " + ex.Message; AppLog.Error("datalog", "load failed", ex); }
    }

    /// An .rlog also carries the ROM the car was running (PROG) and the tuning settings (SET).
    public event Action<byte[], string>? RomFromLog;

    /// Smoothing on: a loaded log is smoothed as it is read, as a live one would have been.
    void SmoothLoaded()
    {
        if (!Engine.Smooth.Enabled || _loaded.Count == 0) return;
        Engine.Smooth.Reset();
        foreach (var f in _loaded) Engine.Smooth.Apply(f);
        AppLog.Info("datalog", $"smoothed the loaded log: {Engine.Smooth.Dropped} spike reading(s) dropped");
        Engine.Smooth.Reset();
    }

    public string LoadFile(string path)
    {
        // a log opened while logging live is what gets looked at: the live link stops (its frames are kept), or its values would go on hiding the log's
        if (Engine.Running && !UiCheck.Active)
        {
            Task.Run(() => { try { Engine.Stop(); } catch (Exception ex) { AppLog.Error("datalog", "stop failed", ex); } });
            AppLog.Action("datalog", "live logging stopped to look at a log file");
        }
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
        SmoothLoaded();
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
        _playShown = -1;
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
        if (_playIndex == _playShown) return;                   // nothing new to show this step
        _playShown = _playIndex;
        _settingPos = true; _pos.Value = _playIndex; _settingPos = false;
        ShowFrame(_playIndex);
        var f = log[_playIndex];
        SetCurrent(f);
        if (DriveSimulator && !_compact && _host.LoadedPath != null) _host.ApplyFrame(f);
        FrameViews(f, _playIndex);
        if (_playIndex + 1 >= log.Count) { _playTimer.Stop(); _status.Text = $"replay finished ({log.Count} frames)"; }
    }

    int _playShown = -1;

    /// The views that follow the frame (values, gauges, the graph cursor), drawn straight from the replay's own timer: the window's refresh is slower, to keep a laptop's CPU free, and would make the replay judder.
    void FrameViews(LogFrame f, int index)
    {
        var now = DateTime.UtcNow;
        if (!_showGraph && (now - _lastParams).TotalMilliseconds >= Perf.ValuesMs) { ShowParameters(f); _lastParams = now; }
        // the gauges take every frame passed since they were fed, so a slower pace draws the same line
        if ((now - _lastGauges).TotalMilliseconds >= Perf.GaugesMs || index + 1 >= _loaded.Count)
        {
            Gauges.Feed(_loaded, _fedIndex, index);
            _fedIndex = index;
            _lastGauges = now;
        }
        if (_showGraph) _graphPanel?.Follow(index, false);
        _graph?.Panel.Follow(index, false);
    }

    /// The frame's values, the list changed line by line instead of made again (no flicker, far less work).
    void ShowParameters(LogFrame f) { _shownNames = [.. f.Channels()]; _params.SetRows(ParameterRows(f, _rawBox.IsChecked == true)); }

    /// The values list's right-click menu: gauges of the values picked (on the dashboard or floating), copy them, graph them.
    IEnumerable<(string, Action)> ValuesMenu(IReadOnlyList<DataList.Row> rows)
    {
        var f = Current;
        var picked = rows.Select(r => r.Cells[0].Text).Where(ch => f?.Get(ch) is double).ToList();
        if (picked.Count == 0) yield break;
        List<(string, double)> Values() => [.. picked.Select(ch => (ch, Current?.Get(ch) ?? double.NaN))];
        string n = picked.Count == 1 ? picked[0] : $"{picked.Count} values";
        yield return ($"Add gauges for {n}", () => Gauges.AddFor(Values(), null, widget: false));
        yield return ("Add as dials", () => Gauges.AddFor(Values(), GaugeKind.Dial, false));
        yield return ("Add as bars", () => Gauges.AddFor(Values(), GaugeKind.Bar, false));
        yield return ("Add as numbers", () => Gauges.AddFor(Values(), GaugeKind.Number, false));
        yield return ("Add as rolling graphs", () => Gauges.AddFor(Values(), GaugeKind.Graph, false));
        yield return ("Add as lamps", () => Gauges.AddFor(Values(), GaugeKind.Light, false));
        yield return ("-", () => { });
        yield return ($"Float {(picked.Count == 1 ? "it" : "them")} in a widget", () => Gauges.AddFor(Values(), null, widget: true));
        yield return ("Copy (name, value, unit)", () => CopyValues(picked));
    }

    async void CopyValues(List<string> channels)
    {
        if (TopLevel.GetTopLevel(this)?.Clipboard is not { } cb || Current is not { } f) return;
        var lines = channels.Select(ch => f.Get(ch) is double v ? $"{ch}\t{LogFrame.Shown(ch, v).Value.ToString("0.###", CultureInfo.InvariantCulture)}\t{LogFrame.Shown(ch, v).Unit}" : ch);
        await cb.SetTextAsync(string.Join(Environment.NewLine, lines));
        _status.Text = $"copied {channels.Count} value(s)";
    }

    /// The values list, the UI check's way in.
    internal DataList ValuesForCheck => _params;

    /// The frame's values as rows: the channel, its value and unit; the raw bytes under them when asked for.
    static List<DataList.Row> ParameterRows(LogFrame f, bool raw)
    {
        var rows = new List<DataList.Row>();
        foreach (var ch in f.Channels())
        {
            if (f.Get(ch) is not double kept) continue;
            bool flag = ch is "vtec" or "fuel_pump";
            var (d, unit) = LogFrame.Shown(ch, kept);
            string text = flag ? (d != 0 ? "ON" : "off") : d.ToString(Math.Abs(d) >= 1000 ? "0" : "0.###", CultureInfo.InvariantCulture);
            rows.Add(new([new(ch, DataList.Address), new(text, flag ? (d != 0 ? DataList.Good : DataList.Dim) : DataList.Text, true),
                          new(unit, DataList.Dim)], flag && d != 0 ? DataList.Good : null, Tip: FlagNames.About(ch) ?? ModuleDebug.Describe(ch)));
        }
        if (raw && f.Raw != null)
        {
            rows.Add(new([new($"raw frame: {f.Raw.Length} bytes{(f.Protocol != null ? ", " + f.Protocol : "")}", DataList.Text)], DataList.Data, Heading: true));
            for (int i = 0; i < f.Raw.Length; i += 8)
                rows.Add(new([new($"{i,2}", DataList.Address), new(string.Join(" ", f.Raw.Skip(i).Take(8).Select(b => b.ToString("X2"))), DataList.Dim)]));
        }
        return rows;
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

        if (!_playTimer.IsEnabled && (DateTime.UtcNow - _lastParams).TotalMilliseconds >= Perf.ValuesMs)
        {
            _lastParams = DateTime.UtcNow;
            if (f != null && !_showGraph) ShowParameters(f);
            // a replay (or the slider) feeds the gauges every frame it passed, not just the one it landed on, so a fast replay draws the same line a slow one does
            int at = Engine.Running || _loaded.Count == 0 ? -1 : Math.Clamp((int)_pos.Value, 0, _loaded.Count - 1);
            if (at >= 0 && f != null && ReferenceEquals(f, _loaded[at])) { Gauges.Feed(_loaded, _fedIndex, at); _fedIndex = at; }
            else { Gauges.Show(f); _fedIndex = -1; }
        }
        if (!_compact && s != null && f != null) _compare.SetRows(CompareRows(f, s, source));
        ShowState();
        // the graphs mark where the log is (the replay, the slider) or run live with the logger
        int where = Math.Clamp((int)_pos.Value, 0, Math.Max(0, _loaded.Count - 1));
        if (!_playTimer.IsEnabled)
        {
            if (_showGraph) _graphPanel?.Follow(where, Engine.Running);
            _graph?.Panel.Follow(where, Engine.Running);
        }
        if (!_compact && (DateTime.UtcNow - _lastCode).TotalMilliseconds > 700 && (_host.PlaybackActive || Engine.Running || _codeSince > 0))
        {
            _lastCode = DateTime.UtcNow;
            UpdateCodeList();
        }
    }

    /// The dot and word at the top of the log card.
    void ShowState()
    {
        bool live = Engine.Running, playing = _playTimer.IsEnabled || _host.PlaybackActive;
        _stateDot.Fill = live ? DataList.Good : playing ? DataList.Data : _loaded.Count > 0 ? DataList.Warning : DataList.Dim;
        _stateText.Text = live ? $"logging · {Engine.FramesPerSecond:0.0}/s" + (Engine.Smooth.Enabled ? " · smoothed" : "")
                        : playing ? $"replaying {_rate:0.#}x"
                        : _loaded.Count > 0 && _pos.Value > 0 && _pos.Value < _loaded.Count - 1 ? $"paused at {(int)_pos.Value + 1} of {_loaded.Count}"
                        : _loaded.Count > 0 ? $"{_loaded.Count} frames loaded" : "not connected";
        _stateText.Foreground = live ? DataList.Good : playing ? DataList.Data : DataList.Dim;
        // the line under it only when it says more than the dot does
        _status.IsVisible = !string.IsNullOrEmpty(_status.Text) && _status.Text != "not connected" && _status.Text != Lang.T("not connected");
    }

    /// The car's readings beside the simulated ECU's, and what each does with them.
    static List<DataList.Row> CompareRows(LogFrame f, SimHost.Snapshot s, string source)
    {
        var o = s.Outputs;
        var inj = o.InjectorMs.Where(v => v > 0).DefaultIfEmpty(0).Average();
        static string V(double? v, string fmt) => v is double x ? x.ToString(fmt, CultureInfo.InvariantCulture) : "-";
        static string B(bool? b) => b is bool x ? (x ? "on" : "off") : "-";
        DataList.Row R(string name, string car, string sim, string diff = "", bool bad = false) =>
            new([new(name), new(car, DataList.Text, true), new(sim, DataList.Call, true), new(diff, bad ? DataList.Warning : DataList.Dim, bad)], bad ? DataList.Warning : null);
        var rows = new List<DataList.Row>
        {
            new([new($"{source}  ·  t = {f.T:F2} s", DataList.Text)], DataList.Data, Heading: true),
            R("RPM", V(f.Rpm, "0"), s.Rpm.ToString("0", CultureInfo.InvariantCulture)),
            R("MAP kPa", V(f.MapKpa, "0.0"), s.Map.ToString("0.0", CultureInfo.InvariantCulture)),
            R("TPS %", V(f.TpsPct, "0.0"), s.Tps.ToString("0.0", CultureInfo.InvariantCulture)),
            R("ECT °C", V(f.EctC, "0"), s.Ect.ToString("0", CultureInfo.InvariantCulture)),
            R("IAT °C", V(f.IatC, "0"), s.Iat.ToString("0", CultureInfo.InvariantCulture)),
            R("O2 V", V(f.O2V, "0.00"), s.O2.ToString("0.00", CultureInfo.InvariantCulture)),
            R("Battery V", V(f.BattV, "0.0"), s.Vbatt.ToString("0.0", CultureInfo.InvariantCulture)),
            R("Speed km/h", V(f.SpeedKmh, "0"), s.SpeedKmh.ToString("0", CultureInfo.InvariantCulture)),
            new([new("What the ECU does", DataList.Text)], DataList.Data, Heading: true),
        };
        string diff = f.InjMs is double lm && inj > 0 ? ((inj - lm) / Math.Max(0.01, lm) * 100).ToString("+0;-0", CultureInfo.InvariantCulture) + " %" : "";
        rows.Add(R("Injector pulse ms", V(f.InjMs, "0.00"), inj > 0 ? inj.ToString("0.00", CultureInfo.InvariantCulture) : "-", diff,
                   f.InjMs is double lm2 && inj > 0 && Math.Abs(inj - lm2) / Math.Max(0.01, lm2) > 0.1));
        rows.Add(R("Fuel pump", B(f.FuelPump), B(o.FuelPump), f.FuelPump is bool fp && fp != o.FuelPump ? "differs" : "", f.FuelPump is bool fp2 && fp2 != o.FuelPump));
        rows.Add(R("VTEC solenoid", B(f.Vtec), B(o.Vtec), f.Vtec is bool vt && vt != o.Vtec ? "differs" : "", f.Vtec is bool vt2 && vt2 != o.Vtec));
        rows.Add(R("Ignition ° (final)", V(f.IgnDeg, "0.00"), ""));
        if (f.Get("afr") is double afr) rows.Add(R("Wideband AFR", afr.ToString("0.00", CultureInfo.InvariantCulture), ""));
        return rows;
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
        var rows = new List<DataList.Row>();
        var addrs = new List<int>();
        foreach (var l in labels)
        {
            double ago = (now - Math.Min(now, exec[l.Value])) / Bus.CpuHz;
            bool running = ago < 0.05;
            rows.Add(new([new($"{l.Value:X4}", DataList.Address), new(l.Name, DataList.Label), new(running ? "running" : $"{ago * 1000:0} ms ago", running ? DataList.Good : DataList.Dim)],
                         running ? DataList.Good : DataList.Code, (int)l.Value));
            addrs.Add((int)l.Value);
        }
        _codeAddrs = addrs;
        _code.SetRows(rows);
    }

    public void Shutdown() => Engine.Dispose();
}
