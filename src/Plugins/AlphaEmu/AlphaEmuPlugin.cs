// Copyright (c) bmgjet. All rights reserved.
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using OkiRomSim.Calibration;
using OkiRomSim.Desktop;

namespace AlphaEmuPlugin;

/// ALPHAemu, ported to Rom Sim Studio: the emulator workflow the ALPHAlink utility drove - a link to the
/// ALPHA NextGEN (USB, a Bluetooth bridge, or the plugin's own simulated device), a multi-map manager
/// that stages / writes / verifies / commits each slot, eight analog inputs with a wideband sensor model
/// behind them, real-time byte patches from the table editor into the running image, a datalog feed the
/// app's own gauges and graph record, snapshots with a working recovery, trouble codes, datalog insights
/// and a command palette - on top of the ROM, definitions and simulator this app already has.
///
/// It adds, and does not replace: the datalog frames are fed in through DatalogEngine, so the app's
/// gauges, graph, recording and map trace work off them; table edits go in through Sim.WriteCells, so
/// undo and the checksum still apply; and the parameters page is a normal calibration page that binds to
/// whichever definitions this ROM has.
public sealed class AlphaEmuPlugin : IOkiPlugin
{
    public string Name => "ALPHAemu";
    public string Description => "The ALPHAemu workflow: ALPHA NextGEN link (USB or a Bluetooth bridge; a simulated device only when switched on in Device), multi-map slots with stage / write / verify / commit, eight analog inputs and a wideband sensor model, real-time table patches, a datalog feed for the gauges and graph, snapshots and recovery, trouble codes and datalog insights.";
    public string Version => "1.0";

    AlphaHub _hub = null!;
    PluginContext _app = null!;
    AlphaConsole? _tab;
    KeyBinding? _keys;

    public void Start(PluginContext app)
    {
        _app = app;
        var state = AlphaState.Load(app.DataFolder);
        state.Root = app.DataFolder;
        state.RestoreStaged();
        state.Sanitise();
        _hub = new AlphaHub(app, state);

        // ---- the workbench tab, and the same console in a window
        _tab = new AlphaConsole(_hub);
        app.AddTab("ALPHAemu", _tab, "The ALPHAemu console: link, slots, analog inputs, real-time update, snapshots, diagnostics.");
        app.AddToolbarButton("🄰", "ALPHAemu", "Open the ALPHAemu console in a window of its own (the tab has the same thing).", _hub.OpenConsole);

        // ---- the Plugins menu (connect, disconnect and real-time update are on the app's own Emulator menu, which ALPHAemu drives)
        app.AddMenuItem("ALPHAemu console…", _hub.OpenConsole, "The whole console: overview, multi-map, analog inputs, wideband, snapshots, diagnostics, device, log.", "🄰");
        app.AddMenuItem("Multi-map manager…", () => _hub.OpenScreen("Multi-map"), "Stage a calibration per slot, then write, verify, commit and deploy.", "🗂");
        app.AddMenuItem("Analog inputs…", () => _hub.OpenScreen("Analog inputs"), "The eight ALPHAemu inputs: roles, live readings and where they go.", "🎚");
        app.AddMenuItem("Wideband sensor…", _hub.OpenWideband, "Factory volt-to-lambda curves or a custom one, with stoich and offset.", "≈");
        app.AddMenuItem("Snapshots and recovery…", () => _hub.OpenScreen("Snapshots"), "Saved calibrations, what differs between them, and the working recovery.", "⏱");
        app.AddMenuItem("Trouble codes and insights…", () => _hub.OpenScreen("Diagnostics"), "Codes the emulator and the simulated ECU hold, session checks, datalog insights.", "⚠");
        app.AddMenuItem("Device, real-time and firmware…", () => _hub.OpenScreen("Device"), "Transport, port, identity, real-time settings and the firmware.", "⚙");
        app.AddMenuItem("Session log…", () => _hub.OpenScreen("Log"), "Every command the link sent and what the device answered.", "📜");
        app.AddMenuItem("Command palette", () => new AlphaPalette(_hub).Show(), "Type what you want to do and press Enter (Ctrl+Alt+A).", "🔍");

        // ---- the settings page
        app.AddSettingsPage("ALPHAemu", SettingsPage);

        // ---- a calibration page of its own, bound like any other feature page
        app.AddCalibrationPage(Parameters);
        app.AddPageSection(Parameters.Key, _ => Section());

        // ---- the app's Emulator and Datalogging controls are ALPHAemu's while the plugin is enabled
        app.TakeOverEmulator(new AlphaTakeover(_hub));
        _hub.Session.Changed += app.EmulatorChanged;

        // ---- a ROM opened: snapshot it, and say so
        app.RomLoaded += path => _app.Ui(() => _hub.RomLoaded(path));

        // ---- Ctrl+Alt+A for the palette, for as long as the plugin is loaded
        _keys = new KeyBinding { Gesture = new KeyGesture(Key.A, KeyModifiers.Control | KeyModifiers.Alt), Command = new RelayCommand(() => new AlphaPalette(_hub).Show()) };
        app.Window.KeyBindings.Add(_keys);

        // on start-up only to a device there is: the real one's port, or the simulation when it is switched on
        if (state.AutoConnect && state.CanConnect) _app.Ui(() => _hub.Connect());
        _app.Log($"ALPHAemu {_hub.State.Transport} · {AlphaState.Bytes(_hub.RomSize())} images · slots "
               + string.Join(", ", _hub.State.Slots.Select(s => s.Loaded ? $"{s.Id}:{s.ShortSha}" : $"{s.Id}:-")));
    }

    // ---------------------------------------------------------------- the settings page

    Control SettingsPage()
    {
        var s = _hub.State;
        var p = new StackPanel { Spacing = 8, Margin = new Thickness(10) };
        p.Children.Add(Alpha.Body("How ALPHAemu reaches the emulator, what it feeds the app, and what it remembers. Everything here is also on the console's own screens.", 12));

        var transport = new ComboBox { ItemsSource = new List<string> { "USB serial to the emulator", "Bluetooth serial bridge" }, SelectedIndex = (int)s.Transport, Width = 260 };
        transport.SelectionChanged += (_, _) => { if (transport.SelectedIndex >= 0) { s.Transport = (AlphaTransport)transport.SelectedIndex; _hub.SaveSoon(); } };
        var ports = Ports();
        var port = new ComboBox { ItemsSource = ports, Width = 170, SelectedItem = ports.Contains(s.Port) ? s.Port : null };
        port.SelectionChanged += (_, _) => { if (port.SelectedItem is string ps) { s.Port = ps; _hub.SaveSoon(); } };
        var refresh = Alpha.Ghost("↻", () => { var again = Ports(); port.ItemsSource = again; }, "Look for serial ports again.");
        var baud = Box(s.Baud, 90); baud.LostFocus += (_, _) => { if (int.TryParse(baud.Text, out var b)) { s.Baud = b; _hub.SaveSoon(); } };
        var hz = Box(s.DatalogHz, 60); hz.LostFocus += (_, _) => { if (int.TryParse(hz.Text, out var h)) { s.DatalogHz = Math.Clamp(h, 1, 100); _hub.SaveSoon(); } };
        var poll = Box(s.AnalogPollMs, 60); poll.LostFocus += (_, _) => { if (int.TryParse(poll.Text, out var ms)) { s.AnalogPollMs = ms; _hub.SaveSoon(); } };
        var delay = Box(s.RealtimeDelayMs, 60); delay.LostFocus += (_, _) => { if (int.TryParse(delay.Text, out var d)) { s.RealtimeDelayMs = d; _hub.SaveSoon(); } };
        var patch = Box(s.MaxPatchBytes, 80); patch.LostFocus += (_, _) => { if (int.TryParse(patch.Text, out var pb)) { s.MaxPatchBytes = pb; _hub.SaveSoon(); } };
        var attempts = Box(s.ReconnectAttempts, 60); attempts.LostFocus += (_, _) => { if (int.TryParse(attempts.Text, out var a)) { s.ReconnectAttempts = a; _hub.SaveSoon(); } };
        var rdelay = Box(s.ReconnectDelayMs, 70); rdelay.LostFocus += (_, _) => { if (int.TryParse(rdelay.Text, out var r)) { s.ReconnectDelayMs = r; _hub.SaveSoon(); } };
        var maxSnaps = Box(s.MaxSnapshots, 60); maxSnaps.LostFocus += (_, _) => { if (int.TryParse(maxSnaps.Text, out var m)) { s.MaxSnapshots = m; _hub.SaveSoon(); } };

        p.Children.Add(Alpha.Divider());
        p.Children.Add(Alpha.Row("Transport", transport, 190, "How the laptop reaches the ALPHA NextGEN. (A simulated device, for trying the screens with nothing plugged in, is switched on on the Device page.)"));
        var portRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        portRow.Children.Add(new TextBlock { Text = "Serial port", Width = 190, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
        portRow.Children.Add(port); portRow.Children.Add(refresh);
        p.Children.Add(portRow);
        p.Children.Add(Alpha.Row("Baud", baud, 190, "The emulator bridge's rate (921600 on the ALPHA NextGEN)."));
        p.Children.Add(Alpha.Row("Datalog rate", hz, 190, "Frames a second the emulator streams, and the plugin hands to the Datalog page."));
        p.Children.Add(Alpha.Check("Send the frames to the Datalog page", s.FeedDatalog, on => { s.FeedDatalog = on; _hub.SaveSoon(); },
            "Off leaves the app's own datalog connection alone; the console still traces what the emulator sends."));
        p.Children.Add(Alpha.Check("Also drive the simulated ECU with the frames", s.DriveSimulator, on => { s.DriveSimulator = on; _hub.SaveSoon(); },
            "Each frame is also applied to the simulator's inputs, so the ROM under test sees what the emulator is logging."));
        p.Children.Add(Alpha.Row("Analog poll", poll, 190, "How often the eight inputs are read (100 ms is what ALPHAlink used)."));
        p.Children.Add(Alpha.Check("Drive the simulator's inputs from the analog inputs", s.AnalogToSimulator, on => { s.AnalogToSimulator = on; _hub.SaveSoon(); }));
        p.Children.Add(Alpha.Divider());
        p.Children.Add(Alpha.Row("Patch after a change sits for", delay, 190, "How long the plugin waits after the last edit before sending, so a drag does not send every intermediate value."));
        p.Children.Add(Alpha.Row("Biggest patch", patch, 190, "Bytes per real-time patch request (2048 is what ALPHAlink allowed)."));
        p.Children.Add(Alpha.Check("Turn real-time update on when the link comes up", s.AutoRealtime, on => { s.AutoRealtime = on; _hub.SaveSoon(); }));
        p.Children.Add(Alpha.Check("Ask before writing the slot that is running", s.ConfirmActiveSlot, on => { s.ConfirmActiveSlot = on; _hub.SaveSoon(); }));
        p.Children.Add(Alpha.Divider());
        p.Children.Add(Alpha.Check("Connect on start-up", s.AutoConnect, on => { s.AutoConnect = on; _hub.SaveSoon(); }));
        p.Children.Add(Alpha.Row("Reconnect tries", attempts, 190, "How many times a lost link is tried again before giving up (the app's own link supervisor does the waiting)."));
        p.Children.Add(Alpha.Row("Reconnect wait", rdelay, 190, "Milliseconds between those tries."));
        p.Children.Add(Alpha.Check("Watch the datalog for things worth pointing out", s.InsightsEnabled, on => { s.InsightsEnabled = on; _hub.SaveSoon(); },
            "Lean under boost, injector duty, the limiter, temperatures, battery, a dead O2 line, fuel cut and VTEC."));
        p.Children.Add(Alpha.Check("Take a snapshot before deploying", s.AutoSnapshotOnDeploy, on => { s.AutoSnapshotOnDeploy = on; _hub.SaveSoon(); }));
        p.Children.Add(Alpha.Row("Keep this many snapshots", maxSnaps, 190));
        p.Children.Add(Alpha.Divider());
        var forget = Alpha.Danger("Forget everything ALPHAemu remembers", () =>
        {
            _hub.Session.Disconnect();
            try
            {
                foreach (var f in Directory.GetFiles(_hub.Folder, "*", SearchOption.AllDirectories)) try { File.Delete(f); } catch { }
            }
            catch { }
            _app.SetStatus("ALPHAemu's settings, staged slots and snapshots are deleted - reload the plugin to start clean");
        }, "Deletes the plugin's settings, staged map slots, snapshots and logs. Nothing else is touched.");
        p.Children.Add(forget);
        p.Children.Add(Alpha.Note("everything ALPHAemu keeps lives in " + _hub.Folder));
        return new ScrollViewer { Content = p, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    static List<string> Ports() { try { return [.. SerialLink.Ports()]; } catch { return []; } }
    static TextBox Box(int value, double width) => new() { Text = value.ToString(CultureInfo.InvariantCulture), Width = width, FontSize = 12 };

    // ---------------------------------------------------------------- the calibration page

    /// The settings ALPHAlink kept on its "ECU Parameters" tab, as a normal calibration page: each row
    /// is bound to whichever definition of this ROM fits, and remembered in the ROM's own slots.
    static readonly CalPage Parameters = new("alphaemu", "ALPHAemu parameters", "ALPHAemu",
        "The limits and activations ALPHAemu's parameter tab kept together. Bind each row to this ROM's "
        + "definitions the same way every other feature page does (the guess is from the definition names); "
        + "with real-time update on, a change here goes to the running image as soon as you make it.",
        [
            new PageGroup("Limits",
            [
                new PageRow("alphaemu.revlimit", "Hard rev limit", RowKind.Value, "rpm", "Where the limiter comes in.", ["revlimit", "rev", "limiter", "rpm limit"]),
                new PageRow("alphaemu.launch", "Launch control limit", RowKind.Value, "rpm", "The ceiling launch control holds.", ["launch", "launchcontrol"]),
                new PageRow("alphaemu.boostcut", "Boost cut threshold", RowKind.Value, "psi", "Boost above this cuts fuel.", ["boostcut", "boost", "cut"]),
                new PageRow("alphaemu.idle", "Idle target", RowKind.Value, "rpm", "The rpm the idle control aims at.", ["idletarget", "idle", "iacv target"]),
            ]),
            new PageGroup("VTEC",
            [
                new PageRow("alphaemu.vtec.enable", "VTEC enabled", RowKind.Switch, Tip: "Off leaves the solenoid alone however the rest is set.", Guess: ["vtecenable", "vtecon", "vtec enabled"]),
                new PageRow("alphaemu.vtec.rpm", "VTEC engagement", RowKind.Value, "rpm", "The lowest rpm VTEC may come on at.", ["vtecrpm", "vtecengage", "vtec"]),
                new PageRow("alphaemu.vtec.ect", "VTEC coolant gate", RowKind.Value, "°C", "Below this temperature VTEC stays off.", ["vtec ect", "vtec temp", "vtecwater"]),
            ]),
            new PageGroup("Outputs the console watches",
            [
                new PageRow("alphaemu.mil", "MIL (check engine)", RowKind.Switch, Tip: "The dash lamp the console shows as an LED.", Guess: ["mil", "check engine", "milton"]),
                new PageRow("alphaemu.fuelcut", "Fuel cut flag", RowKind.Switch, Tip: "Shown as FC on the console.", Guess: ["fuelcut", "ftl", "cutfuel"]),
            ]),
        ]);

    /// A small strip at the bottom of that page, so the emulator is never far away while tuning it.
    Control? Section()
    {
        var line = new TextBlock { FontSize = 11.5, Foreground = Alpha.Dim, TextWrapping = TextWrapping.Wrap };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        timer.Tick += (_, _) =>
        {
            var s = _hub.Session;
            line.Text = s.RealtimeEnabled
                ? $"real-time update is {(s.Synced ? "armed" : "waiting for a baseline against the emulator's running image")} · {s.PatchesSent:N0} patch events, {s.PatchBytesSent:N0} bytes sent"
                : "real-time update is off - changes here wait for a deploy (or turn it on with ⚡ on the bar)";
        };
        var panel = new StackPanel { Spacing = 5, Margin = new Thickness(0, 8, 0, 0) };
        panel.Children.Add(line);
        panel.Children.Add(Wrap(Alpha.Ghost("Open the ALPHAemu console", _hub.OpenConsole, "The whole console, in a window."),
                                Alpha.Ghost("Deploy maps", () => _hub.Maps().DeployRequested(), "Write, verify and commit every staged slot.")));
        // the timer goes when the page does: a page section is rebuilt every time the page is shown
        panel.DetachedFromVisualTree += (_, _) => timer.Stop();
        panel.AttachedToVisualTree += (_, _) => timer.Start();
        return panel;
    }

    static WrapPanel Wrap(params Control[] items)
    {
        var w = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 8, LineSpacing = 8 };
        foreach (var i in items) w.Children.Add(i);
        return w;
    }

    public void Stop()
    {
        try { if (_keys != null) _app.Window.KeyBindings.Remove(_keys); } catch { }
        try { _hub?.Close(); } catch { }      // stops the timers, closes the screens, ends the datalog feed and saves the state
    }
}



