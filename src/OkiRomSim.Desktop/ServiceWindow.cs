// Copyright (c) bmgjet. All rights reserved.
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Presenters;
using Avalonia.Controls.Shapes;
using Avalonia.Styling;
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
    readonly Button _clear = Plain("Clear codes"), _allOff = Plain("All back to normal");
    readonly Control _serviceBox;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(130) };
    TroubleCodes.ServiceState? _state;
    string _codesKey = "";
    /// The last frame from before Clear codes: the ECU restarts with its codes gone and the lamp off, but until its next
    /// frame comes that one still says lamp on - so it is not believed.
    LogFrame? _beforeClear;
    bool _busy, _syncing;
    int _tick;

    static readonly IBrush LampOn = AppTheme.Brush(Color.FromRgb(0xFF, 0xA0, 0x10));
    static readonly IBrush LampOff = AppTheme.Brush(Color.FromArgb(0x40, 0x80, 0x80, 0x80));
    static readonly IBrush Active = AppTheme.Brush(Color.FromRgb(0xC0, 0x30, 0x30));

    // a label that wraps inside its button: a long one ("Lock timing at 16°") makes the button taller, never pushes it onto a line of its own
    static TextBlock Caption(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
    static T Named<T>(T b, string text) where T : Control { Avalonia.Automation.AutomationProperties.SetName(b, text); return b; }
    static ToggleButton Big(string text) => Named(new ToggleButton { Content = Caption(text), MinHeight = 44, FontSize = 14, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center }, text);
    static Button Plain(string text) => Named(new Button { Content = Caption(text), MinHeight = 44, FontSize = 14, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center }, text);

    /// Buttons in four equal columns across the window, so every row of buttons lines up with the others; a button can take
    /// more than one column (Grid.ColumnSpan set before). The buttons in a row are all as tall as the tallest.
    static Grid Row(params Control[] items)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*,*,*") };
        int col = 0;
        foreach (var c in items)
        {
            c.Margin = new Thickness(0, 0, 6, 6);
            c.HorizontalAlignment = HorizontalAlignment.Stretch;
            c.VerticalAlignment = VerticalAlignment.Stretch;
            Grid.SetColumn(c, col);
            g.Children.Add(c);
            col += Math.Max(1, Grid.GetColumnSpan(c));
        }
        return g;
    }

    public ServiceWindow(DatalogEngine engine, SimHost host)
    {
        _engine = engine; _host = host;
        Title = "Codes and service";
        DangerStyles();
        Width = 640; Height = 700; MinWidth = 600;   // the value rows' columns need 600 (they never wrap out of line)
        MinHeight = 420;
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

        var lampRow = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };   // the text wraps in what is left
        _lampText.Margin = new Thickness(12, 0, 0, 0);
        Grid.SetColumn(_lampText, 1);
        lampRow.Children.Add(_lamp);
        lampRow.Children.Add(_lampText);

        var service = new StackPanel { Spacing = 4 };
        service.Children.Add(new TextBlock { Text = "SERVICE", FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 10, 0, 2) });
        service.Children.Add(Row(_inj, _lock));
        service.Children.Add(Row(_maps));
        service.Children.Add(Row(_gio));
        Grid.SetColumnSpan(_allOff, 2);
        service.Children.Add(Row(_allOff));
        service.Children.Add(_serviceNote);
        _serviceBox = service;

        var body = new StackPanel { Margin = new Thickness(14, 10), Spacing = 6 };
        body.Children.Add(lampRow);
        body.Children.Add(new TextBlock { Text = "STORED CODES", FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 8, 0, 0) });
        body.Children.Add(_codes);
        body.Children.Add(Row(_clear));
        body.Children.Add(service);
        body.Children.Add(RemoteBox());
        body.Children.Add(MemoryBox());
        body.Children.Add(_status);

        var chrome = DarkChrome.Apply(this, Title);
        var root = new DockPanel();
        DockPanel.SetDock(chrome, Dock.Top);
        root.Children.Add(chrome);
        root.Children.Add(new ScrollViewer { Content = body });
        Content = root;

        _timer.Tick += (_, _) => Refresh();
        Opened += async (_, _) =>
        {
            Refresh(); _timer.Start();
            if (ServiceAllowed(out _)) await Send(TroubleCodes.State, "the state", quiet: true);
            if (RemoteAllowed()) await ReadRemote();
        };
        Closed += (_, _) => _timer.Stop();
    }

    // ---------------------------------------------------------------- remote control (the remote control module)
    readonly ToggleButton[] _fan = [Big("Fan: auto"), Big("Fan on"), Big("Fan off")];
    readonly ToggleButton _popcorn = Big("Popcorn mode");
    readonly TextBox _password = new() { Width = 140, FontSize = 14, Watermark = "0-65535", MaxLength = 5 };
    readonly TextBlock _remoteInfo = new() { TextWrapping = TextWrapping.Wrap, FontSize = 13 };
    readonly List<Control> _remoteControls = [];
    TroubleCodes.RemoteStateBits? _remote;

    /// One value the remote panel sets (2Ch key n; read with 2Bh key): a number box in the user's unit or a choice, Set / Clear /
    /// Read, and what the ECU has now. 0 from the ECU is "the tune's own": the box then shows the tune's value (from the ROM open here).
    sealed class RemoteValue
    {
        public required string Name, Unit, Zero, Tip;
        public required byte Key;
        public Func<double, int> ToByte = v => (int)v;              // a number shown -> the byte sent
        public Func<int, double> FromByte = b => b;                 // the byte read -> the number shown
        public string[]? Choices;                                   // a choice: index = the byte (0 = the tune's own)
        public Func<double?> Tune = () => null;                     // the tune's own, as shown (a choice: its index)
        public string? Needs;                                       // a slot the ROM open must have for it to mean anything
        public NumericUpDown? Box;
        public ComboBox? Combo;
        public readonly TextBlock Now = new() { VerticalAlignment = VerticalAlignment.Center, FontSize = 12.5, Opacity = 0.85 };
        public int? Have;                                           // what the ECU said last
        public bool Here = true;                                    // the ROM open here has it
        public Control Editor => (Control?)Box ?? Combo!;
        public string Show(double v) => Choices != null ? Choices[Math.Clamp((int)v, 0, Choices.Length - 1)] : $"{v:0.##} {Unit}".TrimEnd();
    }
    readonly List<RemoteValue> _values = [];

    /// The tune's own value of a setting in the ROM open here (its formula's units), or null when the ROM has none.
    double? TuneValue(string slot)
    {
        try
        {
            var defs = _host.Defs();
            return CalPage.Bound(defs, slot) is { } item ? RomData.Read(defs, _host.RomCopy(), item)[0].Value : null;
        }
        catch { return null; }
    }

    void BuildRemoteValues()
    {
        string spd = Units.Label(Units.Shown("km/h")), bst = Units.Label(Units.Shown("psi g"));
        var defs = _host.Defs();
        var mapF = defs.Formula("map_mbar");
        var rpmF = defs.Formula("rpm_axis_byte_log");
        const double Atm = 1013.25, MbarPerPsi = 68.947573;
        // boost: the MAP sensor's counts <-> above the air outside, in the boost unit chosen in Settings > Units
        double BoostShown(double mbarAbs) => Math.Round(Units.Show((mbarAbs - Atm) / MbarPerPsi, "psi g"), 2);
        double MbarOf(double shown) => (Units.Back(shown, "psi g") * MbarPerPsi) + Atm;
        int Rpm50(double v) => (int)Math.Clamp(Math.Round(v / 50), 1, 255);
        // whole numbers: an rpm read back from a crank period is 8012.82, not what anyone typed
        double? Tune(string slot) => TuneValue(slot) is double t ? Math.Round(t) : null;
        _values.AddRange(
        [
            new() { Name = "Rev limit", Key = 0, Unit = "rpm", Zero = "the ROM's own", ToByte = Rpm50, FromByte = b => b * 50, Tune = () => Tune("revlimit.low.set"),
                    Tip = "The rev limit, in 50 rpm steps. It is only ever a lower limit: the ROM's own stays in force above it." },
            new() { Name = "Speed limit", Key = 1, Unit = spd, Zero = "none", ToByte = v => (int)Math.Clamp(Math.Round(Units.Back(v, "km/h")), 1, 255),
                    FromByte = b => Math.Round(Units.Show(b, "km/h"), 1), Tip = $"The speed limit in {spd}; Clear for none." },
            new() { Name = "Boost cut", Key = 2, Unit = bst, Zero = "the tune's own", Needs = "boostcut.hot",
                    ToByte = v => (int)Math.Clamp(Math.Round(mapF.ToRaw(MbarOf(v), 1, 255)), 1, 255), FromByte = b => BoostShown(mapF.ToValue(b)),
                    Tune = () => Tune("boostcut.hot") is double t ? BoostShown(t) : null,
                    Tip = $"The boost cut, in {bst} of boost (above the air outside, the unit in Settings > Units). Never above the tune's own cut unless the Serial port page allows it." },
            new() { Name = "VTEC point", Key = 3, Unit = "rpm", Zero = "the tune's own", Needs = "vtec.rpm.high",
                    ToByte = v => (int)Math.Clamp(Math.Round(rpmF.ToRaw(v, 1, 255)), 1, 255), FromByte = b => Math.Round(rpmF.ToValue(b)), Tune = () => Tune("vtec.rpm.high"),
                    Tip = "The rpm VTEC engages at, whatever the throttle (the tune's high-load point is shown when none is set)." },
            new() { Name = "Shift light", Key = 4, Unit = "rpm", Zero = "the tune's own", Needs = "shiftlight.rpm", ToByte = Rpm50, FromByte = b => b * 50,
                    Tune = () => Tune("shiftlight.rpm"), Tip = "The rpm the shift light (the check-engine lamp) comes on at, in 50 rpm steps, every gear." },
            new() { Name = "Launch rpm", Key = 6, Unit = "rpm", Zero = "the tune's own", Needs = "launch.rpm", ToByte = Rpm50, FromByte = b => b * 50,
                    Tune = () => Tune("launch.rpm"), Tip = "The rpm two-step launch control holds the engine at, in 50 rpm steps (it comes back in as far below as the tune has it)." },
            new() { Name = "Limiter cut", Key = 5, Unit = "", Zero = "the tune's own", Needs = "revlimit.cut", Choices = ["the tune's own", "fuel cut", "ignition cut", "fuel and ignition"],
                    Tune = () => Tune("revlimit.cut") is double t ? t + 1 : null,
                    Tip = "How the rev limiter and launch control cut: fuel (quiet, easy on the exhaust), ignition (the crackle, fuel goes into the exhaust) or both." },
            new() { Name = "Rolling idle", Key = 7, Unit = "", Zero = "the tune's own", Needs = "rollidle.enable", Choices = ["the tune's own", "off", "on"],
                    Tune = () => Tune("rollidle.enable") is double t ? (t != 0 ? 2 : 1) : null,
                    Tip = "Rolling idle (the lumpy idle) on or off, whatever the tune says - its other conditions (throttle, speed, rpm, coolant) still apply." },
            new() { Name = "It leaves out", Key = 8, Unit = "", Zero = "the tune's own", Needs = "rollidle.mode", Choices = ["the tune's own", "an injector opening", "a spark"],
                    Tune = () => Tune("rollidle.mode") is double t ? t + 1 : null, Tip = "What rolling idle leaves out: an injector opening (smoother) or a spark (louder)." },
            new() { Name = "One in every", Key = 9, Unit = "events", Zero = "the tune's own", Needs = "rollidle.every", ToByte = v => (int)Math.Clamp(Math.Round(v), 3, 19),
                    Tune = () => Tune("rollidle.every"), Tip = "Rolling idle leaves out one event in this many (3-19; an even number is taken as the odd one above it, so the miss moves round the cylinders)." },
        ]);
        foreach (var v in _values)
        {
            if (v.Choices != null) v.Combo = new ComboBox { ItemsSource = v.Choices, SelectedIndex = 0, Width = 186, FontSize = 13.5 };
            else
            {
                v.Box = new NumericUpDown { Minimum = 0, Value = 0, FormatString = "0.##", Width = 140, FontSize = 14 };
                v.Box.Increment = v.Unit == "rpm" ? 100 : v.Key == 9 ? 2 : v.Key == 2 ? (decimal)Math.Max(0.1, Math.Round(Units.Show(1, "psi g") - Units.Show(0, "psi g"), 2)) : 5;
                v.Box.Maximum = v.Unit == "rpm" ? 12750 : v.Key == 9 ? 19 : v.Key == 2 ? (decimal)BoostShown(mapF.ToValue(255)) : (decimal)Math.Round(Units.Show(255, "km/h"));
                if (v.Key == 2) v.Box.Minimum = (decimal)BoostShown(mapF.ToValue(1));
            }
            ToolTip.SetTip(v.Editor, v.Tip);
            v.Here = v.Needs == null || CalPage.Bound(defs, v.Needs) != null;
        }
    }

    /// The remote control module's commands, as a remote panel would send them: what a phone or a button box does, from here.
    Control RemoteBox()
    {
        Button Btn(string text, string tip, Func<Task> act)
        {
            var b = Named(new Button { Content = Caption(text), MinHeight = 38, MinWidth = 64, FontSize = 14, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center }, text);
            ToolTip.SetTip(b, tip);
            b.Click += async (_, _) => await act();
            _remoteControls.Add(b);
            return b;
        }
        byte[] fanCmd = [TroubleCodes.FanAuto, TroubleCodes.FanOn, TroubleCodes.FanOff];
        string[] fanWhat = ["the fan as the ECU decides", "the fan on", "the fan off"];
        for (int i = 0; i < 3; i++)
        {
            int k = i;
            _fan[i].Click += async (_, _) => await Remote([fanCmd[k]], fanWhat[k]);
            ToolTip.SetTip(_fan[i], k switch { 0 => "The ECU drives the fan again (30h).", 1 => "The radiator fan on, whatever the coolant temperature (31h).", _ => "The radiator fan held off (32h) - watch the temperature." });
            _remoteControls.Add(_fan[i]);
        }
        _popcorn.Click += async (_, _) => await Remote([_popcorn.IsChecked == true ? TroubleCodes.PopcornOn : TroubleCodes.PopcornOff], _popcorn.IsChecked == true ? "popcorn mode on" : "popcorn mode off");
        ToolTip.SetTip(_popcorn, "Decel pops (3Dh on, 3Eh off): off the throttle above its rpm the fuel stays on, the timing comes out and the sparks are cut in turn. Its settings are on the Added features > Serial port page.");
        _remoteControls.Add(_popcorn);

        BuildRemoteValues();

        // one grid for every value and the password: the names, boxes, units and buttons each in a column of their own, so they
        // line up whatever the window's width or the length of a label; what the ECU has now goes on a line under the box
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 0), ColumnDefinitions = new ColumnDefinitions("Auto,Auto,Auto,Auto,Auto,Auto") };
        int row = 0;
        void Cell(Control c, int column, int span = 1)
        {
            Grid.SetRow(c, row); Grid.SetColumn(c, column); Grid.SetColumnSpan(c, span);
            grid.Children.Add(c);
        }
        void Line(string name, Control editor, string unit, params Control[] buttons)
        {
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            Cell(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, FontSize = 13, Margin = new Thickness(0, 0, 8, 0), TextWrapping = TextWrapping.Wrap, MaxWidth = 110 }, 0);
            editor.Width = 170; editor.VerticalAlignment = VerticalAlignment.Center;
            Cell(editor, 1);
            Cell(new TextBlock { Text = unit, VerticalAlignment = VerticalAlignment.Center, FontSize = 12, Opacity = 0.7, Margin = new Thickness(6, 0, 6, 0), MinWidth = 40 }, 2);
            for (int k = 0; k < buttons.Length; k++) { buttons[k].Margin = new Thickness(0, 2, 6, 2); Cell(buttons[k], 3 + k); }
            row++;
        }
        foreach (var v in _values)
        {
            var rv = v;
            Line(v.Name, v.Editor, v.Unit,
                Btn("Set", $"Set the {v.Name.ToLowerInvariant()} to what is chosen (2Ch {v.Key:X2}h n).", async () => await RemoteSet(rv)),
                Btn("Clear", $"Back to {v.Zero} (2Ch {v.Key:X2}h 00h).", async () => await RemoteClear(rv)),
                Btn("Read", $"Read what the ECU has now (2Bh {v.Key:X2}h).", async () => await RemoteRead(rv)));
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            v.Now.Margin = new Thickness(0, 0, 0, 8);
            v.Now.FontSize = 12;
            v.Now.TextWrapping = TextWrapping.Wrap;
            Cell(v.Now, 1, 5);
            row++;
            _remoteControls.Add(v.Editor);
        }
        ToolTip.SetTip(_password, "A password, 0-65535: the main one runs the engine as tuned, the guest one in valet mode (the Serial port page).");
        _remoteControls.Add(_password);
        Line("Password", _password, "",
            Btn("Unlock", "Send the password (2Fh, high byte, low byte): the main one starts the engine as tuned, the guest one in valet mode.", async () =>
            {
                if (!int.TryParse((_password.Text ?? "").Trim(), out var pw) || pw < 0 || pw > 65535) { _status.Text = "the password is a number 0-65535"; return; }
                await Remote([TroubleCodes.Password, (byte)(pw >> 8), (byte)pw], "the password");
            }),
            Btn("Lock", "Lock it again (2Eh): the engine stops and will not start until a password is sent.", async () =>
            {
                if (!await Dialogs.Confirm(this, "Lock the engine?", "The engine stops straight away and will not start until a password is sent. Only lock a car that is standing still.", "Lock", "Not now")) return;
                await Remote([TroubleCodes.RemoteLock], "locked");
            }));
        var normal = Btn("Remote: all back to normal", "The fan to the ECU and every value below the tune's own again, popcorn off (2Dh). The lock and valet mode stay.",
            async () => await Remote([TroubleCodes.RemoteNormal], "remote back to normal"));

        var box = new StackPanel { Spacing = 4 };
        box.Children.Add(new TextBlock { Text = "REMOTE CONTROL", FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 10, 0, 2) });
        box.Children.Add(_remoteInfo);
        box.Children.Add(Row([.. _fan, _popcorn]));
        box.Children.Add(grid);
        normal.MinHeight = 44;
        Grid.SetColumnSpan(normal, 2);
        box.Children.Add(Row(normal));
        ShowRemote();
        box.Children.Add(new TextBlock
        {
            Text = "The commands a remote panel sends (the remote control module, Added features > Serial port page). What is typed is what is set; Clear puts the tune's own back, and a value not set shows the tune's own. Everything set here is forgotten at the next key-on. The command list is in the documentation (Remote control).",
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.7,
        });
        return box;
    }

    /// The remote commands are offered on a skeleton ROM built with them, or on the channel stream (the ROM answers 7Fh when it has not).
    bool RemoteAllowed() => _host.Defs().Find("RemoteEnable") != null || _engine.Protocol is ChannelStream { HasRemote: true };

    async Task RemoteSet(RemoteValue v)
    {
        int b = v.Combo != null ? Math.Max(0, v.Combo.SelectedIndex) : Math.Clamp(v.ToByte((double)(v.Box!.Value ?? 0)), 1, 255);
        await Remote([TroubleCodes.KeySet, v.Key, (byte)b], v.Name.ToLowerInvariant());
    }

    async Task RemoteClear(RemoteValue v) => await Remote([TroubleCodes.KeySet, v.Key, 0], v.Name.ToLowerInvariant() + ": the tune's own");

    async Task RemoteRead(RemoteValue v)
    {
        if (_busy) return;
        _busy = true;
        try { await ReadValue(v, fill: true); }
        finally { _busy = false; ShowRemote(); }
    }

    /// What the ECU has for a value; with `fill` its box shows it - the tune's own value when nothing is set (0).
    async Task ReadValue(RemoteValue v, bool fill)
    {
        var (a, note) = await _engine.Command([TroubleCodes.KeyRead, v.Key]);
        if (a is byte b && b != TroubleCodes.Refused)
        {
            v.Have = b;
            if (fill) Fill(v, b);
        }
        else { v.Have = null; if (a == null) _status.Text = $"{v.Name}: {note}"; }
    }

    static void Fill(RemoteValue v, int b)
    {
        double? shown = b != 0 ? (v.Combo != null ? b : v.FromByte(b)) : v.Tune();
        if (v.Combo != null) v.Combo.SelectedIndex = shown is double c ? Math.Clamp((int)c, 0, v.Choices!.Length - 1) : 0;
        else if (v.Box != null)
        {
            double x = shown ?? 0;
            v.Box.Value = (decimal)Math.Clamp(x, (double)v.Box.Minimum, (double)v.Box.Maximum);
        }
    }

    async Task Remote(byte[] msg, string what)
    {
        if (_busy || _syncing) return;
        _busy = true;
        try
        {
            var (answer, note) = await _engine.Command(msg);
            if (answer == null) _status.Text = $"{what}: {note}";
            else if (answer == TroubleCodes.Refused)
            {
                _status.Text = msg[0] == TroubleCodes.Password ? "wrong password (7Fh): the engine stays locked" : $"{what}: the ROM cannot (7Fh) - the remote control module is not built in, or not enabled";
                AppLog.Warn("remote", $"{msg[0]:X2} refused");
            }
            else
            {
                _status.Text = msg[0] == TroubleCodes.Password ? (answer == 0x81 ? "unlocked: valet mode (the guest password)" : "unlocked: as tuned (the main password)") : $"{what}: done ({answer:X2})";
                AppLog.Action("remote", $"{what}: {(msg[0] == TroubleCodes.Password ? "2F ** **" : string.Join(" ", msg.Select(b => b.ToString("X2"))))} -> {answer:X2}");
            }
        }
        finally { _busy = false; }
        await ReadRemote(fill: msg.Length > 1 || msg[0] == TroubleCodes.RemoteNormal);
    }

    /// What the ROM has now: the state and every value set (on opening, and after each command).
    async Task ReadRemote(bool fill = true)
    {
        if (_busy) return;
        _busy = true;
        try
        {
            var (st, _) = await _engine.Command(TroubleCodes.RemoteState);
            if (st is not byte s || s == TroubleCodes.Refused) { _remote = null; return; }
            _remote = TroubleCodes.RemoteStateBits.From(s);
            foreach (var v in _values) await ReadValue(v, fill);
        }
        finally { _busy = false; ShowRemote(); }
    }

    void ShowRemote()
    {
        _syncing = true;
        var r = _remote;
        Mark(_fan[0], r is { FanForced: false });
        Mark(_fan[1], r is { FanForced: true, FanOn: true });
        Mark(_fan[2], r is { FanForced: true, FanOn: false }, Active);
        Mark(_popcorn, r?.Popcorn == true, Active);
        foreach (var v in _values)
        {
            v.Now.Text = !v.Here ? "not in the ROM open here"
                : v.Have is not int b ? ""
                : b == 0 ? $"now: {v.Zero}" + (v.Tune() is double t ? $" ({(v.Combo != null ? v.Choices![Math.Clamp((int)t, 0, v.Choices.Length - 1)] : $"{t:0.##} {v.Unit}".TrimEnd())})" : "")
                : $"now: {(v.Combo != null ? v.Choices![Math.Clamp(b, 0, v.Choices.Length - 1)] : $"{v.FromByte(b):0.##} {v.Unit}".TrimEnd())}";
        }
        _remoteInfo.Text = r == null ? (_engine.Running ? "No answer to 3Fh: the remote control module is not in the ROM, or not enabled." : "Connect the datalog to use these.")
            : r.LockedNow ? "LOCKED: the engine will not run until a password is sent."
            : r.Valet ? "Unlocked: VALET MODE (the guest password) - its rev limit, speed limit and timing."
            : "Unlocked: as tuned.";
        if (r is { LockedNow: true } or { Valet: true }) _remoteInfo.Foreground = Active; else _remoteInfo.ClearValue(TextBlock.ForegroundProperty);
        _syncing = false;
    }

    /// A toggle that shows what the ECU has now: lit (the theme's accent) when it is in use, red for what stops or holds the
    /// engine (injectors off, timing locked, fan held off, popcorn), the window's normal button when not.
    static void Mark(ToggleButton b, bool on, IBrush? color = null)
    {
        b.IsChecked = on;
        b.Classes.Set("danger", color == Active);
        b.ClearValue(TemplatedControl.BackgroundProperty);
        b.ClearValue(TemplatedControl.ForegroundProperty);
    }

    /// Checked "danger" toggles red, hovered or not (the theme would paint every checked toggle its accent colour).
    void DangerStyles()
    {
        foreach (var hover in new[] { false, true })
        {
            var style = new Style(x =>
            {
                var sel = x.OfType<ToggleButton>().Class("danger").Class(":checked");
                if (hover) sel = sel.Class(":pointerover");
                return sel.Template().OfType<ContentPresenter>().Name("PART_ContentPresenter");
            });
            style.Setters.Add(new Setter(ContentPresenter.BackgroundProperty, hover ? AppTheme.Brush(Color.FromRgb(0xD8, 0x40, 0x40)) : Active));
            style.Setters.Add(new Setter(ContentPresenter.ForegroundProperty, Brushes.White));
            Styles.Add(style);
        }
    }

    // ---------------------------------------------------------------- ECU memory (the memory read module)
    readonly TextBox _memAddr = new() { Text = "3F8", Width = 70, FontFamily = MainWindow.MonoFont, FontSize = 13, VerticalContentAlignment = VerticalAlignment.Center };
    readonly ToggleButton _memWatch = new() { Content = "Watch", MinHeight = 34, MinWidth = 80, FontSize = 13, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
    readonly TextBlock _memDump = new() { FontFamily = MainWindow.MonoFont, FontSize = 12.5, TextWrapping = TextWrapping.NoWrap };
    readonly DispatcherTimer _memTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    byte[]? _memLast;
    int _memLastAt = -1;

    /// 32 bytes of the car's ECU RAM, read over the datalog cable while it runs (the skeleton ROM's memory read module): a byte that changed since the last read is marked.
    Control MemoryBox()
    {
        var read = new Button { Content = "Read", MinHeight = 34, MinWidth = 80, FontSize = 13, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(_memAddr, "The first RAM address, in hex (80-460): module RAM is 3F8 with the stock trouble codes built in, 31A without.");
        ToolTip.SetTip(read, "Read the 32 bytes from that address now.");
        ToolTip.SetTip(_memWatch, "Read them twice a second while this is down.");
        read.Click += async (_, _) => await ReadMemory();
        _memWatch.IsCheckedChanged += (_, _) => { if (_memWatch.IsChecked == true) _memTimer.Start(); else _memTimer.Stop(); };
        _memTimer.Tick += async (_, _) => { if (!_memBusy) await ReadMemory(); };
        Closed += (_, _) => _memTimer.Stop();
        var box = new StackPanel { Spacing = 4 };
        box.Children.Add(new TextBlock { Text = "ECU MEMORY", FontWeight = FontWeight.Bold, FontSize = 12, Opacity = 0.8, Margin = new Thickness(0, 10, 0, 2) });
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(new TextBlock { Text = "Address", VerticalAlignment = VerticalAlignment.Center, FontSize = 13 });
        row.Children.Add(_memAddr);
        row.Children.Add(read);
        row.Children.Add(_memWatch);
        box.Children.Add(row);
        box.Children.Add(_memDump);
        box.Children.Add(new TextBlock
        {
            Text = "Any RAM byte on the car, read between datalog frames: needs the channel stream and the ROM's memory read module. The ROM itself is never read.",
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.7,
        });
        return box;
    }

    bool _memBusy;

    async Task ReadMemory()
    {
        if (_memBusy) return;
        if (!int.TryParse((_memAddr.Text ?? "").Trim().TrimEnd('h', 'H'), System.Globalization.NumberStyles.HexNumber, null, out var addr))
        { _status.Text = "the address is hex: 3F8, 31A..."; return; }
        _memBusy = true;
        try
        {
            var (data, note) = await _engine.ReadMemory(addr);
            if (data == null) { _status.Text = "ECU memory: " + note; _memWatch.IsChecked = false; return; }
            var sb = new System.Text.StringBuilder();
            for (int r = 0; r < data.Length; r += 8)
            {
                sb.Append($"{addr + r:X3}h  ");
                for (int i = r; i < r + 8 && i < data.Length; i++)
                {
                    bool changed = _memLast != null && _memLastAt == addr && _memLast.Length == data.Length && _memLast[i] != data[i];
                    sb.Append(data[i].ToString("X2")).Append(changed ? '*' : ' ');
                }
                sb.Append('\n');
            }
            _memDump.Text = sb.ToString().TrimEnd();
            bool again = _memLastAt == addr;
            _memLast = data; _memLastAt = addr;
            _status.Text = $"ECU memory {addr:X3}h-{addr + 31:X3}h read at {DateTime.Now:HH:mm:ss}" + (again ? " (* changed since the last read)" : "");
        }
        finally { _memBusy = false; }
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
        bool waitingAfterClear = f != null && ReferenceEquals(f, _beforeClear);
        if (waitingAfterClear) f = null;
        else _beforeClear = null;
        bool live = _engine.Running && _engine.Fresh && f != null;
        var bytes = f != null ? TroubleCodes.Bytes(f) : null;
        var codes = bytes != null ? TroubleCodes.Decode(bytes) : [];
        bool flashing = _state?.Any == true;
        bool lit = f?.Get("cel") is double cel ? cel != 0 : codes.Count > 0;
        _lamp.Fill = flashing ? (_tick / 2 % 2 == 0 ? LampOn : LampOff) : lit && live ? LampOn : LampOff;
        _lampText.Text = waitingAfterClear ? "Codes cleared: the lamp is off. Waiting for the ECU's next frame to confirm."
            : !_engine.Running ? "Not logging: connect the datalog (Datalogging menu) to read the codes."
            : !live ? "Waiting for frames from the ECU…"
            : flashing ? "Service mode: the lamp flashes quickly on the car" + (_state!.InjectorsOff ? " - injectors OFF" : "") + (_state.TimingLocked ? " - timing LOCKED" : "")
            : bytes == null ? "This datalog does not carry the codes (with the channel stream, tick the Trouble codes channel)."
            : codes.Count == 0 ? "Check engine lamp off: no codes stored."
            : $"Check engine lamp on: {codes.Count} code{(codes.Count == 1 ? "" : "s")} stored.";
        string key = waitingAfterClear ? "cleared" : bytes == null ? "-" : string.Join(",", codes);
        if (key != _codesKey)
        {
            _codesKey = key;
            _codes.Children.Clear();
            if (codes.Count == 0) _codes.Children.Add(new TextBlock { Text = waitingAfterClear ? "none (cleared)" : bytes == null ? "(not in the datalog)" : "none", Opacity = 0.6, FontSize = 13 });
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
        bool remote = connected && RemoteAllowed();
        foreach (var b in _remoteControls) b.IsEnabled = remote && !_busy;
        foreach (var v in _values.Where(v => !v.Here)) v.Editor.IsEnabled = false;
        var timing = _host.Defs().Find("DatalogServiceTiming");
        string at = "";
        if (timing != null) try { at = $" at {RomData.Read(_host.Defs(), _host.RomCopy(), timing)[0].Value:0.#}°"; } catch { }
        if (_lock.Content is TextBlock lockText) Named(_lock, lockText.Text = "Lock timing" + at);
        _serviceNote.Text = !connected ? "Connect the datalog to use these." : allowed
            ? "A key cycle puts everything back to normal. The timing it locks at is set on Added features > Serial port."
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
        Mark(_inj, s?.InjectorsOff == true, Active);
        Mark(_lock, s?.TimingLocked == true, Active);
        for (int i = 0; i < _maps.Length; i++) Mark(_maps[i], _maps[i].IsChecked == true);
        for (int i = 0; i < 4; i++) Mark(_gio[i], s?.GioForced[i] == true);
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
                if (!quiet) _status.Text = cmd == TroubleCodes.ClearCodes ? "codes cleared - the lamp goes off as the ECU restarts" : $"{what}: done ({answer:X2})";
                if (cmd == TroubleCodes.ClearCodes)
                {
                    _beforeClear = _engine.Latest;
                    // the simulator's lamp watcher starts again too: no flash rounds left over from the codes that are gone
                    try { _host.Sim.Mil.Reset(); } catch { }
                }
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
