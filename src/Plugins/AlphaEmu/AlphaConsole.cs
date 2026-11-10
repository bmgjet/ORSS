// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// One screen of the ALPHAemu console. Built once, refreshed on the console's timer.
public interface IAlphaPage
{
    string Title { get; }
    string Icon { get; }
    Control Content { get; }
    void Refresh();
}

/// The ALPHAemu console: the operator strip across the top, a rail of screens down the left, and the
/// live calibration surface in the middle. It is one control, so it can sit in the workbench tab or in
/// a window of its own; several may be open at once, all reading the same session.
public sealed class AlphaConsole : UserControl
{
    readonly AlphaHub _hub;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(200) };

    // the operator strip
    readonly TextBlock _mapName = new() { FontSize = 13, FontWeight = FontWeight.SemiBold, Foreground = Alpha.Ink };
    readonly TextBlock _preview = new() { FontSize = 11, Foreground = Alpha.Dim };
    readonly LedLamp _linkLamp = new() { Label = "Link", Colour = Alpha.Cyan };
    readonly LedLamp _calLamp = new() { Label = "Calibration", Colour = Alpha.Green };
    readonly LedLamp _liveLamp = new() { Label = "Realtime", Colour = Alpha.Amber };
    readonly Border _alert = new() { IsVisible = false };
    readonly TextBlock _alertTitle = new() { FontSize = 12.5, FontWeight = FontWeight.SemiBold, Foreground = Alpha.Ink };
    readonly TextBlock _alertSummary = new() { FontSize = 11, Foreground = Alpha.Dim };

    // gauges and readouts
    readonly DialGauge _rpm = new() { Label = "engine speed", Unit = "RPM", Max = 9000, Redline = 8200 };
    readonly DialGauge _afr = new() { Label = "wideband", Unit = "AFR", Min = 10, Max = 18, Decimals = 2 };
    readonly DialGauge _ign = new() { Label = "ignition", Unit = "DEG", Min = -10, Max = 60, Decimals = 1 };
    readonly DialGauge _vss = new() { Label = "road speed", Unit = "KM/H", Max = 220 };
    readonly BarGauge _tps = new() { Label = "TPS", Max = 100, Unit = "%", Colour = Alpha.Cyan, Decimals = 0 };
    readonly BarGauge _iat = new() { Label = "IAT", Min = -20, Max = 120, Unit = "°C", Colour = Alpha.Sky, Decimals = 0 };
    readonly BarGauge _ect = new() { Label = "ECT", Min = -20, Max = 120, Unit = "°C", Colour = Alpha.Red, Warn = 101, Decimals = 0 };
    readonly (Border Card, TextBlock Value, TextBlock Unit) _map = Alpha.Readout("MAP", "BAR", Alpha.Blue);
    readonly (Border Card, TextBlock Value, TextBlock Unit) _inj = Alpha.Readout("INJ", "MS", Alpha.Orange);
    readonly (Border Card, TextBlock Value, TextBlock Unit) _duty = Alpha.Readout("DUTY", "%", Alpha.Green);
    readonly MeterBar _dutyMeter = new() { Label = "injector duty", Max = 110, Warn = 90, Colour = Alpha.Green, Suffix = " %" };
    readonly MeterBar _loadMeter = new() { Label = "engine load", Max = 100, Colour = Alpha.Blue, Suffix = " %", Decimals = 0 };
    readonly LedLamp _mil = new() { Label = "MIL", Colour = Alpha.Red };
    readonly LedLamp _vtec = new() { Label = "VTEC", Colour = Alpha.Purple };
    readonly LedLamp _bks = new() { Label = "BKS", Colour = Alpha.Amber };
    readonly LedLamp _fc = new() { Label = "FC", Colour = Alpha.Red };
    readonly LedLamp _schg = new() { Label = "S-CHG", Colour = Alpha.Sky };
    readonly TraceScope _scope = new(AlphaHub.Traces);

    // health + counters
    readonly TextBlock _stats = new() { FontFamily = Alpha.Mono, FontSize = 11, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
    readonly StackPanel _checks = new() { Spacing = 3 };
    readonly Dictionary<string, (Border Row, LedLamp Dot, TextBlock Value)> _check = new();
    Border _checkCard = null!;

    readonly List<(IAlphaPage Page, Button Button, Border Host)> _pages = [];
    readonly StackPanel _rail = new() { Spacing = 4 };
    readonly StackPanel _pageHost = new() { Spacing = 0 };
    IAlphaPage? _shown;

    public AlphaConsole(AlphaHub hub)
    {
        _hub = hub;
        Content = Build();
        _timer.Tick += (_, _) => Refresh();
        DetachedFromVisualTree += (_, _) => _timer.Stop();
        AttachedToVisualTree += (_, _) => { Refresh(); _timer.Start(); };
    }

    Control Build()
    {
        // ---- operator strip
        var identity = new StackPanel { Spacing = 1 };
        identity.Children.Add(new TextBlock { Text = "ALPHAemu", FontSize = 10, LetterSpacing = 1.6, Foreground = Alpha.Tint(Alpha.Cyan, 220), FontWeight = FontWeight.Bold });
        identity.Children.Add(_mapName);
        identity.Children.Add(_preview);
        var lamps = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, VerticalAlignment = VerticalAlignment.Center };
        lamps.Children.Add(_linkLamp); lamps.Children.Add(_calLamp); lamps.Children.Add(_liveLamp);

        var connectAll = Alpha.Primary("Connect EMU + datalog", () => _hub.Connect(), "Open the link and start logging through it.");
        var realtime = Alpha.Ghost("Real-Time Update", () => _hub.ToggleRealtime(), "Push every table edit to the running image as you make it.");
        var deploy = Alpha.Ghost("Deploy maps", () => { ShowPage("Multi-map"); _hub.Maps().DeployRequested(); }, "Stage and write the map slots.");
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(connectAll); actions.Children.Add(realtime); actions.Children.Add(deploy);

        var strip = new Border
        {
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Alpha.Fade(Alpha.Rgb(0x1d, 0x23, 0x2b), 255), 0), new GradientStop(Alpha.Fade(Alpha.Rgb(0x15, 0x18, 0x1d), 255), 1) },
            },
            BorderBrush = Alpha.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 8),
        };
        var stripGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        Grid.SetColumn(identity, 0); stripGrid.Children.Add(identity);
        Grid.SetColumn(lamps, 1); stripGrid.Children.Add(lamps);
        Grid.SetColumn(actions, 2); stripGrid.Children.Add(actions);
        strip.Child = stripGrid;

        // ---- the ECU alert banner
        _alert.Background = Alpha.Tint(Alpha.Red, 28);
        _alert.BorderBrush = Alpha.Tint(Alpha.Red, 150);
        _alert.BorderThickness = new Thickness(1);
        _alert.CornerRadius = new CornerRadius(7);
        _alert.Padding = new Thickness(10, 6);
        var alertBody = new StackPanel { Spacing = 1 };
        alertBody.Children.Add(new TextBlock { Text = "ECU DIAGNOSTIC ALERT", FontSize = 9, LetterSpacing = 1.3, Foreground = Alpha.Tint(Alpha.Red, 230) });
        alertBody.Children.Add(_alertTitle);
        alertBody.Children.Add(_alertSummary);
        var alertRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        Grid.SetColumn(alertBody, 0); alertRow.Children.Add(alertBody);
        var alertButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        alertButtons.Children.Add(Alpha.Ghost("View codes", () => { ShowPage("Diagnostics"); }, "Open the diagnostics screen."));
        alertButtons.Children.Add(Alpha.Danger("Clear codes", () => _hub.ClearCodes(), "Ask the emulator to forget its stored codes."));
        Grid.SetColumn(alertButtons, 1); alertRow.Children.Add(alertButtons);
        _alert.Child = alertRow;

        // ---- the gauge wall
        var gaugeRow = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (Control c in new Control[] { _rpm, _tps, _afr, _iat, _ect, _ign, _vss }) gaugeRow.Children.Add(c);
        var readouts = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        readouts.Children.Add(_map.Card); readouts.Children.Add(_inj.Card); readouts.Children.Add(_duty.Card);
        var leds = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var l in new[] { _mil, _vtec, _bks, _fc, _schg }) { l.Margin = new Thickness(0, 0, 10, 0); leds.Children.Add(l); }
        var meters = new StackPanel { Spacing = 2, MinWidth = 190, VerticalAlignment = VerticalAlignment.Center };
        meters.Children.Add(_dutyMeter); meters.Children.Add(_loadMeter); meters.Children.Add(leds);
        var gaugePanel = new StackPanel { Spacing = 6 };
        var gaugeGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        Grid.SetColumn(gaugeRow, 0); gaugeGrid.Children.Add(gaugeRow);
        Grid.SetColumn(readouts, 1); gaugeGrid.Children.Add(readouts);
        var gaugeGrid2 = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        Grid.SetColumn(gaugeGrid, 0); gaugeGrid2.Children.Add(gaugeGrid);
        Grid.SetColumn(meters, 1); gaugeGrid2.Children.Add(meters);
        gaugePanel.Children.Add(gaugeGrid2);

        var scopeTitle = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var scopeHead = Alpha.Head("Datalog trace", "The last 20 seconds of what the emulator is logging. Scroll on the trace to change the window.");
        Grid.SetColumn(scopeHead, 0); scopeTitle.Children.Add(scopeHead);
        var scopeButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        scopeButtons.Children.Add(Alpha.Ghost("10s", () => _scope.Seconds = 10, "Ten second window."));
        scopeButtons.Children.Add(Alpha.Ghost("20s", () => _scope.Seconds = 20, "Twenty second window."));
        scopeButtons.Children.Add(Alpha.Ghost("60s", () => _scope.Seconds = 60, "One minute window."));
        scopeButtons.Children.Add(Alpha.Ghost("Clear", () => _scope.ClearTrace(), "Forget the trace so far."));
        Grid.SetColumn(scopeButtons, 1); scopeTitle.Children.Add(scopeButtons);
        gaugePanel.Children.Add(scopeTitle);
        gaugePanel.Children.Add(_scope);
        gaugePanel.Children.Add(_scopeLegend = TraceLegend());

        // ---- the health card
        _checkCard = Alpha.Card("Session checks", _checks,
            Alpha.Ghost("Run again", () => _hub.RunChecks(true), "Ask the emulator and the app again and rebuild the checklist."));

        var overviewStats = new StackPanel { Spacing = 6 };
        overviewStats.Children.Add(_stats);
        overviewStats.Children.Add(_checkCard);
        overviewStats.Children.Add(gaugePanel);
        var overviewScroll = new ScrollViewer { Content = overviewStats, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

        // ---- the rail and the page host
        AddPage(new OverviewPage(overviewScroll));
        AddPage(_hub.Maps());
        AddPage(_hub.Analog());
        AddPage(_hub.Wideband());
        AddPage(_hub.SnapshotPage());
        AddPage(_hub.Diagnostics());
        AddPage(_hub.Device());
        AddPage(_hub.Log());

        // a copy: each page's button is put back into _pages as it is made
        foreach (var p in _pages.ToList())
        {
            var b = new Button
            {
                Content = p.Page.Icon + "  " + p.Page.Title, HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left, FontSize = 12, Padding = new Thickness(8, 5),
                Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            };
            ToolTip.SetTip(b, p.Page.Title + " - ALPHAemu");
            var page = p.Page;
            b.Click += (_, _) => ShowPage(page.Title);
            _rail.Children.Add(b);
            _pages[_pages.FindIndex(x => x.Page == p.Page)] = (p.Page, b, p.Host);
        }

        var rail = new Border
        {
            Background = Alpha.Tint(Alpha.Rgb(0x17, 0x19, 0x1d), 255), BorderBrush = Alpha.Line, BorderThickness = new Thickness(0, 0, 1, 0),
            Padding = new Thickness(6, 8, 6, 8), Width = 170, Child = _rail,
        };
        // the pages fit the width (the gauges wrap, the cards' buttons stay on screen); only down does it scroll
        // room on the right for the scroll bar, which lies over the page
        _pageHost.Margin = new Thickness(10, 10, 20, 10);
        var host = new ScrollViewer { Content = _pageHost, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        Grid.SetColumn(rail, 0); body.Children.Add(rail);
        Grid.SetColumn(host, 1); body.Children.Add(host);

        var root = new DockPanel { Margin = new Thickness(8), LastChildFill = true };
        var top = new StackPanel { Spacing = 6 };
        top.Children.Add(strip);
        top.Children.Add(_alert);
        DockPanel.SetDock(top, Dock.Top); root.Children.Add(top);
        DockPanel.SetDock(body, Dock.Top); root.Children.Add(body);
        Show(_pages[0].Page.Title);
        return root;
    }

    Control _scopeLegend = new Control();
    readonly Dictionary<string, TextBlock> _legendValues = new();

    Control TraceLegend()
    {
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var t in AlphaHub.Traces)
        {
            var value = new TextBlock { Text = "--", FontFamily = Alpha.Mono, FontSize = 11, FontWeight = FontWeight.SemiBold, Foreground = new SolidColorBrush(t.Colour) };
            _legendValues[t.Channel] = value;
            var swatch = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(t.Colour), Margin = new Thickness(0, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
            var chip = new Border
            {
                Background = Alpha.Tint(t.Colour, 22), BorderBrush = Alpha.Tint(t.Colour, 70), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 2), Margin = new Thickness(0, 0, 5, 0),
                Child = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Children = { swatch, new TextBlock { Text = t.Name, FontSize = 10.5, Foreground = Alpha.Dim }, value } },
            };
            var capture = t;
            chip.PointerPressed += (_, _) =>
            {
                _scope.SetEnabled(capture, !capture.DefaultOn);
                chip.Opacity = capture.DefaultOn ? 1 : 0.35;
            };
            ToolTip.SetTip(chip, $"{t.Name}: channel '{t.Channel}', {t.Min:0.##} to {t.Max:0.##}. Click to put it on or off the trace.");
            wrap.Children.Add(chip);
        }
        wrap.Children.Add(new TextBlock { Text = "click a channel to switch it", FontSize = 10, Foreground = Alpha.Dim, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 0, 0) });
        return wrap;
    }

    void AddPage(IAlphaPage page)
    {
        var host = new Border { IsVisible = false, Child = page.Content };
        _pageHost.Children.Add(host);
        _pages.Add((page, new Button(), host));
    }

    public void ShowPage(string title)
    {
        var found = _pages.FirstOrDefault(p => p.Page.Title.Equals(title, StringComparison.OrdinalIgnoreCase));
        if (found.Page != null) Show(found.Page.Title);
    }

    void Show(string title)
    {
        foreach (var p in _pages)
        {
            bool on = p.Page.Title.Equals(title, StringComparison.OrdinalIgnoreCase);
            p.Host.IsVisible = on;
            p.Button.Background = on ? Alpha.Tint(Alpha.Cyan, 40) : Brushes.Transparent;
            p.Button.BorderThickness = new Thickness(on ? 1 : 0, 0, 0, 0);
            p.Button.BorderBrush = Alpha.Tint(Alpha.Cyan, 150);
            p.Button.CornerRadius = new CornerRadius(5);
        }
        _shown = _pages.FirstOrDefault(p => p.Page.Title.Equals(title, StringComparison.OrdinalIgnoreCase)).Page;
        _shown?.Refresh();
    }

    static string Num(double? v, string format = "0.##") => v is double d && !double.IsNaN(d) ? d.ToString(format, CultureInfo.InvariantCulture) : "--";

    void Refresh()
    {
        var s = _hub.Session;
        var f = s.Latest;
        bool live = f != null && s.Phase is AlphaLinkPhase.Logging or AlphaLinkPhase.Linked && s.Streaming;

        // ---- operator strip
        _mapName.Text = _hub.RomName();
        _preview.Text = live ? $"{Num(f!.Rpm, "0")} rpm · {Num(f.TpsPct, "0")}% · {Num(f.MapKpa, "0")} kPa · {Num(f.Get("afr"), "0.00")} AFR · {Num(s.FramesPerSecond, "0")} fps"
                             : s.Phase switch { AlphaLinkPhase.Off => "Awaiting live data - connect the emulator", _ => s.Status };
        _linkLamp.On = s.Phase is AlphaLinkPhase.Linked or AlphaLinkPhase.Logging;
        _linkLamp.Colour = s.Phase switch { AlphaLinkPhase.Logging => Alpha.Green, AlphaLinkPhase.Linked => Alpha.Cyan, AlphaLinkPhase.Reconnecting or AlphaLinkPhase.Connecting => Alpha.Amber, _ => Alpha.DimColour };
        _linkLamp.Label = "Link: " + (s.Phase switch { AlphaLinkPhase.Logging => "logging", AlphaLinkPhase.Linked => "linked", AlphaLinkPhase.Reconnecting => "retrying", AlphaLinkPhase.Connecting => "connecting", _ => "offline" });
        bool rom = _hub.HasRom;
        _calLamp.On = rom; _calLamp.Label = "Calibration: " + (rom ? "loaded" : "none");
        _liveLamp.On = s.RealtimeEnabled; _liveLamp.Colour = s.Synced ? Alpha.Green : Alpha.Amber;
        _liveLamp.Label = "Realtime: " + (s.RealtimeEnabled ? (s.Synced ? "armed" : "no baseline") : "off");

        // ---- the gauges
        _rpm.Value = f?.Rpm ?? double.NaN;
        _tps.Value = f?.TpsPct ?? 0;
        _iat.Value = f?.IatC ?? 0;
        _ect.Value = f?.EctC ?? 0;
        _vss.Value = f?.SpeedKmh ?? 0;
        _ign.Value = f?.IgnDeg ?? double.NaN;
        _afr.Value = f?.Get("afr") ?? double.NaN;
        _map.Value.Text = Num(f?.MapKpa is double k ? k / 100 : null, "0.00");
        _inj.Value.Text = Num(f?.InjMs, "0.00");
        _duty.Value.Text = Num(f?.Get("inj_duty_pct"), "0");
        _dutyMeter.Value = f?.Get("inj_duty_pct") ?? 0;
        double mapBar = (f?.MapKpa ?? 0) / 100;
        _loadMeter.Value = Math.Clamp((mapBar - 0.2) / 1.2 * 100, 0, 100);
        _mil.On = f?.Get("mil") > 0;
        _vtec.On = f?.Vtec == true;
        _bks.On = f?.Get("bks") > 0;
        _fc.On = f?.Get("fc") > 0;
        _schg.On = f?.Get("s_chg") > 0;
        if (f != null) _scope.Add(f);         // only real frames - placeholder frames would bury the "no frames" hint
        foreach (var (channel, box) in _legendValues) box.Text = Num(f?.Get(channel), channel == "afr" ? "0.00" : "0.#");

        // ---- the counters
        _stats.Text = $"frames {s.Frames:N0} · {s.FramesPerSecond:0.#} fps   patches {s.PatchesSent:N0} ({s.PatchBytesSent:N0} bytes)   "
                    + $"analog polls {s.AnalogPolls:N0}   link {s.LinkName}   wideband {s.Wideband.Summary}";

        // ---- the alert banner
        var (codes, source) = s.TroubleCodes();
        _alert.IsVisible = codes.Length > 0;
        if (codes.Length > 0)
        {
            _alertTitle.Text = string.Join(", ", codes.Take(6).Select(c => c + " " + OkiRomSim.Core.MilMonitor.Name(c)));
            _alertSummary.Text = $"{codes.Length} code{(codes.Length == 1 ? "" : "s")} stored by {source}. Clearing writes the emulator's own clear command.";
        }

        // ---- the checklist
        foreach (var c in _hub.RunChecks(false))
        {
            if (!_check.TryGetValue(c.Id, out var row))
            {
                row = Alpha.CheckRow(c.Title, c.Detail);
                _check[c.Id] = row;
                _checks.Children.Add(row.Row);
            }
            row.Dot.On = c.State is "pass" or "warn";
            row.Dot.Colour = c.State switch { "pass" => Alpha.Green, "warn" => Alpha.Amber, "fail" => Alpha.Red, _ => Alpha.DimColour };
            row.Value.Text = c.Value;
            row.Value.Foreground = c.State switch { "pass" => Alpha.GreenBrush, "warn" => Alpha.AmberBrush, "fail" => Alpha.RedBrush, _ => Alpha.Dim };
            row.Row.IsVisible = true;
        }

        _shown?.Refresh();
    }

    /// The overview page is built here (its gauges live on the console), so it is a thin wrapper.
    sealed class OverviewPage : IAlphaPage
    {
        readonly Control _content;
        public OverviewPage(Control content) { _content = content; }
        public string Title => "Overview";
        public string Icon => "◉";
        public Control Content => _content;
        public void Refresh() { }
    }
}



