// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using System.IO.Ports;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace ScanToolPlugin;

/// The first plugin, and the one to copy to start a new one: datalogging from an ELM327 scan tool. It adds "Scan tool (ELM327)…" to the Plugins menu and a Settings page; the window it opens connects to the adapter, asks the car for the standard OBD-II readings and, if you like, feeds them to the Datalog page like any other connection - so the gauges, the graph, recording, the map trace and the O2 tables all work from it.
public sealed class ScanToolPlugin : IOkiPlugin
{
    public string Name => "Scan tool";
    public string Description => "Datalog from an ELM327 scan tool: engine speed, speed, temperatures, MAP, throttle, timing, load, fuel trims, air flow, O2 and battery, into the Datalog page.";
    public string Version => "1.0";

    PluginContext _app = null!;
    ScanSession? _session;
    Window? _window;

    public void Start(PluginContext app)
    {
        _app = app;
        app.AddMenuItem("Scan tool (ELM327)…", OpenWindow, "Connect to an ELM327 scan tool and log the car's OBD-II readings.", "🔌");
        app.AddSettingsPage("Scan tool", SettingsPage);
        // Disconnect on the Datalog page stops the scan tool too
        app.DatalogEngine.ExternalStopped += () => { if (_session is { FeedsDatalog: true }) StopSession(); };
    }

    public void Stop() => StopSession();

    // ------------------------------------------------------------------ settings

    string Port { get => _app.GetSetting("port") ?? OkiRomSim.Desktop.SerialLink.Ports().FirstOrDefault() ?? ""; set => _app.SetSetting("port", value); }
    int Baud { get => int.TryParse(_app.GetSetting("baud"), out var b) ? b : 38400; set => _app.SetSetting("baud", value.ToString(CultureInfo.InvariantCulture)); }
    string ObdProtocol { get => _app.GetSetting("protocol") ?? "0"; set => _app.SetSetting("protocol", value); }
    bool Feed { get => _app.GetSetting("feed") != "0"; set => _app.SetSetting("feed", value ? "1" : "0"); }
    HashSet<byte> Wanted
    {
        get => _app.GetSetting("pids") is { Length: > 0 } s
            ? [.. s.Split(',').Select(x => byte.TryParse(x, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b) ? b : (byte)0).Where(b => b != 0)]
            : [.. Elm327.Pids.Select(p => p.Code)];
        set => _app.SetSetting("pids", string.Join(",", value.Select(b => b.ToString("X2"))));
    }

    static readonly int[] Bauds = [38400, 9600, 57600, 115200, 230400, 500000];
    static readonly (string Code, string Name)[] Protocols =
    [
        ("0", "Automatic"), ("1", "SAE J1850 PWM"), ("2", "SAE J1850 VPW"), ("3", "ISO 9141-2"), ("4", "ISO 14230-4 (5 baud init)"),
        ("5", "ISO 14230-4 (fast init)"), ("6", "ISO 15765-4 CAN 11 bit 500k"), ("7", "ISO 15765-4 CAN 29 bit 500k"),
        ("8", "ISO 15765-4 CAN 11 bit 250k"), ("9", "ISO 15765-4 CAN 29 bit 250k"), ("A", "SAE J1939 CAN"),
    ];

    ComboBox PortBox() => new() { ItemsSource = OkiRomSim.Desktop.SerialLink.Ports(), SelectedItem = Port, Width = 160 };
    ComboBox BaudBox() => new() { ItemsSource = Bauds, SelectedItem = Baud, Width = 120 };
    ComboBox ProtocolBox() => new() { ItemsSource = Protocols.Select(p => p.Name).ToList(), SelectedIndex = Math.Max(0, Array.FindIndex(Protocols, p => p.Code == ObdProtocol)), Width = 260 };

    Control SettingsPage()
    {
        var p = new StackPanel { Spacing = 6, Margin = new Thickness(8) };
        p.Children.Add(new TextBlock { Text = "The ELM327 the Scan tool window connects to (Plugins > Scan tool). Most adapters talk at 38400 baud; some clones at 9600 or 115200.", TextWrapping = TextWrapping.Wrap, Opacity = 0.8 });
        var port = PortBox(); port.SelectionChanged += (_, _) => { if (port.SelectedItem is string s) Port = s; };
        var baud = BaudBox(); baud.SelectionChanged += (_, _) => { if (baud.SelectedItem is int b) Baud = b; };
        var proto = ProtocolBox(); proto.SelectionChanged += (_, _) => { if (proto.SelectedIndex >= 0) ObdProtocol = Protocols[proto.SelectedIndex].Code; };
        var feed = new CheckBox { Content = "Send the readings to the Datalog page", IsChecked = Feed };
        feed.IsCheckedChanged += (_, _) => Feed = feed.IsChecked == true;
        p.Children.Add(Row("Port", port));
        p.Children.Add(Row("Baud rate", baud));
        p.Children.Add(Row("OBD protocol", proto));
        p.Children.Add(feed);
        return p;
    }

    static Control Row(string label, Control editor)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        sp.Children.Add(new TextBlock { Text = label, Width = 110, VerticalAlignment = VerticalAlignment.Center });
        sp.Children.Add(editor);
        return sp;
    }

    // ------------------------------------------------------------------ the window

    void OpenWindow()
    {
        if (_window is { IsVisible: true }) { _window.Activate(); return; }
        var port = PortBox(); var baud = BaudBox(); var proto = ProtocolBox();
        var refresh = new Button { Content = "↻", Padding = new Thickness(6, 1) };
        ToolTip.SetTip(refresh, "Look for serial ports again (an adapter plugged in since).");
        refresh.Click += (_, _) => port.ItemsSource = OkiRomSim.Desktop.SerialLink.Ports();
        var feed = new CheckBox { Content = "Send to the Datalog page (gauges, graph, recording, map trace)", IsChecked = Feed };
        var connect = new Button { Content = _session == null ? "Connect" : "Disconnect", MinWidth = 110 };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4), Text = _session?.Status ?? "not connected" };
        var log = new TextBox { IsReadOnly = true, AcceptsReturn = true, FontFamily = new FontFamily("Consolas, Menlo, monospace"), FontSize = 11, Height = 120 };

        // one line per reading: tick it to ask for it, its value beside it
        var wanted = Wanted;
        var values = new Dictionary<byte, TextBlock>();
        var rows = new StackPanel { Spacing = 2 };
        foreach (var pid in Elm327.Pids)
        {
            var box = new CheckBox { Content = $"{pid.Name}", IsChecked = wanted.Contains(pid.Code), Width = 300 };
            box.IsCheckedChanged += (_, _) =>
            {
                var w = Wanted;
                if (box.IsChecked == true) w.Add(pid.Code); else w.Remove(pid.Code);
                Wanted = w;
                _session?.SetWanted(w);
            };
            var value = new TextBlock { Width = 140, VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Consolas, Menlo, monospace") };
            values[pid.Code] = value;
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(box);
            row.Children.Add(value);
            row.Children.Add(new TextBlock { Text = $"01 {pid.Code:X2} → {pid.Channel}", Opacity = 0.55, FontSize = 11, VerticalAlignment = VerticalAlignment.Center });
            rows.Children.Add(row);
        }

        var top = new WrapPanel();
        foreach (var c in new Control[] { Row("Port", port), refresh, Row("Baud", baud), Row("Protocol", proto) }) { c.Margin = new Thickness(0, 0, 12, 4); top.Children.Add(c); }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(0, 4) };
        buttons.Children.Add(connect);
        buttons.Children.Add(feed);

        var body = new DockPanel { Margin = new Thickness(12, 8) };
        var head = new StackPanel();
        head.Children.Add(top); head.Children.Add(buttons); head.Children.Add(status);
        DockPanel.SetDock(head, Dock.Top); body.Children.Add(head);
        DockPanel.SetDock(log, Dock.Bottom); body.Children.Add(log);
        body.Children.Add(new ScrollViewer { Content = rows });

        void Refresh()
        {
            connect.Content = _session == null ? "Connect" : "Disconnect";
            status.Text = _session?.Status ?? "not connected";
            foreach (var (code, t) in values)
            {
                var pid = Elm327.Pids.First(p => p.Code == code);
                t.Text = _session?.Latest.TryGetValue(code, out var v) == true ? $"{v:0.##} {pid.Unit}"
                       : _session is { Supported.Count: > 0 } s && !s.Supported.Contains(code) && code != 0x42 ? "not on this car" : "";
            }
            if (_session != null) log.Text = _session.Log();
        }
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) => Refresh();
        timer.Start();

        connect.Click += (_, _) =>
        {
            if (_session != null) { StopSession(); Refresh(); return; }
            if (port.SelectedItem is not string p) { status.Text = "pick the adapter's serial port"; return; }
            Port = p;
            if (baud.SelectedItem is int b) Baud = b;
            if (proto.SelectedIndex >= 0) ObdProtocol = Protocols[proto.SelectedIndex].Code;
            Feed = feed.IsChecked == true;
            StartSession();
            Refresh();
        };
        _window = _app.OpenWindow("Scan tool (ELM327)", body, 760, 640);
        _window.Closed += (_, _) => { timer.Stop(); _window = null; };
    }

    void StartSession()
    {
        StopSession();
        _session = new ScanSession(_app, Port, Baud, ObdProtocol, Wanted, Feed);
        _app.SetStatus($"connecting to the ELM327 on {Port}…");
    }

    void StopSession()
    {
        var s = _session;
        _session = null;
        s?.Dispose();
    }
}

/// A connection to the adapter on its own thread: set up, then round the wanted readings for as long as it runs. A lost link is tried again (Settings > Emulator & datalog > Reconnecting says how often) before it gives up.
sealed class ScanSession : IDisposable
{
    readonly PluginContext _app;
    readonly string _port, _protocol;
    readonly int _baud;
    readonly Thread _thread;
    volatile bool _stop;
    HashSet<byte> _wanted;
    readonly Queue<string> _log = new();
    public bool FeedsDatalog { get; }
    public string Status { get; private set; } = "connecting…";
    public HashSet<byte> Supported { get; private set; } = [];
    public Dictionary<byte, double> Latest { get; } = [];

    public ScanSession(PluginContext app, string port, int baud, string protocol, HashSet<byte> wanted, bool feed)
    {
        _app = app; _port = port; _baud = baud; _protocol = protocol; _wanted = wanted; FeedsDatalog = feed;
        if (feed) app.DatalogEngine.BeginExternal("ELM327 on " + port);
        _thread = new Thread(Run) { IsBackground = true, Name = "scan tool" };
        _thread.Start();
    }

    public void SetWanted(HashSet<byte> wanted) => _wanted = [.. wanted];

    public string Log() { lock (_log) return string.Join("\n", _log); }
    void Note(string line) { lock (_log) { _log.Enqueue(line); while (_log.Count > 60) _log.Dequeue(); } }

    void Run()
    {
        int tries = 0;
        while (!_stop)
        {
            try
            {
                using var elm = new Elm327(_port, _baud);
                elm.Traffic += Note;
                Status = "setting up the adapter and finding the car's protocol…";
                elm.Start(_protocol);
                Supported = [.. elm.Supported];
                Status = $"connected: {elm.Version}, protocol {elm.Protocol}, {elm.Supported.Count} readings on this car";
                _app.Log(Status);
                tries = 0;
                var battery = System.Diagnostics.Stopwatch.StartNew();
                double? volts = null;
                while (!_stop)
                {
                    var frame = new LogFrame();
                    foreach (var pid in Elm327.Pids)
                    {
                        if (_stop) break;
                        if (!_wanted.Contains(pid.Code) || !elm.Supported.Contains(pid.Code)) continue;
                        if (elm.Read(pid) is not double v) continue;
                        Latest[pid.Code] = v;
                        frame.Set(pid.Channel, Math.Round(v, 3));
                    }
                    // the adapter reads the battery itself when the car has no reading for it
                    if (_wanted.Contains(0x42) && !elm.Supported.Contains(0x42) && battery.Elapsed.TotalSeconds >= 2)
                    {
                        volts = elm.Battery(); battery.Restart();
                        if (volts is double bv) Latest[0x42] = bv;
                    }
                    if (volts is double bat && !elm.Supported.Contains(0x42)) frame.Set("batt_v", bat);
                    frame.Protocol = "ELM327";
                    if (FeedsDatalog) _app.DatalogEngine.Inject(frame);
                }
            }
            catch (Exception ex) when (!_stop)
            {
                tries++;
                Note("! " + ex.Message);
                if (tries > LinkSupervisor.Attempts)
                {
                    Status = $"gave up after {LinkSupervisor.Attempts} tries: {ex.Message}";
                    _app.Ui(() => _app.SetStatus(Status));
                    if (FeedsDatalog) _app.Ui(() => _app.DatalogEngine.EndExternal());
                    return;
                }
                Status = $"{ex.Message} - trying again ({tries} of {LinkSupervisor.Attempts})";
                Thread.Sleep(Math.Max(200, LinkSupervisor.DelayMs));
            }
            catch { return; }
        }
    }

    public void Dispose()
    {
        _stop = true;
        try { _thread.Join(3000); } catch { }
        if (FeedsDatalog) _app.DatalogEngine.EndExternal();
        Status = "not connected";
    }
}
