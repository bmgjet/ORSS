// Copyright (c) bmgjet. All rights reserved.
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Datalogging > Virtual dyno: power and torque from the ECU's own datalog. Inertia mode reads a roller of known inertia being spun by the car; strip mode uses the car's own weight on a straight, flat stretch, with its air drag and rolling resistance added back. A run starts and stops on the profile's triggers (the hotkey, throttle, MAP, boost, speed, rpm, gear - all of them or any one), once by default (one shot), is drawn as it happens, kept in the runs folder, and can be replayed, overlaid on others, raced head to head against another and printed. Runs can also be found in logs already made. How results are worked out and shown (units, correction, AFR, the hotkey) is in Settings > Dyno and Settings > Units; this window keeps the car, the roller, the air on the day and the triggers.
public sealed class DynoWindow : Window
{
    readonly DatalogEngine _engine;
    readonly DatalogView _view;
    readonly ConcurrentQueue<LogFrame> _incoming = new();
    readonly DynoTriggers _triggers = new();
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(50) };
    readonly DynoGraph _graph = new();

    public static string Folder => AppPaths.Dyno;
    public static string ProfilesDir => Path.Combine(Folder, "Profiles");
    public static string RunsDir => Path.Combine(Folder, "Runs");

    DynoProfile _p = new();
    readonly List<(string Path, DynoRun Run)> _runs = [];
    readonly HashSet<string> _overlaid = new(StringComparer.OrdinalIgnoreCase);
    DynoRun? _current;          // the run just made (kept in the runs folder)
    string _currentPath = "";
    double _lastT = double.NaN;
    bool _filling;

    // replay
    List<(DynoRun Run, DynoResult Result)>? _play;
    double _playT;
    DateTime _playWall;
    double _playRate = 1;

    // the top bar
    readonly ComboBox _profiles = new() { MinWidth = 160, MaxWidth = 240 };
    readonly Button _arm = new() { Content = "Auto start: on", MinWidth = 112 };
    readonly Button _go = new() { Content = "▶ Start run (Space)", MinWidth = 150, FontWeight = FontWeight.SemiBold, Padding = new Thickness(12, 5) };
    readonly TextBlock _waiting = new() { FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(10, 0, 10, 2) };
    readonly TextBlock _state = new() { FontWeight = FontWeight.Bold, VerticalAlignment = VerticalAlignment.Center, FontSize = 14, Margin = new Thickness(8, 0), MinWidth = 76 };
    readonly TextBlock _readout = new() { FontFamily = MainWindow.MonoFont, FontSize = 12, Opacity = 0.9, Margin = new Thickness(10, 0, 10, 4), TextTrimming = TextTrimming.CharacterEllipsis };
    readonly ComboBox _xAxis = new() { ItemsSource = new[] { "rpm", "time", "speed" }, SelectedIndex = 0, Width = 84 };
    readonly StackPanel _runList = new() { Spacing = 1 };
    readonly TextBlock _note = new() { FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
    CheckBox _oneShot = new();

    DynoSettings Ds => _view.Settings?.Invoke().Dyno ?? _fallback;
    readonly DynoSettings _fallback = new();

    public DynoWindow(DatalogView view)
    {
        _view = view;
        _engine = view.Engine;
        Title = "Virtual dyno";
        Width = 1280; Height = 820; MinWidth = 900; MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Directory.CreateDirectory(ProfilesDir);
        Directory.CreateDirectory(RunsDir);
        _triggers.Armed = Ds.ArmOnOpen;
        LoadProfiles();
        LoadRuns();

        // the settings, the graph and the runs
        var settings = _settingsScroll = new ScrollViewer { Content = Settings(), Width = 420, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
        var runsPanel = new DockPanel();
        var runsBar = RunsBar();
        DockPanel.SetDock(runsBar, Dock.Top);
        runsPanel.Children.Add(runsBar);
        runsPanel.Children.Add(new ScrollViewer { Content = _runList, MaxHeight = 170 });
        var runsBox = new Border
        {
            Child = runsPanel,
            BorderBrush = AppTheme.Brush(Color.FromArgb(60, 255, 255, 255)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4),
            Padding = new Thickness(8, 4), Margin = new Thickness(0, 6, 0, 0),
        };
        var centre = new DockPanel { Margin = new Thickness(8, 0, 0, 0) };
        DockPanel.SetDock(runsBox, Dock.Bottom); centre.Children.Add(runsBox);
        DockPanel.SetDock(_note, Dock.Bottom); centre.Children.Add(_note);
        centre.Children.Add(_graph);
        var body = new DockPanel { Margin = new Thickness(10, 4, 10, 10) };
        DockPanel.SetDock(settings, Dock.Left); body.Children.Add(settings);
        body.Children.Add(centre);
        var root = new DockPanel();
        var chrome = DarkChrome.Apply(this, Title);
        DockPanel.SetDock(chrome, Dock.Top); root.Children.Add(chrome);
        var top = TopBar();
        DockPanel.SetDock(top, Dock.Top); root.Children.Add(top);
        DockPanel.SetDock(_waiting, Dock.Top); root.Children.Add(_waiting);
        DockPanel.SetDock(_readout, Dock.Top); root.Children.Add(_readout);
        root.Children.Add(body);
        Content = root;

        _graph.PointPicked += (s, p) => _ = ShowPoint(s, p);
        _graph.MenuWanted += (s, at) => GraphMenu(s, at);
        _engine.Frame += OnFrame;
        _view.CurrentFrameChanged += OnPlayed;
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        // the hotkey is caught before the focused control sees it, so it never presses a button or ticks a box
        AddHandler(KeyDownEvent, OnKey, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        _view.SettingsApplied += OnSettings;
        Closed += (_, _) => { _engine.Frame -= OnFrame; _view.CurrentFrameChanged -= OnPlayed; _view.SettingsApplied -= OnSettings; _timer.Stop(); };
        _xAxis.SelectedItem = Ds.XAxis;
        _graph.XAxis = Ds.XAxis;
        _xAxis.SelectionChanged += (_, _) => { _graph.XAxis = _xAxis.SelectedItem as string ?? "rpm"; Ds.XAxis = _graph.XAxis; _graph.ResetZoom(); };
        Fill();
        ShowState();
        Redraw();
    }

    /// Settings > Dyno or Units changed: the page and the graph in the new ones (the boxes are made again for the units).
    void OnSettings()
    {
        _fill.Clear();
        _settingsScroll!.Content = Settings();
        Fill(); FillRuns(); Redraw(); ShowState();
    }

    // ------------------------------------------------------------------ frames in

    void OnFrame(LogFrame f) => _incoming.Enqueue(f);

    /// A loaded log played on the datalog page feeds the dyno too (not while it is logging live).
    void OnPlayed(LogFrame? f) { if (f != null && !_engine.Running) _incoming.Enqueue(f); }

    void OnKey(object? s, KeyEventArgs e)
    {
        if (!Enum.TryParse<Key>(Ds.HotKey, true, out var hot)) hot = Key.Space;
        if (e.Key != hot || e.Source is TextBox) return;
        e.Handled = true;
        StartOrEnd();
    }

    /// The Start button and the hotkey: end a run that is going; else, when a start condition is "Hotkey pressed", get it ready (the run starts as soon as the other start conditions hold too); else start a run now.
    void StartOrEnd()
    {
        if (_play != null) { _play = null; Redraw(); }
        if (_triggers.Now == DynoTriggers.State.Running)
        {
            var run = _triggers.EndNow(_p);
            if (run != null) Finished(run); else _note.Text = "That run was too short to keep (Shortest run kept, under Triggers).";
        }
        else if (_p.Start.Any(t => t.Channel == "key"))
        {
            _triggers.KeyDown = !_triggers.KeyDown;
            _triggers.Armed = true;
        }
        else
        {
            _triggers.StartNow();
            _note.Text = $"Run started by hand: press the button or {Ds.HotKey} again to end it" + (_p.Stop.Count > 0 ? ", or it ends on the end conditions." : ".");
        }
        ShowState();
    }

    DateTime _lastDraw, _lastFrameWall = DateTime.MinValue, _lastState;
    DynoSample? _lastSample;

    void Tick()
    {
        bool changed = false;
        while (_incoming.TryDequeue(out var f))
        {
            if (f.Rpm == null) continue;
            if (!double.IsNaN(_lastT) && f.T <= _lastT && f.T > _lastT - 5) continue;     // the same frame twice (live and replayed)
            _lastT = f.T;
            var sample = DynoSample.From(f);
            _lastSample = sample;
            _lastFrameWall = DateTime.Now;
            _readout.Text = $"{sample.Rpm,5:0} rpm  {Units.Format(sample.Kmh ?? 0, "km/h", "0")}  TPS {sample.Tps ?? 0,3:0} %  MAP {Units.Format(sample.MapKpa ?? 0, "kPa", "0")}" +
                            (VirtualDyno.Afr(sample, Work(_p)) is double afr ? $"  {Units.Format(afr, "AFR", "0.0")}" : "") + (sample.Gear is double g ? $"  gear {g:0}" : "");
            bool wasRunning = _triggers.Now == DynoTriggers.State.Running;
            _triggers.ArmAgain = !_p.OneShot;
            var done = _triggers.Feed(sample, _p);
            if (done != null) Finished(done);
            else if (wasRunning && _triggers.Now == DynoTriggers.State.Waiting) _note.Text = "That run was too short to keep (Shortest run kept, under Triggers).";
            changed = true;
        }
        if (_play != null) AdvancePlay();
        else if (changed && _triggers.Now == DynoTriggers.State.Running && (DateTime.Now - _lastDraw).TotalMilliseconds > 150)
        {
            _lastDraw = DateTime.Now;
            Redraw();
        }
        // the waiting line follows the readings, a few times a second (and says so when they stop)
        if ((DateTime.Now - _lastState).TotalMilliseconds > 250) { _lastState = DateTime.Now; ShowState(); }
    }

    void Finished(List<DynoSample> samples)
    {
        if (_triggers.KeyDown && _p.Start.Any(t => t.Channel == "key")) _triggers.KeyDown = false;
        var work = Work(_p);
        var run = new DynoRun { Name = $"Run {DateTime.Now:yyyy-MM-dd HH.mm.ss}", When = DateTime.Now, Profile = work, Samples = samples };
        var r = VirtualDyno.Compute(samples, work);
        run.Notes = $"{_p.Car} {(r.PeakW > 0 ? $"{VirtualDyno.ToPower(r.PeakW, work.PowerUnit):0.0} {work.PowerUnit} @ {r.PeakWRpm:0}" : "")}".Trim();
        var path = Keep(run);
        _current = run; _currentPath = path;
        bool once = _p.OneShot && !_triggers.Armed;
        _note.Text = $"{run.Name}: {samples.Count} readings over {samples[^1].T - samples[0].T:0.0} s. {r.Note}. Kept in {RunsDir}." +
                     (once ? " One shot: auto start is off now - look the run over, then press Auto start for the next pull." : "");
        AppLog.Action("dyno", $"run kept: {run.Name}, {run.Notes}");
        FillRuns();
        Redraw();
        ShowState();
    }

    /// A run into the runs folder, and onto the list (newest first). Its path.
    string Keep(DynoRun run)
    {
        var path = Path.Combine(RunsDir, Safe(run.Name) + ".json");
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(RunsDir, Safe(run.Name) + $" ({n}).json");
        try { File.WriteAllText(path, JsonSerializer.Serialize(run, VirtualDyno.Json)); }
        catch (Exception ex) { AppLog.Error("dyno", "run not saved", ex); }
        _runs.Insert(0, (path, run));
        return path;
    }

    void SaveRun(DynoRun run)
    {
        var path = _runs.FirstOrDefault(r => ReferenceEquals(r.Run, run)).Path;
        if (string.IsNullOrEmpty(path)) return;
        try { File.WriteAllText(path, JsonSerializer.Serialize(run, VirtualDyno.Json)); } catch (Exception ex) { AppLog.Error("dyno", "run not saved", ex); }
    }

    void ShowState()
    {
        bool running = _triggers.Now == DynoTriggers.State.Running;
        bool ready = !running && _triggers.KeyDown;
        var key = Ds.HotKey;
        _go.Content = running ? $"■ End run ({key})" : ready ? $"Ready - cancel ({key})" : $"▶ Start run ({key})";
        _arm.Content = _triggers.Armed ? "Auto start: on" : "Auto start: off";
        if (_play != null) { _state.Text = "REPLAY"; _state.Foreground = DataList.Purple; _waiting.Text = ""; return; }
        bool feed = (DateTime.Now - _lastFrameWall).TotalSeconds < 1;
        _state.Text = running ? "RUNNING" : ready ? "READY" : _triggers.Armed ? "WAITING" : "IDLE";
        _state.Foreground = running ? DataList.Error : _triggers.Armed ? DataList.Good : DataList.Dim;
        // what it is waiting for: each condition ticked or crossed for the latest reading
        string Conds(List<DynoTrigger> list, bool all) => _lastSample == null ? "" :
            string.Join(all ? "   and   " : "   or   ", _triggers.Check(_lastSample, list).Select(c => (c.Holds ? "✔ " : "✖ ") + Describe(c.Trigger)));
        _waiting.Text = !feed ? "No datalog readings are coming in: connect the datalog (or play a log on the datalog page) first."
            : running ? (_p.Stop.Count > 0 ? "Ends when:   " + Conds(_p.Stop, _p.StopAll) + $"     (or press {key})" : $"Ends on the button or {key}, or when the start conditions stop holding.")
            : _triggers.Armed ? (_p.Start.Count > 0 ? "Starts when:   " + Conds(_p.Start, _p.StartAll) : $"No start conditions: use the button or {key}.")
            : $"Auto start is off: the button or {key} starts a run by hand" + (_p.OneShot ? "; Auto start arms it for one pull." : ".");
        _waiting.Foreground = !feed ? DataList.Warning : DataList.Text;
    }

    /// A trigger in words, in the units picked: "Speed > 19 mph".
    static string Describe(DynoTrigger t)
    {
        if (t.Channel == "key") return "hotkey pressed";
        var label = VirtualDyno.TriggerChannels.FirstOrDefault(c => c.Channel == t.Channel).Label ?? t.Channel;
        string unit = VirtualDyno.TriggerUnit(t.Channel);
        return $"{label} {t.Op} {Units.Show(t.Value, unit):0.##} {Units.Label(Units.Shown(unit))}".TrimEnd();
    }

    // ------------------------------------------------------------------ the sums, as the settings say

    /// A profile to work out with: its own car, roller and air, with Settings > Dyno's results, correction and AFR, and a run's own changes (its correction, smoothing, loss) on top.
    DynoProfile Work(DynoProfile p, DynoStyle? style = null)
    {
        var w = p.Clone();
        Ds.ApplyTo(w);
        w.Overlays = [.. _p.Overlays];
        if (style != null)
        {
            if (style.Correction is { } c) w.Correction = c;
            if (style.Smoothing is int sm) w.Smoothing = sm;
            if (style.DrivetrainLossPct is double l) w.DrivetrainLossPct = l;
            if (style.RpmStep is double st) w.RpmStep = st;
        }
        return w;
    }

    /// A saved run worked out with the profile it was made with (the car, the roller, the air), and the way things are shown now.
    DynoResult Compute(DynoRun run) => VirtualDyno.Compute(run.Samples, Work(run.Profile, run.Style));

    // ------------------------------------------------------------------ the graph

    void Redraw()
    {
        var list = new List<DynoGraph.Series>();
        int colour = 0;
        Color Next() => DynoGraph.Palette[colour++ % DynoGraph.Palette.Length];
        if (_play != null)
            foreach (var (run, res) in _play) list.Add(new(run.Name, Next(), res, _playT, run, run.Style));
        else
        {
            if (_triggers.Now == DynoTriggers.State.Running && _triggers.Current.Count > 4)
                list.Add(new("live", Next(), VirtualDyno.Compute(_triggers.Current, Work(_p))));
            else if (_current != null && !_overlaid.Contains(RunKey(_current))) list.Add(new(_current.Name, Next(), Compute(_current), null, _current, _current.Style));
            foreach (var (path, run) in _runs.Where(r => _overlaid.Contains(RunKey(r.Run))))
                list.Add(new(run.Name, Next(), Compute(run), null, run, run.Style));
        }
        _graph.Runs = list;
        _graph.Units = Work(_p);
        _graph.InvalidateVisual();
    }

    static string RunKey(DynoRun r) => r.Name + "|" + r.When.Ticks;

    /// Right-click on the graph: a run's own menu (its look, its sums, rename, replay, hide, delete), or the graph's.
    void GraphMenu(DynoGraph.Series? s, Point at)
    {
        var menu = new ContextMenu();
        MenuItem Item(string header, Action a, bool check = false, bool on = false, bool enabled = true)
        {
            var m = new MenuItem { Header = header, IsEnabled = enabled };
            if (check) { m.ToggleType = MenuItemToggleType.CheckBox; m.IsChecked = on; }
            m.Click += (_, _) => a();
            return m;
        }
        MenuItem Sub(string header, params MenuItem[] items) { var m = new MenuItem { Header = header }; foreach (var i in items) m.Items.Add(i); return m; }
        if (s?.Run is { } run)
        {
            var st = run.Style ??= new DynoStyle();
            void Changed() { SaveRun(run); FillRuns(); Redraw(); }
            menu.Items.Add(new MenuItem { Header = run.Name, IsEnabled = false, FontWeight = FontWeight.Bold });
            menu.Items.Add(Sub("Colour", [.. DynoGraph.Palette.Select((c, i) => Item($"■ colour {i + 1}", () => { st.Colour = $"#{c.R:X2}{c.G:X2}{c.B:X2}"; Changed(); })),
                                          Item("Next free colour (default)", () => { st.Colour = ""; Changed(); })]));
            if (menu.Items[^1] is MenuItem colours)
                for (int i = 0; i < DynoGraph.Palette.Length; i++) if (colours.Items[i] is MenuItem ci) ci.Foreground = AppTheme.Brush(DynoGraph.Palette[i]);
            menu.Items.Add(Sub("Line width", [.. new[] { 1.0, 1.5, 2.2, 3, 4 }.Select(w => Item($"{w:0.#}", () => { st.Width = w; Changed(); }, true, Math.Abs(st.Width - w) < 0.01))]));
            menu.Items.Add(Item("Show power", () => { st.ShowPower = !st.ShowPower; Changed(); }, true, st.ShowPower));
            menu.Items.Add(Item("Show torque", () => { st.ShowTorque = !st.ShowTorque; Changed(); }, true, st.ShowTorque));
            menu.Items.Add(Item("Dashed power line", () => { st.Dashed = !st.Dashed; Changed(); }, true, st.Dashed));
            menu.Items.Add(new Separator());
            string[] corr = ["None (as measured)", "SAE J1349", "DIN 70020", "SAE J607 (STD)", "ECE / EEC"];
            menu.Items.Add(Sub("Correction",
                [Item($"As in Settings ({corr[(int)Ds.Correction]})", () => { st.Correction = null; Changed(); }, true, st.Correction == null),
                 .. corr.Select((c, i) => Item(c, () => { st.Correction = (DynoCorrection)i; Changed(); }, true, st.Correction == (DynoCorrection)i))]));
            menu.Items.Add(Sub("Smoothing",
                [Item($"As in Settings ({Ds.Smoothing})", () => { st.Smoothing = null; Changed(); }, true, st.Smoothing == null),
                 .. Enumerable.Range(0, 11).Select(i => Item(i.ToString(), () => { st.Smoothing = i; Changed(); }, true, st.Smoothing == i))]));
            menu.Items.Add(Sub("Drivetrain loss",
                [Item($"As in Settings ({Ds.DrivetrainLossPct:0} %)", () => { st.DrivetrainLossPct = null; Changed(); }, true, st.DrivetrainLossPct == null),
                 .. new[] { 0.0, 8, 10, 12, 15, 18, 20, 25 }.Select(l => Item($"{l:0} %", () => { st.DrivetrainLossPct = l; Changed(); }, true, st.DrivetrainLossPct == l))]));
            menu.Items.Add(Sub("Rpm step",
                [Item($"As in Settings ({Ds.RpmStep:0})", () => { st.RpmStep = null; Changed(); }, true, st.RpmStep == null),
                 .. new[] { 25.0, 50, 100, 200, 250, 500 }.Select(v => Item($"{v:0} rpm", () => { st.RpmStep = v; Changed(); }, true, st.RpmStep == v))]));
            menu.Items.Add(Item($"Scale power and torque… (now x{st.Factor:0.###})", async () =>
            {
                var box = new NumericUpDown { Value = (decimal)st.Factor, Minimum = 0.5m, Maximum = 2m, Increment = 0.005m, FormatString = "0.###", Width = 160 };
                if (!await Dialogs.Prompt(this, "Scale this run", "Power and torque times (a known difference between dynos):", box)) return;
                st.Factor = (double)(box.Value ?? 1); Changed();
            }));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Rename…", async () =>
            {
                var name = await AskName("Rename the run", run.Name);
                if (name == null) return;
                bool ticked = _overlaid.Remove(RunKey(run));
                run.Name = name;
                if (ticked) _overlaid.Add(RunKey(run));
                Changed();
            }));
            menu.Items.Add(Item("Replay it", () => Play([run])));
            menu.Items.Add(Item("Reset its look and sums", () => { run.Style = null; Changed(); }));
            menu.Items.Add(Item("Take it off the graph", () => { _overlaid.Remove(RunKey(run)); if (ReferenceEquals(run, _current)) _current = null; FillRuns(); Redraw(); }));
            menu.Items.Add(Item("Delete the run…", async () =>
            {
                if (!await Dialogs.Confirm(this, "Delete the run?", $"Delete {run.Name}? It cannot be brought back.", "Delete", "Keep")) return;
                foreach (var r in _runs.Where(r => ReferenceEquals(r.Run, run)).ToList()) { try { File.Delete(r.Path); } catch { } _runs.Remove(r); }
                _overlaid.Remove(RunKey(run));
                if (ReferenceEquals(run, _current)) _current = null;
                FillRuns(); Redraw();
            }));
        }
        else
        {
            menu.Items.Add(Item("Reset zoom", _graph.ResetZoom, enabled: _graph.Zoomed));
            menu.Items.Add(Sub("X axis", [.. new[] { "rpm", "time", "speed" }.Select(x => Item(x, () => _xAxis.SelectedItem = x, true, _graph.XAxis == x))]));
            menu.Items.Add(Item("Crank estimate (else at the wheels)", () => { Ds.ShowCrank = !Ds.ShowCrank; _view.SaveSettings(); FillRuns(); Redraw(); }, true, Ds.ShowCrank));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Report…", () => _ = Report()));
            menu.Items.Add(Item("Dyno settings…", () => _view.OpenSettingsAt("Dyno")));
            menu.Items.Add(Item("Units…", () => _view.OpenSettingsAt("Units")));
        }
        menu.Open(_graph);
    }

    // ------------------------------------------------------------------ one reading: where it was in the maps

    /// A reading double-clicked: what the engine was doing there, and where it was in the fuel and ignition maps of the ROM open.
    async Task ShowPoint(DynoGraph.Series s, DynoPoint picked)
    {
        // a point of the curve is an average: the reading itself is the nearest real one
        var p = s.Result.Points.Count > 0 ? s.Result.Points.MinBy(x => Math.Abs(x.Rpm - picked.Rpm) + Math.Abs(x.T - picked.T) * 1000)! : picked;
        var f = new LogFrame { T = p.T, Rpm = p.Rpm, SpeedKmh = p.Kmh };
        foreach (var (k, v) in p.Ch) f.Set(k, v);
        var rows = new List<(string What, string Value)>
        {
            ("Engine", $"{p.Rpm:0} rpm, {Units.Format(p.Kmh, "km/h", "0")}" + (f.Get("gear") is double g ? $", gear {g:0}" : "")),
            ("Power", $"{VirtualDyno.ToPower((Ds.ShowCrank ? p.CrankW : p.WheelW) * (s.Style?.Factor ?? 1), Units.Now.Power):0.0} {Units.Now.Power} {(Ds.ShowCrank ? "crank" : "wheel")}"),
            ("Torque", $"{VirtualDyno.ToTorque((Ds.ShowCrank ? p.CrankTorqueNm : p.TorqueNm) * (s.Style?.Factor ?? 1), Units.Now.Torque):0.0} {VirtualDyno.TorqueLabel(Units.Now.Torque)}"),
        };
        if (f.MapKpa is double map) rows.Add(("MAP", Units.Format(map, "kPa", "0.#") + (f.Get("boost_psi") is double bo ? $" ({Units.ShowBoost(bo):0.0} {Units.BoostUnit} boost)" : "")));
        if (f.TpsPct is double tps) rows.Add(("Throttle", $"{tps:0} %"));
        if (p.Afr is double afr) rows.Add(("AFR", Units.Format(afr, "AFR", "0.00")));
        if (f.IgnDeg is double ign) rows.Add(("Final ignition", $"{ign:0.##}° BTDC"));
        if (f.IgnTableDeg is double igt) rows.Add(("Ignition from the map", $"{igt:0.##}° BTDC"));
        if (f.InjMs is double inj) rows.Add(("Injector time", $"{inj:0.00} ms" + (p.Rpm > 0 ? $" ({inj * p.Rpm / 1200:0} % duty)" : "")));
        if (f.Vtec is bool vt) rows.Add(("VTEC", vt ? "on (high cam)" : "off (low cam)"));
        if (f.Get("knock") is double kn) rows.Add(("Knock", kn.ToString("0.##", CultureInfo.InvariantCulture)));
        if (f.IatC is double iat) rows.Add(("Intake air", Units.Format(iat, "°C", "0")));
        if (f.EctC is double ect) rows.Add(("Coolant", Units.Format(ect, "°C", "0")));
        if (f.Get("fuel_col") is double col) rows.Add(("ECU's map position", $"column {col:0}, row {f.Get(f.Vtec == true ? "fuel_row_hi" : "fuel_row_lo") ?? 0:0}"));
        foreach (var m in MapCells(f)) rows.Add((m.Map, m.Text));

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), Margin = new Thickness(14, 10) };
        for (int i = 0; i < rows.Count; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            var a = new TextBlock { Text = rows[i].What, Opacity = 0.75, Margin = new Thickness(0, 2, 14, 2), FontSize = 12.5 };
            var b = new SelectableTextBlock { Text = rows[i].Value, FontFamily = MainWindow.MonoFont, Margin = new Thickness(0, 2), FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
            Grid.SetRow(a, i); Grid.SetRow(b, i); Grid.SetColumn(b, 1);
            grid.Children.Add(a); grid.Children.Add(b);
        }
        var show = new Button { Content = "Show it on the maps", Margin = new Thickness(14, 0, 6, 12) };
        ToolTip.SetTip(show, "Light this reading's place on the table open on the calibration page (the cam it was on, when the log says).");
        show.Click += (_, _) => _view.ShowFrameOnMaps(f);
        var close = new Button { Content = "Close", Margin = new Thickness(0, 0, 14, 12), IsCancel = true };
        var w = new Window
        {
            Title = $"{s.Name} at {p.Rpm:0} rpm", Width = 520, SizeToContent = SizeToContent.Height, MaxHeight = 760, CanResize = true,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        close.Click += (_, _) => w.Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { show, close } };
        var dock = new DockPanel();
        var chrome = DarkChrome.Apply(w, w.Title);
        DockPanel.SetDock(chrome, Dock.Top); dock.Children.Add(chrome);
        DockPanel.SetDock(buttons, Dock.Bottom); dock.Children.Add(buttons);
        dock.Children.Add(new ScrollViewer { Content = grid });
        w.Content = dock;
        await w.ShowDialog(this);
    }

    /// The fuel and ignition maps of the ROM open, at this reading: the cell it was in and the value there.
    List<(string Map, string Text)> MapCells(LogFrame f)
    {
        var list = new List<(string, string)>();
        try
        {
            var host = _view.Host;
            if (host.LoadedPath == null) return [("Maps", "no ROM is open: open the one the car ran to see its cells")];
            var defs = host.Defs();
            var rom = host.RomCopy();
            var maps = defs.Items.Where(i => i.IsTable && i.Rows >= 8 && i.Cols >= 8 && i.RowAxis != null && i.ColAxis != null &&
                                             (i.Formula is "honda_fuel" or "ign_advance" || i.Category.Equals("Fuel", StringComparison.OrdinalIgnoreCase) || i.Category.Equals("Ignition", StringComparison.OrdinalIgnoreCase)))
                                 .Take(8).ToList();
            foreach (var m in maps)
            {
                var (_, rget) = LogOverlay.AxisInput(defs, m.RowAxis, true);
                var (_, cget) = LogOverlay.AxisInput(defs, m.ColAxis, false);
                if (rget(f) is not double rv || cget(f) is not double cv) continue;
                var ra = RomData.AxisValues(defs, rom, m.RowAxis, m.Rows);
                var ca = RomData.AxisValues(defs, rom, m.ColAxis, m.Cols);
                double rp = LogOverlay.Position(ra, rv), cp = LogOverlay.Position(ca, cv);
                int r = Math.Clamp((int)Math.Round(rp), 0, m.Rows - 1), c = Math.Clamp((int)Math.Round(cp), 0, m.Cols - 1);
                var cells = RomData.Read(defs, rom, m);
                var fd = defs.Formula(m.Formula);
                var cell = cells[(r * m.Cols) + c];
                string hi = m.Name.Contains("high", StringComparison.OrdinalIgnoreCase) || m.Name.Contains("Hi", StringComparison.Ordinal) ? " (high cam)" : "";
                list.Add((m.Name + hi, $"row {r} ({ra[r]:0}), column {c} ({ca[c]:0.#}) = {Units.Format(cell.Value, fd.Unit, "0.##")}  [between rows {rp:0.0}, columns {cp:0.0}]"));
            }
            if (list.Count == 0) list.Add(("Maps", "no fuel or ignition map is named in this ROM's definitions (Detect finds them)"));
        }
        catch (Exception ex) { list.Add(("Maps", "could not be read: " + ex.Message)); }
        return list;
    }

    // ------------------------------------------------------------------ replay and head to head

    void Play(List<DynoRun> runs)
    {
        if (runs.Count == 0) { _note.Text = "Tick the run (or the two runs) to replay first."; return; }
        _play = [.. runs.Select(r => (r, Compute(r)))];
        _playT = 0;
        _playWall = DateTime.Now;
        _note.Text = runs.Count == 2 ? $"Head to head: {runs[0].Name} against {runs[1].Name}, both from their start, at the same speed." : $"Replaying {runs[0].Name}.";
        ShowState();
    }

    void AdvancePlay()
    {
        if (_play == null) return;
        _playT = (DateTime.Now - _playWall).TotalSeconds * _playRate;
        double longest = _play.Max(p => p.Result.Points.Count == 0 ? 0 : p.Result.Points[^1].T - p.Result.Points[0].T);
        var parts = _play.Select(p =>
        {
            var pts = p.Result.Points;
            if (pts.Count == 0) return "";
            var at = pts.LastOrDefault(x => x.T - pts[0].T <= _playT) ?? pts[0];
            return $"{p.Run.Name}: {at.Rpm:0} rpm {Units.Format(at.Kmh, "km/h", "0")} {VirtualDyno.ToPower(Ds.ShowCrank ? at.CrankW : at.WheelW, Units.Now.Power):0} {Units.Now.Power}";
        });
        _readout.Text = $"{_playT:0.00} s   " + string.Join("   |   ", parts);
        Redraw();
        if (_playT > longest + 0.3) { _play = null; Redraw(); ShowState(); _note.Text = "Replay finished."; }
    }

    // ------------------------------------------------------------------ the bars

    static Button B(string text, string tip, Action a, double size = 12.5)
    {
        var b = new Button { Content = text, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(9, 3), FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// One line: the profile (and its menu), Start, Auto start, the state, the x axis, and a menu for the rest.
    Control TopBar()
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 6, 10, 4) };
        _profiles.SelectionChanged += (_, _) =>
        {
            if (_filling || _profiles.SelectedItem is not string name) return;
            LoadProfile(name);
        };
        ToolTip.SetTip(_profiles, "The profile: the car or the roller, the air on the day, the triggers.");
        bar.Children.Add(_profiles);
        var prof = B("☰", "The profile: save, save as, delete, restore the defaults.", () => { });
        prof.Margin = new Thickness(4, 0, 12, 0);
        prof.Click += (_, _) =>
        {
            var m = new ContextMenu();
            void Add(string h, Action a) { var i = new MenuItem { Header = h }; i.Click += (_, _) => a(); m.Items.Add(i); }
            Add("Save", SaveProfile);
            Add("Save as…", async () =>
            {
                var name = await AskName("Save the profile as", _p.Name + " copy");
                if (name == null) return;
                _p.Name = name; SaveProfile(); LoadProfiles();
            });
            Add("Delete", async () =>
            {
                if (!await Dialogs.Confirm(this, "Delete the profile?", $"Delete the profile '{_p.Name}'? Its runs stay.", "Delete", "Keep")) return;
                try { File.Delete(Path.Combine(ProfilesDir, Safe(_p.Name) + ".json")); } catch { }
                LoadProfiles();
            });
            m.Items.Add(new Separator());
            Add("Restore the default profiles", () => { int n = RestoreDefaultProfiles(); LoadProfiles(); _note.Text = $"{n} default profile(s) put back."; });
            Add("Open the dyno folder", () => { try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Folder) { UseShellExecute = true }); } catch { } });
            m.Open(prof);
        };
        bar.Children.Add(prof);
        _go.Click += (_, _) => StartOrEnd();
        ToolTip.SetTip(_go, "Start a run now; again to end it and keep it. The hotkey (Settings > Dyno) does the same wherever the focus is in this window. " +
                            "With 'Hotkey pressed' as a start condition it gets the run ready instead: it starts once the other start conditions hold too.");
        bar.Children.Add(_go);
        _arm.Margin = new Thickness(6, 0, 0, 0);
        _arm.Click += (_, _) => { _triggers.Armed = !_triggers.Armed; if (!_triggers.Armed && _triggers.Now != DynoTriggers.State.Running) _triggers.Cancel(); ShowState(); };
        ToolTip.SetTip(_arm, "On: a run starts by itself when the start conditions hold, and ends on the end conditions (with One shot, once - then it turns itself off). Off: only the button or the hotkey start one.");
        bar.Children.Add(_arm);
        bar.Children.Add(_state);
        bar.Children.Add(new TextBlock { Text = "x", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 4, 0), Opacity = 0.7 });
        ToolTip.SetTip(_xAxis, "What the graph is drawn against: rpm, time or road speed.");
        bar.Children.Add(_xAxis);
        bar.Children.Add(new Border { Width = 10 });
        bar.Children.Add(B("From logs…", "Find every run in logs already made - the one on the datalog page, log files, or a whole folder of them - with this profile's triggers, and keep each one.", () => _ = Scrape()));
        bar.Children.Add(B("Report…", "The graph and the figures on a white sheet: saved as a picture, or opened in the browser to print.", () => _ = Report()));
        bar.Children.Add(B("⚙", "Settings > Dyno: units, results, correction, AFR, the hotkey.", () => _view.OpenSettingsAt("Dyno")));
        return new ScrollViewer { Content = bar, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto, VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
    }

    Control RunsBar()
    {
        var bar = new WrapPanel();
        Button Small(string text, string tip, Action a) { var b = B(text, tip, a, 12); b.Padding = new Thickness(8, 2); b.Margin = new Thickness(0, 0, 6, 4); return b; }
        bar.Children.Add(new TextBlock { Text = "Saved runs  (tick to overlay; right-click a line on the graph for its own settings)", FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 4) });
        bar.Children.Add(Small("▶ Replay", "Replay the ticked run as it happened.", () => Play(Ticked().Take(1).ToList())));
        bar.Children.Add(Small("⇄ Head to head", "Two ticked runs played together from their start at the same speed: watch them race.", () =>
        {
            var t = Ticked().ToList();
            if (t.Count != 2) { _note.Text = "Tick exactly two runs for head to head."; return; }
            Play(t);
        }));
        var rate = new ComboBox { ItemsSource = new[] { "0.5x", "1x", "2x", "4x" }, SelectedIndex = 1, FontSize = 12, Margin = new Thickness(0, 0, 6, 4) };
        rate.SelectionChanged += (_, _) => _playRate = double.Parse((rate.SelectedItem as string ?? "1x").TrimEnd('x'), CultureInfo.InvariantCulture);
        bar.Children.Add(rate);
        bar.Children.Add(Small("■", "Stop the replay.", () => { _play = null; ShowState(); Redraw(); }));
        bar.Children.Add(Small("Rename…", "Rename the ticked run.", async () =>
        {
            var t = _runs.FirstOrDefault(r => _overlaid.Contains(RunKey(r.Run)));
            if (t.Run == null) return;
            var name = await AskName("Rename the run", t.Run.Name);
            if (name == null) return;
            _overlaid.Remove(RunKey(t.Run));
            t.Run.Name = name;
            _overlaid.Add(RunKey(t.Run));
            SaveRun(t.Run);
            FillRuns(); Redraw();
        }));
        bar.Children.Add(Small("Delete", "Delete the ticked runs.", async () =>
        {
            var t = _runs.Where(r => _overlaid.Contains(RunKey(r.Run))).ToList();
            if (t.Count == 0 || !await Dialogs.Confirm(this, "Delete runs?", $"Delete {t.Count} run(s)? They cannot be brought back.", "Delete", "Keep")) return;
            foreach (var r in t) { try { File.Delete(r.Path); } catch { } _runs.Remove(r); _overlaid.Remove(RunKey(r.Run)); if (ReferenceEquals(r.Run, _current)) _current = null; }
            FillRuns(); Redraw();
        }));
        bar.Children.Add(Small("Clear all…", "Delete every saved run (a pile of runs found in old logs that turned out to be junk).", async () =>
        {
            if (_runs.Count == 0) { _note.Text = "There are no saved runs."; return; }
            if (!await Dialogs.Confirm(this, "Delete every run?", $"Delete all {_runs.Count} saved run(s)? They cannot be brought back. The profiles stay.", "Delete them all", "Keep")) return;
            int n = ClearAllRuns();
            _runs.Clear(); _overlaid.Clear(); _current = null;
            FillRuns(); Redraw();
            _note.Text = $"{n} run(s) deleted.";
        }));
        return bar;
    }

    IEnumerable<DynoRun> Ticked() => _runs.Where(r => _overlaid.Contains(RunKey(r.Run))).Select(r => r.Run);

    void FillRuns()
    {
        _runList.Children.Clear();
        foreach (var (path, run) in _runs)
        {
            var r = Compute(run);
            double factor = run.Style?.Factor ?? 1;
            string peaks = r.PeakW > 0 ? $"   {VirtualDyno.ToPower((Ds.ShowCrank ? r.PeakW / (1 - Work(run.Profile, run.Style).DrivetrainLossPct / 100) : r.PeakW) * factor, Units.Now.Power):0.0} {Units.Now.Power} @ {r.PeakWRpm:0}" : "";
            var box = new CheckBox
            {
                Content = new TextBlock { Text = $"{run.Name}   {run.Profile.Mode}  {run.Profile.Car}{peaks}" }, IsChecked = _overlaid.Contains(RunKey(run)), FontSize = 12,
            };
            if (run.Notes.Length > 0) ToolTip.SetTip(box, run.Notes);
            var k = RunKey(run);
            box.IsCheckedChanged += (_, _) => { if (box.IsChecked == true) _overlaid.Add(k); else _overlaid.Remove(k); Redraw(); };
            _runList.Children.Add(box);
        }
        if (_runs.Count == 0) _runList.Children.Add(new TextBlock { Text = "None yet.", Opacity = 0.6, FontSize = 12 });
    }

    // ------------------------------------------------------------------ settings (the profile's: the rest is in Settings > Dyno)

    readonly Dictionary<string, Action> _fill = [];
    StackPanel _start = new(), _stop = new();
    StackPanel _inertia = new(), _strip = new(), _air = new();

    Control Settings()
    {
        // made afresh each time (the units changed: every box is made again in them)
        _start = new() { Spacing = 2 }; _stop = new() { Spacing = 2 };
        _inertia = new(); _strip = new(); _air = new();
        _oneShot = new CheckBox { Content = new TextBlock { Text = "One shot: log one run, then stop and wait" }, FontSize = 12 };
        var p = Form.Page();
        p.Margin = new Thickness(0, 0, 8, 0);
        // a number kept in `unit` (kg, m, N...), shown and typed in the unit picked in Settings > Units
        NumericUpDown Num(string key, Func<double> get, Action<double> set, double min, double max, double step, string fmt = "0.##", string unit = "")
        {
            double S(double v) => Units.Show(v, unit);
            double lo = Math.Min(S(min), S(max)), hi = Math.Max(S(min), S(max));
            var n = Form.Num(S(get()), lo, hi, step * Units.ScaleOf(unit), fmt);
            n.Width = 150;
            n.ValueChanged += (_, _) => { if (_filling) return; set(Units.Back(Form.V(n), unit)); Changed(); };
            _fill[key] = () => n.Value = (decimal)Math.Clamp(S(get()), lo, hi);
            return n;
        }
        ComboBox Combo(string key, string[] items, Func<int> get, Action<int> set, double width = 200)
        {
            var c = new ComboBox { ItemsSource = items, Width = width };
            c.SelectionChanged += (_, _) => { if (_filling || c.SelectedIndex < 0) return; set(c.SelectedIndex); Changed(); };
            _fill[key] = () => c.SelectedIndex = Math.Clamp(get(), -1, items.Length - 1);
            return c;
        }
        Control Row(string label, Control editor, string unit = "", string? tip = null)
        {
            var g = new Grid { ColumnDefinitions = new ColumnDefinitions("150,Auto,*"), Margin = new Thickness(0, 2) };
            var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, FontSize = 12.5 };
            var u = new TextBlock { Text = Units.Label(Units.Shown(unit)), VerticalAlignment = VerticalAlignment.Center, FontSize = 11, Opacity = 0.8, Margin = new Thickness(6, 0, 0, 0) };
            Grid.SetColumn(l, 0); g.Children.Add(l); Grid.SetColumn(editor, 1); g.Children.Add(editor); Grid.SetColumn(u, 2); g.Children.Add(u);
            if (tip != null) ToolTip.SetTip(g, tip);
            return g;
        }

        p.Children.Add(Form.Group("Mode",
            Combo("mode", ["Inertia dyno: the car spins a roller", "Strip: the car on a straight, flat stretch"], () => (int)_p.Mode, v => _p.Mode = (DynoMode)v, 300)));

        var car = new ComboBox { ItemsSource = VirtualDyno.Cars.Select(x => $"{x.Name}  {Units.Format(x.Kg, "kg", "0")}").ToList(), Width = 300, PlaceholderText = "Pick a car to fill these in" };
        car.SelectionChanged += (_, _) =>
        {
            if (_filling || car.SelectedIndex < 0) return;
            var c = VirtualDyno.Cars[car.SelectedIndex];
            _p.Car = c.Name; _p.VehicleKg = c.Kg; _p.DragCd = c.Cd; _p.FrontalM2 = c.FrontalM2;
            Fill(); Changed();
        };
        _strip.Children.Add(Form.Group("The car (strip)",
            car,
            Row("Car", Num("kg", () => _p.VehicleKg, v => _p.VehicleKg = v, 300, 3000, 5, "0", "kg"), "kg", "Curb weight. Weigh the car if you can: every kg wrong is that share of the power wrong."),
            Row("Driver and passengers", Num("driver", () => _p.DriverKg, v => _p.DriverKg = v, 0, 400, 5, "0", "kg"), "kg"),
            Row("Fuel", Num("fuel", () => _p.FuelKg, v => _p.FuelKg = v, 0, 80, 1, "0", "kg"), "kg", "About 0.74 kg a litre of petrol (6.2 lb a US gallon)."),
            Row("Spinning parts", Num("rot", () => _p.RotatingPct, v => _p.RotatingPct = v, 0, 30, 0.5, "0.0"), "%",
                "Wheels, tyres, axles and gearbox spun up with the car, as a share of its mass: about 3 % in 5th, 5 % in 4th, 7 % in 3rd, more lower."),
            Row("Drag coefficient", Num("cd", () => _p.DragCd, v => _p.DragCd = v, 0.15, 0.8, 0.01, "0.00"), "Cd"),
            Row("Frontal area", Num("area", () => _p.FrontalM2, v => _p.FrontalM2 = v, 1, 4, 0.05, "0.00", "m²"), "m²"),
            Row("Rolling resistance", Num("crr", () => _p.RollingCrr, v => _p.RollingCrr = v, 0, 0.05, 0.001, "0.000"), "Crr", "About 0.010-0.015 for road tyres on tarmac.")));
        var roller = new ComboBox { ItemsSource = VirtualDyno.Rollers.Select(x => x.Name).ToList(), Width = 300, PlaceholderText = "An example roller" };
        roller.SelectionChanged += (_, _) =>
        {
            if (_filling || roller.SelectedIndex < 0) return;
            var r = VirtualDyno.Rollers[roller.SelectedIndex];
            _p.RollerInertia = r.Inertia; _p.RollerDiameterM = r.DiameterM;
            Fill(); Changed();
        };
        _inertia.Children.Add(Form.Group("The roller (inertia)",
            roller,
            Row("Roller inertia", Num("inertia", () => _p.RollerInertia, v => _p.RollerInertia = v, 0.1, 5000, 1, "0.##", "kg·m²"), "kg·m²",
                "The rollers' moment of inertia, from the dyno maker. A solid drum is mass x radius² / 2, a thin shell mass x radius²."),
            Row("Roller diameter", Num("diam", () => _p.RollerDiameterM, v => _p.RollerDiameterM = v, 0.05, 3, 0.001, "0.###", "m"), "m"),
            Row("Car's wheels and drivetrain", Num("wheels", () => _p.WheelsKg, v => _p.WheelsKg = v, 0, 300, 1, "0", "kg"), "kg",
                "The car's own spinning parts, as an equivalent mass at the tyre: about 20-35 kg for a front-wheel-drive car."),
            Row("Roller friction", Num("parasitic", () => _p.ParasiticN, v => _p.ParasiticN = v, 0, 2000, 5, "0", "N"), "N", "The dyno's own drag at the roller's surface, if known (a coast-down tells it).")));
        p.Children.Add(_strip);
        p.Children.Add(_inertia);

        p.Children.Add(Form.Group("Road speed",
            Combo("speed", ["Engine rpm, the ratio learned from the speed sensor", "The road speed sensor", "Engine rpm x a fixed ratio"], () => (int)_p.Speed, v => _p.Speed = (DynoSpeed)v, 300),
            Row("Speed per 1000 rpm", Num("kmh", () => _p.KmhPer1000, v => _p.KmhPer1000 = v, 1, 100, 0.1, "0.00", "km/h"), "km/h", "Only for the fixed ratio: the speed in the gear the run is made in, at 1000 rpm.")));

        _air.Children.Add(Form.Group("Air on the day",
            Row("Air temperature", Num("airc", () => _p.AirC, v => _p.AirC = v, -30, 60, 0.5, "0.0", "°C"), "°C"),
            Row("Air pressure", Num("baro", () => _p.BaroKpa, v => _p.BaroKpa = v, 60, 110, 0.1, "0.0", "kPa"), "kPa",
                "For the correction to standard air. Settings > Dyno can take these from the ECU's intake air and baro sensors instead.")));
        p.Children.Add(_air);

        var startMode = Combo("startall", ["All of these", "Any of these"], () => _p.StartAll ? 0 : 1, v => _p.StartAll = v == 0, 140);
        var stopMode = Combo("stopall", ["Any of these", "All of these"], () => _p.StopAll ? 1 : 0, v => _p.StopAll = v == 1, 140);
        _oneShot.IsCheckedChanged += (_, _) => { if (_filling) return; _p.OneShot = _oneShot.IsChecked == true; _triggers.ArmAgain = !_p.OneShot; Changed(); ShowState(); };
        _fill["oneshot"] = () => _oneShot.IsChecked = _p.OneShot;
        ToolTip.SetTip(_oneShot, "On: after a run auto start turns itself off, so one pull is logged and kept, then it stops and waits while you look at it; Auto start arms it for the next. Off: it waits for the next pull straight away.");
        // (the profile's lists, looked up when pressed: loading another profile replaces them)
        Button Add(Func<List<DynoTrigger>> into) { var b = new Button { Content = "+ condition", FontSize = 12, Padding = new Thickness(8, 1) }; b.Click += (_, _) => { into().Add(new DynoTrigger { Channel = "rpm", Op = ">", Value = 2500 }); FillTriggers(); Changed(); }; return b; }
        p.Children.Add(Form.Group("Triggers",
            _oneShot,
            new TextBlock { Text = "Start a run when", FontWeight = FontWeight.SemiBold, FontSize = 12, Margin = new Thickness(0, 6, 0, 0) }, startMode, _start, Add(() => _p.Start),
            new TextBlock { Text = "End it when", FontWeight = FontWeight.SemiBold, FontSize = 12, Margin = new Thickness(0, 6, 0, 0) }, stopMode, _stop, Add(() => _p.Stop),
            Row("Shortest run kept", Num("minrun", () => _p.MinRunS, v => _p.MinRunS = v, 0.2, 30, 0.1, "0.0"), "s"),
            new TextBlock { Text = "Auto start (at the top) on: a run starts by itself when these start conditions hold. The Start button or the hotkey (Settings > Dyno) starts and ends one by hand at any time. " +
                                   "With 'Hotkey pressed' as a start condition, the hotkey gets the run ready and it starts once the other conditions hold too (press it, then floor it). " +
                                   "With no end conditions, a run ends when its start conditions stop holding.", FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap }));

        var overlays = new WrapPanel();
        foreach (var (ch, label) in new[] { ("afr", "AFR"), ("map_kpa", "MAP"), ("boost_psi", "Boost"), ("tps_pct", "Throttle"), ("ign_deg", "Ignition"), ("inj_ms", "Injector time"), ("iat_c", "Intake air"), ("knock", "Knock"), ("speed_kmh", "Speed"), ("gear", "Gear") })
        {
            var c = new CheckBox { Content = new TextBlock { Text = label }, Margin = new Thickness(0, 0, 10, 0), FontSize = 12 };
            c.IsCheckedChanged += (_, _) =>
            {
                if (_filling) return;
                _p.Overlays.RemoveAll(o => o.Equals(ch, StringComparison.OrdinalIgnoreCase));
                if (c.IsChecked == true) _p.Overlays.Add(ch);
                Changed();
            };
            _fill["ov_" + ch] = () => c.IsChecked = _p.Overlays.Contains(ch, StringComparer.OrdinalIgnoreCase);
            overlays.Children.Add(c);
        }
        p.Children.Add(Form.Group("Channels under the graph", overlays));
        var more = new Button { Content = "Results, correction, AFR, hotkey and units: Settings > Dyno…", FontSize = 12, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        more.Click += (_, _) => _view.OpenSettingsAt("Dyno");
        p.Children.Add(more);
        return p;
    }

    void FillTriggers()
    {
        void Rows(StackPanel panel, List<DynoTrigger> list)
        {
            panel.Children.Clear();
            foreach (var t in list.ToList())
            {
                var row = new Grid { ColumnDefinitions = new ColumnDefinitions("128,58,*,Auto,Auto"), Margin = new Thickness(0, 1) };
                var ch = new ComboBox { ItemsSource = VirtualDyno.TriggerChannels.Select(x => x.Label).ToList(), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Stretch };
                int at = Array.FindIndex(VirtualDyno.TriggerChannels, x => x.Channel.Equals(t.Channel, StringComparison.OrdinalIgnoreCase));
                ch.SelectedIndex = at;
                var op = new ComboBox { ItemsSource = new[] { ">", ">=", "<", "<=", "=", "!=" }, SelectedItem = t.Op, FontSize = 12, Margin = new Thickness(4, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
                // each channel's own sensible range: throttle 0-100 %, rpm 0-12500 in 100s, gear 0-6... in the units picked
                var range = VirtualDyno.TriggerRange(t.Channel);
                string unit = VirtualDyno.TriggerUnit(t.Channel);
                double S(double v) => t.Channel == "boost_psi" ? Units.ShowBoost(v) : Units.Show(v, unit);
                double Bk(double v) => t.Channel == "boost_psi" ? Units.BackBoost(v) : Units.Back(v, unit);
                t.Value = Math.Clamp(t.Value, range.Min, range.Max);
                double lo = Math.Min(S(range.Min), S(range.Max)), hi = Math.Max(S(range.Min), S(range.Max));
                double step = Math.Abs(S(range.Step) - S(0));
                var val = Form.Num(S(t.Value), lo, hi, step, step < 1 ? "0.0#" : "0");
                val.Width = double.NaN; val.MinWidth = 110; val.HorizontalAlignment = HorizontalAlignment.Stretch; val.Margin = new Thickness(4, 0, 0, 0);
                var u = new TextBlock { Text = t.Channel == "boost_psi" ? Units.BoostUnit : Units.Label(Units.Shown(unit)), FontSize = 11, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) };
                bool key = t.Channel == "key";
                op.IsVisible = val.IsVisible = u.IsVisible = !key;
                ch.SelectionChanged += (_, _) =>
                {
                    if (ch.SelectedIndex < 0) return;
                    var was = t.Channel;
                    t.Channel = VirtualDyno.TriggerChannels[ch.SelectedIndex].Channel;
                    // another channel: start from a value that makes sense for it
                    if (was != t.Channel) { t.Value = VirtualDyno.TriggerRange(t.Channel).Start; Dispatcher.UIThread.Post(FillTriggers); }
                    Changed();
                };
                op.SelectionChanged += (_, _) => { if (op.SelectedItem is string o) { t.Op = o; Changed(); } };
                val.ValueChanged += (_, _) => { t.Value = Bk(Form.V(val)); Changed(); };
                var del = new Button { Content = "✕", Padding = new Thickness(6, 0), FontSize = 11, Margin = new Thickness(4, 0, 0, 0) };
                ToolTip.SetTip(del, "Take this condition out.");
                del.Click += (_, _) => { list.Remove(t); FillTriggers(); Changed(); };
                Grid.SetColumn(ch, 0); Grid.SetColumn(op, 1); Grid.SetColumn(val, 2); Grid.SetColumn(u, 3); Grid.SetColumn(del, 4);
                if (key) Grid.SetColumnSpan(ch, 4);
                row.Children.Add(ch); row.Children.Add(op); row.Children.Add(val); row.Children.Add(u); row.Children.Add(del);
                panel.Children.Add(row);
            }
        }
        Rows(_start, _p.Start);
        Rows(_stop, _p.Stop);
    }

    void Fill()
    {
        _filling = true;
        foreach (var f in _fill.Values) try { f(); } catch { }
        FillTriggers();
        _filling = false;
        _triggers.ArmAgain = !_p.OneShot;
        Changed(redraw: false);
    }

    void Changed(bool redraw = true)
    {
        _strip.IsVisible = _p.Mode == DynoMode.Strip;
        _inertia.IsVisible = _p.Mode == DynoMode.Inertia;
        if (_filling) return;
        if (redraw) { FillRuns(); Redraw(); }
    }

    // ------------------------------------------------------------------ profiles and runs on disk

    /// The default profiles written back (any of them deleted or changed is replaced): how many.
    public static int RestoreDefaultProfiles()
    {
        Directory.CreateDirectory(ProfilesDir);
        int n = 0;
        foreach (var p in VirtualDyno.DefaultProfiles())
        {
            try { File.WriteAllText(Path.Combine(ProfilesDir, Safe(p.Name) + ".json"), JsonSerializer.Serialize(p, VirtualDyno.Json)); n++; }
            catch (Exception ex) { AppLog.Error("dyno", "default profile not written", ex); }
        }
        return n;
    }

    /// Every saved run deleted: how many.
    public static int ClearAllRuns()
    {
        int n = 0;
        if (!Directory.Exists(RunsDir)) return 0;
        foreach (var f in Directory.GetFiles(RunsDir, "*.json")) { try { File.Delete(f); n++; } catch { } }
        AppLog.Action("dyno", $"{n} saved run(s) deleted");
        return n;
    }

    void LoadProfiles()
    {
        var names = Directory.GetFiles(ProfilesDir, "*.json").Select(f => Path.GetFileNameWithoutExtension(f)).Order(StringComparer.OrdinalIgnoreCase).ToList();
        if (names.Count == 0)
        {
            RestoreDefaultProfiles();
            names = Directory.GetFiles(ProfilesDir, "*.json").Select(f => Path.GetFileNameWithoutExtension(f)).Order(StringComparer.OrdinalIgnoreCase).ToList();
        }
        if (names.Count == 0) return;
        _filling = true;
        _profiles.ItemsSource = names;
        string pick = names.FirstOrDefault(n => n.Equals(Safe(_p.Name), StringComparison.OrdinalIgnoreCase)) ?? names[0];
        _profiles.SelectedItem = pick;
        _filling = false;
        LoadProfile(pick);
    }

    void LoadProfile(string name)
    {
        var f = Path.Combine(ProfilesDir, Safe(name) + ".json");
        try { _p = JsonSerializer.Deserialize<DynoProfile>(File.ReadAllText(f), VirtualDyno.Json) ?? _p; }
        catch (Exception ex) { _note.Text = "Could not read it: " + ex.Message; }
        Fill(); FillRuns(); Redraw();
    }

    void Save(DynoProfile p) => File.WriteAllText(Path.Combine(ProfilesDir, Safe(p.Name) + ".json"), JsonSerializer.Serialize(p, VirtualDyno.Json));

    void SaveProfile()
    {
        try { Save(_p); _note.Text = $"Profile '{_p.Name}' saved."; }
        catch (Exception ex) { _note.Text = "Could not save it: " + ex.Message; }
    }

    void LoadRuns()
    {
        _runs.Clear();
        foreach (var f in Directory.GetFiles(RunsDir, "*.json").OrderByDescending(File.GetLastWriteTimeUtc))
            try { if (JsonSerializer.Deserialize<DynoRun>(File.ReadAllText(f), VirtualDyno.Json) is { } r) _runs.Add((f, r)); }
            catch (Exception ex) { AppLog.Warn("dyno", $"{Path.GetFileName(f)} could not be read: {ex.Message}"); }
        FillRuns();
    }

    static string Safe(string name) => string.Concat(name.Select(ch => Path.GetInvalidFileNameChars().Contains(ch) ? '_' : ch)).Trim();

    async Task<string?> AskName(string title, string suggested)
    {
        var box = new TextBox { Text = suggested, Width = 320 };
        return await Dialogs.Prompt(this, title, "Name:", box) && box.Text is { Length: > 0 } t ? t.Trim() : null;
    }

    // ------------------------------------------------------------------ runs found in logs already made

    static readonly string[] LogPatterns = ["*.rlog", "*.csv", "*.hdl", "*.hml", "*.dlf", "*.bml", "*.log"];

    /// Runs from logs: the one on the datalog page, picked files, or every log in a folder (and the folders in it), each searched with this profile's triggers in the background; every run found is kept.
    async Task Scrape()
    {
        if (_p.Start.Count == 0 || _p.Start.All(t => t.Channel == "key"))
        {
            _note.Text = "This profile only starts on the hotkey, which a recorded log cannot press: add a start condition (throttle over 90 %, say) first.";
            return;
        }
        var pick = await Dialogs.Ask(this, "Runs from logs",
            "Find every run in logs already made, with this profile's start and end conditions (as Auto start would have found them live). Each run found is kept with the others. Search:",
            "The log on the datalog page", "Log files…", "A folder of logs…", "Cancel");
        var sources = new List<(string Name, Func<List<LogFrame>> Frames, DateTime When)>();
        if (pick == "The log on the datalog page")
        {
            var frames = _view.Frames();
            if (frames.Count == 0) { _note.Text = "No log is loaded on the datalog page."; return; }
            sources.Add(("datalog page", () => [.. frames], DateTime.Now));
        }
        else if (pick == "Log files…")
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "Logs to search for runs", AllowMultiple = true,
                FileTypeFilter = [new FilePickerFileType("Datalogs") { Patterns = LogPatterns }, new FilePickerFileType("All files") { Patterns = ["*.*"] }],
            });
            foreach (var f in files) if (f.TryGetLocalPath() is { } path) sources.Add((Path.GetFileNameWithoutExtension(path), () => LogFile.Load(path), File.GetLastWriteTime(path)));
        }
        else if (pick == "A folder of logs…")
        {
            var dirs = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = "A folder of logs" });
            if (dirs.FirstOrDefault()?.TryGetLocalPath() is not { } dir) return;
            var files = LogPatterns.SelectMany(p => Directory.EnumerateFiles(dir, p, SearchOption.AllDirectories)).Distinct().Take(5000).ToList();
            if (files.Count == 0) { _note.Text = $"No logs in {dir}."; return; }
            foreach (var path in files) sources.Add((Path.GetFileNameWithoutExtension(path), () => LogFile.Load(path), File.GetLastWriteTime(path)));
        }
        if (sources.Count == 0) return;
        var profile = _p.Clone();
        var work = Work(_p);
        int found = 0, read = 0, failed = 0;
        _note.Text = $"Searching {sources.Count} log(s) for runs…";
        var kept = await Task.Run(() =>
        {
            var list = new List<DynoRun>();
            foreach (var (name, get, when) in sources)
            {
                List<LogFrame> frames;
                try { frames = get(); read++; }
                catch (Exception ex) { failed++; AppLog.Warn("dyno", $"{name}: {ex.Message}"); continue; }
                int n = 0;
                foreach (var samples in VirtualDyno.RunsIn(frames, profile))
                {
                    n++;
                    var run = new DynoRun
                    {
                        Name = $"{name} run {n} ({samples[0].T:0.0} s)", When = when.AddSeconds(samples[0].T), Profile = work, Samples = samples,
                    };
                    var r = VirtualDyno.Compute(samples, work);
                    run.Notes = $"found in {name}: {samples.Count} readings{(r.PeakW > 0 ? $", {VirtualDyno.ToPower(r.PeakW, work.PowerUnit):0.0} {work.PowerUnit} @ {r.PeakWRpm:0}" : "")}";
                    list.Add(run);
                }
                found += n;
                int done = read + failed;
                if (done % 10 == 0) Dispatcher.UIThread.Post(() => _note.Text = $"Searching logs for runs… {done} of {sources.Count} read, {found} run(s) so far.");
            }
            return list;
        });
        foreach (var run in kept.OrderBy(r => r.When)) Keep(run);
        FillRuns(); Redraw();
        _note.Text = found == 0 ? $"No run matched the triggers in {read} log(s){(failed > 0 ? $" ({failed} could not be read)" : "")}."
                                : $"{found} run(s) found in {read} log(s) and kept{(failed > 0 ? $"; {failed} log(s) could not be read" : "")}. Clear all… removes them again if they are junk.";
        AppLog.Action("dyno", $"runs from logs: {found} found in {read} log(s)");
    }

    // ------------------------------------------------------------------ a project

    /// The profile picked and the runs ticked (their file names), for a project.
    internal (string Profile, List<string> Ticked) ViewState() =>
        (_p.Name, [.. _runs.Where(r => _overlaid.Contains(RunKey(r.Run)) && r.Path.Length > 0).Select(r => Path.GetFileName(r.Path))]);

    /// A project opened: its profiles and runs are in the folder now; read them again and show what it showed.
    internal void RestoreView(string profile, List<string> ticked)
    {
        LoadRuns();
        _filling = true;
        var names = Directory.GetFiles(ProfilesDir, "*.json").Select(f => Path.GetFileNameWithoutExtension(f)).Order(StringComparer.OrdinalIgnoreCase).ToList();
        _profiles.ItemsSource = names;
        var pick = names.FirstOrDefault(n => n.Equals(Safe(profile), StringComparison.OrdinalIgnoreCase)) ?? names.FirstOrDefault();
        _profiles.SelectedItem = pick;
        _filling = false;
        if (pick != null) LoadProfile(pick);
        _overlaid.Clear();
        foreach (var (path, run) in _runs) if (ticked.Contains(Path.GetFileName(path), StringComparer.OrdinalIgnoreCase)) _overlaid.Add(RunKey(run));
        FillRuns(); Redraw();
    }

    // ------------------------------------------------------------------ the layout check

    /// The layout check's test of a run, through the window as a user drives it: readings fed in as the datalog would, a run by the Start button, one by the hotkey pressed while another button has the focus, and one by auto start on the throttle. The runs it makes are deleted.
    internal async Task<string> SelfTest()
    {
        var said = new List<string>();
        var before = _runs.Count;
        double t = 1000;
        async Task Feed(double secs, double tps, Func<double, double> rpm)
        {
            for (double x = 0; x < secs; x += 0.02)
            {
                t += 0.02;
                _incoming.Enqueue(new LogFrame { T = t, Rpm = rpm(x), SpeedKmh = Math.Floor(rpm(x) / 1000 * 30), TpsPct = tps, MapKpa = tps > 50 ? 98 : 35, BaroKpa = 101, IatC = 25 });
                if ((int)(x / 0.02) % 5 == 0) await Task.Delay(10);
            }
            await Task.Delay(150);
        }
        bool Is(string state) => _state.Text == state;
        // 1: by hand, with auto start off
        _triggers.Armed = false; ShowState();
        await Feed(0.5, 10, _ => 900);
        _go.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        await Feed(3, 100, x => 3000 + x * 1300);
        said.Add($"button: {(Is("RUNNING") ? "running" : "NOT running (" + _state.Text + ")")}");
        _go.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        await Feed(0.3, 10, _ => 900);
        said.Add($"  ended, kept: {(_runs.Count == before + 1 ? "yes" : "NO")}");
        // 2: the hotkey, with the focus on another button (it must not press that button)
        var other = new Button();
        var bar = (_go.Parent as Panel)!;
        bar.Children.Add(other);
        int clicks = 0; other.Click += (_, _) => clicks++;
        other.Focus();
        if (!Enum.TryParse<Key>(Ds.HotKey, true, out var hot)) hot = Key.Space;
        void Press() => other.RaiseEvent(new KeyEventArgs { RoutedEvent = KeyDownEvent, Key = hot, Source = other });
        Press();
        await Feed(3, 100, x => 3000 + x * 1300);
        said.Add($"hotkey ({Ds.HotKey}): {(Is("RUNNING") ? "running" : "NOT running (" + _state.Text + ")")}, the focused button {(clicks == 0 ? "left alone" : "PRESSED")}");
        Press();
        await Feed(0.3, 10, _ => 900);
        said.Add($"  ended, kept: {(_runs.Count == before + 2 ? "yes" : "NO")}");
        bar.Children.Remove(other);
        // 3: auto start on the throttle (the profile's own start and end conditions), one shot: a second pull is not taken
        _triggers.Armed = true; ShowState();
        var saved = (_p.Start, _p.Stop, _p.StartAll, _p.StopAll, _p.OneShot);
        _p.Start = [new() { Channel = "tps_pct", Op = ">", Value = 90 }]; _p.Stop = [new() { Channel = "tps_pct", Op = "<", Value = 80 }]; _p.StartAll = true; _p.StopAll = false; _p.OneShot = true;
        await Feed(0.5, 10, _ => 900);
        await Feed(3, 100, x => 3000 + x * 1300);
        bool autoRan = Is("RUNNING");
        await Feed(0.5, 10, _ => 900);
        bool disarmed = !_triggers.Armed;
        await Feed(2, 100, x => 3000 + x * 1300);
        await Feed(0.5, 10, _ => 900);
        said.Add($"auto start (throttle > 90 %): {(autoRan ? "ran" : "did NOT run")}, kept: {(_runs.Count == before + 3 ? "yes" : "NO")}; one shot: {(disarmed && _runs.Count == before + 3 ? "stopped after one" : "DID NOT STOP")}");
        (_p.Start, _p.Stop, _p.StartAll, _p.StopAll, _p.OneShot) = saved;
        // 4: runs from a log: the same pulls found again
        var log = new List<LogFrame>();
        double lt = 0;
        foreach (var (secs, tps, rpm) in new (double, double, Func<double, double>)[] { (1, 10, _ => 900), (3, 100, x => 3000 + x * 1300), (1, 10, _ => 900), (3, 100, x => 3000 + x * 1300), (1, 10, _ => 900) })
            for (double x = 0; x < secs; x += 0.05) { lt += 0.05; log.Add(new LogFrame { T = lt, Rpm = rpm(x), SpeedKmh = Math.Floor(rpm(x) / 1000 * 30), TpsPct = tps, MapKpa = 98, BaroKpa = 101, IatC = 25 }); }
        var p2 = _p.Clone(); p2.Start = [new() { Channel = "tps_pct", Op = ">", Value = 90 }]; p2.Stop = [new() { Channel = "tps_pct", Op = "<", Value = 80 }];
        said.Add($"runs in a log: {VirtualDyno.RunsIn(log, p2).Count} (2 made)");
        // the runs this made go again
        foreach (var r in _runs.Take(_runs.Count - before).ToList()) { try { if (r.Path.Length > 0) File.Delete(r.Path); } catch { } _runs.Remove(r); }
        _current = null;
        FillRuns(); Redraw(); ShowState();
        return string.Join("; ", said);
    }

    ScrollViewer? _settingsScroll;
    /// The layout check: the settings scrolled down to the triggers.
    internal void ShowTriggers() => Dispatcher.UIThread.Post(() => _settingsScroll?.ScrollToEnd(), DispatcherPriority.Background);

    /// The layout check's picture: two made-up strip runs (in memory only), ticked, with AFR under them.
    internal void ForCheck()
    {
        List<DynoSample> Made(double kw, double afr)
        {
            var list = new List<DynoSample>();
            double v = 3000 / 1000.0 * 30 / 3.6, t = 0;
            // to 7500 rpm, or as far as it gets in 30 s (air drag can stop a made-up car short of it)
            while (v * 3.6 / 30 * 1000 < 7500 && t < 30)
            {
                double rpm = v * 3.6 / 30 * 1000, shape = Math.Sin(Math.PI * (rpm - 2000) / 7000);
                list.Add(new DynoSample { T = t, Rpm = rpm, Kmh = Math.Floor(v * 3.6), Tps = 100, MapKpa = 100, IatC = 25, BaroKpa = 101.3, Ch = { ["afr"] = afr + Math.Sin(rpm / 700) * 0.3, ["ign_deg"] = 28 + rpm / 1000 } });
                v += (kw * 1000 * shape / v - 0.5 * 1.2 * 0.32 * 1.85 * v * v - 150) / 1200 * 0.02; t += 0.02;
            }
            return list;
        }
        var a = new DynoRun { Name = "Baseline", Profile = _p.Clone(), Samples = Made(100, 12.8), When = DateTime.Now.AddMinutes(-10) };
        var b = new DynoRun { Name = "After tune", Profile = _p.Clone(), Samples = Made(112, 12.4) };
        _runs.Insert(0, ("", b)); _runs.Insert(0, ("", a));
        _overlaid.Add(RunKey(a)); _overlaid.Add(RunKey(b));
        if (!_p.Overlays.Contains("afr")) _p.Overlays.Add("afr");
        FillRuns(); Redraw();
    }

    // ------------------------------------------------------------------ the printed sheet

    async Task Report()
    {
        var shown = _graph.Runs.Where(s => s.Result.Curve.Count > 0).ToList();
        if (shown.Count == 0) { _note.Text = "Nothing on the graph to report."; return; }
        var units = Work(_p);
        var sheetGraph = new DynoGraph { Runs = [.. shown.Select(s => s with { UpTo = null })], Units = units, XAxis = _graph.XAxis, Print = true, Width = 1400, Height = 760 };
        var lines = new StackPanel { Spacing = 2, Margin = new Thickness(0, 0, 0, 10) };
        lines.Children.Add(new TextBlock { Text = "Virtual dyno", FontSize = 26, FontWeight = FontWeight.Bold, Foreground = Brushes.Black });
        string tu = VirtualDyno.TorqueLabel(units.TorqueUnit);
        foreach (var s in shown)
        {
            var run = s.Run;
            var pr = run?.Profile ?? _p;
            var w = run != null ? Work(run.Profile, run.Style) : units;
            double f = run?.Style?.Factor ?? 1, loss = 1 - (w.DrivetrainLossPct / 100);
            string what = pr.Mode == DynoMode.Strip ? $"strip, {pr.Car} {Units.Format(pr.VehicleKg + pr.DriverKg + pr.FuelKg, "kg", "0")}" : $"inertia dyno, roller {Units.Format(pr.RollerInertia, "kg·m²", "0.#")}";
            lines.Children.Add(new TextBlock
            {
                Foreground = AppTheme.Brush(s.Style?.Colour is { Length: > 0 } c && Color.TryParse(c, out var col) ? col : s.Colour), FontSize = 14, FontFamily = MainWindow.MonoFont,
                Text = $"{s.Name}:  {VirtualDyno.ToPower((units.ShowCrank ? s.Result.PeakW / loss : s.Result.PeakW) * f, units.PowerUnit):0.0} {units.PowerUnit} @ {s.Result.PeakWRpm:0} rpm, " +
                       $"{VirtualDyno.ToTorque((units.ShowCrank ? s.Result.PeakNm / loss : s.Result.PeakNm) * f, units.TorqueUnit):0.0} {tu} @ {s.Result.PeakNmRpm:0} rpm  ({what}, {w.Correction} x {s.Result.Correction:0.000}{(run != null ? $", {run.When:yyyy-MM-dd HH:mm}" : "")})",
            });
        }
        lines.Children.Add(new TextBlock
        {
            Foreground = Brushes.DimGray, FontSize = 12,
            Text = $"{(units.ShowCrank ? $"Crank estimate (drivetrain loss {units.DrivetrainLossPct:0} %)" : "At the wheels")}. Solid: power; dashed: torque. Made with Rom Sim Studio from the ECU's datalog.",
        });
        var sheet = new StackPanel { Background = Brushes.White, Margin = new Thickness(0), Children = { new Border { Padding = new Thickness(30, 24), Child = new StackPanel { Children = { lines, sheetGraph } } } } };
        sheet.Measure(new Size(1460, 1100));
        sheet.Arrange(new Rect(0, 0, 1460, sheet.DesiredSize.Height));
        var size = new PixelSize(1460, (int)Math.Ceiling(sheet.DesiredSize.Height));
        using var bmp = new RenderTargetBitmap(size);
        bmp.Render(sheet);
        var pick = await Dialogs.Ask(this, "Report", "Save the sheet as a picture, or open it in the browser to print?", "Save picture…", "Print…", "Cancel");
        if (pick == "Save picture…")
        {
            var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
            {
                Title = "Save the dyno sheet", SuggestedFileName = Safe(shown[0].Name) + ".png", DefaultExtension = "png",
                FileTypeChoices = [new FilePickerFileType("PNG picture") { Patterns = ["*.png"] }],
            });
            if (file?.TryGetLocalPath() is { } path) { bmp.Save(path); _note.Text = "Saved " + path; }
        }
        else if (pick == "Print…")
        {
            var png = Path.Combine(Path.GetTempPath(), "romsim-dyno-sheet.png");
            bmp.Save(png);
            var html = Path.Combine(Path.GetTempPath(), "romsim-dyno-sheet.html");
            File.WriteAllText(html, "<!doctype html><html><head><meta charset=\"utf-8\"><title>Virtual dyno</title><style>@page{size:landscape;margin:10mm}body{margin:0}img{width:100%}</style></head>" +
                                    $"<body onload=\"window.print()\"><img src=\"data:image/png;base64,{Convert.ToBase64String(File.ReadAllBytes(png))}\"></body></html>");
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(html) { UseShellExecute = true }); } catch (Exception ex) { _note.Text = "Could not open the browser: " + ex.Message; }
        }
    }
}
