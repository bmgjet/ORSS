// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Core;

namespace OkiRomSim.Desktop;

/// Datalogging > Codes and service: the trouble codes the car's ECU has stored and whether its check-engine lamp is lit, read from the datalog as it runs, with Clear codes (50h, as HTS clears them); and, on the skeleton ROM, the service commands of its datalog (dlservice.asm): injectors off, timing locked for a timing light, the maps picked, the GIO outputs forced on - all through the datalog cable, with the check-engine lamp flashing quickly on the car while the injectors are off or the timing is locked. Big buttons: it is used beside the car, often with one hand.
public sealed class ServiceWindow : Window
{
    readonly DatalogEngine _engine;
    readonly SimHost _host;
    readonly Ellipse _lamp = new() { Width = 46, Height = 46, StrokeThickness = 2, Stroke = Brushes.DimGray };
    readonly TextBlock _lampText = new() { FontSize = 15, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel _codes = new() { Spacing = 2 };
    readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.85 };
    readonly TextBlock _serviceNote = new() { TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.7 };
    readonly ToggleButton _inj = Big("Injectors off"), _lock = Big("Lock timing");
    readonly ToggleButton[] _maps = [Big("Maps: by switch"), Big("First maps"), Big("Second maps")];
    readonly ToggleButton[] _gio = [Big("GIO 1"), Big("GIO 2"), Big("GIO 3"), Big("GIO 4")];
    readonly Button _clear = new() { Content = "Clear codes", MinHeight = 44, MinWidth = 150, FontSize = 14, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
    readonly Button _allOff = new() { Content = "All back to normal", MinHeight = 44, MinWidth = 180, FontSize = 14, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
    readonly Control _serviceBox;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(130) };
    TroubleCodes.ServiceState? _state;
    string _codesKey = "";
    bool _busy, _syncing;
    int _tick;

    static readonly IBrush LampOn = new SolidColorBrush(Color.FromRgb(0xFF, 0xA0, 0x10));
    static readonly IBrush LampOff = new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80));
    static readonly IBrush Active = new SolidColorBrush(Color.FromRgb(0xC0, 0x30, 0x30));

    static ToggleButton Big(string text) => new() { Content = text, MinHeight = 44, MinWidth = 120, FontSize = 14, Margin = new Thickness(0, 0, 6, 6), HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };

    public ServiceWindow(DatalogEngine engine, SimHost host)
    {
        _engine = engine; _host = host;
        Title = "Codes and service";
        Width = 620; Height = 700; MinWidth = 380; MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        ToolTip.SetTip(_lamp, "The check-engine lamp, as the ECU drives it: lit while a code is stored; flashing quickly while the injectors are off or the timing is locked.");
        ToolTip.SetTip(_clear, "Clear the codes the ECU has stored (50h over the datalog, as HTS clears them). A fault that is still there comes back.");
        _clear.Click += async (_, _) =>
        {
            if (!await Dialogs.Confirm(this, "Clear the codes?", "Clear the trouble codes stored in the ECU? A fault that is still there is stored again straight away.", "Clear", "Not now")) return;
            await Send(TroubleCodes.ClearCodes, "clear the codes");
        };
        ToolTip.SetTip(_inj, "Switch the injectors off (51h), and on again (52h): to clear a flooded engine or for a compression test. The check-engine lamp flashes quickly while they are off; a key cycle puts them back on.");
        _inj.Click += async (_, _) => await Send(_inj.IsChecked == true ? TroubleCodes.InjectorsOff : TroubleCodes.InjectorsOn, _inj.IsChecked == true ? "injectors off" : "injectors on");
        _lock.Click += async (_, _) => await Send(_lock.IsChecked == true ? TroubleCodes.TimingLock : TroubleCodes.TimingNormal, _lock.IsChecked == true ? "timing locked" : "timing normal");
        for (int i = 0; i < _maps.Length; i++)
        {
            byte cmd = (byte)(TroubleCodes.MapsBySwitch + i);
            string what = i switch { 0 => "the maps by their switch", 1 => "the first maps", _ => "the second maps" };
            _maps[i].Click += async (_, _) => await Send(cmd, what);
            ToolTip.SetTip(_maps[i], i switch
            {
                0 => "The secondary maps as their switch input says (55h): the normal way.",
                1 => "The first maps, whatever the switch says (56h).",
                _ => "The secondary maps, whatever the switch says (57h). Their module (secondary maps or the secondary tune) must be on.",
            });
        }
        for (int i = 0; i < _gio.Length; i++)
        {
            byte cmd = (byte)(TroubleCodes.Gio1 + i);
            int n = i + 1;
            _gio[i].Click += async (_, _) => await Send(cmd, $"GIO {n}");
            ToolTip.SetTip(_gio[i], $"Force GIO {n}'s output on, whatever its conditions ({cmd:X2}h); again for its own conditions. The GIO must be on, with an output chosen.");
        }
        ToolTip.SetTip(_allOff, "Injectors on, timing normal, maps by their switch, every GIO back to its own conditions (5Eh).");
        _allOff.Click += async (_, _) => await Send(TroubleCodes.AllNormal, "all back to normal");

        var lampRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        lampRow.Children.Add(_lamp);
        lampRow.Children.Add(_lampText);

        var service = new StackPanel { Spacing = 4 };
        service.Children.Add(new TextBlock { Text = "SERVICE", FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 10, 0, 2) });
        service.Children.Add(Wrap(_inj, _lock));
        service.Children.Add(Wrap(_maps));
        service.Children.Add(Wrap(_gio));
        service.Children.Add(Wrap(_allOff));
        service.Children.Add(_serviceNote);
        _serviceBox = service;

        var body = new StackPanel { Margin = new Thickness(14, 10), Spacing = 6 };
        body.Children.Add(lampRow);
        body.Children.Add(new TextBlock { Text = "STORED CODES", FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 8, 0, 0) });
        body.Children.Add(_codes);
        body.Children.Add(Wrap(_clear));
        body.Children.Add(service);
        body.Children.Add(_status);

        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(new ScrollViewer { Content = body });
        Content = root;

        _timer.Tick += (_, _) => Refresh();
        Opened += async (_, _) => { Refresh(); _timer.Start(); if (ServiceAllowed(out _)) await Send(TroubleCodes.State, "the state", quiet: true); };
        Closed += (_, _) => _timer.Stop();
    }

    static WrapPanel Wrap(params Control[] items)
    {
        var w = new WrapPanel();
        foreach (var c in items) { c.Margin = new Thickness(0, 0, 6, 6); w.Children.Add(c); }
        return w;
    }

    /// The service commands are the skeleton ROM's: another ROM may take their bytes for something else (on HTS every 5xh byte clears the codes). So they are offered on the channel stream (the skeleton's own protocol), or when the ROM open here is a skeleton build with them.
    bool ServiceAllowed(out string why)
    {
        bool stream = _engine.Protocol is ChannelStream;
        bool romHas = _host.Defs().Find("DatalogServiceTiming") != null;
        why = stream || romHas ? ""
            : "The service commands are the skeleton ROM's (its datalog module): log it with the channel stream, or open the ROM the car runs here, to use them. Clear codes works on the others too (HTS ROMs clear with the same 50h).";
        return stream || romHas;
    }

    void Refresh()
    {
        _tick++;
        var f = _engine.Latest;
        bool live = _engine.Running && _engine.Fresh && f != null;
        var bytes = f != null ? TroubleCodes.Bytes(f) : null;
        var codes = bytes != null ? TroubleCodes.Decode(bytes) : [];
        bool flashing = _state?.Any == true;
        bool lit = f?.Get("cel") is double cel ? cel != 0 : codes.Count > 0;
        _lamp.Fill = flashing ? (_tick / 2 % 2 == 0 ? LampOn : LampOff) : lit && live ? LampOn : LampOff;
        _lampText.Text = !_engine.Running ? "Not logging: connect the datalog (Datalogging menu) to read the codes."
            : !live ? "Waiting for frames from the ECU…"
            : flashing ? "Service mode: the lamp flashes quickly on the car" + (_state!.InjectorsOff ? " - injectors OFF" : "") + (_state.TimingLocked ? " - timing LOCKED" : "")
            : bytes == null ? "This datalog does not carry the codes (with the channel stream, tick the Trouble codes channel)."
            : codes.Count == 0 ? "Check engine lamp off: no codes stored."
            : $"Check engine lamp on: {codes.Count} code{(codes.Count == 1 ? "" : "s")} stored.";
        string key = bytes == null ? "-" : string.Join(",", codes);
        if (key != _codesKey)
        {
            _codesKey = key;
            _codes.Children.Clear();
            if (codes.Count == 0) _codes.Children.Add(new TextBlock { Text = bytes == null ? "(not in the datalog)" : "none", Opacity = 0.6, FontSize = 13 });
            foreach (var c in codes)
            {
                var g = new Grid { ColumnDefinitions = new ColumnDefinitions("56,*") };
                g.Children.Add(new TextBlock { Text = c.ToString(), FontFamily = MainWindow.MonoFont, FontSize = 18, FontWeight = FontWeight.Bold });
                var d = new TextBlock { Text = TroubleCodes.Describe(c), FontSize = 14, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
                Grid.SetColumn(d, 1); g.Children.Add(d);
                _codes.Children.Add(g);
            }
        }
        bool connected = _engine.Running && _engine.Protocol != null;
        _clear.IsEnabled = connected && !_busy;
        bool allowed = ServiceAllowed(out var why);
        foreach (var b in new Control[] { _inj, _lock, _allOff }.Concat(_maps).Concat(_gio)) b.IsEnabled = connected && allowed && !_busy;
        var timing = _host.Defs().Find("DatalogServiceTiming");
        string at = "";
        if (timing != null) try { at = $" at {RomData.Read(_host.Defs(), _host.RomCopy(), timing)[0].Value:0.#}°"; } catch { }
        _lock.Content = "Lock timing" + at;
        _serviceNote.Text = !connected ? "Connect the datalog to use these." : allowed
            ? "A key cycle puts everything back to normal. The timing it locks at is DatalogServiceTiming (Datalog settings)."
            : why;
        ShowState();
    }

    void ShowState()
    {
        _syncing = true;
        var s = _state;
        _inj.IsChecked = s?.InjectorsOff == true;
        _lock.IsChecked = s?.TimingLocked == true;
        _maps[0].IsChecked = s != null && !s.MapsChosen;
        _maps[1].IsChecked = s is { MapsChosen: true, SecondMaps: false };
        _maps[2].IsChecked = s is { MapsChosen: true, SecondMaps: true };
        for (int i = 0; i < 4; i++) _gio[i].IsChecked = s?.GioForced[i] == true;
        foreach (var b in new[] { _inj, _lock }) b.Background = b.IsChecked == true ? Active : null;
        _syncing = false;
    }

    async Task Send(byte cmd, string what, bool quiet = false)
    {
        if (_busy || _syncing) return;
        _busy = true;
        try
        {
            var (answer, note) = await _engine.Command(cmd);
            if (answer == null) { _status.Text = $"{what}: {note}"; return; }
            if (answer == TroubleCodes.Refused && cmd != TroubleCodes.State)
            {
                _status.Text = $"{what}: the ROM cannot (7Fh) - the module it needs is not built in";
                AppLog.Warn("service", $"{cmd:X2} refused");
            }
            else if (cmd == TroubleCodes.State) { _state = TroubleCodes.ServiceState.From(answer.Value); if (!quiet) _status.Text = "state read"; }
            else
            {
                if (!quiet) _status.Text = cmd == TroubleCodes.ClearCodes ? "codes cleared" : $"{what}: done ({answer:X2})";
                AppLog.Action("service", $"{what}: {cmd:X2} -> {answer:X2}");
            }
            // what the ROM now has, for the buttons
            if (cmd != TroubleCodes.State && ServiceAllowed(out _))
            {
                var (st, _) = await _engine.Command(TroubleCodes.State);
                if (st is byte b && b != TroubleCodes.Refused) _state = TroubleCodes.ServiceState.From(b);
            }
        }
        finally { _busy = false; ShowState(); }
    }
}
