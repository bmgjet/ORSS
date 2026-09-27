// Copyright (c) bmgjet. All rights reserved.
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

using OkiRomSim.Core;
namespace OkiRomSim.Desktop;

/// The Trace page. Plainly, the instructions the simulator ran, newest at the bottom. With Hit trace ticked: which ROM addresses are being fetched, as instructions or as data, shown as a list in the order they happen and as colour on the source lines. The hits come from the simulator, or from a real ECU through a Moates Ostrich 2.0 / Demon running its Trace.
public sealed class HitTraceView : UserControl
{
    readonly SimHost _host;
    readonly Func<string, string?> _sourceText;
    MoatesTrace _moates => _host.Emulator;
    readonly ComboBox _source = new() { Width = 190, ItemsSource = new[] { "Simulator", "Ostrich 2.0 / Demon (serial)" }, SelectedIndex = 0 };
    readonly Button _connect, _upload, _start;
    // set in Settings > Emulator & datalog
    string _port = "", _base = "8000";
    bool _nonRedundant = true;
    readonly TextBlock _status = new() { FontSize = 11, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _summary = new() { FontSize = 11, Opacity = 0.8, Margin = new Thickness(10, 4), TextWrapping = TextWrapping.Wrap };
    readonly CheckBox _hitMode = new() { Content = "Hit trace", FontSize = 12, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
    readonly Control _plain;
    readonly Panel _hitBar = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly Border _summaryBar;
    readonly ContentControl _body = new();
    readonly DataList _flow = new(new("Address", 76), new("Kind", 60), new("Routine", 230), new("Instruction / source line", 300))
    {
        Empty = "No hits yet: run the simulator, or connect an Ostrich 2.0 / Demon and start its trace.",
    };
    DateTime _lastHeavy;
    long _lastFlowKey = -1;

    public event Action<int>? GoToAddress;
    public bool ColourSource { get; private set; } = true;
    public bool Hardware => _source.SelectedIndex == 1;
    /// Hit trace ticked: the fetches (code and data), from the simulator or the emulator, instead of the instructions alone.
    public bool HitMode { get => _hitMode.IsChecked == true; set => _hitMode.IsChecked = value; }

    public HitTraceView(SimHost host, Control plain, Func<string, string?> sourceText)
    {
        _host = host; _sourceText = sourceText; _plain = plain;
        _moates.Hit += a => _host.ExternalHits.Add(a);
        _moates.Status += m => Dispatcher.UIThread.Post(() => _status.Text = m);

        _connect = Btn("Connect", Connect, "Open the emulator's serial port (Settings > Emulator & datalog) and identify the Ostrich / Demon (921.6 kbaud).");
        _upload = Btn("Upload ROM", Upload, "Write the ROM image the simulator is running (with any calibration edits) into the emulator, so the car runs exactly this code.");
        _start = Btn("Start trace", StartStop, "Start or stop the emulator's address-hit Trace. Every EPROM address the ECU fetches is reported and marked in the source.");
        var clear = Btn("Clear", () =>
        {
            if (Hardware) _host.ExternalHits.Clear(); else _host.ClearSimHits();
            _lastFlowKey = -1;
            _status.Text = "hits cleared";
        }, "Forget all hits so far (for the simulator this also resets its coverage counters).");

        _hitBar.Children.Add(Panels.Divider());
        _hitBar.Children.Add(Label("Source"));
        _hitBar.Children.Add(_source);
        _hitBar.Children.Add(_connect); _hitBar.Children.Add(_upload);
        _hitBar.Children.Add(_start);
        _hitBar.Children.Add(clear);
        var bar = Panels.Bar(_hitMode, _hitBar, _status);
        _status.Margin = new Thickness(8, 0);
        ToolTip.SetTip(_hitMode, "Hit trace: every ROM address fetched - instructions and the table and constant bytes they read - in the order they " +
                                 "happen, from the simulator or from a real ECU through a Moates Ostrich 2.0 / Demon, and the source coloured by what " +
                                 "was fetched (green = executed, blue = read as data, brighter = more recent). Off: the instructions the simulator ran.");
        _hitMode.IsCheckedChanged += (_, _) => { ShowMode(); AppLog.Action("trace", HitMode ? "hit trace on" : "hit trace off"); };
        ToolTip.SetTip(_source, "Simulator: hits from the simulated CPU (instructions it ran, ROM bytes it read). Ostrich 2.0 / Demon: hits streamed from a real ECU through the emulator's Trace.");
        ToolTip.SetTip(_flow, "Hits in the order they happened, newest at the bottom. Double-click one to go to it in the source.");
        _source.SelectionChanged += (_, _) => UpdateButtons();
        _flow.Activated += r => { if (r.Address >= 0) GoToAddress?.Invoke(r.Address); };

        _summaryBar = new Border { Child = _summary };
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*") };
        Grid.SetRow(bar, 0); g.Children.Add(bar);
        Grid.SetRow(_summaryBar, 1); g.Children.Add(_summaryBar);
        Grid.SetRow(_body, 2); g.Children.Add(_body);
        Content = g;
        ShowMode();
        UpdateButtons();
    }

    void ShowMode()
    {
        bool hit = HitMode;
        _hitBar.IsVisible = hit;
        _summaryBar.IsVisible = hit;
        _body.Content = UiStyles.Adopt(hit ? (Control)_flow : _plain);
        _status.Text = "";
        _lastFlowKey = -1;
    }

    /// Serial work waits on the cable: run it off the UI thread and show the result after.
    void RunOffThread(string busy, Func<string> work)
    {
        _status.Text = busy;
        Task.Run(() =>
        {
            string message;
            try { message = work(); }
            catch (Exception ex) { message = ex.Message; AppLog.Error("hit trace", busy, ex); }
            Dispatcher.UIThread.Post(() => { _status.Text = message; UpdateButtons(); });
        });
    }

    static TextBlock Label(string t) => new() { Text = t, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 4, 0), FontSize = 11 };
    static Button Btn(string text, Action a, string tip)
    {
        var b = new Button { Content = text, Margin = new Thickness(2, 1), FontSize = 11.5, Padding = new Thickness(8, 3) };
        b.Click += (_, _) => a();
        ToolTip.SetTip(b, tip);
        return b;
    }

    void UpdateButtons()
    {
        bool hw = Hardware;
        _connect.IsEnabled = hw;
        _upload.IsEnabled = hw && _moates.Connected;
        _start.IsEnabled = !hw || _moates.Connected;
        _connect.Content = _moates.Connected ? "Disconnect" : "Connect";
        _start.Content = hw && _moates.Tracing ? "Stop trace" : "Start trace";
        ToolTip.SetTip(_start, hw ? "Start or stop the emulator's address-hit Trace. Every EPROM address the ECU fetches is reported and marked in the source."
                                  : "The simulator always traces: nothing to start. Pick Ostrich 2.0 / Demon as the source to trace a real ECU.");
        if (!hw) _start.IsEnabled = false;
    }

    void Connect()
    {
        try
        {
            if (_moates.Connected)
            {
                RunOffThread("disconnecting…", () => { _host.EmulatorDisconnect(); return "disconnected"; });
            }
            else
            {
                var p = _port.Length > 0 ? _port : MoatesTrace.Ports().LastOrDefault() ?? "";
                if (p.Length == 0) _status.Text = "no serial port: set it in Settings > Emulator & datalog";
                else RunOffThread($"connecting to {p}…", () => "connected: " + _host.EmulatorConnect(p));
            }
        }
        catch (Exception ex) { _status.Text = "connect failed: " + ex.Message; _host.EmulatorDisconnect(); AppLog.Error("hit trace", "connect failed", ex); }
        UpdateButtons();
    }

    void Upload()
    {
        try
        {
            RunOffThread("uploading the ROM…", () => _host.EmulatorUploadAll());
        }
        catch (Exception ex) { _status.Text = "upload failed: " + ex.Message; AppLog.Error("hit trace", "upload failed", ex); }
    }

    void StartStop()
    {
        try
        {
            if (_moates.Tracing) { _moates.StopTrace(); _status.Text = $"trace stopped after {_moates.Hits:N0} hits"; }
            else
            {
                if (int.TryParse(_base, System.Globalization.NumberStyles.HexNumber, null, out var b)) _moates.Base = b;
                _moates.StartTrace(Bus.RomSize, _nonRedundant);
                _status.Text = $"tracing {_moates.Base:X5}-{_moates.Base + Bus.RomSize - 1:X5}";
            }
        }
        catch (Exception ex) { _status.Text = "trace failed: " + ex.Message; }
        UpdateButtons();
    }

    static readonly Regex DataLine = new(@"^\s*([A-Za-z_][\w]*\s*:)?\s*(DB|DW)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// Source colouring for one file: line -> (executed?, recency 0..1).
    public Dictionary<int, (bool Code, double Heat)>? LineHits(string file)
    {
        if (!ColourSource || _host.Assembly is not { } asm) return null;
        var full = Path.GetFullPath(file);
        var entries = asm.SourceMap.Where(e => string.Equals(e.File, full, StringComparison.OrdinalIgnoreCase)).ToList();
        if (entries.Count == 0) return null;
        var result = new Dictionary<int, (bool, double)>();
        if (!Hardware)
        {
            var (now, exec, data, count) = _host.SimHits();
            double Heat(ulong at) => at == 0 ? 0 : Math.Clamp(1 - ((now - Math.Min(now, at)) / Bus.CpuHz / 2.0), 0, 1);
            foreach (var e in entries)
            {
                if (e.Address >= Bus.RomSize) continue;
                if (exec[e.Address] > 0) { result[e.Line] = (true, Heat(exec[e.Address])); continue; }
                ulong last = 0;
                for (int i = 0; i < e.Length && e.Address + i < Bus.RomSize; i++)
                    if (count[e.Address + i] > 0) last = Math.Max(last, data[e.Address + i]);
                if (last > 0) result[e.Line] = (false, Heat(last));
            }
        }
        else
        {
            var hits = _host.ExternalHits;
            long now = HitStore.Now;
            var text = _sourceText(file)?.Split('\n');
            foreach (var e in entries)
            {
                long last = 0;
                for (int i = 0; i < e.Length && e.Address + i < Bus.RomSize; i++)
                    if (hits.Count[e.Address + i] > 0) last = Math.Max(last, hits.Last[e.Address + i]);
                if (last == 0) continue;
                bool data = text != null && e.Line - 1 < text.Length && DataLine.IsMatch(text[e.Line - 1]);
                result[e.Line] = (!data, Math.Clamp(1 - (HitStore.Seconds(now - last) / 2.0), 0, 1));
            }
        }
        return result;
    }

    /// Called on the UI refresh tick while the tab is showing.
    public void Tick(SimHost.Snapshot s)
    {
        if ((DateTime.UtcNow - _lastHeavy).TotalMilliseconds < 400) return;
        _lastHeavy = DateTime.UtcNow;
        UpdateButtons();
        var asm = _host.Assembly;
        string Where(int a)
        {
            var src = asm?.Lookup(a);
            var line = src == null ? null : _sourceText(src.File)?.Split('\n') is { } t && src.Line - 1 < t.Length ? t[src.Line - 1].Trim() : null;
            if (line != null && line.Length > 70) line = line[..70];
            return line ?? "";
        }
        var rows = new List<DataList.Row>();
        DataList.Row Hit(int a, bool code, string what) => new(
            [new($"{a:X4}", DataList.Address), new(code ? "code" : "data", code ? DataList.Code : DataList.Data), new(_host.NearestLabel(a), DataList.Label),
             new(what, code ? DataList.MnemonicInk(what) : DataList.Dim)],
            code ? DataList.Code : DataList.Data, a, _host.Where((ushort)a) + Environment.NewLine + what);
        if (!Hardware)
        {
            var reads = _host.RecentRomReads(400);
            long key = s.Instructions;
            if (key == _lastFlowKey) return;
            _lastFlowKey = key;
            var byPc = reads.GroupBy(r => r.Pc).ToDictionary(g => g.Key, g => g.Select(x => x.Address).Distinct().ToList());
            foreach (var t in s.Trace.TakeLast(120))
            {
                rows.Add(Hit(t.Pc, true, t.Text));
                if (byPc.TryGetValue(t.Pc, out var data))
                    foreach (var a in data.Take(4)) rows.Add(Hit(a, false, "read: " + Where(a)));
            }
            _summary.Text = $"Simulator: {s.Coverage:N0} ROM addresses executed so far, {reads.Count} recent data reads. " +
                            "Source lines: green = executed, blue = read as data; brighter = more recent.";
        }
        else
        {
            var hits = _host.ExternalHits;
            long total = hits.Total;
            if (total == _lastFlowKey) return;
            _lastFlowKey = total;
            long n = Math.Min(Math.Min(total, 300), hits.Recent.Length);
            for (long i = total - n; i < total; i++)
            {
                int a = hits.Recent[i % hits.Recent.Length];
                var line = Where(a);
                rows.Add(Hit(a, !DataLine.IsMatch(line), line));
            }
            int distinct = hits.Count.Count(c => c > 0);
            _summary.Text = $"{(_moates.Connected ? _moates.Version : "not connected")}: {total:N0} hits, {distinct:N0} different addresses. " +
                            "Source lines: green = instruction fetched, blue = data read; brighter = more recent.";
        }
        _flow.SetRows(rows, follow: true);
    }

    public void Shutdown() => _moates.Close();

    /// Settings > Emulator & datalog.
    public void SetOptions(string port, string windowBase, bool skipRepeats, bool colourSource)
    {
        _port = port; _base = windowBase.Length > 0 ? windowBase : "8000";
        _nonRedundant = skipRepeats; ColourSource = colourSource;
    }
}
