// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Datalogging > Demon onboard logging: a Moates Demon logs the ECU by itself, into its own memory, with no laptop in the car (DemonOnboard). Here it is set up - what it asks the ECU, how often, when to log - switched on and off, and its sessions read back into the datalog panel or a CSV. The Demon is on the emulator's port; the live datalog through it is paused while this talks to it.
public sealed class OnboardWindow : Window
{
    readonly SimHost _host;
    readonly DatalogView _view;
    readonly Func<AppSettings>? _settings;
    readonly TextBlock _state = new() { TextWrapping = TextWrapping.Wrap, FontSize = 13 };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.85 };
    readonly ProgressBar _progress = new() { Minimum = 0, Maximum = 1, Height = 6, IsVisible = false };
    readonly ComboBox _protocol = new() { MinWidth = 200 };
    readonly ComboBox _rate = new() { MinWidth = 200 };
    readonly ComboBox _trigger = new() { MinWidth = 200 };
    readonly NumericUpDown _above = new() { Minimum = 0, Maximum = 255, Value = 0, Increment = 1, Width = 110, FormatString = "0" };
    readonly TextBlock _aboveUnit = new() { VerticalAlignment = VerticalAlignment.Center };
    readonly CheckBox _compress = new() { Content = "Compressed (more sessions fit; the tuning software reads both)" };
    readonly ListBox _sessions = new() { MinHeight = 140 };
    readonly Button _open = new() { Content = "Open in the datalog", IsEnabled = false };
    readonly Button _save = new() { Content = "Save CSV…", IsEnabled = false };
    readonly List<Button> _actions = [];
    List<DemonOnboard.Session> _read = [];
    RelayPlan? _readPlan;

    static readonly (string Text, int Skip)[] Rates = [("every packet", 0), ("every 2nd", 1), ("every 3rd", 2), ("every 4th", 3), ("every 6th", 5), ("every 10th", 9), ("every 20th", 19)];
    static readonly (string Text, int At, string Unit)[] Triggers =
    [
        ("always, while the key is on", -1, ""), ("throttle above", 6, "%"), ("road speed above", 17, "km/h"), ("manifold pressure above", 5, "kPa"),
    ];

    public OnboardWindow(SimHost host, DatalogView view, Func<AppSettings>? settings)
    {
        _host = host; _view = view; _settings = settings;
        Title = "Demon onboard logging";
        Width = 640; Height = 720; MinWidth = 420; MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        var plans = EmulatorRelay.Candidates().ToList();
        _protocol.ItemsSource = plans.Select(p => p.Name).ToList();
        var s = settings?.Invoke();
        _protocol.SelectedIndex = Math.Max(0, plans.FindIndex(p => p.Name == (s?.OnboardProtocol ?? "")) is int pi and >= 0 ? pi
            : plans.FindIndex(p => p.Name == (_view.Engine.Protocol is EmulatorRelay er ? er.Name.Replace(" via emulator", "") : "Multi-byte 20h")));
        _rate.ItemsSource = Rates.Select(r => r.Text).ToList();
        _rate.SelectedIndex = Math.Clamp(Array.FindIndex(Rates, r => r.Skip == (s?.OnboardSkip ?? 0)), 0, Rates.Length - 1);
        _trigger.ItemsSource = Triggers.Select(t => t.Text).ToList();
        _trigger.SelectedIndex = Math.Clamp(s?.OnboardTrigger ?? 0, 0, Triggers.Length - 1);
        _above.Value = s?.OnboardAbove ?? 0;
        _compress.IsChecked = s?.OnboardCompress ?? false;
        _trigger.SelectionChanged += (_, _) => ShowTrigger();
        _protocol.SelectionChanged += (_, _) => ShowTrigger();
        _rate.SelectionChanged += (_, _) => ShowTrigger();
        ShowTrigger();
        ToolTip.SetTip(_protocol, "What the Demon asks the ECU for: the ROM's datalog request (the same one datalogging through the Demon uses).");
        ToolTip.SetTip(_rate, "Keep every packet (about 65 a second for the 51-byte frame), or only some of them: the memory lasts longer.");
        ToolTip.SetTip(_trigger, "When a session is logged: always while the key is on, or only while the throttle, the speed or the manifold pressure is above a value.");

        var arm = Act("Start onboard logging", "Set the Demon up (what to ask, how often, when) and switch its onboard logging on. It then logs by itself, with the laptop gone, until it is switched off here.", Arm);
        var stop = Act("Stop onboard logging", "Switch the Demon's onboard logging off.", () => Run("stopping", d => d.Enable(false, out var n) ? "onboard logging is off" : n));
        var read = Act("Read the state", "How many sessions the Demon holds, how full it is, whether it is logging.", () => Run("reading the state", _ => "ok"));
        var download = Act("Download the sessions", "Read every session the Demon has logged, to open in the datalog or save.", Download);
        var erase = Act("Erase…", "Erase every session in the Demon (about ten seconds).", Erase);

        var form = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), RowDefinitions = new RowDefinitions("Auto,Auto,Auto,Auto"), Margin = new Thickness(0, 6) };
        void Row(int r, string label, Control c)
        {
            var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 3, 10, 3) };
            Grid.SetRow(l, r); form.Children.Add(l);
            c.Margin = new Thickness(0, 3); Grid.SetRow(c, r); Grid.SetColumn(c, 1); form.Children.Add(c);
        }
        Row(0, "Ask the ECU", _protocol);
        Row(1, "Keep", _rate);
        var trig = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        trig.Children.Add(_trigger); trig.Children.Add(_above); trig.Children.Add(_aboveUnit);
        Row(2, "Log", trig);
        Row(3, "", _compress);

        _open.Click += (_, _) => OpenSelected();
        _save.Click += async (_, _) => await SaveSelected();
        _sessions.SelectionChanged += (_, _) => { _open.IsEnabled = _save.IsEnabled = _sessions.SelectedIndex >= 0; };
        _sessions.DoubleTapped += (_, _) => OpenSelected();

        var body = new StackPanel { Margin = new Thickness(14, 10), Spacing = 6 };
        body.Children.Add(_state);
        body.Children.Add(Head("SET UP"));
        body.Children.Add(form);
        body.Children.Add(Wrap(arm, stop, read));
        body.Children.Add(Head("SESSIONS"));
        body.Children.Add(Wrap(download, erase));
        body.Children.Add(_sessions);
        body.Children.Add(Wrap(_open, _save));
        body.Children.Add(_progress);
        body.Children.Add(_status);
        body.Children.Add(new TextBlock
        {
            Text = "The Demon keeps what it asks the ECU until it loses both USB and key-on power: start onboard logging again after that. " +
                   "Its samples carry no time of their own: they are timed here by the rate the Demon gets them at.",
            FontSize = 11, Opacity = 0.6, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
        });

        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(new ScrollViewer { Content = body });
        Content = root;
        Opened += (_, _) => { if (Ready(out var why)) Run("reading the state", _ => "ok"); else _state.Text = why; };
    }

    static TextBlock Head(string t) => new() { Text = t, FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 8, 0, 0) };

    static WrapPanel Wrap(params Control[] items)
    {
        var w = new WrapPanel();
        foreach (var c in items) { c.Margin = new Thickness(0, 0, 6, 6); w.Children.Add(c); }
        return w;
    }

    Button Act(string text, string tip, Action a)
    {
        var b = new Button { Content = text, MinHeight = 36 };
        ToolTip.SetTip(b, tip);
        b.Click += (_, _) => a();
        _actions.Add(b);
        return b;
    }

    RelayPlan? Plan() => EmulatorRelay.Candidates().ElementAtOrDefault(_protocol.SelectedIndex)?.Relay;

    void ShowTrigger()
    {
        var t = Triggers[Math.Max(0, _trigger.SelectedIndex)];
        bool honda = Plan()?.Length == HondaDatalog.FrameLength;
        _above.IsVisible = _aboveUnit.IsVisible = t.At >= 0;
        _aboveUnit.Text = t.Unit;
        _trigger.IsEnabled = honda;
        if (!honda) _trigger.SelectedIndex = 0;
        if (Plan() is { } p) ToolTip.SetTip(_rate, $"About {DemonOnboard.EstimatedHz(p, Rates[Math.Max(0, _rate.SelectedIndex)].Skip):0} packets a second kept.");
    }

    bool Ready(out string why)
    {
        why = !_host.Emulator.Connected ? "Connect the Demon first (Emulator menu): onboard logging is set up and read over its port."
            : !(_host.Emulator.Device.Contains("Demon", StringComparison.OrdinalIgnoreCase) || _host.Emulator.Kind == "Demon")
                ? $"The emulator on {_host.Emulator.PortName} is {(_host.Emulator.Device.Length > 0 ? "a " + _host.Emulator.Device : "not a Demon")}: onboard logging is the Demon's."
            : "";
        return why.Length == 0;
    }

    /// The Demon's triggers for the choice made: a byte of the packet in a range (the packet's byte 0 is the Demon's 'O').
    List<DemonOnboard.Trigger> TriggersNow()
    {
        var t = Triggers[Math.Max(0, _trigger.SelectedIndex)];
        double v = (double)(_above.Value ?? 0);
        if (Plan()?.Length != HondaDatalog.FrameLength) return [];
        if (t.At < 0) return [new(26, 0, 0, 255)];         // the battery byte, anything: while the ECU answers (as the tuning software does it)
        byte low = t.Unit switch
        {
            "%" => (byte)Math.Clamp(Math.Round((v * 2.04) + 25), 0, 255),
            "kPa" => (byte)Math.Clamp(Math.Round(((v * 10) + 59) / 7.221), 0, 255),
            _ => (byte)Math.Clamp(Math.Round(v), 0, 255),
        };
        return [new(t.At, 0, low, 255)];
    }

    void Arm()
    {
        if (Plan() is not { } plan) { _status.Text = "pick what to ask the ECU"; return; }
        int skip = Rates[Math.Max(0, _rate.SelectedIndex)].Skip;
        var triggers = TriggersNow();
        bool compress = _compress.IsChecked == true;
        if (_settings?.Invoke() is { } s)
        {
            s.OnboardProtocol = (string?)_protocol.SelectedItem ?? ""; s.OnboardSkip = skip; s.OnboardTrigger = _trigger.SelectedIndex;
            s.OnboardAbove = (int)(_above.Value ?? 0); s.OnboardCompress = compress; s.Save();
        }
        Run("setting the Demon up", d =>
        {
            d.Enable(false, out _);
            if (!d.Setup(plan, skip, triggers, out var why)) return why;
            if (!d.Compression(compress)) return "the Demon did not take the packet mode";
            if (!d.Enable(true, out why)) return why;
            AppLog.Action("onboard", $"armed: {plan.Request:X2} x{plan.Length}, every {skip + 1}, {triggers.Count} trigger(s), {(compress ? "compressed" : "plain")}");
            return $"onboard logging is on: about {DemonOnboard.EstimatedHz(plan, skip):0} packets a second, {(triggers.Count == 0 || triggers[0].At == 26 ? "while the key is on" : "while " + _trigger.SelectedItem + " " + _above.Value + " " + _aboveUnit.Text)}";
        });
    }

    async void Erase()
    {
        if (!await Dialogs.Confirm(this, "Erase the Demon?", "Erase every session the Demon holds? It takes about ten seconds and cannot be undone.", "Erase", "Not now")) return;
        Run("erasing (about ten seconds)", d => d.Erase() ? "erased" : "the Demon did not say it had erased");
    }

    void Download()
    {
        if (Plan() is not { } plan) { _status.Text = "pick what the Demon asked the ECU for (the setting it was started with)"; return; }
        double hz = DemonOnboard.EstimatedHz(plan, Rates[Math.Max(0, _rate.SelectedIndex)].Skip);
        Run("reading the sessions", d =>
        {
            var st = d.ReadState(out var why);
            if (st == null) return why;
            bool was = st.Enabled;
            // stopped while it is read (the tuning software does the same), started again after if it was on
            d.Enable(false, out _);
            try
            {
                if (st.PageWritten == 0) { Dispatcher.UIThread.Post(() => { _read = []; _sessions.ItemsSource = null; }); return "the Demon holds no sessions"; }
                var flash = d.ReadPages(0, Math.Min(st.PageWritten + 1, st.Pages), st.PageSize, p => Dispatcher.UIThread.Post(() => _progress.Value = p));
                if (flash == null) return "a read of the Demon's memory failed (its checksum): try again";
                var list = DemonOnboard.Parse(flash, st.PageSize, plan, hz);
                Dispatcher.UIThread.Post(() =>
                {
                    _read = list; _readPlan = plan;
                    _sessions.ItemsSource = list.Select(x => $"Session {x.Number}: {x.Frames.Count} samples, about {TimeSpan.FromSeconds(x.Frames.Count / hz):m\\:ss}" +
                                                             (x.Compressed ? ", compressed" : "") + (x.Bad > 0 ? $", {x.Bad} unreadable" : "") + (x.Cut ? " (cut short: power lost?)" : "")).ToList();
                });
                AppLog.Action("onboard", $"downloaded {list.Count} session(s), {list.Sum(x => x.Frames.Count)} samples");
                return $"{list.Count} session(s) read";
            }
            finally { if (was) d.Enable(true, out _); }
        });
    }

    void OpenSelected()
    {
        if (_sessions.SelectedIndex < 0 || _sessions.SelectedIndex >= _read.Count) return;
        var s = _read[_sessions.SelectedIndex];
        _view.LoadFrames([.. s.Frames], $"Demon onboard session {s.Number}");
        _status.Text = $"session {s.Number} opened in the datalog panel";
    }

    async Task SaveSelected()
    {
        if (_sessions.SelectedIndex < 0 || _sessions.SelectedIndex >= _read.Count) return;
        var s = _read[_sessions.SelectedIndex];
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Save the session", SuggestedFileName = $"demon-onboard-{s.Number}.csv", DefaultExtension = "csv",
            FileTypeChoices = [new FilePickerFileType("CSV") { Patterns = ["*.csv"] }],
        });
        if (file?.TryGetLocalPath() is not { } path) return;
        LogFile.SaveCsv(path, s.Frames);
        _status.Text = $"saved {Path.GetFileName(path)}";
    }

    /// Talk to the Demon off the UI thread, with the live datalog through it paused meanwhile; the state is read after.
    void Run(string what, Func<DemonOnboard, string> work)
    {
        if (!Ready(out var why)) { _status.Text = why; return; }
        var engine = _view.Engine;
        bool paused = engine.Running && engine.Source.StartsWith("emulator", StringComparison.OrdinalIgnoreCase);
        foreach (var b in _actions) b.IsEnabled = false;
        _progress.IsVisible = true; _progress.Value = 0;
        _status.Text = what + "…";
        Task.Run(() =>
        {
            string result, state = "";
            try
            {
                if (paused) Dispatcher.UIThread.Invoke(() => _view.PauseForEmulator());
                var d = new DemonOnboard(new EmulatorLink(_host.Emulator))
                {
                    OnPacket = p => AppLog.Write(LogKind.Serial, "onboard", $"{(p.Dir == PacketDir.Tx ? "→" : "←")} {p.Bytes.Length} bytes  {p.Note}",
                                                  string.Join(" ", p.Bytes.Take(32).Select(x => x.ToString("X2")))),
                };
                result = work(d);
                if (d.ReadState(out var n) is { } st)
                    state = $"The Demon holds {st.Sessions} session(s), {st.UsedBytes / 1024.0:0} KB of {st.Bytes / 1024} KB used. Onboard logging is {(st.Enabled ? "ON" : "off")}" +
                            $"{(st.SessionOpen ? ", logging a session now" : "")}{(st.Full ? " - its memory is FULL" : "")}; packets {(st.Compressed ? "compressed" : "plain")}.";
                else state = "The Demon's state could not be read: " + n;
            }
            catch (Exception ex) { result = "failed: " + ex.Message; AppLog.Error("onboard", what, ex); }
            finally { if (paused) Dispatcher.UIThread.Post(() => _view.ResumeAfterEmulator()); }
            Dispatcher.UIThread.Post(() =>
            {
                _status.Text = result;
                if (state.Length > 0) _state.Text = state;
                _progress.IsVisible = false;
                foreach (var b in _actions) b.IsEnabled = true;
            });
        });
    }
}
