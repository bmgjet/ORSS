// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Datalogging > Trigger pattern: the distributor's crank (CKP), TDC and cylinder (CYP) signals as the ECU caught them over one cam
/// revolution (the skeleton ROM's trigger pattern log), as bars - each crank tooth's time, the TDC and CYP pulses under the teeth they
/// came with - and, sensor by sensor, what looks wrong. Captured once, every 2 s, every 1 s or back to back (real time); a capture that
/// fails leaves the last good one up and is counted, and the repeat carries on - only a link or a ROM that cannot do it stops it. In the
/// simulator a sensor fault can be put on the signals to see what each looks like.
public sealed class TriggerWindow : Window
{
    readonly DatalogEngine _engine;
    readonly AppHost _host;
    readonly TriggerChart _chart = new();
    readonly StackPanel _findings = new() { Spacing = 4 };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.85, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _capture;
    readonly ComboBox _repeat = new() { MinWidth = 120 };
    readonly ComboBox _fault = new() { MinWidth = 220 };
    readonly TextBlock _stats = new() { FontSize = 11.5, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0) };
    bool _busy, _closed;
    /// The repeat running now (0 none): a new one, or the window closed, ends the one before.
    int _loop;
    int _good, _missed;
    TriggerPattern? _lastGood;

    /// How often to capture: 0 once (the button), else the gap in ms between the starts of two (1 back to back).
    static readonly (string Text, int Ms)[] Repeats = [("Once", 0), ("Every 2 s", 2000), ("Every 1 s", 1000), ("Real time", 1)];

#if !TUNER_ONLY
    static readonly (TriggerFault Fault, string Text)[] Faults =
    [
        (TriggerFault.None, "Simulate: sensors healthy"),
        (TriggerFault.CkpMissedTooth, "Simulate: crank misses a tooth"),
        (TriggerFault.CkpExtraPulse, "Simulate: noise on the crank"),
        (TriggerFault.TdcMissing, "Simulate: a TDC pulse missing"),
        (TriggerFault.CypMissing, "Simulate: no cylinder pulse"),
        (TriggerFault.CypLate, "Simulate: cylinder pulse late"),
    ];
#endif

    public TriggerWindow(DatalogEngine engine, AppHost host)
    {
        _engine = engine; _host = host;
        Title = "Trigger pattern";
        Width = 900; Height = 620; MinWidth = 560; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _capture = Panels.Button("Capture", () => _ = Capture(), "Catch one cam revolution now: the ECU records the next 24 crank teeth and the TDC and cylinder pulses with them (the datalog stops for a moment).", Toolbar.Run);
        _repeat.ItemsSource = Repeats.Select(r => r.Text).ToList();
        _repeat.SelectedIndex = 0;
        ToolTip.SetTip(_repeat, "Capture again and again, to catch a fault that comes and goes (a sensor that drops out when hot, or over bumps): every 2 s, " +
            "every 1 s, or real time - one revolution straight after the other, as fast as the ECU sends them (the datalog's other channels pause meanwhile). " +
            "A capture that fails leaves the last good one up and is counted; the repeat carries on.");
        _repeat.SelectionChanged += (_, _) => StartRepeat();
#if !TUNER_ONLY
        _fault.ItemsSource = Faults.Select(f => f.Text).ToList();
        _fault.SelectedIndex = Math.Max(0, Array.FindIndex(Faults, f => f.Fault == host.Sim.Engine.Trigger));
        _fault.SelectionChanged += (_, _) =>
        {
            if (_fault.SelectedIndex < 0) return;
            _host.SetInput("trigfault", (int)Faults[_fault.SelectedIndex].Fault);
            AppLog.Action("datalog", "trigger pattern: " + Faults[_fault.SelectedIndex].Text);
        };
        ToolTip.SetTip(_fault, "In the simulator only: put a fault on the distributor's signals, once a cam revolution, to see what it looks like here (and what the ECU makes of it).");
#endif

        var bar = Panels.Bar(_capture, _repeat, _stats, Panels.Divider(), _fault, Panels.Divider(), _status);
        var chartCard = Panels.Card("One cam revolution", _chart);
        var legend = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.75, Margin = new Thickness(2, 0, 2, 6),
            Text = "Each bar is a crank (CKP) tooth: how long since the tooth before - so a healthy engine at steady speed gives 24 bars the same height. " +
                   "A missed crank pulse shows as a bar about twice as tall, an extra (noise) pulse as two short ones. Under the bars: a TDC pulse every " +
                   "sixth tooth (four in all), and one cylinder (CYP) pulse, three teeth after cylinder 1's TDC. Shown from cylinder 1's TDC.",
        };
        var findingsCard = Panels.Card("What it shows", new ScrollViewer { Content = _findings, MaxHeight = 220 });
        var body = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto"), Margin = new Thickness(8) };
        Grid.SetRow(bar, 0); body.Children.Add(bar);
        chartCard.Margin = new Thickness(0, 6, 0, 6);
        Grid.SetRow(chartCard, 1); body.Children.Add(chartCard);
        Grid.SetRow(legend, 2); body.Children.Add(legend);
        Grid.SetRow(findingsCard, 3); body.Children.Add(findingsCard);
        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(body);
        Content = root;
        Opened += (_, _) => Refresh();
        Closed += (_, _) => { _closed = true; _loop++; };
        Show(null, "Press Capture: the datalog must be connected (the channel stream) to a ROM with the trigger pattern log.");
    }

    /// The bar's state as it is now (the simulator's fault list only while logging from the simulator).
#if !TUNER_ONLY
    void Refresh() => _fault.IsVisible = _engine.OnSimulator || !_engine.Running && _host.LoadedPath != null;
#else
    void Refresh() => _fault.IsVisible = false;   // the simulated faults need the simulator, which this build does not have
#endif

    /// Nothing more can come: the datalog is not connected, not the channel stream, or the ROM has no trigger pattern log.
    bool CannotAsk(out string why)
    {
        why = !_engine.Running ? "the datalog is not connected: Datalogging > Connect"
            : _engine.Protocol is not ChannelStream cs ? "the trigger pattern needs the channel stream (the skeleton ROM's datalog)"
            : cs.Version >= 4 && !cs.HasTriggerLog ? $"this ROM has no trigger pattern log: add it with {AboutPage.ChangeFunctions}"
            : "";
        return why.Length > 0;
    }

    /// The repeat picked: the one before ends, this one starts (Once: none).
    void StartRepeat()
    {
        int me = ++_loop;
        _good = _missed = 0;
        int ms = Repeats[Math.Max(0, _repeat.SelectedIndex)].Ms;
        AppLog.Action("datalog", "trigger pattern: " + Repeats[Math.Max(0, _repeat.SelectedIndex)].Text);
        if (ms == 0) { _stats.Text = ""; return; }
        _ = Loop(me, ms);
    }

    async Task Loop(int me, int ms)
    {
        var sw = new System.Diagnostics.Stopwatch();
        while (me == _loop && !_closed)
        {
            sw.Restart();
            if (CannotAsk(out var why))
            {
                _status.Text = why + " - the repeat waits for it";
                await Task.Delay(1000);
                continue;
            }
            await Capture();
            if (me != _loop || _closed) return;
            int wait = Math.Max(ms == 1 ? 20 : 50, ms - (int)sw.ElapsedMilliseconds);   // real time: just room for the stream to say it is alive
            await Task.Delay(wait);
        }
    }

    async Task Capture()
    {
        if (_busy || _closed) return;
        _busy = true;
        _capture.IsEnabled = false;
        Refresh();
        if (_repeat.SelectedIndex <= 0) _status.Text = "capturing a cam revolution…";
        try
        {
            var (p, note) = await _engine.CaptureTrigger();
            if (_closed) return;
            if (p != null)
            {
                // what the ECU caught, whole or not: a revolution the crank signal stopped in is the fault itself, shown as it got
                _good++;
                _lastGood = p;
                Show(p, $"{p.At:HH:mm:ss.f}  {p.Summary()}");
            }
            else
            {
                // nothing came back (a byte lost on the line): the last good one stays up, the miss is counted
                _missed++;
                _status.Text = note + (_lastGood != null ? $" - showing the one from {_lastGood.At:HH:mm:ss.f}" : "");
            }
            if (_repeat.SelectedIndex > 0) _stats.Text = $"{_good} caught{(_missed > 0 ? $", {_missed} missed" : "")}";
        }
        catch (Exception ex) { _missed++; AppLog.Error("datalog", "trigger pattern", ex); _status.Text = "the capture failed: " + ex.Message; }
        finally { _busy = false; _capture.IsEnabled = true; }
    }

    void Show(TriggerPattern? p, string status)
    {
        _status.Text = status;
        _chart.Pattern = p;
        _findings.Children.Clear();
        if (p == null) return;
        var found = p.Analyse();
        foreach (var sensor in new[] { "CKP", "TDC", "CYP" })
        {
            var mine = found.Where(f => f.Sensor == sensor).ToList();
            string name = sensor switch { "CKP" => "Crank (CKP)", "TDC" => "TDC", _ => "Cylinder (CYP)" };
            if (mine.Count == 0)
            {
                if (!p.Complete && sensor != "CKP") continue;
                _findings.Children.Add(Line(TriggerPattern.Severity.Ok, name, sensor switch
                {
                    "CKP" => $"24 even teeth (about {p.Rpm:0} rpm).",
                    "TDC" => "Four pulses, six teeth apart.",
                    _ => "One pulse, three teeth after cylinder 1's TDC.",
                }));
            }
            foreach (var f in mine) _findings.Children.Add(Line(f.Level, name, f.Text));
        }
    }

    static Control Line(TriggerPattern.Severity level, string sensor, string text)
    {
        var dot = new Avalonia.Controls.Shapes.Ellipse
        {
            Width = 10, Height = 10, Margin = new Thickness(0, 4, 8, 0), VerticalAlignment = VerticalAlignment.Top,
            Fill = AppTheme.Brush(level switch { TriggerPattern.Severity.Ok => Color.FromRgb(0x4c, 0xc0, 0x6a), TriggerPattern.Severity.Warn => Color.FromRgb(0xe6, 0xb0, 0x40), _ => Color.FromRgb(0xe0, 0x50, 0x50) }),
        };
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,110,*") };
        var name = new TextBlock { Text = sensor, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Top };
        var t = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(dot, 0); g.Children.Add(dot);
        Grid.SetColumn(name, 1); g.Children.Add(name);
        Grid.SetColumn(t, 2); g.Children.Add(t);
        return g;
    }

    /// For the UI check: a capture shown without a datalog.
    public void ShowForCheck(TriggerPattern p) => Show(p, $"{p.At:HH:mm:ss}  {p.Summary()}");

    /// For the UI check: a repeat picked (its index in Once / Every 2 s / Every 1 s / Real time), and what it has caught so far.
    public void RepeatForCheck(int i) => _repeat.SelectedIndex = i;
    public (int Good, int Missed) StatsForCheck => (_good, _missed);
}

/// The bars: one a crank tooth, as tall as its time; the usual height as a dashed line; the TDC and cylinder pulses in two rows under
/// them; the teeth a finding names in red.
public sealed class TriggerChart : Control
{
    TriggerPattern? _p;
    public TriggerPattern? Pattern { get => _p; set { _p = value; InvalidateVisual(); } }

    public TriggerChart() { MinHeight = 200; ClipToBounds = true; }

    static readonly Color Bar = Color.FromRgb(0x4e, 0xa1, 0xff), Bad = Color.FromRgb(0xe0, 0x50, 0x50), Tdc = Color.FromRgb(0xe6, 0xb0, 0x40), Cyp = Color.FromRgb(0x5c, 0xd6, 0x7a);

    public override void Render(DrawingContext ctx)
    {
        var r = new Rect(Bounds.Size);
        var text = AppTheme.Brush(DarkChrome.Text);
        var grid = new Pen(AppTheme.Brush(Color.FromArgb(50, 255, 255, 255)));
        const double left = 52, right = 10, top = 10, rowH = 18;
        double bottom = (rowH * 2) + 22;
        var plot = new Rect(left, top, Math.Max(10, r.Width - left - right), Math.Max(10, r.Height - top - bottom));
        FormattedText T(string s, double size = 11, IBrush? b = null) =>
            new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), size, b ?? text);
        ctx.DrawRectangle(null, grid, plot);
        if (_p == null || _p.Caught.Count == 0)
        {
            var msg = T(_p == null ? "No capture yet." : "No crank tooth came.", 13);
            ctx.DrawText(msg, new Point(plot.X + ((plot.Width - msg.Width) / 2), plot.Y + ((plot.Height - msg.Height) / 2)));
            return;
        }
        var teeth = _p.Ordered();
        var flagged = _p.Analyse().Where(f => f.Sensor == "CKP").SelectMany(f => f.Teeth).ToHashSet();
        double typ = Math.Max(1, _p.Typical);
        double top63 = 63;
        double y(double v) => plot.Bottom - (Math.Min(v, top63) / top63 * plot.Height);
        // the scale: milliseconds at the usual height, twice it and half it
        foreach (var k in new[] { 0.5, 1.0, 2.0 })
        {
            double v = typ * k;
            if (v > top63) continue;
            double yy = y(v);
            var pen = k == 1.0 ? new Pen(AppTheme.Brush(Color.FromArgb(150, 255, 255, 255)), 1, new DashStyle([4, 3], 0)) : grid;
            ctx.DrawLine(pen, new Point(plot.X, yy), new Point(plot.Right, yy));
            double ms = _p.Shift <= 15 ? v * (1 << _p.Shift) * TriggerPattern.UsPerCount / 1000.0 : 0;
            var lab = T(ms > 0 ? $"{ms:0.00} ms" : $"{k:0.#}x", 10);
            ctx.DrawText(lab, new Point(plot.X - lab.Width - 4, yy - (lab.Height / 2)));
        }
        double slot = plot.Width / TriggerPattern.Teeth, w = Math.Max(2, slot * 0.7);
        double rowTdc = plot.Bottom + 4, rowCyp = rowTdc + rowH;
        var tl = T("TDC", 10, AppTheme.Brush(Tdc)); ctx.DrawText(tl, new Point(plot.X - tl.Width - 4, rowTdc + 2));
        var cl = T("CYP", 10, AppTheme.Brush(Cyp)); ctx.DrawText(cl, new Point(plot.X - cl.Width - 4, rowCyp + 2));
        for (int i = 0; i < teeth.Count; i++)
        {
            var t = teeth[i];
            double x = plot.X + (i * slot) + ((slot - w) / 2);
            var b = AppTheme.Brush(flagged.Contains(i) ? Bad : Bar);
            double yy = y(t.Scaled);
            ctx.DrawRectangle(b, null, new Rect(x, yy, w, plot.Bottom - yy));
            if (t.Saturated) ctx.DrawText(T("+", 11, AppTheme.Brush(Bad)), new Point(x + (w / 2) - 3, plot.Y + 1));
            if (t.Tdc) ctx.DrawRectangle(AppTheme.Brush(Tdc), null, new Rect(x, rowTdc + 3, w, rowH - 6), 2, 2);
            if (t.Cyp) ctx.DrawRectangle(AppTheme.Brush(Cyp), null, new Rect(x, rowCyp + 3, w, rowH - 6), 2, 2);
            if (slot > 14 || i % 2 == 0)
            {
                var n = T((i + 1).ToString(CultureInfo.InvariantCulture), 9.5);
                ctx.DrawText(n, new Point(x + (w / 2) - (n.Width / 2), rowCyp + rowH + 2));
            }
        }
        // the teeth not caught (the signal stopped): greyed slots
        for (int i = teeth.Count; i < TriggerPattern.Teeth; i++)
            ctx.DrawRectangle(AppTheme.Brush(Color.FromArgb(30, 255, 255, 255)), null, new Rect(plot.X + (i * slot) + ((slot - w) / 2), plot.Y, w, plot.Height));
    }
}
